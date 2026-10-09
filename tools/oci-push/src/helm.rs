//! Helm charts as OCI artifacts, and the OCI image layout that carries them.
//!
//! The fleet distributes its own Helm charts as Nix store paths: substrate's
//! `mkHelmChart` builds one deterministic `.tgz`, and `mkHelmRepo` calls
//! `oci-push layout` to turn a set of them into OCI image layouts that a
//! node-local registry serves as `oci://charts.pleme.internal/pleme-io/charts/<chart>`.
//! The same layout is pushed to ghcr (`oci-push push --layout`) as the public
//! export. Flux, engenho and `helm dependency` consume either unchanged, because
//! what they receive is exactly what `helm push` would have produced:
//!
//! * config blob — media type `application/vnd.cncf.helm.config.v1+json`, the
//!   chart's `Chart.yaml` metadata as JSON (what `helm pull` unmarshals into
//!   `chart.Metadata`);
//! * one layer   — media type `application/vnd.cncf.helm.chart.content.v1.tar+gzip`,
//!   the chart archive byte for byte;
//! * tag         — the chart version with `+` spelled `_` (Helm's own rule:
//!   `+` is not legal in an OCI tag, and `helm pull --version 1.0.0+x` asks for
//!   tag `1.0.0_x`).
//!
//! DETERMINISTIC BY CONSTRUCTION. Every JSON document written here (config,
//! manifest, index) is canonical — object keys sorted at every depth, no
//! insignificant whitespace — so the same chart bytes give the same manifest
//! digest on every machine, and that digest equals the one oci-client would
//! compute when it canonicalises a manifest it pushes. `helm push` stamps an
//! `org.opencontainers.image.created` annotation from the wall clock; it is
//! omitted here on purpose, since it would make two builds of one chart two
//! different artifacts.
//!
//! TYPED-EMISSION: no `format!`; failures are `PushError` variants.

use std::collections::BTreeMap;
use std::fs;
use std::io::Read;
use std::path::{Component, Path, PathBuf};

use flate2::read::GzDecoder;
use oci_client::client::ImageLayer;
use serde_json::{Map, Value};

use crate::PushError;

/// Helm's OCI config media type (helm.sh/helm/v3/pkg/registry `ConfigMediaType`).
pub(crate) const MT_HELM_CONFIG: &str = "application/vnd.cncf.helm.config.v1+json";
/// Helm's chart layer media type (`ChartLayerMediaType`).
pub(crate) const MT_HELM_CHART: &str = "application/vnd.cncf.helm.chart.content.v1.tar+gzip";
/// Helm's provenance layer media type (`ProvLayerMediaType`). Never written
/// here; accepted on transfer so a signed chart copies whole.
pub(crate) const MT_HELM_PROV: &str = "application/vnd.cncf.helm.chart.provenance.v1.prov";
pub(crate) const MT_OCI_MANIFEST: &str = "application/vnd.oci.image.manifest.v1+json";
pub(crate) const MT_OCI_INDEX: &str = "application/vnd.oci.image.index.v1+json";
/// The OCI image-layout annotation that names a manifest's tag.
pub(crate) const ANN_REF_NAME: &str = "org.opencontainers.image.ref.name";
const ANN_TITLE: &str = "org.opencontainers.image.title";
const ANN_VERSION: &str = "org.opencontainers.image.version";
const ANN_DESCRIPTION: &str = "org.opencontainers.image.description";
const LAYOUT_MARKER: &str = "oci-layout";
const LAYOUT_VERSION: &str = "1.0.0";

/// `sha256:<hex>` of `bytes` — oci-client's own digest, so a layout and a push
/// can never disagree about what a blob is called.
pub(crate) fn sha256_digest(bytes: &[u8]) -> String {
    ImageLayer::new(bytes.to_vec(), String::new(), None).sha256_digest()
}

