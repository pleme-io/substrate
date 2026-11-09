# skopeo call sites — the measured note

This note sat as a comment above the `skopeo-copy` entry of
`lib/release/patterns-full.nix`. That file is generated from the
pleme-io/actions `action.yml` files, so a regeneration cannot keep a
hand-written comment; the note lives here instead, unchanged. Its open
`pending-*` markers are also listed at the top of `CLAUDE.md`.

```text
── RETIRING THE ACTIONS DID NOT RETIRE THE BINARY ──────────────────────
The two entries below are honestly measured and honestly worded, and put
together they still mislead: they retire the two *actions*, and a reader
scanning this catalog reasonably concludes skopeo is gone from the fleet.
It is not. Measured 2026-08-01 across 951 pleme-io repos: SIXTEEN live
`${pkgs.skopeo}/bin/skopeo copy` invocations in NINE files across five
repos, none an action and none visible to this catalog —

  aresta/flake.nix (1) · blackmatter-akeyless/flake.nix (1) ·
  enxerto/flake.nix (1) · infrastructure/github-runner/…/flake.nix (3) ·
  pangea-architectures/services/akeyless-{sra,csi-provider,ztwa,gateway,
    secrets-injection}-image/flake.nix (2 each = 10)

An earlier revision of this paragraph said ELEVEN and called the five
pangea files "byte-identical". Both were wrong — they carry two copies
each, not one. Left visible rather than silently rewritten, because the
correction below is about exactly this failure mode.

── CORRECTED 2026-08-01, SAME DAY: "eleven, ONE class" was wrong twice ──
The real figures, from reading all nine files rather than two: SIXTEEN
executable `skopeo copy` invocations across NINE files in FIVE repos.
(28 raw occurrences fleet-wide; the other 12 are prose in this catalog,
hardened-images, substrate and tatara-infra. Control: `doca` returns 270
on the same probe, so the count is real and not a dead grep.)

And they are FOUR conversion classes, not one. This matters because the
original note said "just use the primitive", and that is false for three
of the four:

  1. GHCR, no auth      aresta, enxerto            --insecure-policy
  2. private + creds    blackmatter-akeyless       --dest-creds
  3. runner, w/ retry   github-runner (x3)         --dest-creds --retry-times
  4. Zot, OCI media     pangea-architectures (5x2) --dest-authfile --format oci

── AND THAT CLASS ANALYSIS WAS ALSO WRONG (measured 2026-08-01) ────────
The paragraph above said only class 1 was convertible, that class 4's
`--format oci` had no doca equivalent, and that converting it "would
change the media types of five live images". EVERY PART OF THAT IS FALSE.
Read from `tools/oci-push/src/main.rs`, not inferred:

  --format oci    doca emits OCI media types UNCONDITIONALLY. Lines 74-76:
                  MT_CONFIG/MT_LAYER_GZIP/MT_MANIFEST are all
                  application/vnd.oci.image.*, and there are ZERO
                  `vnd.docker.distribution.manifest` emission sites — doca
                  has no docker-manifest push path to accidentally take.
                  skopeo's `--format oci` is therefore a NO-OP equivalent,
                  not a missing feature.
  --dest-creds    dest-user / dest-pass inputs.
  self-signed     dest-ca-cert + insecure (wired through `with:` 2026-07-29).
  --retry-times   push_with_retry: 5 attempts, backoff 1s/2s/4s/8s, and the
                  source says 5 was chosen to MATCH the skopeo call site it
                  replaces. Strictly better than skopeo's: it retries only
                  TRANSIENT failures, so a 401 or a malformed archive fails
                  fast instead of burning the budget with backoff.

── CLASS 4's TARGET DOES NOT SERVE A REGISTRY TODAY (2026-08-02) ──────
Before threading a CA path, probe the endpoint. All 10 class-4
invocations push to ONE host -- `zot.alpha.1.k8s.quero.lol`, 15 textual
references across the five flakes -- and it does not answer as a registry:

  DNS      CNAME -> pixie.porkbun.com -> 207.207.210.229
  TLS      curl: (60) SSL: no alternative certificate subject name
           matches target hostname 'zot.alpha.1.k8s.quero.lol'
  -k       HTTP 301 from openresty -- a generic ingress redirect, not a
           /v2/ registry response

CONTROL, AND IT CHANGED THE CONCLUSION: `grafana.quero.cloud` -- known
live -- resolves to the SAME CNAME and the SAME IP. So pixie.porkbun.com
is this fleet's shared ingress, NOT a parking page, and "the domain is
dead" would have been wrong. What is true is narrower: the ingress has no
cert covering this hostname and returns a generic 301 rather than a
registry, so nothing is serving a Zot there right now.

CONSEQUENCE FOR THE MIGRATION: the class-4 TLS question is unanswerable
while the endpoint does not serve TLS for its own name. Whether doca needs
--dest-ca-cert depends on what cert a RESTORED Zot presents, and that is
not knowable from a 301. Converting these ten now would be writing
untestable code against a host that cannot accept a push from skopeo
either.

So class 4 is not blocked on doca and not blocked on a CA path -- it is
blocked on an endpoint. `pending-class4-endpoint: zot.alpha.1.k8s.quero.lol
 serves a 301, not /v2/. Establish whether it is retired, moved, or
 unprovisioned before converting the ten call sites that target it.`

── CLASS 4 IS NOT A DROP-IN — TLS TRUST DIFFERS (measured 2026-08-02) ──
"Covered by doca" is true at the FEATURE level and still not a
copy-paste conversion, because skopeo and doca trust different roots.

  skopeo  uses the SYSTEM trust store. The five pangea-architectures
          call sites pass NO ca flag at all, so the Zot's self-signed CA
          must already be installed on the host — and it works.
  doca    is oci-client with `default-features = false, features =
          ["rustls-tls"]` (Cargo.toml) — webpki COMPILED-IN roots. Its
          `ca_cert_path` builds `extra_root_certificates`, EXTRA on top
          of that set, and the code comment says so explicitly: "pinning
          a self-signed in-cluster cert". There is no system-store read.

So converting class 4 by deleting the skopeo flags would leave doca
unable to verify the Zot at all — five LIVE images failing on TLS, from
a change that looks like pure simplification. `--dest-authfile` genuinely
does map to nothing (doca reads $HOME/.docker/config.json ambiently,
runner-verified), and `--format oci` genuinely maps to nothing (doca is
OCI-only). Two of the three flags vanish and the third is load-bearing —
which is the worst possible mix, because the first two teach you the
pattern that breaks on the third.

The correct conversion threads a CA path, exactly as the already-working
doca consumers do: a hardened-images workflow passes
`dest-ca-cert: /usr/local/share/ca-certificates/<registry>-ca.crt`, and
actions/zot-pull-scan exposes src-ca-cert/dest-ca-cert for this reason.
pangea-architectures' flakes have no such path today; supplying one is
real work, not a flag rename.

GENERAL RULE this is the second instance of: a flag that exists on the
OLD tool and not the NEW one means one of two OPPOSITE things — the new
tool does it unconditionally (--format oci), or the new tool does not do
it at all (--dest-authfile's system-store cousin). Absence of a knob is
not evidence either way. Read the source; the two look identical from the
call site.

So all four classes are covered by doca TODAY. The remaining work is
mechanical conversion of 16 call sites, not a doca enhancement, and the
`Backend::Skopeo` fallback was already deleted 2026-07-31.

THREE CONSECUTIVE REVISIONS OF THIS NOTE WERE WRONG, and the direction
flipped each time: under-count (11 for 16), then over-generalise (one
class for four), then over-caution (four blockers for zero). The constant
was reasoning about a tool from the SHAPE OF THE CALL SITE rather than
from the tool's source. A skopeo flag existing does not imply doca needs
a matching flag — it may already do that thing unconditionally, which is
exactly what `--format oci` turned out to be. Read the replacement's
source before pricing the replacement.

WHY THE FIRST COUNT WAS WRONG, because the mechanism recurs: the original
figure came from counting matching grep LINES, then reading two files and
generalising the shape to the rest. Grouping by SYMPTOM ("they all call
skopeo copy") silently asserts a shared FIX, which is a different and much
stronger claim than a shared symptom. Both errors ran the same direction —
under-count, over-generalise — and neither would have been caught by
re-running the grep, only by opening every file.

`pending-skopeo-callsites: 16 invocations / 9 files / 4 classes.
 1 CONVERTED (aresta, class 1, 2026-08-02). No doca enhancement needed,
 but conversion is NOT uniformly mechanical: class 4 (10 sites) must
 thread a --dest-ca-cert path it does not have today, or five live
 images lose the ability to verify the Zot's self-signed cert.`

THE DESTINATION ALREADY EXISTS AND IS ALREADY CONVERTED. `lib/service/
image-release.nix` (`mkImageReleaseApp`) threads `ociPush` → `DOCA_BIN`;
forge's image_release.rs moved off skopeo. So these eleven are not blocked
on a missing capability — they hand-roll around a primitive that is
already doca-based (Operating Principle #1: use the primitive, don't
re-implement its near-miss).

HOW THE COUNT WAS NEARLY MISSED, because the trap generalizes: the first
probe was `grep -rn --include=*.nix … .` from the pleme-io root and it
returned 0 — the recorded org-root gitignore trap. A 0 with no control is
indistinguishable from clean, and it was only caught because the same run
probed a known-present string and got 0 for THAT too. Per-repo iteration
(`for d in */; do grep -r "$d"`) returns 31 mentions / 16 uncommented / 11
real. Always pair an absence claim with a positive control that must be
non-zero, and never trust a fleet-wide grep issued from the org root.

`pending-skopeo-callsites: 11 flake call sites → mkImageReleaseApp.`
```
