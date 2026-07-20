# Tests — iroha.component-flake (THE BLACKMATTER SWALLOW: parity against
# the TRUE legacy implementation over shared fixtures — top-level attr-name
# sets per output class, metadata deep-equality, verbatim
# module/overlay/package passthrough, devShell parity, eval-check semantics
# incl. the captured legacy eval-nixos-module bug, typed throws).
#
# 2026-06-12: the live lib/blackmatter-component-flake.nix was RETIRED and is
# now a delegation shim over iroha.mkComponentFlake. Two bindings below:
#   legacy — the frozen TRUE legacy implementation
#            (fixtures/legacy-component-flake.nix), so parity keeps being
#            asserted against the real pre-swallow semantics forever;
#   shim   — the live ../../blackmatter-component-flake.nix, pinned by the
#            shim-* tests to behave exactly as v2 (typed throws, working
#            eval-nixos-module check, identical metadata).
#
# Stub inputs: real nixpkgs lib; legacyPackages stubbed with fake
# mkShellNoCC/runCommand that return inspectable attrsets, so the suite
# stays pure-eval. Deep drv equality is impossible against stubs —
# derivation-level assertions are structural (attr names, env shape,
# script/shellHook strings).
{ lib, iroha }:
let
  inherit (iroha) mkComponentFlake;
  legacy = import ./fixtures/legacy-component-flake.nix;
  shim = import ../../blackmatter-component-flake.nix;

  sortedNames = s: builtins.sort builtins.lessThan (builtins.attrNames s);

  # ── stub self/nixpkgs (real lib, fake package builders) ─────────────
  stubPkgs = system: {
    stdenv.hostPlatform = {
      inherit system;
      isDarwin = lib.hasSuffix "darwin" system;
    };
    nixpkgs-fmt = "drv:nixpkgs-fmt:${system}";
    nil = "drv:nil:${system}";
    nixd = "drv:nixd:${system}";
    jq = "drv:jq:${system}";
    mkShellNoCC = spec: {
      type = "derivation";
      name = "devshell:${system}";
      inherit (spec) packages shellHook;
    };
    # passing iroha check ⇒ env == { }; failing ⇒ env ? failureReport.
    runCommand = name: env: script: {
      type = "derivation";
      inherit name env script;
    };
  };
  stubNixpkgs = {
    inherit lib;
    legacyPackages = lib.genAttrs [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ] stubPkgs;
  };
  stubSelf = {
    outPath = "/stub/self";
  };

  # ── fixture modules (attrset form so verbatim passthrough is provable
  #    via the _file marker — Nix function equality is always false) ────
  hmModule = {
    _file = "<fixture:hm-module>";
    options.blackmatter.components.foo.enable = lib.mkEnableOption "foo (hm)";
  };
  nixosModule = {
    _file = "<fixture:nixos-module>";
    options.blackmatter.components.foo.enable = lib.mkEnableOption "foo (nixos)";
  };
  darwinModule = {
    _file = "<fixture:darwin-module>";
    options.blackmatter.components.foo.enable = lib.mkEnableOption "foo (darwin)";
  };

  # ── representative specs ─────────────────────────────────────────────
  fullSpec = {
    self = stubSelf;
    nixpkgs = stubNixpkgs;
    name = "blackmatter-foo";
    description = "Foo component";
    modules = {
      homeManager = hmModule;
      nixos = nixosModule;
      darwin = darwinModule;
    };
    package = pkgs: {
      type = "derivation";
      name = "foo-pkg-${pkgs.stdenv.hostPlatform.system}";
    };
    overlay = final: prev: { foo = "overlay-foo"; };
    extraDevShellPackages = pkgs: [ "drv:extra-tool" ];
    extraChecks = pkgs: { custom-check = pkgs.runCommand "custom-check" { } "echo ok"; };
    autoEvalChecks = true;
    extraModuleArgs = {
      fixtureArg = 42;
    };
  };
  legacyFull = legacy fullSpec;
  mineFull = mkComponentFlake fullSpec;
  shimFull = shim fullSpec;

  minimalSpec = {
    self = stubSelf;
    nixpkgs = stubNixpkgs;
    name = "blackmatter-bar";
    modules.homeManager = {
      _file = "<fixture:bar-hm>";
      options.blackmatter.components.bar.enable = lib.mkEnableOption "bar";
    };
  };
  legacyMin = legacy minimalSpec;
  mineMin = mkComponentFlake minimalSpec;

  # module that THREADS extraModuleArgs (fails to apply without fixtureArg)
  probeSpec = fullSpec // {
    name = "blackmatter-probe";
    modules.homeManager =
      { fixtureArg, lib, ... }:
      {
        options.blackmatter.components.probe = {
          enable = lib.mkEnableOption "probe";
          val = lib.mkOption {
            type = lib.types.int;
            default = fixtureArg;
          };
        };
      };
  };
  legacyProbe = legacy probeSpec;
  mineProbe = mkComponentFlake probeSpec;

  # module MISSING its enable option → disabled-config def is unmatched
  brokenSpec = fullSpec // {
    modules = {
      homeManager = { };
    };
  };
  legacyBroken = legacy brokenSpec;
  mineBroken = mkComponentFlake brokenSpec;

  optSpec = minimalSpec // {
    name = "qux";
    enableOptionPath = [
      "services"
      "blackmatter"
      "qux"
    ];
    modules.homeManager = {
      _file = "<fixture:qux-hm>";
      options.services.blackmatter.qux.enable = lib.mkEnableOption "qux";
    };
  };
  legacyOpt = legacy optSpec;
  mineOpt = mkComponentFlake optSpec;

  # extraApps — the extraChecks twin. The consumer returns ALREADY-SHAPED
  # flake app values; the builder merges them verbatim into apps.<system>.
  # No legacy counterpart exists (the argument is v2-only), so the pairing
  # here is v2-vs-shim, and the legacy binding is only used to prove the
  # argument stays absent from the pre-existing output shape.
  appsSpec = minimalSpec // {
    name = "blackmatter-baz";
    extraApps = pkgs: {
      default = {
        type = "app";
        program = "/bin/baz-${pkgs.stdenv.hostPlatform.system}";
      };
    };
  };
  mineApps = mkComponentFlake appsSpec;
  shimApps = shim appsSpec;

  # legacy checks embed evaluation in the runCommand SCRIPT interpolation —
  # forcing .script is how a legacy eval-check passes or throws.
  legacyCheckEvals =
    chk: (builtins.tryEval (builtins.seq chk.script true)).success;