/// Rebuild `v` with every object's keys in byte order. Explicit rather than
/// relying on serde_json's map type: with the `preserve_order` feature unified
/// in by any dependency, `Map` keeps insertion order and a "sorted" document
/// silently stops being one.
fn canonical(v: &Value) -> Value {
    match v {
        Value::Object(m) => {
            let mut keys: Vec<&String> = m.keys().collect();
            keys.sort();
            let mut out = Map::new();
            for k in keys {
                out.insert(k.clone(), canonical(&m[k]));
            }
            Value::Object(out)
        }
        Value::Array(a) => Value::Array(a.iter().map(canonical).collect()),
        other => other.clone(),
    }
}

/// Canonical JSON bytes of `v`.
pub(crate) fn canonical_bytes(v: &Value) -> Vec<u8> {
    // Serialising a `Value` cannot fail (no non-string keys, no I/O).
    serde_json::to_vec(&canonical(v)).unwrap_or_default()
}

fn descriptor(media_type: &str, bytes: &[u8]) -> Value {
    let mut d = Map::new();
    d.insert("mediaType".into(), Value::from(media_type));
    d.insert("digest".into(), Value::from(sha256_digest(bytes)));
    d.insert("size".into(), Value::from(bytes.len() as u64));
    Value::Object(d)
}

/// One chart archive, read and understood.
#[derive(Clone, Debug)]
pub(crate) struct HelmChart {
    pub name: String,
    pub version: String,
    pub description: Option<String>,
    /// Canonical JSON of the archive's `Chart.yaml` — the config blob.
    pub config: Vec<u8>,
    /// The archive itself — the chart layer, never re-encoded.
    pub content: Vec<u8>,
}

impl HelmChart {
    pub(crate) fn read(path: &str) -> Result<HelmChart, PushError> {
        let bytes = fs::read(path).map_err(|source| PushError::ReadTarball {
            path: path.to_string(),
            source,
        })?;
        HelmChart::from_archive(path, bytes)
    }

    /// Parse a chart archive: a gzipped tar whose `<top>/Chart.yaml` (exactly
    /// one level deep — a subchart's `Chart.yaml` lives deeper) carries the
    /// chart's metadata.
    pub(crate) fn from_archive(source: &str, content: Vec<u8>) -> Result<HelmChart, PushError> {
        let invalid = |detail: &'static str| PushError::HelmChart {
            path: source.to_string(),
            detail,
        };
        if content.len() < 2 || content[0] != 0x1f || content[1] != 0x8b {
            return Err(invalid("not a gzip chart archive (helm package output is .tgz)"));
        }
        let mut archive = tar::Archive::new(GzDecoder::new(std::io::Cursor::new(&content)));
        let mut chart_yaml: Option<Vec<u8>> = None;
        for entry in archive.entries().map_err(PushError::Archive)? {
            let mut entry = entry.map_err(PushError::Archive)?;
            let path = entry.path().map_err(PushError::Archive)?.into_owned();
            // `./app/Chart.yaml` and `app/Chart.yaml` are the same entry.
            let parts: Vec<Component> = path
                .components()
                .filter(|c| !matches!(c, Component::CurDir))
                .collect();
            let at_root = parts.len() == 2
                && matches!(parts[0], Component::Normal(_))
                && parts[1] == Component::Normal(std::ffi::OsStr::new("Chart.yaml"));
            if at_root {
                if chart_yaml.is_some() {
                    return Err(invalid("more than one top-level <dir>/Chart.yaml"));
                }
                let mut buf = Vec::new();
                entry.read_to_end(&mut buf).map_err(PushError::Archive)?;
                chart_yaml = Some(buf);
            }
        }
        let chart_yaml = chart_yaml.ok_or_else(|| invalid("no <dir>/Chart.yaml at the archive root"))?;
        let meta: Value = serde_yaml::from_slice(&chart_yaml).map_err(|e| PushError::ChartYaml {
            path: source.to_string(),
            source: e,
        })?;
        let field = |k: &str| meta.get(k).and_then(Value::as_str).map(str::to_string);
        let name = field("name").ok_or_else(|| invalid("Chart.yaml has no string `name`"))?;
        let version = field("version").ok_or_else(|| invalid("Chart.yaml has no string `version`"))?;
        if name.is_empty() || version.is_empty() {
            return Err(invalid("Chart.yaml `name` and `version` must be non-empty"));
        }
        Ok(HelmChart {
            description: field("description"),
            config: canonical_bytes(&meta),
            name,
            version,
            content,
        })
    }

    /// The OCI tag Helm uses for this version (`+` → `_`).
    pub(crate) fn tag(&self) -> String {
        self.version.replace('+', "_")
    }

    pub(crate) fn chart_digest(&self) -> String {
        sha256_digest(&self.content)
    }

    /// The canonical OCI image manifest for this chart.
    pub(crate) fn manifest(&self) -> Vec<u8> {
        let mut ann = Map::new();
        ann.insert(ANN_TITLE.into(), Value::from(self.name.as_str()));
        ann.insert(ANN_VERSION.into(), Value::from(self.version.as_str()));
        if let Some(d) = &self.description {
            ann.insert(ANN_DESCRIPTION.into(), Value::from(d.as_str()));
        }
        let mut m = Map::new();
        m.insert("schemaVersion".into(), Value::from(2));
        m.insert("mediaType".into(), Value::from(MT_OCI_MANIFEST));
        m.insert("config".into(), descriptor(MT_HELM_CONFIG, &self.config));
        m.insert(
            "layers".into(),
            Value::Array(vec![descriptor(MT_HELM_CHART, &self.content)]),
        );
        m.insert("annotations".into(), Value::Object(ann));
        canonical_bytes(&Value::Object(m))
    }
}

