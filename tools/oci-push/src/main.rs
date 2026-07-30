//! oci-push — push a Nix-produced OCI image tarball (`docker-archive`) to an
//! OCI registry.
//!
//! Typed replacement for the host-nix skopeo bash that previously lived inline
//! in substrate's `image-push.yml`. Per the pleme-io NO-SHELL law + "acquire
//! and contextualize, never just consume": skopeo is *absorbed* into a pleme-io
//! primitive. The workflow step collapses to a single
//! `nix run github:pleme-io/substrate#oci-push -- …`.
//!
//! # Backends — same semantics draped over each
//!
//! The push *intent* — "copy this `docker-archive` tarball to
//! `<registry>/<image>:<tag>` for each requested tag, with these credentials"
//! — is backend-agnostic ([`PushBackend`] / [`PushSpec`]). Concrete backends:
//!
//! * [`NativeBackend`] (**default**, `--backend native`): pure-Rust OCI
//!   distribution push built on the fleet's `oci-client` crate (the same one
//!   wasm-platform uses). Reads the docker-archive, gzips each layer, hands the
//!   gzipped layers + verbatim config to `oci-client`, which uploads the blobs
//!   and PUTs the manifest. No external binary.
//! * [`SkopeoBackend`] (`--backend skopeo`): shells out to `skopeo copy`.
//!   Fallback / escape hatch; supplied on `PATH` by the flake wrapper.
//!
//! ## The two digest spaces (why native is correct)
//!
//! Nix `dockerTools` stores layers UNCOMPRESSED (`layer.tar`); the image config
//! already carries the right `rootfs.diff_ids` (sha256 of the *uncompressed*
//! bytes). A registry manifest references layers by the sha256 of the
//! *compressed* (gzip) blob. We therefore gzip each layer and pass the gzipped
//! bytes to `oci-client` (which digests exactly what it uploads → correct
//! manifest layer digests), while passing the config verbatim (preserving its
//! `diff_ids`). The two spaces never cross.
//!
//! TYPED-EMISSION: no `std::format!()`. Errors are a typed enum whose `Display`
//! is the only render surface (`write!` allowed there); the skopeo argv is
//! built via `Command::arg`; the OCI reference is built by `oci-client`'s typed
//! `Reference`.

use std::collections::HashMap;
use std::env;
use std::fmt;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use flate2::Compression;
use oci_client::client::{
    Certificate, CertificateEncoding, ClientConfig, ClientProtocol, Config as OciBlobConfig,
    ImageLayer,
};
use oci_client::manifest::OciImageManifest;
use oci_client::secrets::RegistryAuth;
use oci_client::{Client, Reference};
use serde::{Deserialize, Serialize};

/// OCI media types — used consistently (config + layer + manifest all OCI) so
/// no Docker/OCI mixing trips the registry.
const MT_CONFIG: &str = "application/vnd.oci.image.config.v1+json";
const MT_LAYER_GZIP: &str = "application/vnd.oci.image.layer.v1.tar+gzip";
const MT_MANIFEST: &str = "application/vnd.oci.image.manifest.v1+json";

/// HTTP for local registries (localhost / loopback, with or without a port),
/// HTTPS otherwise. A local test rig speaks plain HTTP; public registries
/// (ghcr.io) and a properly-TLS'd in-cluster registry speak HTTPS -- see
/// `--dest-ca-cert` for pinning a self-signed in-cluster cert rather than
/// falling back to `--insecure` (plain HTTP).
fn protocol_for(registry: &str) -> ClientProtocol {
    let host = registry.split('/').next().unwrap_or(registry);
    let bare = host.split(':').next().unwrap_or(host);
    if bare == "localhost" || bare == "127.0.0.1" || bare == "::1" {
        ClientProtocol::Http
    } else {
        ClientProtocol::Https
    }
}

/// Shared client-config builder for every subcommand that talks to a
/// registry: `insecure` forces plain HTTP (an explicit escape hatch, never
/// the default); `ca_cert_path` pins a specific PEM certificate as an
/// EXTRA trusted root (real verification against a known cert, never a
/// blanket "accept any certificate" toggle -- that option is deliberately
/// not exposed here).
fn client_config_for(
    registry: &str,
    insecure: bool,
    ca_cert_path: &Option<String>,
) -> Result<ClientConfig, PushError> {
    let extra_root_certificates = match ca_cert_path {
        Some(path) => {
            let pem = fs::read(path).map_err(|source| PushError::ReadCaCert {
                path: path.clone(),
                source,
            })?;
            vec![Certificate {
                encoding: CertificateEncoding::Pem,
                data: pem,
            }]
        }
        None => Vec::new(),
    };
    let protocol = if insecure {
        ClientProtocol::Http
    } else {
        protocol_for(registry)
    };
    Ok(ClientConfig {
        protocol,
        extra_root_certificates,
        ..Default::default()
    })
}

/// A ClientConfig pinned to an explicit os/arch.
///
/// Without this, resolving a multi-arch index uses the CLIENT's own platform,
/// so the same command answers differently depending on which runner it lands
/// on, and fails outright on a host whose platform the index does not carry.
/// skopeo has always had `--override-os` / `--override-arch` for this reason,
/// and a promotion pipeline that reads a version off a linux/amd64 index must
/// say so rather than inherit whatever the runner happens to be.
fn client_config_for_platform(
    registry: &str,
    insecure: bool,
    ca_cert_path: &Option<String>,
    os: &str,
    arch: &str,
) -> Result<ClientConfig, PushError> {
    let base = client_config_for(registry, insecure, ca_cert_path)?;
    let want_os = os.to_string();
    let want_arch = arch.to_string();
    Ok(ClientConfig {
        platform_resolver: Some(Box::new(move |entries| {
            entries
                .iter()
                .find(|e| {
                    e.platform.as_ref().is_some_and(|p| {
                        p.os == want_os && p.architecture == want_arch
                    })
                })
                .map(|e| e.digest.clone())
        })),
        ..base
    })
}

/// Typed failure modes. The `Display` impl is the single render surface.
#[derive(Debug)]
enum PushError {
    MissingArg(&'static str),
    MissingValue(&'static str),
    UnknownFlag(String),
    UnknownBackend(String),
    NoSubcommand,
    UnknownSubcommand(String),
    Json(serde_json::Error),
    ConfigParse(serde_yaml::Error),
    OciPull { reference: String, detail: String },
    LabelAbsent { reference: String, label: String },
    NotImplemented(&'static str),
    ReadTarball { path: String, source: std::io::Error },
    Archive(std::io::Error),
    NoManifestJson,
    UnsupportedCompressor(&'static str),
    ManifestParse(serde_json::Error),
    EmptyManifest,
    MissingEntry(String),
    Gzip(std::io::Error),
    Runtime(std::io::Error),
    Reference { reference: String, detail: String },
    OciPush { tag: String, detail: String },
    SkopeoSpawn { tag: String, source: std::io::Error },
    SkopeoFailed { tag: String, code: Option<i32> },
    WriteRegistriesConf(std::io::Error),
    ReadCaCert { path: String, source: std::io::Error },
    Chmod { path: String, source: std::io::Error },
    ReadDir { path: String, source: std::io::Error },
    ResolveSymlink { path: String, source: std::io::Error },
    RemoveSymlink { path: String, source: std::io::Error },
    CopyReal { path: String, source: std::io::Error },
    NoCandidateTag { reference: String, considered: usize },
    PrefixMismatch { tag: String, prefix: String },
    WriteGithubOutput(std::io::Error),
    NoPlatformMatch { reference: String, os: String, arch: String },
    WriteArchive { path: String, source: std::io::Error },
    Gunzip(std::io::Error),
}

impl fmt::Display for PushError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PushError::MissingArg(n) => write!(f, "oci-push: missing required --{n}"),
            PushError::MissingValue(n) => write!(f, "oci-push: --{n} requires a value"),
            PushError::UnknownFlag(x) => write!(f, "oci-push: unknown flag {x}"),
            PushError::UnknownBackend(b) => {
                write!(f, "oci-push: unknown --backend '{b}' (expected: native, skopeo)")
            }
            PushError::NoSubcommand => write!(
                f,
                "oci-push: no subcommand (expected: push | transfer | inspect | pull | list | resolve | tag | delete | config-show | harden-rootfs)"
            ),
            PushError::UnknownSubcommand(s) => write!(
                f,
                "oci-push: unknown subcommand '{s}' (expected: push | transfer | inspect | pull | list | resolve | tag | delete | config-show | harden-rootfs)"
            ),
            PushError::Json(e) => write!(f, "oci-push: JSON error: {e}"),
            PushError::ConfigParse(e) => write!(f, "oci-push: config parse error: {e}"),
            PushError::OciPull { reference, detail } => {
                write!(f, "oci-push: pull failed for '{reference}': {detail}")
            }
            PushError::LabelAbsent { reference, label } => {
                write!(
                    f,
                    "oci-push: '{reference}' carries no label '{label}' (absent is an error, not an empty value)"
                )
            }
            PushError::NotImplemented(what) => {
                write!(f, "oci-push: {what} is not yet implemented")
            }
            PushError::ReadTarball { path, source } => {
                write!(f, "oci-push: cannot read tarball {path}: {source}")
            }
            PushError::Archive(e) => write!(f, "oci-push: error reading docker-archive: {e}"),
            PushError::NoManifestJson => {
                write!(f, "oci-push: docker-archive has no manifest.json")
            }
            PushError::UnsupportedCompressor(c) => write!(
                f,
                "oci-push: docker-archive outer compressor '{c}' is unsupported — \
                 rebuild the image with the default gz compressor (dockerTools \
                 `compressor = \"gz\"`)"
            ),
            PushError::ManifestParse(e) => write!(f, "oci-push: manifest.json parse error: {e}"),
            PushError::EmptyManifest => write!(f, "oci-push: manifest.json array is empty"),
            PushError::MissingEntry(p) => {
                write!(f, "oci-push: docker-archive missing referenced entry '{p}'")
            }
            PushError::Gzip(e) => write!(f, "oci-push: gzip of layer failed: {e}"),
            PushError::Runtime(e) => write!(f, "oci-push: could not start async runtime: {e}"),
            PushError::Reference { reference, detail } => {
                write!(f, "oci-push: invalid reference '{reference}': {detail}")
            }
            PushError::OciPush { tag, detail } => {
                write!(f, "oci-push: native push failed for tag '{tag}': {detail}")
            }
            PushError::SkopeoSpawn { tag, source } => {
                write!(f, "oci-push: failed to spawn skopeo for tag '{tag}': {source}")
            }
            PushError::SkopeoFailed { tag, code } => match code {
                Some(c) => write!(f, "oci-push: skopeo copy failed for tag '{tag}' (exit {c})"),
                None => write!(f, "oci-push: skopeo copy killed by signal for tag '{tag}'"),
            },
            PushError::WriteRegistriesConf(e) => {
                write!(f, "oci-push: could not write registries.conf: {e}")
            }
            PushError::ReadCaCert { path, source } => {
                write!(f, "oci-push: cannot read CA cert {path}: {source}")
            }
            PushError::Chmod { path, source } => {
                write!(f, "oci-push: chmod {path} failed: {source}")
            }
            PushError::ReadDir { path, source } => {
                write!(f, "oci-push: cannot read directory {path}: {source}")
            }
            PushError::ResolveSymlink { path, source } => {
                write!(f, "oci-push: cannot resolve symlink {path}: {source}")
            }
            PushError::RemoveSymlink { path, source } => {
                write!(f, "oci-push: cannot remove symlink {path}: {source}")
            }
            PushError::NoCandidateTag { reference, considered } => write!(
                f,
                "oci-push: no candidate tag for '{reference}' ({considered} tag(s) listed, none a pure X.Y.Z semver after exclusions)"
            ),
            PushError::PrefixMismatch { tag, prefix } => write!(
                f,
                "oci-push: highest tag '{tag}' does not start with required prefix '{prefix}'"
            ),
            PushError::NoPlatformMatch { reference, os, arch } => write!(
                f,
                "oci-push: '{reference}' has no {os}/{arch} instance in its image index"
            ),
            PushError::WriteArchive { path, source } => {
                write!(f, "oci-push: cannot write archive '{path}': {source}")
            }
            PushError::Gunzip(e) => write!(f, "oci-push: cannot gunzip layer: {e}"),
            PushError::WriteGithubOutput(e) => {
                write!(f, "oci-push: cannot append to GITHUB_OUTPUT: {e}")
            }
            PushError::CopyReal { path, source } => {
                write!(f, "oci-push: cannot materialize {path} as a real file: {source}")
            }
        }
    }
}

impl std::error::Error for PushError {}

/// Which push backend to drive. Defaults to [`Backend::Native`]. Serde-capable
/// + `snake_case` so it doubles as the `DocaConfig` `default_backend` field
/// (authored as `native` / `skopeo` in YAML).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Backend {
    #[default]
    Native,
    Skopeo,
}

