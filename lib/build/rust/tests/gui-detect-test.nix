# Pure eval tests for lib/build/rust/gui-detect.nix.
#
# The detector decides, per crate and without asking, whether a linux artifact
# is static musl or dynamic glibc. That decision is invisible until the binary
# either runs or panics at startup on a machine nobody is watching, so the
# tests here are shaped around the two ways it can be wrong:
#
#   * a FALSE NEGATIVE ships the panic — the GUI crate gets a static artifact
#     and `NoWaylandLib` at startup. `winit-is-detected` is that row.
#   * a FALSE POSITIVE silently takes static-musl away from a deploy tool.
#     `a-clipboard-is-not-a-gui` is that row, and it is not hypothetical: six
#     fleet repos pull `wayland-client` through `arboard`/`copypasta` and open
#     no window at all.
#
# And the row that guards the measurement rather than the answer:
# `the-denominator-is-inside-the-verdict`. A detector that examined nothing
# and a detector that found nothing both report `isGui = false`; without
# `scanned`, a change that stopped reading Cargo.lock would turn every repo
# quietly static and every gate quietly green.
{ lib }:

let
  testHelpers = import ../../../util/test-helpers.nix { inherit lib; };
  gd = import ../gui-detect.nix { inherit lib; };

  v = args: gd.detect args;

  winit = v { src = ./fixtures/gui-winit; };
  clip = v { src = ./fixtures/gui-clipboard-only; };
  noLock = v { src = ./fixtures/gui-no-lock; };
  mixedShell = v { src = ./fixtures/gui-workspace-mixed; packageName = "demo-shell"; };
  mixedHeadless = v { src = ./fixtures/gui-workspace-mixed; packageName = "demo-headless"; };
  mixedWhole = v { src = ./fixtures/gui-workspace-mixed; };

  tests = [
    # ── The panic this exists to prevent ──────────────────────────────
    (testHelpers.mkTest "winit-is-detected"
      (winit.isGui && builtins.elem "winit" winit.matched)
      "a winit crate must be GUI — missing it ships a static binary that dies on dlopen at startup")

    (testHelpers.mkTest "a-detected-crate-names-what-decided-it"
      (winit.matched != [ ])
      "the verdict must name the crates that decided it, or a wrong answer cannot be argued with")

    # ── The false positive that costs a real artifact ─────────────────
    (testHelpers.mkTest "a-clipboard-is-not-a-gui"
      (!clip.isGui && clip.matched == [ ])
      "wayland-client via arboard opens no window — six fleet repos would lose static-musl for nothing")

    (testHelpers.mkTest "the-clipboard-fixture-really-contains-wayland"
      (let names = builtins.map (p: p.name)
             (builtins.fromTOML (builtins.readFile ./fixtures/gui-clipboard-only/Cargo.lock)).package;
       in builtins.elem "wayland-client" names && builtins.elem "x11rb" names)
      "the negative row is only meaningful if the fixture actually carries the tempting crates")

    # ── Reachability, not grep ────────────────────────────────────────
    (testHelpers.mkTest "a-workspace-member-is-judged-on-its-own-closure"
      (mixedShell.isGui && !mixedHeadless.isGui)
      "two members of ONE lock must get DIFFERENT answers — this is what a whole-file scan cannot do")

    (testHelpers.mkTest "closure-mode-is-actually-reached"
      (mixedShell.mode == "closure" && mixedShell.root == "demo-shell")
      "the discriminating row above is worthless if the detector silently fell back to lock mode")

    (testHelpers.mkTest "the-headless-member-scans-fewer-crates-than-the-shell"
      (mixedHeadless.scanned < mixedShell.scanned)
      "a narrower closure must BE narrower — equal counts mean the walk collapsed to the whole lock")

    (testHelpers.mkTest "without-a-root-the-verdict-covers-the-whole-lock"
      (mixedWhole.mode == "lock" && mixedWhole.isGui)
      "an ambiguous workspace must classify conservatively AND say `lock`, so the answer is readable as workspace-wide")

    # ── The denominator ───────────────────────────────────────────────
    (testHelpers.mkTest "the-denominator-is-inside-the-verdict"
      (winit.scanned > 0 && clip.scanned > 0)
      "a verdict must carry what it examined — otherwise 'found nothing' and 'looked at nothing' are the same value")

    (testHelpers.mkTest "an-absent-lock-says-absent-rather-than-false"
      (noLock.mode == "absent" && noLock.scanned == 0 && !noLock.isGui)
      "no lock must report scanned=0/absent — a bare `false` would read as a measurement that was never taken")

    (testHelpers.mkTest "explain-distinguishes-absent-from-negative"
      (gd.explain noLock != gd.explain clip)
      "the two false verdicts must not render the same bytes — that is the whole point of `mode`")

    # ── The override ──────────────────────────────────────────────────
    (testHelpers.mkTest "an-explicit-false-overrides-a-positive-detection"
      (!(gd.resolve { src = ./fixtures/gui-winit; gui = false; }).isGui)
      "the escape hatch must actually bypass detection, or a measured correction has nowhere to go")

    (testHelpers.mkTest "an-explicit-verdict-admits-it-was-not-derived"
      ((gd.resolve { src = ./fixtures/gui-winit; gui = false; }).mode == "explicit")
      "an override must be labelled `explicit` — reading it back as a derivation would launder an assertion as a measurement")

    (testHelpers.mkTest "a-null-override-still-derives"
      ((gd.resolve { src = ./fixtures/gui-winit; gui = null; }).isGui)
      "null must mean derive, not false — the default must never be the silently-wrong one")

    # ── The catalog ───────────────────────────────────────────────────
    (testHelpers.mkTest "the-catalog-excludes-the-measured-false-positives"
      (!(builtins.elem "wayland-client" gd.guiCrates)
        && !(builtins.elem "x11rb" gd.guiCrates)
        && !(builtins.elem "raw-window-handle" gd.guiCrates))
      "the crates six fleet repos pull for a CLIPBOARD must stay out of the catalog")

    (testHelpers.mkTest "the-catalog-covers-the-fleet-backends"
      (builtins.all (c: builtins.elem c gd.guiCrates) [ "winit" "wgpu" "smithay" "eframe" ])
      "the four backends the fleet actually ships must be in the catalog")

    (testHelpers.mkTest "the-two-catalog-classes-do-not-overlap"
      (builtins.all (c: !(builtins.elem c gd.runtimeDlopenCrates)) gd.windowSystemCrates)
      "a crate in both lists would be counted twice in `matched` and read as stronger evidence than it is")
  ];

  result = testHelpers.runTests tests;

in {
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;

  asCheck = pkgs:
    if result.allPassed
    then pkgs.runCommand "rust-gui-detect-test" { } ''
      echo "rust/gui-detect: ${result.summary}" > $out
    ''
    else throw ''
      rust/gui-detect tests FAILED (${result.summary}):
        - ${builtins.concatStringsSep "\n  - " result.failures}'';
}