in
{
  # ── parity: output attr-name sets per class ───────────────────────────
  parity-top-level-attr-names-full = {
    expr = sortedNames mineFull;
    expected = sortedNames legacyFull;
  };
  parity-top-level-attr-names-minimal = {
    expr = sortedNames mineMin;
    expected = sortedNames legacyMin;
  };
  parity-packages-shape = {
    expr = {
      systems = sortedNames mineFull.packages;
      perSystem = sortedNames mineFull.packages."x86_64-linux";
    };
    expected = {
      systems = sortedNames legacyFull.packages;
      perSystem = sortedNames legacyFull.packages."x86_64-linux";
    };
  };
  parity-checks-attr-names = {
    expr = sortedNames mineFull.checks."x86_64-linux";
    expected = sortedNames legacyFull.checks."x86_64-linux";
  };
  parity-optional-outputs-absent-when-unset = {
    expr = [
      (mineMin ? nixosModules)
      (mineMin ? darwinModules)
      (mineMin ? packages)
      (mineMin ? overlays)
    ];
    expected = [
      (legacyMin ? nixosModules)
      (legacyMin ? darwinModules)
      (legacyMin ? packages)
      (legacyMin ? overlays)
    ];
  };
  parity-checks-empty-when-auto-eval-off = {
    expr = {
      mine = builtins.attrNames mineMin.checks."x86_64-linux";
      legacy = builtins.attrNames legacyMin.checks."x86_64-linux";
    };
    expected = {
      mine = [ ];
      legacy = [ ];
    };
  };

  # ── verbatim passthrough (the swallow preserves authored artifacts) ──
  modules-passed-verbatim = {
    expr = [
      mineFull.homeManagerModules.default._file
      mineFull.nixosModules.default._file
      mineFull.darwinModules.default._file
    ];
    expected = [
      "<fixture:hm-module>"
      "<fixture:nixos-module>"
      "<fixture:darwin-module>"
    ];
  };
  overlay-passed-verbatim = {
    expr = [
      (mineFull.overlays.default { } { }).foo
      (legacyFull.overlays.default { } { }).foo
    ];
    expected = [
      "overlay-foo"
      "overlay-foo"
    ];
  };
  package-receives-per-system-pkgs = {
    expr = {
      mine = mineFull.packages."aarch64-darwin".default.name;
      legacy = legacyFull.packages."aarch64-darwin".default.name;
    };
    expected = {
      mine = "foo-pkg-aarch64-darwin";
      legacy = "foo-pkg-aarch64-darwin";
    };
  };

  # ── metadata: CATALOG REFLECTION must be emitted identically ──────────
  parity-metadata-deep-equal-full = {
    expr = mineFull.blackmatter == legacyFull.blackmatter;
    expected = true;
  };
  parity-metadata-deep-equal-minimal = {
    expr = mineMin.blackmatter == legacyMin.blackmatter;
    expected = true;
  };
  metadata-content-pinned = {
    expr = mineFull.blackmatter.component;
    expected = {
      name = "blackmatter-foo";
      description = "Foo component";
      shortName = "foo";
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      hasHomeManagerModule = true;
      hasNixosModule = true;
      hasDarwinModule = true;
      hasPackage = true;
      hasOverlay = true;
      optionPath = [
        "blackmatter"
        "components"
        "foo"
      ];
    };
  };
  metadata-enable-option-path-override = {
    expr = {
      mine = mineOpt.blackmatter.component.optionPath;
      legacy = legacyOpt.blackmatter.component.optionPath;
      shortName = mineOpt.blackmatter.component.shortName;
    };
    expected = {
      mine = [
        "services"
        "blackmatter"
        "qux"
      ];
      legacy = [
        "services"
        "blackmatter"
        "qux"
      ];
      shortName = "qux";
    };
  };

  # ── devShell parity (string-level: shellHook text + package list) ────
  parity-devshell-shellhook = {
    expr =
      mineFull.devShells."x86_64-linux".default.shellHook
      == legacyFull.devShells."x86_64-linux".default.shellHook;
    expected = true;
  };
  parity-devshell-packages = {
    expr = mineFull.devShells."x86_64-linux".default.packages;
    expected = legacyFull.devShells."x86_64-linux".default.packages;
  };

  # ── eval-check semantics ──────────────────────────────────────────────
  # iroha check passes ⇔ stub runCommand env == { } (failure branch
  # carries failureReport); legacy check passes ⇔ forcing .script does
  # not throw (eval is embedded in the script interpolation).
  eval-check-hm-passes-both = {
    expr = {
      mine = mineFull.checks."x86_64-linux".eval-hm-module.env == { };
      legacy = legacyCheckEvals legacyFull.checks."x86_64-linux".eval-hm-module;
    };
    expected = {
      mine = true;
      legacy = true;
    };
  };
  eval-check-darwin-passes-both = {
    expr = {
      mine = mineFull.checks."x86_64-linux".eval-darwin-module.env == { };
      legacy = legacyCheckEvals legacyFull.checks."x86_64-linux".eval-darwin-module;
    };
    expected = {
      mine = true;
      legacy = true;
    };
  };
  # CAPTURED LEGACY BUG: the legacy nixos stub layer prefix-conflicts with
  # commonStubs (systemd vs systemd.services, system vs
  # system.activationScripts) — the legacy eval-nixos-module check throws
  # by construction. v2 fixes the universe; same check attr name passes.
  # 2026-06-12: the legacy implementation was retired (the live file is now
  # a shim over v2); `legacy` here is the frozen fixture, so this test keeps
  # pinning the TRUE pre-swallow breakage forever. The shim-* tests below
  # pin the post-delegation reality of the live file.
  eval-check-nixos-legacy-broken-mine-fixed = {
    expr = {
      legacy = legacyCheckEvals legacyFull.checks."x86_64-linux".eval-nixos-module;
      mine = mineFull.checks."x86_64-linux".eval-nixos-module.env == { };
    };
    expected = {
      legacy = false;
      mine = true;
    };
  };

  # ── the live shim IS v2 (post-retirement pins, 2026-06-12) ───────────
  # lib/blackmatter-component-flake.nix delegates to iroha.mkComponentFlake;
  # these tests fail if the shim ever drifts from the v2 semantics.
  shim-nixos-eval-check-now-works = {
    # The legacy implementation's eval-nixos-module check threw by
    # construction; through the shim the same consumer call gets v2's
    # working check.
    expr = shimFull.checks."x86_64-linux".eval-nixos-module.env == { };
    expected = true;
  };
  shim-metadata-deep-equal-v2 = {
    expr = shimFull.blackmatter == mineFull.blackmatter;
    expected = true;
  };
  shim-top-level-attr-names-equal-v2 = {
    expr = sortedNames shimFull;
    expected = sortedNames mineFull;
  };
  shim-typed-throws-active = {
    # Unknown top-level arg + unknown modules.* key — silently dropped by
    # the retired legacy implementation, typed throws through the shim.
    expr = [
      (builtins.tryEval (shim (minimalSpec // { bogus = 1; }))).success
      (builtins.tryEval (shim (
        minimalSpec
        // {
          modules = {
            homemanager = { };
          };
        }
      ))).success
    ];
    expected = [
      false
      false
    ];
  };
  eval-check-broken-module-fails-both = {
    expr = {
      mine = mineBroken.checks."x86_64-linux".eval-hm-module.env ? failureReport;
      legacy = legacyCheckEvals legacyBroken.checks."x86_64-linux".eval-hm-module;
    };
    expected = {
      mine = true;
      legacy = false;
    };
  };
  eval-check-threads-extra-module-args = {
    expr = {
      mine = mineProbe.checks."x86_64-linux".eval-hm-module.env == { };
      legacy = legacyCheckEvals legacyProbe.checks."x86_64-linux".eval-hm-module;
    };
    expected = {
      mine = true;
      legacy = true;
    };
  };
  extra-checks-merged = {
    expr = {
      mine = mineFull.checks."x86_64-linux".custom-check.name;
      legacy = legacyFull.checks."x86_64-linux".custom-check.name;
    };
    expected = {
      mine = "custom-check";
      legacy = "custom-check";
    };
  };

  # ── extraApps (the extraChecks twin) ─────────────────────────────────
  extra-apps-merged = {
    expr = {
      systems = sortedNames mineApps.apps;
      perSystem = sortedNames mineApps.apps."x86_64-linux";
      app = mineApps.apps."x86_64-linux".default;
    };
    expected = {
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];
      perSystem = [ "default" ];
      app = {
        type = "app";
        program = "/bin/baz-x86_64-linux";
      };
    };
  };
  extra-apps-receives-per-system-pkgs = {
    expr = mineApps.apps."aarch64-darwin".default.program;
    expected = "/bin/baz-aarch64-darwin";
  };
  # BACKWARD COMPATIBILITY: nothing but extraApps feeds `apps`, so a
  # consumer that never passes it emits no `apps` attr — the legacy output
  # shape is untouched (parity-top-level-attr-names-* pins this globally).
  apps-absent-when-extra-apps-unset = {
    expr = [
      (mineFull ? apps)
      (mineMin ? apps)
      (legacyFull ? apps)
    ];
    expected = [
      false
      false
      false
    ];
  };
  shim-extra-apps-flows-through = {
    # The live shim forwards the argument set verbatim — extraApps must
    # clear the v2 allowlist and emit through the delegation path too.
    expr = shimApps.apps."x86_64-linux".default;
    expected = {
      type = "app";
      program = "/bin/baz-x86_64-linux";
    };
  };

  # ── typed throws (call-time guard) ────────────────────────────────────
  missing-name-throws = {
    expr =
      (builtins.tryEval (mkComponentFlake {
        self = stubSelf;
        nixpkgs = stubNixpkgs;
      })).success;
    expected = false;
  };
  missing-required-input-throws = {
    expr = [
      (builtins.tryEval (mkComponentFlake (removeAttrs minimalSpec [ "self" ]))).success
      (builtins.tryEval (mkComponentFlake (removeAttrs minimalSpec [ "nixpkgs" ]))).success
    ];
    expected = [
      false
      false
    ];
  };
  unknown-key-throws = {
    # unknown top-level argument + unknown modules.* class (the legacy
    # silently dropped the latter — a typo lost the module).
    expr = [
      (builtins.tryEval (mkComponentFlake (minimalSpec // { bogus = 1; }))).success
      (builtins.tryEval (mkComponentFlake (
        minimalSpec
        // {
          modules = {
            homemanager = { };
          };
        }
      ))).success
    ];
    expected = [
      false
      false
    ];
  };
  empty-systems-throws = {
    expr = (builtins.tryEval (mkComponentFlake (minimalSpec // { systems = [ ]; }))).success;
    expected = false;
  };
}