impl Backend {
    fn parse(s: &str) -> Result<Backend, PushError> {
        match s {
            "native" => Ok(Backend::Native),
            "skopeo" => Ok(Backend::Skopeo),
            other => Err(PushError::UnknownBackend(other.to_string())),
        }
    }
}

/// Everything a backend needs to push every requested tag of one image.
struct PushSpec {
    registry: String,
    image: String,
    tags: Vec<String>,
    tarball: String,
    dest_user: String,
    dest_pass: String,
    /// Force plain HTTP regardless of `protocol_for`'s hostname heuristic.
    /// A deliberate escape hatch, not the default — a registry that
    /// genuinely has no TLS. Prefer `ca_cert` (real transport encryption
    /// with a pinned, verified server identity) whenever the registry
    /// serves HTTPS at all, even self-signed.
    insecure: bool,
    /// PEM-encoded CA/leaf certificate to trust IN ADDITION TO the system
    /// root store — for a self-signed registry cert (e.g. an in-cluster
    /// Zot with no cert-manager), this pins verification to that SPECIFIC
    /// certificate. Never disables verification outright (no
    /// accept_invalid_certificates escape hatch is exposed here) — a
    /// registry with an untrusted cert and no pin fails closed.
    ca_cert: Option<String>,
}

impl PushSpec {
    /// `<registry>/<image>:<tag>` for a given tag.
    fn reference(&self, tag: &str) -> String {
        let mut r =
            String::with_capacity(self.registry.len() + self.image.len() + tag.len() + 2);
        r.push_str(&self.registry);
        r.push('/');
        r.push_str(&self.image);
        r.push(':');
        r.push_str(tag);
        r
    }
}

/// The push strategy. Receives the full spec (all tags) so a backend can
/// prepare shared work — e.g. native parses + gzips the archive once.
trait PushBackend {
    fn push_all(&self, spec: &PushSpec) -> Result<(), PushError>;
}

// ===================== native backend ===================== //

struct NativeBackend {
    /// gzip level (0..=9) applied to each layer blob before upload.
    gzip_level: u32,
}

/// One entry of the docker-save `manifest.json` (top level is an array).
#[derive(Deserialize)]
struct DockerManifestEntry {
    #[serde(rename = "Config")]
    config: String,
    #[serde(rename = "Layers")]
    layers: Vec<String>,
}

impl NativeBackend {
    /// Read every entry of the docker-archive into memory, transparently
    /// gunzipping the outer wrapper when present (`buildLayeredImage` gzips it;
    /// detect by the gzip magic, not the filename). Inner `layer.tar` entries
    /// are always raw tar and are never double-decompressed.
    fn read_archive(tarball: &str) -> Result<HashMap<String, Vec<u8>>, PushError> {
        let bytes = fs::read(tarball).map_err(|source| PushError::ReadTarball {
            path: tarball.to_string(),
            source,
        })?;
        Self::read_archive_bytes(bytes)
    }

    /// Split out for testability: read every entry of a docker-archive given
    /// its raw bytes, transparently gunzipping the outer wrapper when present.
    fn read_archive_bytes(bytes: Vec<u8>) -> Result<HashMap<String, Vec<u8>>, PushError> {
        let gzipped = bytes.len() >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;

        // Reject non-gzip outer compressors with a legible error — a raw-tar
        // parse of a zstd/xz/bzip2 frame would otherwise fail cryptically.
        // Nix dockerTools defaults to gz; only a non-default `compressor`
        // setting produces these.
        if !gzipped && bytes.len() >= 4 {
            if bytes[..4] == [0x28, 0xb5, 0x2f, 0xfd] {
                return Err(PushError::UnsupportedCompressor("zstd"));
            }
            if bytes[0] == 0xfd && bytes[1] == 0x37 && bytes[2] == 0x7a {
                return Err(PushError::UnsupportedCompressor("xz"));
            }
            if bytes[0] == 0x42 && bytes[1] == 0x5a && bytes[2] == 0x68 {
                return Err(PushError::UnsupportedCompressor("bzip2"));
            }
        }

        let reader: Box<dyn Read> = if gzipped {
            Box::new(GzDecoder::new(std::io::Cursor::new(bytes)))
        } else {
            Box::new(std::io::Cursor::new(bytes))
        };
        let mut archive = tar::Archive::new(reader);

        let mut entries: HashMap<String, Vec<u8>> = HashMap::new();
        for entry in archive.entries().map_err(PushError::Archive)? {
            let mut entry = entry.map_err(PushError::Archive)?;
            let path = entry
                .path()
                .map_err(PushError::Archive)?
                .to_string_lossy()
                .into_owned();
            let mut buf = Vec::new();
            entry.read_to_end(&mut buf).map_err(PushError::Archive)?;
            entries.insert(path, buf);
        }
        Ok(entries)
    }

    fn gzip(raw: &[u8], level: u32) -> Result<Vec<u8>, PushError> {
        let mut enc = GzEncoder::new(Vec::new(), Compression::new(level));
        std::io::Write::write_all(&mut enc, raw).map_err(PushError::Gzip)?;
        enc.finish().map_err(PushError::Gzip)
    }
}

