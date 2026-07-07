# MINIMAL-PRODUCTION-IMAGE — the strict-stack default for every OCI image

**Rule.** Every production OCI image the substrate builds defaults to the
**strictest runtime closure the binary allows** — no OS base, no shell, no
coreutils, no package-manager, no init, and no OS libc a static binary does not
need. `minimal: true` is **default-on**; the image we ship is the image we
test with.

This is Pillar 8 (Nix images, no Dockerfiles) taken to its strict end, and the
build-side half of the camelot FedRAMP-High "minimal Nix closures" RA-5/SI-2
lever: fewer package sources ⇒ a cleaner CVE verdict **by construction**.

---

## Industry-standard-first (no NIH)

| Reference | What it is | Our equivalent |
|---|---|---|
| `gcr.io/distroless/static` (Google) | scratch + CA bundle, no shell/libc/init, for a static binary | `minimal: true` → the `scratch` base |
| Chainguard / Wolfi `static` | same posture, apk-free | same |
| Nix `dockerTools.buildLayeredImage` | ships ONLY the referenced closure — already best-in-class | the mechanism we build on |

Nix `dockerTools` already emits closure-only images, so this is **not a new
tool** — it is "strip to the strict closure + no shell/OS/init", expressed as a
typed knob and enforced by a build test.

## The strict stack

```
minimal image = buildLayeredImage {
  contents = [ static_go_binary, ca_bundle ];   # + the binary's own closure
}
```

- **scratch base** (no `fromImage`) — already true fleet-wide.
- **no shell / coreutils / busybox / pkg-mgr** — no fallback for an attacker.
- **no init (tini)** — a Go binary handles its own signals; tini is
  *dynamically linked* and drags the whole glibc subtree, so it is **not** free.
- **no OS libc** for a `CGO_ENABLED=0` binary — it is self-contained. A dynamic
  (CGO/boringcrypto) binary still gets its libc via its **own** closure, so
  `minimal` is always safe — it just ships more for a dynamic binary.
- Go built with **`-tags timetzdata,netgo,osusergo`** so the binary embeds
  zoneinfo and drops its `/etc/{protocols,services,mime.types,passwd}`
  references — nothing in the base is needed for name/time/user lookups.

Strict non-binary closure of a static service = **{ the binary, ca-bundle }**.

## The typed knob (substrate)

| Builder | Knob | Default | Effect |
|---|---|---|---|
| `lib/build/go/docker.nix::mkGoDockerImage` | `minimal` | `false`¹ | forces the `scratch` base (cacert only, no tini/busybox); overrides `distroless`/`tini`; self-declares `com.pleme.image.minimal=true` |
| `lib/build/go/service-flake.nix` | `minimal` | **`true`** | the production Go-service flake — minimal by default |
| `lib/build/go/service-flake.nix` | `goTags` | `[timetzdata netgo osusergo]` | static Go build tags (applied only when `minimal`) |
| `lib/build/go/docker.nix::mkGoServiceImage` | `minimal` | **`true`** | one-call helper — minimal by default |
| all three (`docker.nix`, `service-flake.nix`) | `withCacert` | **`true`** | keep the CA-cert bundle (outbound TLS needs it; a 0-code-CVE data pkg). `false` → true-scratch (binary only, ZERO non-binary closure) for a no-outbound-TLS service. `SSL_CERT_FILE` is emitted only when the bundle ships. The strip target is tini+glibc, never cacert. |

¹ `mkGoDockerImage` is the raw builder and stays back-compat `false`; the
**production** entry points (`service-flake.nix`, `mkGoServiceImage`) default it
**on**. Set `minimal = false` for a fat/debug image with a shell.

### Base-selection ladder (docker.nix)

| Mode | Base contents | Ships a shell? | glibc from base? |
|---|---|---|---|
| `minimal: true` | `cacert` (or nothing if `withCacert = false`) | no | no |
| `distroless: true` (+`tini`) | `cacert` (+ `tini`) | no | via tini (~32.6 MB) |
| neither (fat/debug) | `cacert` + `busybox` | **yes** | no |

## The measured gap this closes (tier-honest, from the built tarballs)

