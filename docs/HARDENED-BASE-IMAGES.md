# HARDENED-BASE-IMAGES — the default way every non-scratch OCI image is built

**Rule.** Every pleme-io OCI image that isn't a genuinely static, scratch-base
binary (that case is [`MINIMAL-PRODUCTION-IMAGE.md`](./MINIMAL-PRODUCTION-IMAGE.md),
sibling doc) is built by wrapping an nixpkgs-built derivation on a hardened base
from [`lib/build/oci/hardened-base.nix`](../lib/build/oci/hardened-base.nix) —
never a hand-rolled `pkgs.dockerTools.buildLayeredImage` call. This is Pillar 8
applied to the dynamically-linked / multi-file / vendor-rewrap case
`MINIMAL-PRODUCTION-IMAGE.md`'s scratch posture doesn't cover.

## The primitive

`hardened-base.nix` exposes three base families and two builders:

| Base | Contents | For |
|---|---|---|
| `bases.distroless-static` | CA roots + nonroot passwd/group + writable /tmp. No libc. | statically-linked binaries |
| `bases.distroless-glibc` | distroless-static + glibc | **the default** — dynamically-linked Rust/Go/etc. binaries |
| `bases.wolfi` | distroless-glibc + busybox | a runtime that needs a minimal shell/coreutils (e.g. Ruby's C-extension toolchain) |

| Builder | Shape | Use for |
|---|---|---|
| `mkPackageImage` | wraps ONE nixpkgs derivation (a compiled binary, or a full package like RabbitMQ) on a hardened base | the default — nearly every service/tool image |
| `mkVendorRewrap` | pulls an upstream image by digest, extracts ONE named binary from its rootfs, repackages on a hardened base | replacing a vendor-shipped image (e.g. an akeyless base image) with a hardened rewrap |

Every base carries the fleet's nonroot convention — **uid/gid 65532** (`nonrootUid`/`nonrootGid`), the same numeric convention distroless/Chainguard use. `mkPackageImage`'s `user` defaults to it; only override for a genuine need (host-mount access, a service that must run root).

## The recipe

```nix
hardened = import "${substrate}/lib/build/oci/hardened-base.nix" { inherit pkgs; };
in hardened.mkPackageImage {
  service = "my-service";
  base = hardened.bases.distroless-glibc;   # dynamically-linked binary — the common case
  package = myBinaryDerivation;              # whatever nixpkgs/gen/lockfile-builder already builds
  publishName = "ghcr.io/pleme-io/my-service";
  publishTag = version;
  entrypoint = [ "${myBinaryDerivation}/bin/my-service" ];
  env = [ "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt" "RUST_LOG=info" ];
  # user defaults to hardened.nonrootUid:nonrootGid; extraContents = [ ... ] for anything beyond cacert+binary
};
```

Adjust the relative import path to wherever the consuming flake already refers
to `substrate` (a flake input, `${substrate}/...`) or `../oci/hardened-base.nix`
from within substrate itself.

## Two shared per-language wrappers already build on this

- **`lib/build/go/docker.nix`** (`mkGoDockerImage`) — still owns its own
  distroless-selection ladder for the *static* Go case (Pillar 8's
  scratch-vs-distroless knob, see `MINIMAL-PRODUCTION-IMAGE.md`); only its
  nonroot `user` default is shared with hardened-base's convention (65532, not
  the older, silently-drifted 65534 "nobody").
- **`lib/build/rust/tool-image.nix`** (`mkImage`) — the shared Rust CLI-tool
  image builder. Fully converted to `mkPackageImage` + `distroless-glibc`
  (2026-07-18); every consumer of this shared function is hardened by this one
  change, no per-repo work needed.

**These are not yet unified into one canonical surface.** `shared/docker-image.nix`
(`mkTypedDockerImage`/`mkWebDockerImage`) already *claims*, in its own header
comment, to be the universal builder meant to replace the per-language
implementations — it hasn't been finished or adopted yet. Treat that file as
the eventual consolidation target, not a second, competing implementation to
extend independently. Tracked as fleet follow-up work.

## Worked examples (real, committed, this is not a hypothetical pattern)

- `pleme-io/breathe` — three service images (controller, host-agent, api-server)
  built per-workspace-member via `substrate.rust.library`, each wrapped with
  `mkPackageImage` + `distroless-glibc` (host-agent overrides `user = "0:0"`
  since it genuinely needs host access — the documented exception, not the norm).
- `pleme-io/saber`, `pleme-io/batata-quente` — single Rust API-server binaries,
  straightforward swap, ports/env preserved exactly.
- `pleme-io/dev-tools` (`operator-lib`'s `mkOperatorDockerImage`) — converted
  the same way even though it turned out to have zero live consumers (a
  separate, confirmed finding — see the fleet audit below).

## What this is NOT for — the documented exception class

CI-runner / diagnostic-toolchain images (ARC runner images, `forge`'s
provisioning image, `umbra`'s diagnostic sidecar, `tatara-lisp`'s universal
action base) deliberately bake in many tools + a real shell + often root, and
should **not** be forced onto `mkPackageImage`'s single-binary shape. Their
real security boundary is pod ephemerality + node isolation + scoped tokens,
not shrinking the image — a large, root-capable, but fully Nix-pinned toolchain
is the *correct* answer there, not a violation of this doctrine. Tag these
with a one-line `# not a hardened-base candidate: <reason>` comment rather than
silently leaving them unexplained. (A shared `mkToolboxImage` scaffold —
common `/tmp` handling + the `closureInfo`/SBOM passthrough fix, NOT a curated
tool allowlist — is a separate, real follow-up these six images all need
regardless of the single-binary question, since none of them currently carry
the closure-info fix `hardened-base.nix`'s other builders already have.)

## Standing rule

Every new or touched image-producing flake in pleme-io routes through this
primitive (or the documented CI-runner/toolchain exception). See
[`theory/SECURITY-LAYER.md`](https://github.com/pleme-io/theory/blob/main/SECURITY-LAYER.md)
§8/§9 for the ledger + the org-wide standing rule this doc is cited from.
