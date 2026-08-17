# The fleet Go toolchain — substrate's answer to fenix

**Status:** shipped 2026-07-30. Proven on `x86_64-linux` (rio), eval-verified on
`aarch64-darwin`. The one number to know: **48 findings including 1 CRITICAL → 0,
with no suppression of any kind.**

**Canonical rule.** *Every Go artifact the fleet ships is compiled by
`substrate.goToolchains.${system}.stable` — a from-source Go pinned by explicit
version + sha256 in `lib/build/go/go-toolchain-pin.json`, built from SUBSTRATE's
nixpkgs. A consumer's own nixpkgs pin never decides which compiler its artifacts
are built by. Building below the pin's declared CVE floor is eval-rejected, not a
config knob.*

---

## 1. The incident this exists for

Read this first. Everything below is a consequence of it.

**2026-07-30.** A downstream consumer's monorepo
builds a hardened **distroless** web-ui image through substrate's
`mkStaticSpaImage`. Its flake pins `nixpkgs = nixos-24.05` (`b134951`, May 2024).
Trivy against the built image reported, against exactly **one** target —
`nix/store/…-compat-sh-bin-sh/bin/sh`, type `gobinary`:

```
Total: 48 (UNKNOWN: 0, LOW: 3, MEDIUM: 30, HIGH: 14, CRITICAL: 1)
  stdlib CVE-2025-68121 CRITICAL v1.22.8 -> 1.24.13, 1.25.7, 1.26.0-rc.3
         crypto/tls: incorrect certificate validation during session resumption
  stdlib CVE-2025-61726 HIGH     v1.22.8 -> 1.24.12, 1.25.6   (net/url)
```

Every other component scanned **clean**: the static musl Rust server binary, the
SPA assets, the config file, the CA roots. The entire CVE surface of a hardened
distroless image was one Go shim's stdlib.

That shim is `compat-sh` — 152 lines, a shaped `/bin/sh` that implements `sleep`
and refuses everything else. It exists because the akeyless saas chart names
`/bin/sh` in a `preStop` hook and a distroless image has none. **It cannot be
deleted.** It imports `fmt`, `os`, `strconv`, `strings`, `time` and nothing else.
It was vulnerable for exactly one reason: nixos-24.05 ships go 1.22.8.

The same pin produced two sibling failures the same day:

| symptom | cause |
|---|---|
| `go: go.mod requires go >= 1.23 (running go 1.22.8; GOTOOLCHAIN=local)` | 24.05's go cannot satisfy compat-sh's own `go` directive |
| `the package requires the Cargo feature called edition2024` | 24.05's cargo 1.77 cannot build oci-push, until `fenix` was threaded to it |
| 48 CVEs in a distroless image | 24.05's go compiled the only Go binary in it |

Three symptoms, one cause: **the consumer's nixpkgs was choosing the fleet's
compilers.** The Rust half of that had already been fixed (fenix →
`oci-push.nix`). The Go half had not.

### The load-bearing insight

> A Go binary's stdlib CVE set is decided by the **compiler**, not by the `go`
> directive in `go.mod`.

Compiling 152 *unchanged* lines with go 1.26.5 links a clean stdlib even while
`go.mod` still says `go 1.22`. This is visible directly on the proof artifact —
`go version -m` on the fixed binary shows `go1.26.5` *and* a
`DefaultGODEBUG=asynctimerchan=1,…` compatibility set, which is go 1.26 honouring
the 1.22 language directive. The directive governs **language semantics**; the
compiler governs **the stdlib you link**.

So this is a toolchain-provenance problem with a toolchain-provenance fix. No
source edit closes it. And per the standing operator bar, no scanner suppression
is allowed to either: **no `.trivyignore`, no VEX, no `--ignore-unfixed`, no
whitelist.** Fix at cause or not at all.

---

## 2. What fenix does, and the piece-by-piece Go mirror

fenix is not a compiler build. It is a **committed transcription of upstream's own
published hashes**, evaluated against **fenix's own nixpkgs**, delivered as a
finished derivation. Both halves matter:

- `lib/mk-toolchain.nix`: `src = fetchurl { inherit (source) url sha256; }` — the
  rustc/cargo bytes are rust-lang's release tarballs, as fixed-output derivations.
- `data/stable.json`: a committed `{url, hash}` table per component per target,
  regenerated from upstream's channel manifest by a bot. **Selection is a diff,
  never a resolution at eval.**
- `fenix.inputs.nixpkgs.follows = "nixpkgs"` in substrate: the toolchain is a
  function of (substrate's nixpkgs) × (fenix's hash tables). **The consumer's pin
  contributes nothing.**

| fenix (Rust) | substrate (Go) | state |
|---|---|---|
| `data/stable.json` | `lib/build/go/go-toolchain-pin.json` | **landed** |
| `lib/mk-toolchain.nix` (unpack prebuilt) | `lib/build/go/toolchain.nix` (compile from source) | **landed, deliberately divergent** — see §6 |
| `fenix.stable` | `substrate.goToolchains.${system}.stable` | **landed** |
| `fenix.toolchainOf { channel; date; sha256 }` | `mkGoToolchain { pkgs; version; hash }` | **landed** — hash **mandatory**, see §6 |
| `mkRustOverlay` | `mkGoOverlay { goToolchain }` | **landed**, secondary by design |
| `substrate.rustOverlays.${system}.rust` | `substrate.goOverlays.${system}.go` | **landed** |
| `oci-push.nix`'s `{ fenix ? null }` + scoped `makeRustPlatform` | `mkHardenedGoBinary`'s `goToolchain ? null` + scoped `buildGoModule.override` | **landed** — the shape that actually cures the incident |
| `fenix.targets.<triple>.rust-std` | *(none needed)* | **N/A** — Go cross is GOOS/GOARCH on one toolchain at CGO off |
| fenix's `update` bot regenerating `data/*.json` | *(nothing)* | **GAP** — the pin is hand-bumped and will rot. See §7 |

---

## 3. How to consume it

### The default path — nothing to do

Anything reached through `substrate.lib.${system}` already gets the pinned
compiler. `flake.nix` passes it into `./lib`, which passes it to
`hardened-image.nix` and `static-spa-image.nix`.

```nix
# Measured: this compiles compat-sh with go 1.26.5 even when `pkgs` is a
# nixos-24.05 package set whose own pkgs.go is 1.22.8.
substrate.lib.${system}.mkHardenedGoBinary pkgs { name = "svc"; src = ./.; vendorHash = null; }
```

### Per-derivation (the recommended explicit form)

```nix
hardened = import "${substrate}/lib/build/go/hardened-image.nix" {
  goToolchain = substrate.goToolchains.${system}.stable;
};
img = hardened.mkHardenedGoImage pkgs { name = "svc"; src = ./.; vendorHash = "sha256-…"; };
```

No new flake input. No requirement that the consumer's nixpkgs be recent.

### With your own pkgs, through `libFor`

```nix
lib = substrate.libFor {
  inherit pkgs system;
  fenix = …;                                        # Rust
  goToolchain = substrate.goToolchains.${system}.stable;  # Go
};
```

### Package-set-wide (secondary — read the warning)

```nix
pkgs = import nixpkgs { inherit system; overlays = [ substrate.goOverlays.${system}.go ]; };
```

This replaces `go` and `buildGoModule` **globally**, so every Go package in the
closure rebuilds against the substrate toolchain and `pkgsMusl` inherits it too.
This is precisely what `lib/build/rust/overlay.nix` refuses to do for rustc/cargo
("breaks nixpkgs packages (mercurial, librsvg, cryptography…)"). Prefer the
per-derivation seam.

---

## 4. The CVE floor

`mkHardenedGoBinary` rejects, **at eval time**, any build whose compiler is below
`go-toolchain-pin.json`'s `cveFloor`.

```
error: mkHardenedGoBinary: "compat-sh" would be compiled by Go 1.22.8,
       below the fleet CVE floor of 1.26.5.
       …
       No `goToolchain` was passed, so this build took the consuming nixpkgs' own
       `go`. That is exactly what produced the 2026-07-30 incident: 48 findings,
       1 CRITICAL, out of one 152-line shim compiled by go 1.22.8.
```