The 9 Akeyless microservice images were the reference workload. **Measured**
(not assumed) from the built `.tar.gz` in the store:

- Base was `cacert + tini`, **not** scratch. `tini` is dynamically linked and
  dragged the **entire glibc subtree** — `glibc + libidn2 + libunistring +
  libgcc` ≈ **32.6 MB uncompressed, 4 OS packages incl. glibc** — into a
  container whose only process is a **statically-linked** Go binary that needs
  none of it. Proven: extracted `tini`'s interpreter is the exact shipped
  `…-glibc-2.40/ld-linux`; `cacert`'s closure is itself-only (0 glibc).
- The Go binary's nixpkgs-stdlib patches referenced `tzdata + iana-etc +
  mailcap` ≈ **3.6 MB, 3 data packages** — removable via the build tags.
- **Net:** 9 OS packages → 1 (cacert, pure data); both material code-CVE OS
  sources (**glibc + tini**) → gone; non-binary closure ~37 MB → ~0.65 MB;
  est. ~10 MB compressed/image. The binary itself (and its vendored-Go-module
  CVE surface) is a **separate, app-level** concern and is unchanged.

Doc-honesty note: earlier comments claimed the tini base was "~3 MB extra" —
measured reality was ~37 MB (a ~12× under-count). Corrected 2026-07-07.

## The build tests — we test with the minimal production image

| Check | Where | Proves | Runs on |
|---|---|---|---|
| `go-minimal-image` | `tests/minimal-image-test.nix` | pure forcing-function: the minimal base has **no init, no shell, no glibc**; is cacert-only | every system (incl. darwin) |
| `go-minimal-image-serves` | `tests/minimal-image-serve-test.nix` + `fixtures/smoke` | builds the smoke fixture as a **scratch-base** image, then **starts it and curls `/health`=200** — a live proof the stripped image serves with no missing dep | Linux / super-cache-ci |
| `mkMinimalImageCheck` | `lib/build/go/minimal-image-check.nix` | reusable: unpacks any built image + asserts no shell/coreutils/init/libc in layers, static binary, closure ≤ ceiling, `com.pleme.image.minimal=true`, optional exec-smoke | Linux |

Both flake checks are wired in `substrate` `checks.<system>.*`; the fixture is
built through the **same** minimal builder a production service uses, so green
CI == the minimal image starts + serves.

## Composition

- **gen-secattest (per-derivation CVE layer):** a minimal image feeds the CVE
  gate a smaller package set — the `Concern::CveVex` verdict is cleaner by
  construction (RA-5/SI-2). The `com.pleme.image.minimal` label lets the gate /
  admission surface key off the posture.
- **super-cache-ci:** the build that produces these ships fewer store paths per
  image → less to hash/cache/push, with no change to the daemon path.
- **camelot:** "minimal Nix closures" is the named FedRAMP-High CVE-remediation
  lever; this standard makes it the default, not a manual strip.

## Tier-honesty ledger

| Piece | Tier |
|---|---|
| `minimal` knob (docker.nix, default-on in service-flake + mkGoServiceImage) | **shipped** |
| `goTags` static build tags threaded into the raw `go install` | **shipped** |
| `go-minimal-image` pure forcing-function (11/11, builds green) | **shipped** |
| `mkMinimalImageCheck` reusable conformance generator | **shipped** (Linux-run) |
| `go-minimal-image-serves` end-to-end build+run+serve | **shipped**, built by Linux CI (evaluated on darwin) |
| doc-honesty fix (~37 MB, not ~3 MB) | **shipped** |
| exact tzdata/iana/mailcap removal by tags | **measured intent** — the closure test MEASURES the real result; the tags are the standard Go static recipe |
| gen-secattest / cosign / SBOM wired into the Go image path | **design** — the knobs exist but the real scan is the zot faucet at admission, not the build |

## Waiver

`skip-minimal-image: <typed-reason>` at the top of the repo's `CLAUDE.md`.
Acceptable: a genuinely multi-process container needing an init reaper (use
`minimal = false` + `distroless = true` + `tini = true`, and name why); a
debug/dev image that must carry a shell. **Time pressure is not acceptable** —
minimal is one flag flip.
