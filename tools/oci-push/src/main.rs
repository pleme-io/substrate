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
use oci_client::client::{ClientConfig, ClientProtocol, Config as OciBlobConfig, ImageLayer};
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
/// HTTPS otherwise. A local test rig or in-cluster zot speaks plain HTTP;
/// public registries (ghcr.io) speak HTTPS.
fn protocol_for(registry: &str) -> ClientProtocol {
    let host = registry.split('/').next().unwrap_or(registry);
    let bare = host.split(':').next().unwrap_or(host);
    if bare == "localhost" || bare == "127.0.0.1" || bare == "::1" {
        ClientProtocol::Http
    } else {
        ClientProtocol::Https
    }
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
                "oci-push: no subcommand (expected: push | transfer | inspect | pull | list | tag | delete)"
            ),
            PushError::UnknownSubcommand(s) => write!(
                f,
                "oci-push: unknown subcommand '{s}' (expected: push | transfer | inspect | pull | list | tag | delete)"
            ),
            PushError::Json(e) => write!(f, "oci-push: JSON error: {e}"),
            PushError::ConfigParse(e) => write!(f, "oci-push: config parse error: {e}"),
            PushError::OciPull { reference, detail } => {
                write!(f, "oci-push: pull failed for '{reference}': {detail}")
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
        let client = Client::new(ClientConfig {
            protocol: protocol_for(&spec.registry),
            ..Default::default()
        });

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

    while let Some(flag) = it.next() {
        match flag.as_str() {
            "--registry" => registry = Some(next_value(&mut it, "registry")?),
            "--image" => image = Some(next_value(&mut it, "image")?),
            "--tag" => tag = Some(next_value(&mut it, "tag")?),
            "--tarball" => tarball = Some(next_value(&mut it, "tarball")?),
            "--dest-user" => dest_user = Some(next_value(&mut it, "dest-user")?),
            "--dest-pass" => dest_pass = Some(next_value(&mut it, "dest-pass")?),
            "--backend" => backend = Some(Backend::parse(&next_value(&mut it, "backend")?)?),
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

    while let Some(flag) = it.next() {
        match flag.as_str() {
            "--ref" => reference = Some(next_value(&mut it, "ref")?),
            "--user" => user = Some(next_value(&mut it, "user")?),
            "--pass" => pass = Some(next_value(&mut it, "pass")?),
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
    let proto = protocol_for(r.registry());

    runtime()?.block_on(async {
        let client = Client::new(ClientConfig {
            protocol: proto,
            ..Default::default()
        });
        let (manifest, digest) = client
            .pull_manifest(&r, &auth)
            .await
            .map_err(|e| PushError::OciPull {
                reference: r.to_string(),
                detail: e.to_string(),
            })?;
        let rendered = serde_json::to_string_pretty(&manifest).map_err(PushError::Json)?;
        println!("{rendered}");
        eprintln!("digest: {digest}");
        Ok::<(), PushError>(())
    })
}

/// `pull` — registry → local docker-archive. Reserved: reconstructing a
/// docker-save tarball requires gunzipping each registry layer back to its
/// `layer.tar` and re-deriving `manifest.json`; a typed seam until built (no
/// silent stub, per the TYPED-SPEC rule).
fn cmd_pull<I: Iterator<Item = String>>(_it: I) -> Result<(), PushError> {
    Err(PushError::NotImplemented("pull (registry -> docker-archive)"))
}

/// `list` — list the tags of a repository.
fn cmd_list<I: Iterator<Item = String>>(mut it: I) -> Result<(), PushError> {
    let mut reference: Option<String> = None;
    let mut user: Option<String> = None;
    let mut pass: Option<String> = None;
    while let Some(flag) = it.next() {
        match flag.as_str() {
            "--ref" => reference = Some(next_value(&mut it, "ref")?),
            "--user" => user = Some(next_value(&mut it, "user")?),
            "--pass" => pass = Some(next_value(&mut it, "pass")?),
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
    let proto = protocol_for(r.registry());
    runtime()?.block_on(async {
        let client = Client::new(ClientConfig {
            protocol: proto,
            ..Default::default()
        });
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

fn run() -> Result<(), PushError> {
    let mut args = env::args();
    let _prog = args.next();
    match args.next().as_deref() {
        Some("push") => cmd_push(args),
        Some("transfer") => cmd_transfer(args),
        Some("inspect") => cmd_inspect(args),
        Some("pull") => cmd_pull(args),
        Some("list") => cmd_list(args),
        Some("tag") => cmd_tag(args),
        Some("delete") => cmd_delete(args),
        Some("config-show") => cmd_config_show(args),
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
        };
        assert_eq!(spec.reference("v1"), "ghcr.io/pleme-io/foo:v1");
    }
}
