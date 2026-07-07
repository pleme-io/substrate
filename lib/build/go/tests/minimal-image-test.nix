# minimal-image-test.nix — pure eval forcing-function for the
# MINIMAL-PRODUCTION-IMAGE base-selection contract (docker.nix / distroless.nix).
#
# The verification-matrix rule (CLOSED-LOOP MASS-SYNTHESIS §1): one test that
# exercises every base MODE and fails the build the moment the minimal base
# regains a shell, an init, or a libc. Pure `nix eval` — no `nix build`, runs
# on darwin, wired into substrate `checks.<system>.go-minimal-image`.
#
#   nix eval --impure --expr \
#     '(import ./lib/build/go/tests/minimal-image-test.nix { pkgs = import <nixpkgs> {}; }).summary'
#
# The three modes correspond to docker.nix's base-selection ladder:
#   minimal    → scratch base = cacert ONLY (no tini, no glibc, no shell)
#   distroless → cacert (+ tini iff tini=true)
#   (fat)      → cacert + busybox (a shell IS present — the debug base)
{ pkgs, lib ? pkgs.lib }:
let
  checks = import ../../../iroha/checks.nix { inherit lib; };
  distroless = import ../distroless.nix;

  base = args: distroless.mkDistrolessBase pkgs args;
  names = xs: map (p: p.name or (p.pname or "")) xs;
  hasComp = needle: xs: lib.any (n: lib.hasInfix needle (lib.toLower n)) (names xs);

  # The three base modes.
  scratch = distroless.scratchBase pkgs;              # minimal: true
  minimalTini = distroless.minimalBase pkgs;          # distroless + tini
  fat = [ pkgs.cacert pkgs.busybox ];                 # minimal: false, distroless: false
in
checks.mkEvalChecks {
  name = "go-minimal-image";
  tests = {
    # ── scratch = THE minimal production base ────────────────────────
    "scratch-has-cacert"        = { expr = hasComp "cacert" scratch;   expected = true; };
    "scratch-no-init-tini"      = { expr = hasComp "tini" scratch;     expected = false; };
    "scratch-no-shell-busybox"  = { expr = hasComp "busybox" scratch;  expected = false; };
    "scratch-no-glibc"          = { expr = hasComp "glibc" scratch;    expected = false; };
    "scratch-is-cacert-only"    = { expr = builtins.length scratch;    expected = 1; };

    # ── the +tini base drags an init (and, via its closure, glibc) ───
    "tini-base-has-cacert"      = { expr = hasComp "cacert" minimalTini; expected = true; };
    "tini-base-has-tini"        = { expr = hasComp "tini" minimalTini;   expected = true; };
    "tini-base-two-paths"       = { expr = builtins.length minimalTini;  expected = 2; };

    # ── the fat base is a debug base: it HAS a shell ─────────────────
    "fat-base-has-busybox"      = { expr = hasComp "busybox" fat; expected = true; };

    # ── contract: withCacert=false drops the cert bundle ─────────────
    "no-cacert-drops-cert"      = { expr = hasComp "cacert" (base { withCacert = false; withTini = false; }); expected = false; };
    "no-cacert-empty"           = { expr = builtins.length (base { withCacert = false; withTini = false; }); expected = 0; };
  };
}