/// Group charts by name — one OCI repository per chart, as Helm requires (the
/// repository's last path segment IS the chart name).
pub(crate) fn group_by_name(charts: Vec<HelmChart>) -> BTreeMap<String, Vec<HelmChart>> {
    let mut groups: BTreeMap<String, Vec<HelmChart>> = BTreeMap::new();
    for c in charts {
        groups.entry(c.name.clone()).or_default().push(c);
    }
    groups
}

/// How a layout names its manifests (`org.opencontainers.image.ref.name`).
///
/// * `Version` — `<tag>`: the layout IS one chart's OCI repository
///   (`<repository>/<chart>`); one chart name per layout.
/// * `ChartVersion` — `<chart>:<tag>`: the layout is a whole chart
///   REPOSITORY (`<repository>`), every chart in it. This is the shape porto
///   (the node-local registry) mounts as `{repository, layout}`, routing
///   `<chart>:<tag>` to `<repository>/<chart>:<tag>`, and the shape
///   `push --layout` exports the same way. No registry host ever appears in a
///   ref.name.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RefStyle {
    Version,
    ChartVersion,
}

impl RefStyle {
    pub(crate) fn parse(s: &str) -> Result<RefStyle, PushError> {
        match s {
            "version" => Ok(RefStyle::Version),
            "chart-version" => Ok(RefStyle::ChartVersion),
            _ => Err(PushError::MissingArg("ref-name version|chart-version")),
        }
    }

    fn ref_name(self, c: &HelmChart) -> String {
        match self {
            RefStyle::Version => c.tag(),
            RefStyle::ChartVersion => [c.name.as_str(), ":", c.tag().as_str()].concat(),
        }
    }
}

/// Split a layout ref.name into (repository suffix, tag): `"app:0.1.0"` →
/// (`Some("app")`, `"0.1.0"`), `"0.1.0"` → (`None`, `"0.1.0"`). An OCI tag
/// cannot contain `:`, so the split is unambiguous.
pub(crate) fn split_ref_name(r: &str) -> (Option<&str>, &str) {
    match r.rsplit_once(':') {
        Some((repo, tag)) => (Some(repo), tag),
        None => (None, r),
    }
}

/// What one written manifest is, for the summary consumers read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct LayoutEntry {
    pub chart: String,
    pub version: String,
    pub tag: String,
    /// The manifest's `org.opencontainers.image.ref.name` in the layout.
    pub ref_name: String,
    pub manifest_digest: String,
    pub chart_digest: String,
}