Three design points that are not obvious:

1. **It is asserted against `drv.passthru.go.version`** — the compiler read back
   off the built derivation — and **not** against `pkgs.go.version`. `pkgs.go` is
   a *proxy*: nixpkgs aliases `buildGoModule` to a versioned builder
   (`buildGo122Module` on 24.05), so an overlay that replaced one and not the
   other makes the two disagree. Asserting on the proxy would be a guard that
   examines the wrong thing.

2. **It is not default-off.** The toolchain *seam* is `? null` with graceful
   fallback, so a caller that passes nothing keeps its previous compiler. The
   *floor* is not — a floor a consumer can silently skip is decoration. A caller
   whose compiler already clears the floor is unaffected; a caller below it is
   deliberately broken, loudly, with the fix in the message.

3. **The floor caught substrate's own nixpkgs**, which is the clearest evidence it
   is not merely a "newer than 24.05" test: substrate's anchor ships go 1.26.3,
   itself 5 stdlib vulns short of clean, and substrate's own Linux image checks
   had to be threaded the toolchain to keep evaluating.

### Deviating

Lowering the floor is a deviation, not configuration. It needs
`skip-go-floor: <typed-reason>` at the top of the deviating repo's `CLAUDE.md`.
Prefer `goFloor = "1.25.12"` over `goFloor = null`, so the number you accepted
appears in the diff. Suppressing the *scanner* instead is never an option.

### Tier honesty — do not round these up

| claim | tier |
|---|---|
| a consumer that takes the toolchain builds with the pinned version | **truly-unrepresentable-otherwise** — the version is data on the derivation |
| the fleet never builds below the CVE floor | **eval-rejected** — a Nix `throw`, and only for callers going through `mkHardenedGoBinary` |
| "0 CVE" | **a claim about a date.** The floor asserts *not below the declared floor*, never *clean*. The database moves; the pin does not. |

### Which builders are floored

| builder | ceiling (go.mod ≤ toolchain) | floor (toolchain ≥ clean) |
|---|---|---|
| `mkHardenedGoBinary` / `mkHardenedGoImage` | — | **yes** |
| `mkStaticSpaImage` (via its compat-sh) | — | **yes** |
| `mkGoTool` | yes (`goVersionAssert`) | not yet |
| `private-module.nix` | yes | not yet |
| `package-builder.nix` | yes (`goLangAssert`) | not yet |
| `mkGoDockerImage` | — | not yet |

Note the asymmetry that existed before this change: **every** version assert in
`lib/build/go/` was a *ceiling* — go.mod must not be ahead of the toolchain.
Nothing anywhere asserted the toolchain was not **behind**. On an un-overlaid
24.05 consumer that combination is actively perverse: it *forbade* a modern
`go.mod` while *permitting* the old compiler, which is exactly the pair of
failures the incident produced.

---

## 5. The measured staleness ledger