impl PushBackend for NativeBackend {
    fn push_all(&self, spec: &PushSpec) -> Result<(), PushError> {
        // ---- parse the docker-archive once ----
        let entries = Self::read_archive(&spec.tarball)?;
        let manifest_bytes = entries
            .get("manifest.json")
            .ok_or(PushError::NoManifestJson)?;
        let parsed: Vec<DockerManifestEntry> =
            serde_json::from_slice(manifest_bytes).map_err(PushError::ManifestParse)?;
        let entry = parsed.into_iter().next().ok_or(PushError::EmptyManifest)?;

        let config_bytes = entries
            .get(&entry.config)
            .ok_or_else(|| PushError::MissingEntry(entry.config.clone()))?
            .clone();
        let config = OciBlobConfig {
            data: config_bytes,
            media_type: MT_CONFIG.to_string(),
            annotations: None,
        };

        // ---- gzip each (uncompressed) layer once ----
        let mut layers: Vec<ImageLayer> = Vec::with_capacity(entry.layers.len());
        for layer_path in &entry.layers {
            let raw = entries
                .get(layer_path)
                .ok_or_else(|| PushError::MissingEntry(layer_path.clone()))?;
            let gz = Self::gzip(raw, self.gzip_level)?;
            layers.push(ImageLayer::new(gz, MT_LAYER_GZIP.to_string(), None));
        }

        // ---- push every tag (blobs are HEAD-deduped by oci-client) ----
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(PushError::Runtime)?;
        let auth = RegistryAuth::Basic(spec.dest_user.clone(), spec.dest_pass.clone());
        let client = Client::new(client_config_for(
            &spec.registry,
            spec.insecure,
            &spec.ca_cert,
        )?);

        rt.block_on(async {
            for tag in &spec.tags {
                let reference_str = spec.reference(tag);
                let reference = Reference::try_from(reference_str.as_str()).map_err(|e| {
                    PushError::Reference {
                        reference: reference_str.clone(),
                        detail: e.to_string(),
                    }
                })?;
                eprintln!("oci-push[native]: pushing {reference_str}");
                let mut manifest = OciImageManifest::build(&layers, &config, None);
                // Set the top-level mediaType explicitly (build leaves it None);
                // self-describing manifest for stricter downstream registries.
                manifest.media_type = Some(MT_MANIFEST.to_string());
                client
                    .push(&reference, &layers, config.clone(), &auth, Some(manifest))
                    .await
                    .map_err(|e| PushError::OciPush {
                        tag: tag.clone(),
                        detail: e.to_string(),
                    })?;
                eprintln!("oci-push[native]: pushed {reference_str}");
            }
            Ok::<(), PushError>(())
        })
    }
}

// ===================== skopeo backend (fallback) ===================== //

struct SkopeoBackend;

impl SkopeoBackend {
    /// The ubuntu runner ships a v1 `/etc/containers/registries.conf` which
    /// nixpkgs skopeo rejects; write a minimal v2 config (we push only
    /// fully-qualified `docker://` refs, so no search registries are needed).
    fn registries_conf() -> Result<PathBuf, PushError> {
        let dir = env::var_os("RUNNER_TEMP")
            .map(PathBuf::from)
            .unwrap_or_else(env::temp_dir);
        let path = dir.join("oci-push-registries.conf");
        fs::write(&path, b"unqualified-search-registries = []\n")
            .map_err(PushError::WriteRegistriesConf)?;
        Ok(path)
    }

    fn push_one(spec: &PushSpec, tag: &str, conf: &Path) -> Result<(), PushError> {
        let target = spec.reference(tag);
        let source = {
            let mut s = String::from("docker-archive:");
            s.push_str(&spec.tarball);
            s
        };
        let dest = {
            let mut d = String::from("docker://");
            d.push_str(&target);
            d
        };
        let creds = {
            let mut c = String::with_capacity(spec.dest_user.len() + spec.dest_pass.len() + 1);
            c.push_str(&spec.dest_user);
            c.push(':');
            c.push_str(&spec.dest_pass);
            c
        };
        eprintln!("oci-push[skopeo]: copying {source} -> {target}");
        let status = Command::new("skopeo")
            .arg("--insecure-policy")
            .arg("copy")
            .arg("--dest-creds")
            .arg(&creds)
            .arg(&source)
            .arg(&dest)
            .env("CONTAINERS_REGISTRIES_CONF", conf)
            .status()
            .map_err(|source| PushError::SkopeoSpawn {
                tag: tag.to_string(),
                source,
            })?;
        if !status.success() {
            return Err(PushError::SkopeoFailed {
                tag: tag.to_string(),
                code: status.code(),
            });
        }
        Ok(())
    }
}

impl PushBackend for SkopeoBackend {
    fn push_all(&self, spec: &PushSpec) -> Result<(), PushError> {
        let conf = Self::registries_conf()?;
        for tag in &spec.tags {
            Self::push_one(spec, tag, &conf)?;
        }
        Ok(())
    }
}

// ===================== typed config (DocaConfig) ===================== //
//
// Lightweight shikumi-SHAPED config: the TieredConfig contract
// (bare / discovered / prescribed_default) implemented as inherent methods,
// + serde + YAML + a `config-show` operator surface — WITHOUT pulling the full
// `shikumi` crate, which drags gen-platform / gen-types / notify git-dep trees
// (disproportionate for a lean CI tool). The method signatures match
// shikumi::TieredConfig exactly, so this is a trivial trait-upgrade later.
// pending-shikumi: full `impl shikumi::TieredConfig` once the build can absorb
// the dependency without the git-dep vendoring cost.

/// Typed config for the oci-push (doca) OCI manager. Authored at
/// `~/.config/oci-push/oci-push.yaml`; path override via `OCI_PUSH_CONFIG`.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct DocaConfig {
    /// Registry used when a push omits `--registry` / `INPUT_REGISTRY`.
    #[serde(default = "default_registry")]
    default_registry: String,
    /// Push implementation when none is given.
    #[serde(default)]
    default_backend: Backend,
    /// gzip level (0..=9) for layer blobs (native backend).
    #[serde(default = "default_gzip_level")]
    gzip_level: u32,
    /// Named auth profiles. The password is NEVER stored — only the name of
    /// the env var carrying it, so secrets stay out of YAML + git.
    #[serde(default)]
    auth_profiles: HashMap<String, AuthProfile>,
    /// Tags applied to every push in addition to the explicit `--tag`.
    #[serde(default)]
    default_additional_tags: Vec<String>,
}

/// One auth profile; `password_env` names the env var holding the secret.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct AuthProfile {
    username: String,
    password_env: String,
}

fn default_registry() -> String {
    "ghcr.io".to_string()
}
fn default_gzip_level() -> u32 {
    6
}

impl Default for DocaConfig {
    fn default() -> Self {
        Self::prescribed_default()
    }
}

impl DocaConfig {
    /// Tier 0 — bare: zero-opinion floor; every field explicit (no defaults).
    fn bare() -> Self {
        Self {
            default_registry: String::new(),
            default_backend: Backend::Native,
            gzip_level: 0,
            auth_profiles: HashMap::new(),
            default_additional_tags: Vec::new(),
        }
    }
    /// Tier 1 — discovered: nothing host-detectable for this tool ⇒ bare.
    fn discovered() -> Self {
        Self::bare()
    }
    /// Tier 2 — prescribed default: ghcr.io, native backend, gzip 6.
    fn prescribed_default() -> Self {
        Self {
            default_registry: default_registry(),
            default_backend: Backend::Native,
            gzip_level: default_gzip_level(),
            auth_profiles: HashMap::new(),
            default_additional_tags: Vec::new(),
        }
    }

    /// Discover + load: `$OCI_PUSH_CONFIG`, else
    /// `$XDG_CONFIG_HOME/oci-push/oci-push.yaml` (or `~/.config/…`), else the
    /// prescribed default. A present-but-unparseable file is a typed error.
    fn load() -> Result<DocaConfig, PushError> {
        match config_path() {
            Some(p) if p.exists() => {
                let bytes = fs::read(&p).map_err(|source| PushError::ReadTarball {
                    path: p.to_string_lossy().into_owned(),
                    source,
                })?;
                serde_yaml::from_slice(&bytes).map_err(PushError::ConfigParse)
            }
            _ => Ok(DocaConfig::prescribed_default()),
        }
    }
}

fn config_path() -> Option<PathBuf> {
    if let Some(p) = env::var_os("OCI_PUSH_CONFIG") {
        return Some(PathBuf::from(p));
    }
    let base = env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?;
    Some(base.join("oci-push").join("oci-push.yaml"))
}