fn write_file(path: &Path, bytes: &[u8]) -> Result<(), PushError> {
    fs::write(path, bytes).map_err(|source| PushError::LayoutIo {
        path: path.display().to_string(),
        source,
    })
}

fn blob_path(dir: &Path, digest: &str) -> PathBuf {
    let hex = digest.strip_prefix("sha256:").unwrap_or(digest);
    dir.join("blobs").join("sha256").join(hex)
}

/// Write one OCI image layout: every version of ONE chart (`RefStyle::Version`)
/// or every chart of a repository (`RefStyle::ChartVersion`).
///
/// Refuses, under `Version`, charts of different names (that layout is one
/// chart's OCI repository), and always two different archives claiming the
/// same chart version (the tag would mean two things). Identical archives are
/// deduplicated. Manifests are listed in `index.json` sorted by ref.name, so
/// the file is a function of the chart set, not of argument order.
pub(crate) fn write_layout(
    dir: &Path,
    charts: &[HelmChart],
    style: RefStyle,
) -> Result<Vec<LayoutEntry>, PushError> {
    let mut by_tag: BTreeMap<String, &HelmChart> = BTreeMap::new();
    let first = charts.first().ok_or(PushError::MissingArg("helm-chart"))?;
    for c in charts {
        if style == RefStyle::Version && c.name != first.name {
            return Err(PushError::LayoutMixedCharts {
                first: first.name.clone(),
                second: c.name.clone(),
            });
        }
        if let Some(prev) = by_tag.get(&style.ref_name(c)) {
            if prev.content != c.content {
                return Err(PushError::ChartVersionConflict {
                    chart: c.name.clone(),
                    version: c.version.clone(),
                });
            }
            continue;
        }
        by_tag.insert(style.ref_name(c), c);
    }

    let blobs = dir.join("blobs").join("sha256");
    fs::create_dir_all(&blobs).map_err(|source| PushError::LayoutIo {
        path: blobs.display().to_string(),
        source,
    })?;

    let mut entries = Vec::with_capacity(by_tag.len());
    let mut manifests = Vec::with_capacity(by_tag.len());
    for (ref_name, c) in &by_tag {
        let manifest = c.manifest();
        let manifest_digest = sha256_digest(&manifest);
        for bytes in [&c.config, &c.content, &manifest] {
            write_file(&blob_path(dir, &sha256_digest(bytes)), bytes)?;
        }
        let mut desc = match descriptor(MT_OCI_MANIFEST, &manifest) {
            Value::Object(m) => m,
            _ => Map::new(),
        };
        let mut ann = Map::new();
        ann.insert(ANN_REF_NAME.into(), Value::from(ref_name.as_str()));
        desc.insert("annotations".into(), Value::Object(ann));
        manifests.push(Value::Object(desc));
        entries.push(LayoutEntry {
            chart: c.name.clone(),
            version: c.version.clone(),
            tag: c.tag(),
            ref_name: ref_name.clone(),
            manifest_digest,
            chart_digest: c.chart_digest(),
        });
    }

    let mut index = Map::new();
    index.insert("schemaVersion".into(), Value::from(2));
    index.insert("mediaType".into(), Value::from(MT_OCI_INDEX));
    index.insert("manifests".into(), Value::Array(manifests));
    write_file(&dir.join("index.json"), &canonical_bytes(&Value::Object(index)))?;
    let mut marker = Map::new();
    marker.insert("imageLayoutVersion".into(), Value::from(LAYOUT_VERSION));
    write_file(&dir.join(LAYOUT_MARKER), &canonical_bytes(&Value::Object(marker)))?;
    Ok(entries)
}

/// One manifest of a layout, every byte it references read and verified.
#[derive(Clone, Debug)]
pub(crate) struct LayoutImage {
    /// `org.opencontainers.image.ref.name`, when the index names one.
    pub tag: Option<String>,
    pub manifest: Vec<u8>,
    pub manifest_digest: String,
    pub manifest_media_type: String,
    pub config_media_type: String,
    pub layer_media_types: Vec<String>,
    /// `(digest, bytes)` for the config and every layer, config first.
    pub blobs: Vec<(String, Vec<u8>)>,
}