Measured 2026-07-30 against all 159 stdlib entries in Go's own vulnerability
database (`vuln.go.dev/index/modules.json`, then each ID's OSV affected ranges):

| Go version | known stdlib vulns | what it was |
|---|---|---|
| 1.22.8 | (48 trivy findings) | nixos-24.05 — the incident |
| **1.25.9** | **13** | substrate's own pin *before this change* |
| **1.26.3** | **5** | substrate's own nixpkgs anchor (`6b31628`) |
| 1.26.4 | 2 | |
| **1.25.12** | **0** | last clean point on the 1.25 line |
| **1.26.5** | **0** | **the pin** |

Two conclusions, both load-bearing:

- **Shipping this at 1.25.9 would have failed the bar.** "Newer than the consumer"
  is not the requirement; *clean* is. 1.25.9 would have traded 48 findings for a
  smaller non-zero set.
- **"Just use nixpkgs' go" is not a fix for this class**, only a slower version of
  the same bug. Substrate's own anchor is not clean either. Only an explicit pin
  is deterministic by construction.

---

## 6. Two deliberate divergences from fenix

**Source tarball, not go.dev's prebuilt binaries.** `bootstrap.nix` already
fetches the prebuilt tarballs, and using them as the *delivered* compiler would be
the closer byte-level mirror of fenix. It is not done, because the prebuilt
toolchain lacks the `iana-etc` / `mailcap` / `tzdata` / `GO_LDSO` patches, and
those patch Go's **stdlib source**: they change the runtime lookup paths for
`/etc/services`, MIME types and zoneinfo in *every binary the fleet produces*.
Swapping to prebuilt is a fleet-wide **runtime** change wearing a build-plumbing
label. It needs its own decision, not a ride-along.

**The hash is mandatory.** `fenix.toolchainOf` falls back to
`builtins.fetchurl` when `sha256` is omitted — a network fetch at **eval** time.
`mkGoToolchain` throws instead. Substrate's determinism bar does not tolerate that
arm.

### Hermeticity: `GOTOOLCHAIN=local` is pinned in the toolchain

Upstream's `go.env` ships `GOTOOLCHAIN=auto` and nixpkgs copies it verbatim; the
`local` pin lived only in `buildGoModule`'s env. So every path that invokes `go`
*outside* `buildGoModule` — a devShell, `nix run`, `mkGoTool`'s completion
`postInstall`, the govulncheck gate — inherited `auto` and would **download a
compiler from the module proxy** the moment a `go.mod` asked for a newer one.
Inside a nix sandbox that fails closed and looks fine; on a network-enabled runner
it silently breaks HERMETIC SUPPLY CHAIN.

It is now pinned in `go.env` itself, via `--replace-fail` so a future upstream that
drops the line breaks the build loudly rather than quietly pinning nothing.
**Verified on the built Linux artifact:** `go env GOTOOLCHAIN` → `local`.

---

## 7. Honest gaps

- **The pin is hand-bumped and will rot.** fenix has a bot regenerating
  `data/*.json`; there is no analogue here. Substrate becoming the new bottleneck
  instead of the consumer's nixpkgs is a real risk, not a rhetorical one. Bump
  recipe in §8; a watch/autobump mechanism is unbuilt.
- **The musl lane is unproven.** `libc = "musl"` injects a compiler built against
  substrate's glibc stdenv into `pkgsMusl.buildGoModule`. Sound in principle for
  `libc = "none"` (the compiler only runs at build time and the artifact links no
  libc); for the static-PIE musl lane the C-toolchain/libc mixing was neither
  evaluated nor built. The musl lane was already documented as not proven on a
  Linux builder; that is unchanged.
- **Five Go builders are unfloored** (§4 table). Each carries only the ceiling.
- **`govulncheck` is not, and cannot be, the stdlib gate.** It is
  reachability-aware by design. Measured on rio against a program with compat-sh's
  own import set: `govulncheck ./...` printed *"No vulnerabilities found"* while
  itself noting the stdlib vulns it declined to report because "your code doesn't
  appear to call" them — and `govulncheck -mode=binary` on the **same** binary
  reported 28. Trivy's gobinary analyzer reads the same `.go.buildinfo` field
  binary mode falls back to, which is why the scanner said 48 and this gate would
  have said 0. Source mode answers "is my code exploitable"; the CVE floor answers
  "is my stdlib current". Both, not either. Additionally the gate is non-strict at
  defaults and a nix sandbox has no network to reach `vuln.go.dev`, so
  "could not analyse" and "clean" are indistinguishable in its exit status —
  **treat a green `img.checks.vuln` as evidence of nothing** unless it ran with
  network *and* strict.
- **The image conformance check's known-vacuous predicates were NOT touched.**
  `minimal-image-check.nix` greps `tar tzf` of the OUTER docker-archive, whose only
  members are `<sha>/layer.tar` + `manifest.json` + `<config>.json`, so its
  forbidden-component grep and store-path ceiling examine an empty set and cannot
  fail. That is a real defect, and it is *adjacent* to this change rather than part
  of it: fixing it naively turns `mkStaticSpaImage` red on its first run, because
  `/bin/sh` is in the default forbidden list while that builder ships one **on
  purpose** (`compatShell ? true`). The forbidden set has to become a function of
  the declared shape (assert `/bin/sh` *resolves to* the compat-sh store path) in
  the same change, or the gate just gets switched off. Left for its own change.
  **Do not cite a green Go conformance check as evidence about the toolchain.**
- **`checks.x86_64-linux.go-minimal-image-serves` is red, and was red before this
  change** (verified against `origin/main`): `CGO_ENABLED: in \`env\`: 1; in
  derivation arguments: "0"` — the fixture sets it as a top-level attr while
  substrate's own nixpkgs wants it in `env`. The portable fix is the `preBuild`
  export that `hardened-image.nix` already documents at length. Not touched here;
  that file is another workstream's active surface.

---

## 8. Bumping the fleet Go compiler

1. Read upstream's manifest — **never** a local prefetch:
   `curl -sS 'https://go.dev/dl/?mode=json&include=all'`
2. Confirm the candidate is clean against Go's own database:
   `vuln.go.dev/index/modules.json` → the `stdlib` entry → each ID's OSV ranges.
3. Edit `lib/build/go/go-toolchain-pin.json`: `version`, `srcHash` (hex → SRI),
   and `cveFloor` + `cveFloorMeasured` if the floor moves.
4. **Crossing a minor** additionally needs the matching
   `go_no_vendor_checks-<minor>.patch` copied from the nixpkgs anchor and added to
   `toolchain.nix`'s table. An unknown minor throws rather than reusing an older
   variant — that variant applies *with fuzz* on darwin and fails on the Linux
   builder, the slowest possible place to find out.
5. Build on Linux (`ssh rio`). Darwin cannot build these.

---

## 9. The proof

All on rio (`x86_64-linux`, 32 cores, nix 2.31.5), trivy 0.69.3 with a DB
downloaded the same day. One variable changed: whether substrate's pinned
toolchain is injected into the **incident consumer's own** nixos-24.05
`buildGoModule`. Same source, same builder, same hardening flags.

```
$ go version -m …/compat-sh          # BEFORE
compat-sh: go1.22.8
  build -tags=netgo,osusergo   build -trimpath=true   build CGO_ENABLED=0

$ go version -m …/compat-sh          # AFTER
compat-sh: go1.26.5
  build -tags=netgo,osusergo   build -trimpath=true   build CGO_ENABLED=0
  build DefaultGODEBUG=asynctimerchan=1,…      # go1.26 honouring go.mod's `go 1.22`
```

```
BEFORE ── trivy rootfs --scanners vuln
  compat-sh (gobinary)
  Total: 48 (UNKNOWN: 0, LOW: 3, MEDIUM: 30, HIGH: 14, CRITICAL: 1)
    CRITICAL CVE-2025-68121 stdlib v1.22.8 -> 1.24.13, 1.25.7, 1.26.0-rc.3
    HIGH     CVE-2025-61726 stdlib v1.22.8 -> 1.24.12, 1.25.6
  examined: stdlib v1.22.8

AFTER  ── trivy rootfs --scanners vuln
  compat-sh (gobinary)
  Total: 0
  examined: stdlib v1.26.5
```

`48 (1 CRITICAL) → 0`, byte-identical to the incident's reported numbers on the
BEFORE side. Zero suppression: no `.trivyignore`, no VEX, no `--ignore-unfixed`,
no severity filter.

**Non-vacuity, checked explicitly, because a clean scan of nothing is the failure
mode here.** Both runs report `Target: compat-sh, Type: gobinary` — not `-` — and
`--list-all-pkgs` shows both examined the same two packages, differing only in
`stdlib v1.22.8` vs `stdlib v1.26.5`. A gotcha worth recording: **`trivy fs` does
not scan a bare Go binary** — it reported `Target: -, Type: -` and a clean
summary, which reads exactly like a pass. `trivy rootfs` is the mode that
examines it.