fn non_empty(s: String) -> Option<String> {
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

// ===================== shared CLI helpers ===================== //

fn next_value<I: Iterator<Item = String>>(
    it: &mut I,
    flag: &'static str,
) -> Result<String, PushError> {
    it.next().ok_or(PushError::MissingValue(flag))
}

/// GitHub-Action input fallback: a `with:` input surfaced by the action.yml as
/// `INPUT_<FLAG_UPPER_UNDERSCORE>` (e.g. `--dest-user` ⇒ `INPUT_DEST_USER`).
/// Lets the action.yml stay pure declaration (no shell flag-mapping); the
/// binary reads inputs from env when the matching CLI flag is absent. Empty
/// values are treated as unset.
fn env_input(name: &str) -> Option<String> {
    env::var(name).ok().filter(|s| !s.is_empty())
}

/// Basic auth when both creds are present; anonymous otherwise (public source).
fn auth_or_anon(user: Option<String>, pass: Option<String>) -> RegistryAuth {
    match (user, pass) {
        (Some(u), Some(p)) => RegistryAuth::Basic(u, p),
        _ => RegistryAuth::Anonymous,
    }
}

fn runtime() -> Result<tokio::runtime::Runtime, PushError> {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(PushError::Runtime)
}

fn parse_reference(s: &str) -> Result<Reference, PushError> {
    Reference::try_from(s).map_err(|e| PushError::Reference {
        reference: s.to_string(),
        detail: e.to_string(),
    })
}

/// Layer media types accepted when pulling (covers OCI + Docker, gzip + plain).
const ACCEPTED_LAYERS: &[&str] = &[
    "application/vnd.oci.image.layer.v1.tar+gzip",
    "application/vnd.oci.image.layer.v1.tar",
    "application/vnd.docker.image.rootfs.diff.tar.gzip",
    "application/vnd.docker.image.rootfs.diff.tar",
];

// ===================== subcommands ===================== //

/// `push` — docker-archive tarball → registry (native or skopeo backend).
fn cmd_push<I: Iterator<Item = String>>(mut it: I) -> Result<(), PushError> {
    let mut registry: Option<String> = None;
    let mut image: Option<String> = None;
    let mut tag: Option<String> = None;
    let mut tarball: Option<String> = None;
    let mut dest_user: Option<String> = None;
    let mut dest_pass: Option<String> = None;
    let mut additional: Vec<String> = Vec::new();
    let mut backend: Option<Backend> = None;
    let mut insecure = false;
    let mut ca_cert: Option<String> = None;

    while let Some(flag) = it.next() {
        match flag.as_str() {
            "--registry" => registry = Some(next_value(&mut it, "registry")?),
            "--image" => image = Some(next_value(&mut it, "image")?),
            "--tag" => tag = Some(next_value(&mut it, "tag")?),
            "--tarball" => tarball = Some(next_value(&mut it, "tarball")?),
            "--dest-user" => dest_user = Some(next_value(&mut it, "dest-user")?),
            "--dest-pass" => dest_pass = Some(next_value(&mut it, "dest-pass")?),
            "--backend" => backend = Some(Backend::parse(&next_value(&mut it, "backend")?)?),
            // Bare flag, no value — a registry with genuinely no TLS at all.
            // Prefer --dest-ca-cert over this whenever the registry serves
            // HTTPS with a self-signed/private cert.
            "--insecure" => insecure = true,
            "--dest-ca-cert" => ca_cert = Some(next_value(&mut it, "dest-ca-cert")?),
            "--additional-tags" => {
                additional = next_value(&mut it, "additional-tags")?
                    .split_whitespace()
                    .map(str::to_string)
                    .collect();
            }
            other => return Err(PushError::UnknownFlag(other.to_string())),
        }
    }

    // Resolution precedence: CLI flag → INPUT_* env → DocaConfig → hard default.
    let cfg = DocaConfig::load()?;

    if additional.is_empty() {
        if let Some(s) = env_input("INPUT_ADDITIONAL_TAGS") {
            additional = s.split_whitespace().map(str::to_string).collect();
        }
    }
    if additional.is_empty() {
        additional = cfg.default_additional_tags.clone();
    }
    let backend = match backend {
        Some(b) => b,
        None => match env_input("INPUT_BACKEND") {
            Some(s) => Backend::parse(&s)?,
            None => cfg.default_backend,
        },
    };

    let primary = tag
        .or_else(|| env_input("INPUT_TAG"))
        .ok_or(PushError::MissingArg("tag"))?;
    let mut tags = Vec::with_capacity(1 + additional.len());
    tags.push(primary);
    tags.extend(additional);

    let spec = PushSpec {
        registry: registry
            .or_else(|| env_input("INPUT_REGISTRY"))
            .or_else(|| non_empty(cfg.default_registry.clone()))
            .ok_or(PushError::MissingArg("registry"))?,
        image: image
            .or_else(|| env_input("INPUT_IMAGE"))
            .ok_or(PushError::MissingArg("image"))?,
        tags,
        tarball: tarball
            .or_else(|| env_input("INPUT_TARBALL"))
            .unwrap_or_else(|| String::from("./image.tar.gz")),
        dest_user: dest_user
            .or_else(|| env_input("INPUT_DEST_USER"))
            .ok_or(PushError::MissingArg("dest-user"))?,
        dest_pass: dest_pass
            .or_else(|| env_input("INPUT_DEST_PASS"))
            .ok_or(PushError::MissingArg("dest-pass"))?,
        insecure: insecure || env_input("INPUT_INSECURE").as_deref() == Some("true"),
        ca_cert: ca_cert.or_else(|| env_input("INPUT_DEST_CA_CERT")),
    };
    let backend: Box<dyn PushBackend> = match backend {
        Backend::Native => Box::new(NativeBackend {
            gzip_level: cfg.gzip_level,
        }),
        Backend::Skopeo => Box::new(SkopeoBackend),
    };
    backend.push_all(&spec)
}

/// `transfer` — copy an image from one registry to another (native oci-client:
/// pull the manifest + blobs from `--src`, push them to `--dest`). The pulled
/// layers are already registry-format (gzipped), so they re-push verbatim.
fn cmd_transfer<I: Iterator<Item = String>>(mut it: I) -> Result<(), PushError> {
    let mut src: Option<String> = None;
    let mut dest: Option<String> = None;
    let mut src_user: Option<String> = None;
    let mut src_pass: Option<String> = None;
    let mut dest_user: Option<String> = None;
    let mut dest_pass: Option<String> = None;

    while let Some(flag) = it.next() {
        match flag.as_str() {
            "--src" => src = Some(next_value(&mut it, "src")?),
            "--dest" => dest = Some(next_value(&mut it, "dest")?),
            "--src-user" => src_user = Some(next_value(&mut it, "src-user")?),
            "--src-pass" => src_pass = Some(next_value(&mut it, "src-pass")?),
            "--dest-user" => dest_user = Some(next_value(&mut it, "dest-user")?),
            "--dest-pass" => dest_pass = Some(next_value(&mut it, "dest-pass")?),
            other => return Err(PushError::UnknownFlag(other.to_string())),
        }
    }

    let src_ref = parse_reference(
        &src.or_else(|| env_input("INPUT_SRC"))
            .ok_or(PushError::MissingArg("src"))?,
    )?;
    let dest_ref = parse_reference(
        &dest
            .or_else(|| env_input("INPUT_DEST"))
            .ok_or(PushError::MissingArg("dest"))?,
    )?;
    let src_auth = auth_or_anon(
        src_user.or_else(|| env_input("INPUT_SRC_USER")),
        src_pass.or_else(|| env_input("INPUT_SRC_PASS")),
    );
    let dest_auth = RegistryAuth::Basic(
        dest_user
            .or_else(|| env_input("INPUT_DEST_USER"))
            .ok_or(PushError::MissingArg("dest-user"))?,
        dest_pass
            .or_else(|| env_input("INPUT_DEST_PASS"))
            .ok_or(PushError::MissingArg("dest-pass"))?,
    );

    let src_proto = protocol_for(src_ref.registry());
    let dest_proto = protocol_for(dest_ref.registry());

    runtime()?.block_on(async {
        let src_client = Client::new(ClientConfig {
            protocol: src_proto,
            ..Default::default()
        });
        eprintln!("oci-push[transfer]: pulling {src_ref}");
        let data = src_client
            .pull(&src_ref, &src_auth, ACCEPTED_LAYERS.to_vec())
            .await
            .map_err(|e| PushError::OciPull {
                reference: src_ref.to_string(),
                detail: e.to_string(),
            })?;

        let dest_client = Client::new(ClientConfig {
            protocol: dest_proto,
            ..Default::default()
        });
        let manifest = data
            .manifest
            .unwrap_or_else(|| OciImageManifest::build(&data.layers, &data.config, None));
        eprintln!("oci-push[transfer]: pushing {dest_ref}");
        dest_client
            .push(&dest_ref, &data.layers, data.config, &dest_auth, Some(manifest))
            .await
            .map_err(|e| PushError::OciPush {
                tag: dest_ref.to_string(),
                detail: e.to_string(),
            })?;
        eprintln!("oci-push[transfer]: done {src_ref} -> {dest_ref}");
        Ok::<(), PushError>(())
    })
}

/// `inspect` — fetch + print a manifest (+ its digest) from a registry.
fn cmd_inspect<I: Iterator<Item = String>>(mut it: I) -> Result<(), PushError> {
    let mut reference: Option<String> = None;
    let mut user: Option<String> = None;
    let mut pass: Option<String> = None;
    let mut insecure = false;
    let mut ca_cert: Option<String> = None;
    let mut digest_only = false;
    let mut label: Option<String> = None;
    let mut os: Option<String> = None;
    let mut arch: Option<String> = None;

    while let Some(flag) = it.next() {
        match flag.as_str() {
            "--ref" => reference = Some(next_value(&mut it, "ref")?),
            "--user" => user = Some(next_value(&mut it, "user")?),
            "--pass" => pass = Some(next_value(&mut it, "pass")?),
            "--insecure" => insecure = true,
            "--dest-ca-cert" => ca_cert = Some(next_value(&mut it, "dest-ca-cert")?),
            // --digest-only added 2026-07-29. Prints ONLY the digest, to stdout,
            // with no trailing prose. Additive and non-breaking: without it the
            // behaviour is exactly as before (pretty manifest on stdout, digest
            // on stderr).
            //
            // Why it is needed: the digest is the one field a promotion pipeline
            // actually wants, and it was the one field not machine-readable.
            // Emitting the manifest on stdout and the digest on stderr means a
            // caller had to either parse a pretty-printed JSON blob or scrape
            // stderr, and the obvious third option -- pull the digest out of the
            // manifest -- is not available at all, because a digest is the hash
            // OF the manifest and does not appear inside it.
            //
            // What it unlocks: tag -> immutable digest resolution in one call, so
            // a consumer can copy `repo@sha256:...` instead of `repo:tag`. That
            // turns "the tag moved under us" from a silent wrong-bytes promotion
            // into something that cannot happen -- the failure mode that
            // motivated this whole change was a rolling tag that quietly stopped
            // tracking while every gate stayed green.
            "--digest-only" => digest_only = true,
            // --label added 2026-07-30. Prints ONE config label's value to
            // stdout, nothing else, and exits non-zero when the label is
            // absent.
            //
            // Why it is needed: a label is the other field a promotion pipeline
            // reads, and until now it was not reachable from this tool at all.
            // `inspect` renders the MANIFEST, but labels live in the CONFIG
            // BLOB the manifest merely points at, so no amount of parsing the
            // existing output could produce one. Callers therefore had to keep
            // skopeo on the runner purely for `--format '{{ index .Labels ...}}'`,
            // which is how a promotion job on a runner without skopeo dies at
            // "command not found" with every other step already correct.
            //
            // Absent is an ERROR, not an empty line: a version gate that reads
            // a missing label as "" and carries on is the failure this exists
            // to prevent.
            "--label" => label = Some(next_value(&mut it, "label")?),
            // Explicit platform, mirroring skopeo's --override-os/--override-arch.
            // Defaults to linux/amd64 rather than the client's own platform so
            // the same command gives the same answer on every runner.
            "--os" => os = Some(next_value(&mut it, "os")?),
            "--arch" => arch = Some(next_value(&mut it, "arch")?),
            other => return Err(PushError::UnknownFlag(other.to_string())),
        }
    }

    let r = parse_reference(
        &reference
            .or_else(|| env_input("INPUT_REF"))
            .ok_or(PushError::MissingArg("ref"))?,
    )?;
    let auth = auth_or_anon(
        user.or_else(|| env_input("INPUT_USER")),
        pass.or_else(|| env_input("INPUT_PASS")),
    );
    let insecure = insecure || env_input("INPUT_INSECURE").as_deref() == Some("true");
    let ca_cert = ca_cert.or_else(|| env_input("INPUT_DEST_CA_CERT"));
    // Env fallback, same shape as --insecure above. Without this the action's
    // `digest-only:` input would be declared but inert -- a flag reachable only
    // from a hand-typed argv, which is the exact defect class of a typed option
    // that nothing reads.
    let digest_only = digest_only || env_input("INPUT_DIGEST_ONLY").as_deref() == Some("true");
    let label = label.or_else(|| env_input("INPUT_LABEL"));
    let os = os
        .or_else(|| env_input("INPUT_OS"))
        .unwrap_or_else(|| "linux".to_string());
    let arch = arch
        .or_else(|| env_input("INPUT_ARCH"))
        .unwrap_or_else(|| "amd64".to_string());
    let cfg = client_config_for_platform(r.registry(), insecure, &ca_cert, &os, &arch)?;

    runtime()?.block_on(async {
        let client = Client::new(cfg);
        let (manifest, digest) = client
            .pull_manifest(&r, &auth)
            .await
            .map_err(|e| PushError::OciPull {
                reference: r.to_string(),
                detail: e.to_string(),
            })?;
        // A label lives in the config blob, which the manifest only points at,
        // so it costs one extra fetch. Only paid when asked for.
        if let Some(key) = label.as_deref() {
            // pull_manifest_and_config resolves the config blob for us, and on a
            // multi-arch index it resolves a platform manifest first, which a
            // hand-rolled pull_blob against `manifest.config` cannot do because
            // an index has no config field at all.
            // (manifest, DIGEST, config) — the digest is the middle element, not
            // the last. Getting that order wrong parses the digest string as
            // JSON and fails with "expected value at line 1 column 1".
            let (_m, _digest, cfg_raw) =
                client
                    .pull_manifest_and_config(&r, &auth)
                    .await
                    .map_err(|e| PushError::OciPull {
                        reference: r.to_string(),
                        detail: format!("config: {e}"),
                    })?;
            let cfg_json: serde_json::Value =
                serde_json::from_str(&cfg_raw).map_err(PushError::Json)?;
            // Both spellings: OCI writes "config", docker-archive writes "Config".
            let value = cfg_json
                .get("config")
                .or_else(|| cfg_json.get("Config"))
                .and_then(|c| c.get("Labels"))
                .and_then(|l| l.get(key))
                .and_then(|v| v.as_str());
            return match value {
                Some(v) => {
                    println!("{v}");
                    Ok::<(), PushError>(())
                }
                None => Err(PushError::LabelAbsent {
                    reference: r.to_string(),
                    label: key.to_string(),
                }),
            };
        }
        let rendered = serde_json::to_string_pretty(&manifest).map_err(PushError::Json)?;
        if digest_only {
            println!("{digest}");
        } else {
            println!("{rendered}");
            eprintln!("digest: {digest}");
        }
        Ok::<(), PushError>(())
    })
}

/// `pull` — registry → local docker-archive. Reserved: reconstructing a
/// docker-save tarball requires gunzipping each registry layer back to its
/// `layer.tar` and re-deriving `manifest.json`; a typed seam until built (no
/// silent stub, per the TYPED-SPEC rule).
/// `pull` — registry -> `docker-archive` tarball. The inverse of the native
/// push path, and the last thing that forced an external `skopeo` onto a runner.
///
/// # The two digest spaces, in reverse
///
/// A registry stores layers GZIPPED (the manifest digests the compressed blob).
/// A `docker-archive` stores them UNCOMPRESSED (`layer.tar`), and the image
/// config's `rootfs.diff_ids` are digests of those uncompressed bytes. So each
/// layer is gunzipped on the way out, exactly mirroring the gzip the push path
/// applies on the way in. Skipping that produces an archive whose `diff_ids` do
/// not match its own layers -- an archive that loads and then behaves oddly,
/// rather than one that fails cleanly.
///
/// # Platform selection
///
/// A multi-arch reference resolves through `ClientConfig::platform_resolver`.
/// The default picks the HOST platform, which silently makes the output
/// runner-dependent -- the same trap `--override-arch` exists to close for
/// skopeo. Here `--arch`/`--os` install an explicit resolver, and an index with
/// no matching instance is [`PushError::NoPlatformMatch`] rather than a
/// host-shaped guess.
fn cmd_pull<I: Iterator<Item = String>>(mut it: I) -> Result<(), PushError> {
    let mut reference: Option<String> = None;
    let mut out: Option<String> = None;
    let mut image_name: Option<String> = None;
    let mut image_tag: Option<String> = None;
    let mut arch: Option<String> = None;
    let mut os_: Option<String> = None;
    let mut user: Option<String> = None;
    let mut pass: Option<String> = None;
    let mut insecure = false;
    let mut ca_cert: Option<String> = None;

    while let Some(flag) = it.next() {
        match flag.as_str() {
            "--ref" => reference = Some(next_value(&mut it, "ref")?),
            "--out" => out = Some(next_value(&mut it, "out")?),
            "--image-name" => image_name = Some(next_value(&mut it, "image-name")?),
            "--image-tag" => image_tag = Some(next_value(&mut it, "image-tag")?),
            "--arch" => arch = Some(next_value(&mut it, "arch")?),
            "--os" => os_ = Some(next_value(&mut it, "os")?),
            "--user" => user = Some(next_value(&mut it, "user")?),
            "--pass" => pass = Some(next_value(&mut it, "pass")?),
            "--insecure" => insecure = true,
            "--dest-ca-cert" => ca_cert = Some(next_value(&mut it, "dest-ca-cert")?),
            other => return Err(PushError::UnknownFlag(other.to_string())),
        }
    }

    let raw_ref = reference
        .or_else(|| env_input("INPUT_REF"))
        .ok_or(PushError::MissingArg("ref"))?;
    let r = parse_reference(&raw_ref)?;
    let out = out
        .or_else(|| env_input("INPUT_OUT"))
        .ok_or(PushError::MissingArg("out"))?;
    let auth = auth_or_anon(
        user.or_else(|| env_input("INPUT_USER")),
        pass.or_else(|| env_input("INPUT_PASS")),
    );
    let insecure = insecure || env_input("INPUT_INSECURE").as_deref() == Some("true");
    let ca_cert = ca_cert.or_else(|| env_input("INPUT_DEST_CA_CERT"));
    let want_os = os_.or_else(|| env_input("INPUT_OS")).unwrap_or_else(|| "linux".to_string());
    let want_arch = arch
        .or_else(|| env_input("INPUT_ARCH"))
        .unwrap_or_else(|| "amd64".to_string());
    // RepoTags. A docker-archive without them loads as a dangling image, so the
    // caller must be able to name what it will `docker load`.
    let name = image_name
        .or_else(|| env_input("INPUT_IMAGE_NAME"))
        .unwrap_or_else(|| r.repository().to_string());
    let tag = image_tag
        .or_else(|| env_input("INPUT_IMAGE_TAG"))
        .unwrap_or_else(|| "latest".to_string());

    let mut cfg = client_config_for(r.registry(), insecure, &ca_cert)?;
    let ros = want_os.clone();
    let rarch = want_arch.clone();
    cfg.platform_resolver = Some(Box::new(move |entries: &[oci_client::manifest::ImageIndexEntry]| {
        entries
            .iter()
            .find(|e| {
                e.platform
                    .as_ref()
                    .map(|p| p.os == ros && p.architecture == rarch)
                    .unwrap_or(false)
            })
            .map(|e| e.digest.clone())
    }));

    runtime()?.block_on(async {
        let client = Client::new(cfg);
        // SEQUENTIAL, IN MANIFEST ORDER, and that is the whole point.
        //
        // The obvious implementation is `client.pull()`, which returns an
        // ImageData carrying every layer. It is WRONG here: pull() fetches the
        // layers concurrently and hands them back in COMPLETION order, while
        // `ImageLayer` exposes no digest to reorder by. Caught end-to-end rather
        // than by inspection -- `docker load` rejected the archive with a digest
        // mismatch, and comparing each layer against the config's
        // `rootfs.diff_ids` showed the bytes were right but shuffled: written
        // layer 4 hashed to the config's layer 2. A container runtime verifies
        // diff_ids, so a shuffled archive is not "slightly off", it is
        // unloadable.
        //
        // Fetching one layer at a time against `manifest.layers` makes order a
        // property of the loop instead of a race, needs no digest to sort by, and
        // adds no hashing dependency. It trades parallelism for correctness, which
        // is the right trade for an artifact whose whole job is to be byte-exact.
        let (manifest, _mdigest, config_json) = client
            .pull_manifest_and_config(&r, &auth)
            .await
            .map_err(|e| {
                let detail = e.to_string();
                let lowered = detail.to_lowercase();
                if lowered.contains("platform") || lowered.contains("image index") {
                    PushError::NoPlatformMatch {
                        reference: r.to_string(),
                        os: want_os.clone(),
                        arch: want_arch.clone(),
                    }
                } else {
                    PushError::OciPull {
                        reference: r.to_string(),
                        detail,
                    }
                }
            })?;

        let mut builder = tar::Builder::new(Vec::new());
        let mut layer_paths: Vec<String> = Vec::new();

        let append = |b: &mut tar::Builder<Vec<u8>>, path: &str, bytes: &[u8]| -> Result<(), PushError> {
            let mut h = tar::Header::new_gnu();
            h.set_size(bytes.len() as u64);
            h.set_mode(0o644);
            h.set_cksum();
            b.append_data(&mut h, path, bytes).map_err(PushError::Archive)
        };

        for (i, desc) in manifest.layers.iter().enumerate() {
            let mut blob: Vec<u8> = Vec::new();
            client
                .pull_blob(&r, desc, &mut blob)
                .await
                .map_err(|e| PushError::OciPull {
                    reference: desc.digest.clone(),
                    detail: e.to_string(),
                })?;

            // A registry layer is gzipped and a docker-archive layer is not, so
            // this is the exact inverse of the gzip the push path applies. Guard
            // on the media type: an already-uncompressed layer must pass through
            // untouched rather than be handed to a gzip reader.
            let raw = if desc.media_type.ends_with("gzip") {
                let mut d = GzDecoder::new(blob.as_slice());
                let mut v = Vec::new();
                d.read_to_end(&mut v).map_err(PushError::Gunzip)?;
                v
            } else {
                blob
            };
            let mut path = String::new();
            path.push_str(&i.to_string());
            path.push_str("/layer.tar");
            append(&mut builder, &path, &raw)?;
            layer_paths.push(path);
        }

        let cfg_name = "config.json";
        append(&mut builder, cfg_name, config_json.as_bytes())?;

        let mut repo_tag = String::new();
        repo_tag.push_str(&name);
        repo_tag.push(':');
        repo_tag.push_str(&tag);
        let entry = serde_json::json!([{
            "Config": cfg_name,
            "RepoTags": [repo_tag],
            "Layers": layer_paths,
        }]);
        let manifest_bytes = serde_json::to_vec(&entry).map_err(PushError::Json)?;
        append(&mut builder, "manifest.json", &manifest_bytes)?;

        let tar_bytes = builder.into_inner().map_err(PushError::Archive)?;
        fs::write(&out, &tar_bytes).map_err(|source| PushError::WriteArchive {
            path: out.clone(),
            source,
        })?;

        println!("wrote {out}");
        println!("layers={}", layer_paths.len());
        println!("digest={_mdigest}");
        Ok::<(), PushError>(())
    })
}

/// `list` — list the tags of a repository.
// `--insecure` / `--dest-ca-cert` added 2026-07-29, for parity with `inspect`
// and `push`. Before this, `list` was the ONE subcommand that built its
// ClientConfig inline (`protocol: proto, ..Default::default()`) instead of going
// through `client_config_for`, so it had no `extra_root_certificates` and no way
// to accept one. Consequence: a registry serving a self-signed cert was
// unreachable to `list` by construction, and no flag or env var could fix it --
// `update-ca-certificates` on the host does not help either, because the
// oci-client build here selects `rustls-tls`, whose trust anchors are the
// compiled-in webpki set (`rustls-native-certs` is not in the lock).
//
// That made `doca list` unusable against a cluster-internal registry, which is
// exactly where tag discovery is most wanted: enumerating what a scan-and-admit
// registry has actually admitted, so a promotion can pin the newest admitted
// version instead of dereferencing a rolling tag that may have stopped moving.
// The flag names match `inspect`'s deliberately, including the slightly odd
// `--dest-ca-cert` (there is no source/dest split on a read, but a caller
// scripting several subcommands should not have to remember which spelling each
// one takes).
fn cmd_list<I: Iterator<Item = String>>(mut it: I) -> Result<(), PushError> {
    let mut reference: Option<String> = None;
    let mut user: Option<String> = None;
    let mut pass: Option<String> = None;
    let mut insecure = false;
    let mut ca_cert: Option<String> = None;
    while let Some(flag) = it.next() {
        match flag.as_str() {
            "--ref" => reference = Some(next_value(&mut it, "ref")?),
            "--user" => user = Some(next_value(&mut it, "user")?),
            "--pass" => pass = Some(next_value(&mut it, "pass")?),
            "--insecure" => insecure = true,
            "--dest-ca-cert" => ca_cert = Some(next_value(&mut it, "dest-ca-cert")?),
            other => return Err(PushError::UnknownFlag(other.to_string())),
        }
    }
    let r = parse_reference(
        &reference
            .or_else(|| env_input("INPUT_REF"))
            .ok_or(PushError::MissingArg("ref"))?,
    )?;
    let auth = auth_or_anon(
        user.or_else(|| env_input("INPUT_USER")),
        pass.or_else(|| env_input("INPUT_PASS")),
    );
    let insecure = insecure || env_input("INPUT_INSECURE").as_deref() == Some("true");
    let ca_cert = ca_cert.or_else(|| env_input("INPUT_DEST_CA_CERT"));
    let cfg = client_config_for(r.registry(), insecure, &ca_cert)?;
    runtime()?.block_on(async {
        let client = Client::new(cfg);
        let resp = client
            .list_tags(&r, &auth, None, None)
            .await
            .map_err(|e| PushError::OciPull {
                reference: r.to_string(),
                detail: e.to_string(),
            })?;
        for t in resp.tags {
            println!("{t}");
        }
        Ok::<(), PushError>(())
    })
}

/// Parse a pure `X.Y.Z` tag into comparable numbers. Returns `None` for
/// anything else, which is what excludes arch-suffixed mirrors (`1.0.53-arm64`),
/// prereleases, and `latest`-style pointers. Numeric comparison, not string
/// comparison, so 1.0.9 < 1.0.10 orders correctly -- a lexical sort gets that
/// backwards and would happily promote the older build.
fn semver_triple(tag: &str) -> Option<(u64, u64, u64)> {
    let mut parts = tag.split('.');
    let a = parts.next()?.parse().ok()?;
    let b = parts.next()?.parse().ok()?;
    let c = parts.next()?.parse().ok()?;
    if parts.next().is_some() {
        return None;
    }
    Some((a, b, c))
}

/// `resolve` — answer "what is the newest thing this registry actually holds,
/// and what are its exact bytes" in ONE typed call: list the repo's tags, keep
/// only pure `X.Y.Z` semvers, drop `--exclude-tag` values, take the numerically
/// highest, resolve it to an immutable digest, and emit both.
///
/// # Why this lives in the binary and not in a shell pipeline
///
/// This replaces a `list | grep -E | grep -vx | sort -V | tail -1` chain plus a
/// second call to turn the winner into a digest. That pipeline is four
/// dependencies and three silent-failure modes wide: `grep -vx` matching
/// nothing looks identical to matching everything, `sort -V` is GNU-specific
/// (absent on BSD/macOS runners), an empty pipeline yields empty string rather
/// than an error, and the whole thing is invisible to any type checker. Here
/// each step is a typed value, an empty candidate set is
/// [`PushError::NoCandidateTag`] rather than `""`, and ordering is arithmetic.
///
/// # `--require-prefix`
///
/// Asserts the winner starts with a given string (e.g. `1.0.`). A promotion
/// pipeline that publishes into a `1.0.<patch>` line must NOT silently
/// republish a `2.x` build under a `1.0` tag; this turns that from a
/// mislabelled artifact into a hard failure.
///
/// # Output
///
/// `tag=<tag>` and `digest=<digest>` on stdout, one per line. When
/// `GITHUB_OUTPUT` is set the same pairs are appended there, so a CI caller
/// consumes them as step outputs with no parsing and no shell.
fn cmd_resolve<I: Iterator<Item = String>>(mut it: I) -> Result<(), PushError> {
    let mut reference: Option<String> = None;
    let mut user: Option<String> = None;
    let mut pass: Option<String> = None;
    let mut insecure = false;
    let mut ca_cert: Option<String> = None;
    let mut exclude: Vec<String> = Vec::new();
    let mut require_prefix: Option<String> = None;

    while let Some(flag) = it.next() {
        match flag.as_str() {
            "--ref" => reference = Some(next_value(&mut it, "ref")?),
            "--user" => user = Some(next_value(&mut it, "user")?),
            "--pass" => pass = Some(next_value(&mut it, "pass")?),
            "--insecure" => insecure = true,
            "--dest-ca-cert" => ca_cert = Some(next_value(&mut it, "dest-ca-cert")?),
            "--exclude-tag" => exclude.push(next_value(&mut it, "exclude-tag")?),
            "--require-prefix" => require_prefix = Some(next_value(&mut it, "require-prefix")?),
            other => return Err(PushError::UnknownFlag(other.to_string())),
        }
    }

    let raw_ref = reference
        .or_else(|| env_input("INPUT_REF"))
        .ok_or(PushError::MissingArg("ref"))?;
    let r = parse_reference(&raw_ref)?;
    let auth = auth_or_anon(
        user.or_else(|| env_input("INPUT_USER")),
        pass.or_else(|| env_input("INPUT_PASS")),
    );
    let insecure = insecure || env_input("INPUT_INSECURE").as_deref() == Some("true");
    let ca_cert = ca_cert.or_else(|| env_input("INPUT_DEST_CA_CERT"));
    // Comma-separated in the env form, because a GitHub Actions input cannot
    // repeat. Empty entries are dropped so a trailing comma is harmless.
    if exclude.is_empty() {
        if let Some(raw) = env_input("INPUT_EXCLUDE_TAGS") {
            exclude.extend(
                raw.split(',')
                    .map(str::trim)
                    .filter(|p| !p.is_empty())
                    .map(str::to_string),
            );
        }
    }
    let require_prefix = require_prefix.or_else(|| env_input("INPUT_REQUIRE_PREFIX"));
    let cfg = client_config_for(r.registry(), insecure, &ca_cert)?;

    runtime()?.block_on(async {
        let client = Client::new(cfg);
        let listed = client
            .list_tags(&r, &auth, None, None)
            .await
            .map_err(|e| PushError::OciPull {
                reference: r.to_string(),
                detail: e.to_string(),
            })?;
        let considered = listed.tags.len();

        let winner = listed
            .tags
            .iter()
            .filter(|t| !exclude.iter().any(|x| x == *t))
            .filter_map(|t| semver_triple(t).map(|v| (v, t)))
            .max_by_key(|(v, _)| *v)
            .map(|(_, t)| t.clone())
            .ok_or_else(|| PushError::NoCandidateTag {
                reference: r.to_string(),
                considered,
            })?;

        if let Some(prefix) = &require_prefix {
            if !winner.starts_with(prefix.as_str()) {
                return Err(PushError::PrefixMismatch {
                    tag: winner.clone(),
                    prefix: prefix.clone(),
                });
            }
        }

        // Re-parse with the winning tag so the digest belongs to exactly the tag
        // reported, never to whatever the input reference happened to point at.
        let mut tagged = String::new();
        tagged.push_str(r.registry());
        tagged.push('/');
        tagged.push_str(r.repository());
        tagged.push(':');
        tagged.push_str(&winner);
        let tr = parse_reference(&tagged)?;

        let (_manifest, digest) =
            client
                .pull_manifest(&tr, &auth)
                .await
                .map_err(|e| PushError::OciPull {
                    reference: tr.to_string(),
                    detail: e.to_string(),
                })?;

        println!("tag={winner}");
        println!("digest={digest}");
        if let Some(path) = env::var_os("GITHUB_OUTPUT") {
            use std::io::Write as _;
            let mut f = fs::OpenOptions::new()
                .append(true)
                .create(true)
                .open(path)
                .map_err(PushError::WriteGithubOutput)?;
            writeln!(f, "tag={winner}").map_err(PushError::WriteGithubOutput)?;
            writeln!(f, "digest={digest}").map_err(PushError::WriteGithubOutput)?;
        }
        Ok::<(), PushError>(())
    })
}

/// `tag` — add a new tag to an existing manifest with NO blob re-upload: pull
/// the manifest from `--ref`, push it back to the same repo under `--new-tag`.
fn cmd_tag<I: Iterator<Item = String>>(mut it: I) -> Result<(), PushError> {
    let mut reference: Option<String> = None;
    let mut new_tag: Option<String> = None;
    let mut user: Option<String> = None;
    let mut pass: Option<String> = None;
    while let Some(flag) = it.next() {
        match flag.as_str() {
            "--ref" => reference = Some(next_value(&mut it, "ref")?),
            "--new-tag" => new_tag = Some(next_value(&mut it, "new-tag")?),
            "--user" => user = Some(next_value(&mut it, "user")?),
            "--pass" => pass = Some(next_value(&mut it, "pass")?),
            other => return Err(PushError::UnknownFlag(other.to_string())),
        }
    }
    let src = parse_reference(
        &reference
            .or_else(|| env_input("INPUT_REF"))
            .ok_or(PushError::MissingArg("ref"))?,
    )?;
    let nt = new_tag
        .or_else(|| env_input("INPUT_NEW_TAG"))
        .ok_or(PushError::MissingArg("new-tag"))?;
    let auth = auth_or_anon(
        user.or_else(|| env_input("INPUT_USER")),
        pass.or_else(|| env_input("INPUT_PASS")),
    );
    // Same registry/repository, new tag.
    let mut dest_str =
        String::with_capacity(src.registry().len() + src.repository().len() + nt.len() + 2);
    dest_str.push_str(src.registry());
    dest_str.push('/');
    dest_str.push_str(src.repository());
    dest_str.push(':');
    dest_str.push_str(&nt);
    let dest = parse_reference(&dest_str)?;
    let proto = protocol_for(src.registry());
    runtime()?.block_on(async {
        let client = Client::new(ClientConfig {
            protocol: proto,
            ..Default::default()
        });
        let (manifest, _digest) =
            client
                .pull_manifest(&src, &auth)
                .await
                .map_err(|e| PushError::OciPull {
                    reference: src.to_string(),
                    detail: e.to_string(),
                })?;
        let digest = client
            .push_manifest(&dest, &manifest)
            .await
            .map_err(|e| PushError::OciPush {
                tag: dest.to_string(),
                detail: e.to_string(),
            })?;
        eprintln!("oci-push[tag]: {src} -> {dest} ({digest})");
        Ok::<(), PushError>(())
    })
}

/// `delete` — remove a tag/manifest. Reserved: oci-client 0.13 exposes no
/// manifest-delete (would need a raw `DELETE /v2/<name>/manifests/<ref>`).
/// Typed seam — no silent stub.
fn cmd_delete<I: Iterator<Item = String>>(_it: I) -> Result<(), PushError> {
    Err(PushError::NotImplemented("delete (manifest delete)"))
}

/// `config-show <bare|discovered|default|loaded>` — print a config tier as YAML.
/// The fleet-standard operator surface: see the floor, the prescribed defaults,
/// or what would actually load from disk. Defaults to `default`.
fn cmd_config_show<I: Iterator<Item = String>>(mut it: I) -> Result<(), PushError> {
    let tier = it.next().unwrap_or_else(|| "default".to_string());
    let cfg = match tier.as_str() {
        "bare" => DocaConfig::bare(),
        "discovered" => DocaConfig::discovered(),
        "default" | "prescribed" => DocaConfig::prescribed_default(),
        "loaded" => DocaConfig::load()?,
        other => return Err(PushError::UnknownSubcommand(other.to_string())),
    };
    let yaml = serde_yaml::to_string(&cfg).map_err(PushError::ConfigParse)?;
    print!("{yaml}");
    Ok(())
}

/// `harden-rootfs [--root <path>]` — make a Nix-assembled rootfs directory
/// safe for OCI layer packaging. Two fixes, both build-time-only concerns
/// with nowhere else typed to live:
///
/// 1. `<root>/tmp` is chmod'd world-writable + sticky (1777), recursively.
///    Nix strips write bits from every registered store path, so a `chmod`
///    baked into a derivation is a no-op by the time it reaches an image —
///    this must run at tar-assembly time (`dockerTools.buildLayeredImage`'s
///    `fakeRootCommands`, the one place in that pipeline a mutation
///    actually lands).
/// 2. Any symlinked `<root>/etc/passwd` or `<root>/etc/group` is replaced
///    with a real file carrying the same content. `dockerTools`' `contents`
///    merge goes through `symlinkJoin`, so files contributed that way land
///    as absolute symlinks into `/nix/store/<hash>/...` — some container
///    runtimes (confirmed: containerd 2.x) reject a layer whose
///    `/etc/passwd` escapes into `/nix/store` this way.
///
/// This replaces what was previously an inline shell loop in
/// `oci/hardened-base.nix`'s own `fakeRootCommands` string — ported here
/// per the fleet's NO-SHELL rule (a `for`/`if`/`readlink` loop is real
/// logic, not 3-line glue) so it's typed, testable, and shared by every
/// consumer of that file rather than re-embedded per base variant.
///
/// `--root` defaults to `.` — `fakeRootCommands` runs with the assembled
/// rootfs already as CWD.
fn cmd_harden_rootfs<I: Iterator<Item = String>>(mut it: I) -> Result<(), PushError> {
    let mut root = PathBuf::from(".");
    while let Some(flag) = it.next() {
        match flag.as_str() {
            "--root" => root = PathBuf::from(it.next().ok_or(PushError::MissingValue("root"))?),
            other => return Err(PushError::UnknownFlag(other.to_string())),
        }
    }

    let tmp = root.join("tmp");
    if tmp.exists() {
        chmod_recursive(&tmp, 0o1777)?;
    }

    for rel in ["etc/passwd", "etc/group"] {
        materialize_if_symlink(&root.join(rel))?;
    }

    Ok(())
}

/// `chmod -R <mode>` — Rust has no built-in recursive chmod; walk it by hand.
fn chmod_recursive(path: &Path, mode: u32) -> Result<(), PushError> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).map_err(|source| {
        PushError::Chmod { path: path.display().to_string(), source }
    })?;
    if path.is_dir() {
        let entries = fs::read_dir(path).map_err(|source| PushError::ReadDir {
            path: path.display().to_string(),
            source,
        })?;
        for entry in entries {
            let entry = entry.map_err(|source| PushError::ReadDir {
                path: path.display().to_string(),
                source,
            })?;
            chmod_recursive(&entry.path(), mode)?;
        }
    }
    Ok(())
}