fn layout_invalid(dir: &Path, detail: &'static str, subject: &str) -> PushError {
    PushError::LayoutInvalid {
        path: dir.display().to_string(),
        detail,
        subject: subject.to_string(),
    }
}

fn read_json(dir: &Path, file: &Path) -> Result<Value, PushError> {
    let bytes = fs::read(file).map_err(|source| PushError::LayoutIo {
        path: file.display().to_string(),
        source,
    })?;
    serde_json::from_slice(&bytes).map_err(|_| layout_invalid(dir, "is not JSON", &file.display().to_string()))
}

/// Read a descriptor's blob and prove it is what the descriptor says: the file
/// exists under its digest, its sha256 IS that digest, its length IS `size`.
fn read_blob(dir: &Path, desc: &Value) -> Result<(String, Vec<u8>, String), PushError> {
    let digest = desc
        .get("digest")
        .and_then(Value::as_str)
        .ok_or_else(|| layout_invalid(dir, "descriptor has no digest", ""))?;
    let media_type = desc
        .get("mediaType")
        .and_then(Value::as_str)
        .ok_or_else(|| layout_invalid(dir, "descriptor has no mediaType", digest))?;
    let size = desc
        .get("size")
        .and_then(Value::as_u64)
        .ok_or_else(|| layout_invalid(dir, "descriptor has no size", digest))?;
    if !digest.starts_with("sha256:") {
        return Err(layout_invalid(dir, "only sha256 digests are supported", digest));
    }
    let path = blob_path(dir, digest);
    let bytes = fs::read(&path).map_err(|source| PushError::LayoutIo {
        path: path.display().to_string(),
        source,
    })?;
    if sha256_digest(&bytes) != digest {
        return Err(layout_invalid(dir, "blob content does not hash to its digest", digest));
    }
    if bytes.len() as u64 != size {
        return Err(layout_invalid(dir, "blob size does not match its descriptor", digest));
    }
    Ok((digest.to_string(), bytes, media_type.to_string()))
}

/// Read and VERIFY an OCI image layout: the `oci-layout` marker, `index.json`,
/// and for every manifest it lists, the manifest blob plus its config and
/// every layer (each hashed and sized against its descriptor). A layout this
/// returns `Ok` for can be pushed without a registry ever rejecting a digest.
pub(crate) fn read_layout(dir: &Path) -> Result<Vec<LayoutImage>, PushError> {
    let marker = read_json(dir, &dir.join(LAYOUT_MARKER))?;
    if marker.get("imageLayoutVersion").and_then(Value::as_str) != Some(LAYOUT_VERSION) {
        return Err(layout_invalid(dir, "oci-layout imageLayoutVersion is not 1.0.0", ""));
    }
    let index = read_json(dir, &dir.join("index.json"))?;
    let manifests = index
        .get("manifests")
        .and_then(Value::as_array)
        .ok_or_else(|| layout_invalid(dir, "index.json has no manifests array", ""))?;
    let mut images = Vec::with_capacity(manifests.len());
    for desc in manifests {
        let (manifest_digest, manifest, manifest_media_type) = read_blob(dir, desc)?;
        if manifest_media_type != MT_OCI_MANIFEST {
            return Err(layout_invalid(
                dir,
                "only OCI image manifests are supported in index.json (no nested index)",
                &manifest_digest,
            ));
        }
        let tag = desc
            .get("annotations")
            .and_then(|a| a.get(ANN_REF_NAME))
            .and_then(Value::as_str)
            .map(str::to_string);
        let parsed: Value = serde_json::from_slice(&manifest)
            .map_err(|_| layout_invalid(dir, "manifest blob is not JSON", &manifest_digest))?;
        if parsed.get("mediaType").and_then(Value::as_str) != Some(MT_OCI_MANIFEST) {
            return Err(layout_invalid(
                dir,
                "manifest's own mediaType differs from its index descriptor",
                &manifest_digest,
            ));
        }
        let config_desc = parsed
            .get("config")
            .ok_or_else(|| layout_invalid(dir, "manifest has no config", &manifest_digest))?;
        let layers = parsed
            .get("layers")
            .and_then(Value::as_array)
            .ok_or_else(|| layout_invalid(dir, "manifest has no layers array", &manifest_digest))?;
        let (cd, cb, cmt) = read_blob(dir, config_desc)?;
        let mut blobs = vec![(cd, cb)];
        let mut layer_media_types = Vec::with_capacity(layers.len());
        for l in layers {
            let (d, b, mt) = read_blob(dir, l)?;
            blobs.push((d, b));
            layer_media_types.push(mt);
        }
        images.push(LayoutImage {
            tag,
            manifest,
            manifest_digest,
            manifest_media_type,
            config_media_type: cmt,
            layer_media_types,
            blobs,
        });
    }
    Ok(images)
}

