//! An in-process OCI distribution registry for doca's own tests — just enough
//! of the spec (chunked + monolithic blob upload, manifest PUT/GET/HEAD, blob
//! GET/HEAD) to round-trip an artifact through the REAL oci-client code paths
//! `push`, `push --layout` and `transfer` use, with no network and no external
//! binary. It verifies every finished upload against the digest the client
//! named, exactly as a real registry does, so a doca bug that mis-digests a
//! blob fails here rather than at ghcr.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};

use crate::helm::sha256_digest;

#[derive(Default)]
pub(crate) struct Store {
    pub blobs: HashMap<String, Vec<u8>>,
    /// (repository, tag-or-digest) -> (content type, bytes)
    pub manifests: HashMap<(String, String), (String, Vec<u8>)>,
    uploads: HashMap<String, Vec<u8>>,
    next: u64,
}

pub(crate) struct TestRegistry {
    pub addr: String,
    pub store: Arc<Mutex<Store>>,
}

impl TestRegistry {
    pub(crate) fn start() -> TestRegistry {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap().to_string();
        let store = Arc::new(Mutex::new(Store::default()));
        let shared = store.clone();
        std::thread::spawn(move || {
            for conn in listener.incoming().flatten() {
                let st = shared.clone();
                std::thread::spawn(move || {
                    let _ = serve(conn, &st);
                });
            }
        });
        TestRegistry { addr, store }
    }
}

struct Response {
    status: u16,
    headers: Vec<(&'static str, String)>,
    body: Vec<u8>,
}

fn resp(status: u16) -> Response {
    Response { status, headers: Vec::new(), body: Vec::new() }
}

fn serve(stream: TcpStream, store: &Arc<Mutex<Store>>) -> std::io::Result<()> {
    let mut writer = stream.try_clone()?;
    let mut reader = BufReader::new(stream);
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line)? == 0 {
            return Ok(());
        }
        let mut parts = line.split_whitespace();
        let method = parts.next().unwrap_or("").to_string();
        let target = parts.next().unwrap_or("").to_string();
        let mut headers: HashMap<String, String> = HashMap::new();
        loop {
            let mut h = String::new();
            reader.read_line(&mut h)?;
            let h = h.trim_end();
            if h.is_empty() {
                break;
            }
            if let Some((k, v)) = h.split_once(':') {
                headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
            }
        }
        let mut body = Vec::new();
        if headers.get("transfer-encoding").map(String::as_str) == Some("chunked") {
            loop {
                let mut size = String::new();
                reader.read_line(&mut size)?;
                let n = usize::from_str_radix(size.trim(), 16).unwrap_or(0);
                let mut chunk = vec![0u8; n + 2];
                reader.read_exact(&mut chunk)?;
                if n == 0 {
                    break;
                }
                body.extend_from_slice(&chunk[..n]);
            }
        } else if let Some(len) = headers.get("content-length").and_then(|l| l.parse::<usize>().ok()) {
            body = vec![0u8; len];
            reader.read_exact(&mut body)?;
        }
        let r = handle(&method, &target, &headers, body, store);
        let mut head = String::from("HTTP/1.1 ");
        head.push_str(&r.status.to_string());
        head.push_str(" X\r\nContent-Length: ");
        head.push_str(&r.body.len().to_string());
        head.push_str("\r\n");
        for (k, v) in &r.headers {
            head.push_str(k);
            head.push_str(": ");
            head.push_str(v);
            head.push_str("\r\n");
        }
        head.push_str("\r\n");
        writer.write_all(head.as_bytes())?;
        if method != "HEAD" {
            writer.write_all(&r.body)?;
        }
        writer.flush()?;
    }
}

fn query_param(query: &str, key: &str) -> Option<String> {
    query.split('&').find_map(|kv| {
        let (k, v) = kv.split_once('=')?;
        (k == key).then(|| v.replace("%3A", ":").replace("%3a", ":"))
    })
}