/// If `path` is a symlink, resolve it (`readlink -f` semantics) and replace
/// it with a real copy of the target's bytes + mode — `fs::copy` preserves
/// the source's permission bits, matching `cp`'s default behavior. A
/// missing path or a real (non-symlink) file is left untouched — honest
/// no-op, not an error, since both are valid starting states depending on
/// which base variant supplied the file.
fn materialize_if_symlink(path: &Path) -> Result<(), PushError> {
    let meta = match fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(_) => return Ok(()),
    };
    if !meta.file_type().is_symlink() {
        return Ok(());
    }
    let real = fs::canonicalize(path).map_err(|source| PushError::ResolveSymlink {
        path: path.display().to_string(),
        source,
    })?;
    fs::remove_file(path).map_err(|source| PushError::RemoveSymlink {
        path: path.display().to_string(),
        source,
    })?;
    fs::copy(&real, path).map_err(|source| PushError::CopyReal {
        path: path.display().to_string(),
        source,
    })?;
    Ok(())
}

fn run() -> Result<(), PushError> {
    let mut args = env::args();
    let _prog = args.next();
    match args.next().as_deref() {
        Some("push") => cmd_push(args),
        Some("transfer") => cmd_transfer(args),
        Some("inspect") => cmd_inspect(args),
        Some("pull") => cmd_pull(args),
        Some("list") => cmd_list(args),
        Some("resolve") => cmd_resolve(args),
        Some("tag") => cmd_tag(args),
        Some("delete") => cmd_delete(args),
        Some("config-show") => cmd_config_show(args),
        Some("harden-rootfs") => cmd_harden_rootfs(args),
        // Back-compat: a leading flag means the legacy flat `push` form.
        Some(flag) if flag.starts_with("--") => {
            let rest = std::iter::once(flag.to_string()).chain(args);
            cmd_push(rest)
        }
        Some(other) => Err(PushError::UnknownSubcommand(other.to_string())),
        None => Err(PushError::NoSubcommand),
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn build_tar(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let mut builder = tar::Builder::new(Vec::new());
        for (path, data) in entries {
            let mut header = tar::Header::new_gnu();
            header.set_size(data.len() as u64);
            header.set_mode(0o644);
            builder.append_data(&mut header, path, *data).unwrap();
        }
        builder.into_inner().unwrap()
    }

    #[test]
    fn reads_plain_docker_archive() {
        let tar = build_tar(&[
            (
                "manifest.json",
                br#"[{"Config":"cfg.json","Layers":["l/layer.tar"]}]"#,
            ),
            ("cfg.json", b"{}"),
            ("l/layer.tar", b"layerbytes"),
        ]);
        let m = NativeBackend::read_archive_bytes(tar).unwrap();
        assert!(m.contains_key("manifest.json"));
        assert_eq!(m.get("cfg.json").unwrap().as_slice(), b"{}");
        assert_eq!(m.get("l/layer.tar").unwrap().as_slice(), b"layerbytes");
    }

    #[test]
    fn reads_gzip_wrapped_archive() {
        // buildLayeredImage gzips the outer wrapper; detection is by magic.
        let tar = build_tar(&[("manifest.json", b"[]")]);
        let wrapped = NativeBackend::gzip(&tar, 6).unwrap();
        assert_eq!(&wrapped[..2], &[0x1f, 0x8b]);
        let m = NativeBackend::read_archive_bytes(wrapped).unwrap();
        assert!(m.contains_key("manifest.json"));
    }

    #[test]
    fn manifest_entry_parses_array() {
        let json = br#"[{"Config":"c.json","RepoTags":["x/y:1"],"Layers":["a","b"]}]"#;
        let parsed: Vec<DockerManifestEntry> = serde_json::from_slice(json).unwrap();
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].config, "c.json");
        assert_eq!(parsed[0].layers, vec!["a".to_string(), "b".to_string()]);
    }

    #[test]
    fn gzip_roundtrips() {
        let raw = b"the quick brown fox ".repeat(100);
        let gz = NativeBackend::gzip(&raw, 6).unwrap();
        assert_eq!(&gz[..2], &[0x1f, 0x8b]);
        let mut dec = GzDecoder::new(gz.as_slice());
        let mut back = Vec::new();
        dec.read_to_end(&mut back).unwrap();
        assert_eq!(back, raw);
    }

    #[test]
    fn protocol_detection() {
        assert!(matches!(protocol_for("ghcr.io"), ClientProtocol::Https));
        assert!(matches!(protocol_for("ghcr.io/pleme-io/x"), ClientProtocol::Https));
        assert!(matches!(protocol_for("localhost:5000"), ClientProtocol::Http));
        assert!(matches!(protocol_for("127.0.0.1:5000"), ClientProtocol::Http));
    }

    #[test]
    fn rejects_non_gzip_compressor() {
        let zstd = vec![0x28, 0xb5, 0x2f, 0xfd, 0, 0, 0, 0];
        assert!(matches!(
            NativeBackend::read_archive_bytes(zstd).unwrap_err(),
            PushError::UnsupportedCompressor("zstd")
        ));
        let xz = vec![0xfd, 0x37, 0x7a, 0x58, 0x5a, 0];
        assert!(matches!(
            NativeBackend::read_archive_bytes(xz).unwrap_err(),
            PushError::UnsupportedCompressor("xz")
        ));
    }

    #[test]
    fn config_tiers() {
        assert_eq!(DocaConfig::bare().gzip_level, 0);
        assert!(DocaConfig::bare().default_registry.is_empty());
        let d = DocaConfig::prescribed_default();
        assert_eq!(d.gzip_level, 6);
        assert_eq!(d.default_registry, "ghcr.io");
        assert!(matches!(d.default_backend, Backend::Native));
        // discovered() inherits bare() for this tool.
        assert_eq!(DocaConfig::discovered().gzip_level, 0);
    }

    #[test]
    fn config_yaml_roundtrip() {
        let yaml = serde_yaml::to_string(&DocaConfig::prescribed_default()).unwrap();
        assert!(yaml.contains("native")); // Backend authored snake_case
        let back: DocaConfig = serde_yaml::from_str(&yaml).unwrap();
        assert_eq!(back.default_registry, "ghcr.io");
        assert_eq!(back.gzip_level, 6);
    }

    #[test]
    fn reference_render() {
        let spec = PushSpec {
            registry: "ghcr.io".into(),
            image: "pleme-io/foo".into(),
            tags: vec![],
            tarball: String::new(),
            dest_user: String::new(),
            dest_pass: String::new(),
            insecure: false,
            ca_cert: None,
        };
        assert_eq!(spec.reference("v1"), "ghcr.io/pleme-io/foo:v1");
    }

    /// Unique scratch dir per test -- Rust's default test runner runs tests
    /// in parallel, so a shared fixed path would race across threads.
    fn scratch_dir(name: &str) -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let mut dir_name = String::from("oci-push-test-");
        dir_name.push_str(name);
        dir_name.push('-');
        dir_name.push_str(&std::process::id().to_string());
        dir_name.push('-');
        dir_name.push_str(&n.to_string());
        let path = std::env::temp_dir().join(dir_name);
        fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn chmod_recursive_sets_mode_on_dir_and_children() {
        use std::os::unix::fs::PermissionsExt;
        let root = scratch_dir("chmod");
        let sub = root.join("sub");
        fs::create_dir(&sub).unwrap();
        let file = sub.join("f");
        fs::write(&file, b"x").unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();

        chmod_recursive(&root, 0o1777).unwrap();

        for p in [&root, &sub, &file] {
            let mode = fs::metadata(p).unwrap().permissions().mode() & 0o7777;
            assert_eq!(mode, 0o1777, "{p:?} should be 1777");
        }
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn materialize_if_symlink_replaces_symlink_with_real_copy() {
        use std::os::unix::fs::symlink;
        let root = scratch_dir("materialize-symlink");
        let real = root.join("real-passwd");
        fs::write(&real, b"root:x:0:0::/root:/bin/sh\n").unwrap();
        let link = root.join("passwd");
        symlink(&real, &link).unwrap();

        materialize_if_symlink(&link).unwrap();

        let meta = fs::symlink_metadata(&link).unwrap();
        assert!(!meta.file_type().is_symlink(), "should no longer be a symlink");
        assert_eq!(fs::read(&link).unwrap(), b"root:x:0:0::/root:/bin/sh\n");
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn materialize_if_symlink_is_a_noop_for_a_real_file() {
        let root = scratch_dir("materialize-real");
        let file = root.join("passwd");
        fs::write(&file, b"real content").unwrap();

        materialize_if_symlink(&file).unwrap();

        assert_eq!(fs::read(&file).unwrap(), b"real content");
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn materialize_if_symlink_is_a_noop_for_a_missing_path() {
        let root = scratch_dir("materialize-missing");
        let missing = root.join("does-not-exist");
        assert!(materialize_if_symlink(&missing).is_ok());
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn harden_rootfs_end_to_end() {
        use std::os::unix::fs::symlink;
        let root = scratch_dir("harden-rootfs-e2e");
        fs::create_dir_all(root.join("etc")).unwrap();
        fs::create_dir_all(root.join("tmp")).unwrap();
        let real_passwd = root.join("real-passwd");
        fs::write(&real_passwd, b"nonroot:x:65532:65532::/home/nonroot:/sbin/nologin\n").unwrap();
        symlink(&real_passwd, root.join("etc/passwd")).unwrap();
        let real_group = root.join("real-group");
        fs::write(&real_group, b"nonroot:x:65532:\n").unwrap();
        symlink(&real_group, root.join("etc/group")).unwrap();

        cmd_harden_rootfs(vec!["--root".to_string(), root.display().to_string()].into_iter())
            .unwrap();

        assert!(!fs::symlink_metadata(root.join("etc/passwd"))
            .unwrap()
            .file_type()
            .is_symlink());
        assert!(!fs::symlink_metadata(root.join("etc/group"))
            .unwrap()
            .file_type()
            .is_symlink());
        use std::os::unix::fs::PermissionsExt;
        let tmp_mode = fs::metadata(root.join("tmp")).unwrap().permissions().mode() & 0o7777;
        assert_eq!(tmp_mode, 0o1777);
        fs::remove_dir_all(&root).unwrap();
    }
}