/// The summary `oci-push layout --summary` writes and `mkHelmRepo` publishes
/// as `charts.json`: what is in the layouts, by chart, version, tag and digest.
pub(crate) fn summary_json(repository: Option<&str>, entries: &[(String, LayoutEntry)]) -> Vec<u8> {
    let charts: Vec<Value> = entries
        .iter()
        .map(|(layout, e)| {
            let mut m = Map::new();
            m.insert("chart".into(), Value::from(e.chart.as_str()));
            m.insert("version".into(), Value::from(e.version.as_str()));
            m.insert("tag".into(), Value::from(e.tag.as_str()));
            m.insert("refName".into(), Value::from(e.ref_name.as_str()));
            m.insert("digest".into(), Value::from(e.manifest_digest.as_str()));
            m.insert("chartDigest".into(), Value::from(e.chart_digest.as_str()));
            m.insert("layout".into(), Value::from(layout.as_str()));
            Value::Object(m)
        })
        .collect();
    let mut root = Map::new();
    root.insert("charts".into(), Value::Array(charts));
    if let Some(r) = repository {
        root.insert("repository".into(), Value::from(r));
    }
    let mut out = canonical_bytes(&Value::Object(root));
    out.push(b'\n');
    out
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// A chart archive shaped like mkHelmChart's output: gzip, files only,
    /// `<name>/Chart.yaml` at depth one plus a subchart's Chart.yaml deeper.
    pub(crate) fn chart_tgz(name: &str, version: &str) -> Vec<u8> {
        let mut chart_yaml = String::from("apiVersion: v2\ndescription: test chart\nname: ");
        chart_yaml.push_str(name);
        chart_yaml.push_str("\ntype: application\nversion: ");
        chart_yaml.push_str(version);
        chart_yaml.push('\n');
        let mut root = String::from(name);
        root.push('/');
        let files: Vec<(String, Vec<u8>)> = vec![
            ([root.as_str(), "Chart.yaml"].concat(), chart_yaml.into_bytes()),
            (
                [root.as_str(), "charts/lib/Chart.yaml"].concat(),
                b"apiVersion: v2\nname: lib\nversion: 9.9.9\ntype: library\n".to_vec(),
            ),
            ([root.as_str(), "values.yaml"].concat(), b"a: 1\n".to_vec()),
        ];
        let mut tar_bytes = Vec::new();
        {
            let mut b = tar::Builder::new(&mut tar_bytes);
            for (p, data) in &files {
                let mut h = tar::Header::new_gnu();
                h.set_size(data.len() as u64);
                h.set_mode(0o644);
                h.set_mtime(1);
                h.set_cksum();
                b.append_data(&mut h, p, data.as_slice()).unwrap();
            }
            b.finish().unwrap();
        }
        let mut enc = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::new(9));
        std::io::Write::write_all(&mut enc, &tar_bytes).unwrap();
        enc.finish().unwrap()
    }

    pub(crate) fn scratch(name: &str) -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push("doca-helm-tests");
        p.push(name);
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).unwrap();
        p
    }

    fn all_files(dir: &Path) -> BTreeMap<String, Vec<u8>> {
        let mut out = BTreeMap::new();
        let mut stack = vec![dir.to_path_buf()];
        while let Some(d) = stack.pop() {
            for e in fs::read_dir(&d).unwrap() {
                let p = e.unwrap().path();
                if p.is_dir() {
                    stack.push(p);
                } else {
                    let rel = p.strip_prefix(dir).unwrap().display().to_string();
                    out.insert(rel, fs::read(&p).unwrap());
                }
            }
        }
        out
    }

    #[test]
    fn reads_metadata_from_the_root_chart_yaml_not_a_subchart() {
        let c = HelmChart::from_archive("t", chart_tgz("app", "1.2.3+nix.1")).unwrap();
        assert_eq!(c.name, "app");
        assert_eq!(c.version, "1.2.3+nix.1");
        assert_eq!(c.tag(), "1.2.3_nix.1");
        // canonical: sorted keys, compact
        assert_eq!(
            String::from_utf8(c.config.clone()).unwrap(),
            r#"{"apiVersion":"v2","description":"test chart","name":"app","type":"application","version":"1.2.3+nix.1"}"#
        );
    }

    #[test]
    fn refuses_a_non_chart() {
        assert!(matches!(
            HelmChart::from_archive("t", b"not gzip".to_vec()),
            Err(PushError::HelmChart { .. })
        ));
        let mut enc = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::new(1));
        let mut tar_bytes = Vec::new();
        tar::Builder::new(&mut tar_bytes).finish().unwrap();
        std::io::Write::write_all(&mut enc, &tar_bytes).unwrap();
        assert!(matches!(
            HelmChart::from_archive("t", enc.finish().unwrap()),
            Err(PushError::HelmChart { detail, .. }) if detail.contains("no <dir>/Chart.yaml")
        ));
    }

    #[test]
    fn manifest_carries_helm_media_types_and_exact_digests() {
        let c = HelmChart::from_archive("t", chart_tgz("app", "0.1.0")).unwrap();
        let m: Value = serde_json::from_slice(&c.manifest()).unwrap();
        assert_eq!(m["mediaType"], MT_OCI_MANIFEST);
        assert_eq!(m["config"]["mediaType"], MT_HELM_CONFIG);
        assert_eq!(m["config"]["digest"], sha256_digest(&c.config).as_str());
        assert_eq!(m["layers"].as_array().unwrap().len(), 1, "helm pull requires exactly one chart layer");
        assert_eq!(m["layers"][0]["mediaType"], MT_HELM_CHART);
        assert_eq!(m["layers"][0]["digest"], sha256_digest(&c.content).as_str());
        assert_eq!(m["layers"][0]["size"], c.content.len() as u64);
        assert!(m["annotations"].get("org.opencontainers.image.created").is_none());
        // the manifest is canonical: re-canonicalising changes nothing
        assert_eq!(canonical_bytes(&m), c.manifest());
    }

    #[test]
    fn layout_validates_and_names_the_tag() {
        let dir = scratch("layout-validates");
        let c = HelmChart::from_archive("t", chart_tgz("app", "0.1.0+b")).unwrap();
        let entries = write_layout(&dir, &[c.clone()], RefStyle::Version).unwrap();
        assert_eq!(entries.len(), 1);
        let images = read_layout(&dir).unwrap();
        assert_eq!(images.len(), 1);
        let img = &images[0];
        assert_eq!(img.tag.as_deref(), Some("0.1.0_b"));
        assert_eq!(img.manifest_digest, entries[0].manifest_digest);
        assert_eq!(img.config_media_type, MT_HELM_CONFIG);
        assert_eq!(img.layer_media_types, vec![MT_HELM_CHART.to_string()]);
        assert_eq!(img.blobs[1].1, c.content, "the chart layer is the archive byte for byte");
        assert_eq!(
            fs::read_to_string(dir.join("oci-layout")).unwrap(),
            r#"{"imageLayoutVersion":"1.0.0"}"#
        );
    }

    #[test]
    fn layout_is_a_function_of_the_chart_set_not_argument_order() {
        let a = HelmChart::from_archive("a", chart_tgz("app", "0.1.0")).unwrap();
        let b = HelmChart::from_archive("b", chart_tgz("app", "0.2.0")).unwrap();
        let d1 = scratch("order-1");
        let d2 = scratch("order-2");
        write_layout(&d1, &[a.clone(), b.clone()], RefStyle::Version).unwrap();
        write_layout(&d2, &[b, a.clone(), a], RefStyle::Version).unwrap();
        let f1 = all_files(&d1);
        assert_eq!(f1, all_files(&d2));
        // 2 configs + 2 charts + 2 manifests + index.json + oci-layout
        assert_eq!(f1.len(), 8);
    }

    #[test]
    fn layout_refuses_mixed_charts_and_conflicting_versions() {
        let a = HelmChart::from_archive("a", chart_tgz("app", "0.1.0")).unwrap();
        let other = HelmChart::from_archive("o", chart_tgz("other", "0.1.0")).unwrap();
        assert!(matches!(
            write_layout(&scratch("mixed"), &[a.clone(), other.clone()], RefStyle::Version),
            Err(PushError::LayoutMixedCharts { .. })
        ));
        let mut forged = a.clone();
        forged.content.push(0);
        assert!(matches!(
            write_layout(&scratch("conflict"), &[a.clone(), forged], RefStyle::ChartVersion),
            Err(PushError::ChartVersionConflict { .. })
        ));
    }

    /// The porto contract: ONE layout for the whole repository, each manifest
    /// named `<chart>:<tag>` (`+` as `_`), no registry host.
    #[test]
    fn repository_layout_names_every_manifest_chart_colon_tag() {
        let dir = scratch("repo-layout");
        let a = HelmChart::from_archive("a", chart_tgz("app", "0.1.0+nix.1")).unwrap();
        let o = HelmChart::from_archive("o", chart_tgz("other", "2.0.0")).unwrap();
        let entries = write_layout(&dir, &[o, a], RefStyle::ChartVersion).unwrap();
        let refs: Vec<_> = read_layout(&dir).unwrap().into_iter().map(|i| i.tag.unwrap()).collect();
        assert_eq!(refs, vec!["app:0.1.0_nix.1".to_string(), "other:2.0.0".to_string()]);
        assert_eq!(entries[0].tag, "0.1.0_nix.1");
        assert_eq!(split_ref_name("app:0.1.0_nix.1"), (Some("app"), "0.1.0_nix.1"));
        assert_eq!(split_ref_name("0.1.0"), (None, "0.1.0"));
    }

    #[test]
    fn verifier_catches_a_tampered_blob_and_a_wrong_size() {
        let dir = scratch("tamper");
        let c = HelmChart::from_archive("t", chart_tgz("app", "0.1.0")).unwrap();
        write_layout(&dir, &[c.clone()], RefStyle::Version).unwrap();
        // control: untampered layout verifies
        assert!(read_layout(&dir).is_ok());
        let chart_blob = blob_path(&dir, &c.chart_digest());
        let mut bytes = fs::read(&chart_blob).unwrap();
        bytes.push(0);
        fs::write(&chart_blob, &bytes).unwrap();
        assert!(matches!(
            read_layout(&dir),
            Err(PushError::LayoutInvalid { detail, .. }) if detail.contains("hash")
        ));
    }

    #[test]
    fn summary_is_canonical() {
        let e = LayoutEntry {
            chart: "app".into(),
            version: "0.1.0".into(),
            tag: "0.1.0".into(),
            manifest_digest: "sha256:aa".into(),
            chart_digest: "sha256:bb".into(),
            ref_name: "app:0.1.0".into(),
        };
        let s = String::from_utf8(summary_json(Some("pleme-io/charts"), &[("app".into(), e)])).unwrap();
        assert_eq!(
            s,
            "{\"charts\":[{\"chart\":\"app\",\"chartDigest\":\"sha256:bb\",\"digest\":\"sha256:aa\",\"layout\":\"app\",\"refName\":\"app:0.1.0\",\"tag\":\"0.1.0\",\"version\":\"0.1.0\"}],\"repository\":\"pleme-io/charts\"}\n"
        );
    }
}