fn handle(
    method: &str,
    target: &str,
    headers: &HashMap<String, String>,
    body: Vec<u8>,
    store: &Arc<Mutex<Store>>,
) -> Response {
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    if path == "/v2/" || path == "/v2" {
        let mut r = resp(200);
        r.body = b"{}".to_vec();
        return r;
    }
    let Some(rest) = path.strip_prefix("/v2/") else { return resp(404) };
    let mut st = store.lock().unwrap();

    if let Some(i) = rest.rfind("/blobs/uploads") {
        let name = &rest[..i];
        let id = rest[i + "/blobs/uploads".len()..].trim_start_matches('/').to_string();
        let mut location = String::from("/v2/");
        location.push_str(name);
        location.push_str("/blobs/uploads/");
        match method {
            "POST" => {
                st.next += 1;
                let id = st.next.to_string();
                st.uploads.insert(id.clone(), Vec::new());
                location.push_str(&id);
                let mut r = resp(202);
                r.headers.push(("Location", location));
                return r;
            }
            "PATCH" => {
                let Some(buf) = st.uploads.get_mut(&id) else { return resp(404) };
                buf.extend_from_slice(&body);
                let end = buf.len().saturating_sub(1);
                location.push_str(&id);
                let mut r = resp(202);
                r.headers.push(("Location", location));
                r.headers.push(("Range", ["0-", &end.to_string()].concat()));
                return r;
            }
            "PUT" => {
                let Some(mut buf) = st.uploads.remove(&id) else { return resp(404) };
                buf.extend_from_slice(&body);
                let Some(digest) = query_param(query, "digest") else { return resp(400) };
                if sha256_digest(&buf) != digest {
                    return resp(400);
                }
                st.blobs.insert(digest.clone(), buf);
                let mut r = resp(201);
                r.headers.push(("Location", ["/v2/", name, "/blobs/", &digest].concat()));
                r.headers.push(("Docker-Content-Digest", digest));
                return r;
            }
            _ => return resp(405),
        }
    }
    if let Some(i) = rest.rfind("/blobs/") {
        let digest = &rest[i + "/blobs/".len()..];
        return match st.blobs.get(digest) {
            Some(b) => {
                let mut r = resp(200);
                r.headers.push(("Docker-Content-Digest", digest.to_string()));
                r.headers.push(("Content-Type", "application/octet-stream".into()));
                r.body = b.clone();
                r
            }
            None => resp(404),
        };
    }
    if let Some(i) = rest.rfind("/manifests/") {
        let name = rest[..i].to_string();
        let reference = rest[i + "/manifests/".len()..].to_string();
        match method {
            "PUT" => {
                let ct = headers.get("content-type").cloned().unwrap_or_default();
                let digest = sha256_digest(&body);
                st.manifests.insert((name.clone(), reference), (ct.clone(), body.clone()));
                st.manifests.insert((name.clone(), digest.clone()), (ct, body));
                let mut r = resp(201);
                r.headers.push(("Location", ["/v2/", &name, "/manifests/", &digest].concat()));
                r.headers.push(("Docker-Content-Digest", digest));
                return r;
            }
            "GET" | "HEAD" => {
                return match st.manifests.get(&(name, reference)) {
                    Some((ct, b)) => {
                        let mut r = resp(200);
                        r.headers.push(("Content-Type", ct.clone()));
                        r.headers.push(("Docker-Content-Digest", sha256_digest(b)));
                        r.body = b.clone();
                        r
                    }
                    None => resp(404),
                };
            }
            _ => return resp(405),
        }
    }
    resp(404)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::helm::{self, HelmChart};
    use crate::{cmd_transfer, push_layout, PushSpec, ACCEPTED_LAYERS};
    use oci_client::secrets::RegistryAuth;
    use oci_client::Client;
    use std::path::Path;

    fn spec(addr: &str, image: &str, layout: &Path, tags: Vec<String>) -> PushSpec {
        PushSpec {
            registry: addr.to_string(),
            image: image.to_string(),
            tags,
            tarball: String::new(),
            layout: Some(layout.display().to_string()),
            dest_user: "u".into(),
            dest_pass: "p".into(),
            insecure: false,
            ca_cert: None,
        }
    }

    /// layout → push → pull, through the real oci-client, the way `helm pull`
    /// sees it: the manifest the registry serves is the layout's manifest byte
    /// for byte (same digest), its config carries the Helm media type, and the
    /// single chart layer is the original archive.
    #[test]
    fn helm_layout_round_trips_through_a_registry_with_its_digest() {
        let reg = TestRegistry::start();
        let dir = helm::tests::scratch("roundtrip");
        let chart = HelmChart::from_archive("t", helm::tests::chart_tgz("app", "0.1.0+nix.1")).unwrap();
        let entries = helm::write_layout(&dir, &[chart.clone()]).unwrap();

        push_layout(&spec(&reg.addr, "pleme-io/charts/app", &dir, vec![]), &dir.display().to_string()).unwrap();

        {
            let st = reg.store.lock().unwrap();
            let (ct, served) = st
                .manifests
                .get(&("pleme-io/charts/app".to_string(), "0.1.0_nix.1".to_string()))
                .expect("pushed under the ref.name tag, with + spelled _");
            assert_eq!(ct, helm::MT_OCI_MANIFEST);
            assert_eq!(sha256_digest(served), entries[0].manifest_digest, "registry digest == layout digest");
        }

        let mut reference = reg.addr.clone();
        reference.push_str("/pleme-io/charts/app:0.1.0_nix.1");
        let r: oci_client::Reference = reference.parse().unwrap();
        let rt = crate::runtime().unwrap();
        let data = rt
            .block_on(Client::new(crate::client_config_for(&reg.addr, false, &None).unwrap()).pull(
                &r,
                &RegistryAuth::Anonymous,
                vec![helm::MT_HELM_CHART],
            ))
            .unwrap();
        assert_eq!(data.config.media_type, helm::MT_HELM_CONFIG);
        assert_eq!(data.config.data, chart.config);
        assert_eq!(data.layers.len(), 1);
        assert_eq!(data.layers[0].media_type, helm::MT_HELM_CHART);
        assert_eq!(data.layers[0].data, chart.content, "helm pull gets the archive byte for byte");
        assert_eq!(data.digest.as_deref(), Some(entries[0].manifest_digest.as_str()));
    }

    /// `--tag` selects one manifest and `--additional-tags` alias it; a tag the
    /// layout does not carry is refused before any upload.
    #[test]
    fn layout_push_selects_and_aliases_by_tag() {
        let reg = TestRegistry::start();
        let dir = helm::tests::scratch("select");
        let a = HelmChart::from_archive("a", helm::tests::chart_tgz("app", "0.1.0")).unwrap();
        let b = HelmChart::from_archive("b", helm::tests::chart_tgz("app", "0.2.0")).unwrap();
        helm::write_layout(&dir, &[a, b]).unwrap();
        let layout = dir.display().to_string();

        push_layout(&spec(&reg.addr, "c/app", &dir, vec!["0.2.0".into(), "latest".into()]), &layout).unwrap();
        {
            let st = reg.store.lock().unwrap();
            let get = |t: &str| st.manifests.get(&("c/app".to_string(), t.to_string())).map(|m| m.1.clone());
            assert!(get("0.2.0").is_some());
            assert_eq!(get("latest"), get("0.2.0"));
            assert!(get("0.1.0").is_none(), "only the selected manifest is pushed");
        }
        assert!(matches!(
            push_layout(&spec(&reg.addr, "c/app", &dir, vec!["9.9.9".into()]), &layout),
            Err(crate::PushError::LayoutTagAbsent { .. })
        ));
    }

    /// `transfer` mirrors a Helm chart registry-to-registry (it used to refuse
    /// the chart layer's media type), and the canonical manifest keeps its
    /// digest across the copy.
    #[test]
    fn transfer_mirrors_a_helm_chart_keeping_its_digest() {
        assert!(ACCEPTED_LAYERS.contains(&helm::MT_HELM_CHART));
        let reg = TestRegistry::start();
        let dir = helm::tests::scratch("transfer");
        let chart = HelmChart::from_archive("t", helm::tests::chart_tgz("app", "0.3.0")).unwrap();
        let entries = helm::write_layout(&dir, &[chart]).unwrap();
        push_layout(&spec(&reg.addr, "src/app", &dir, vec![]), &dir.display().to_string()).unwrap();

        let src = [reg.addr.as_str(), "/src/app:0.3.0"].concat();
        let dest = [reg.addr.as_str(), "/mirror/app:0.3.0"].concat();
        let args: Vec<String> = ["--src", &src, "--dest", &dest, "--dest-user", "u", "--dest-pass", "p"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        cmd_transfer(args.into_iter()).unwrap();
        let st = reg.store.lock().unwrap();
        let (_, mirrored) = st
            .manifests
            .get(&("mirror/app".to_string(), "0.3.0".to_string()))
            .expect("transferred");
        assert_eq!(sha256_digest(mirrored), entries[0].manifest_digest);
    }
}
