# Tests — iroha.flake-unit (the flake-parts faces: dendritic flake.modules
# projection, legacy module aliases incl. default, reflection meta, gated
# perSystem/overlay/checks emission, dendritic-root veneer composition,
# dev-partition shape, typed throws).
{ lib, iroha }:
let
  inherit (iroha)
    mkFlakeUnit
    mkDendriticRoot
    mkDevPartition
    mkPackageModule
    ;

  # ── unit under projection (a real mkPackageModule result) ────────────
  pm = mkPackageModule {
    name = "tend";
    description = "tend repo daemon";
  };

  # ── stub per-system build + stub pkgs (zero real nixpkgs) ────────────
  stubPackage = { pkgs, system }: "DRV:${system}:${pkgs.marker}";
  stubPkgs = {
    marker = "stub";
    stdenv.hostPlatform.system = "x86_64-linux";
  };

  fu = mkFlakeUnit { unit = pm; };
  fuP = mkFlakeUnit {
    unit = pm;
    package = stubPackage;
  };
  fuNoChecks = mkFlakeUnit {
    unit = pm;
    package = stubPackage;
    registerChecks = false;
  };
  fuNoOverlay = mkFlakeUnit {
    unit = pm;
    package = stubPackage;
    registerOverlay = false;
  };
  fuLayered = mkFlakeUnit {
    unit = pm;
    package = stubPackage;
    overlayLayer = "fixes";
  };

  perSys = fuP.perSystem {
    pkgs = stubPkgs;
    system = "x86_64-linux";
  };

  # ── dendritic-root stubs ──────────────────────────────────────────────
  rootInputs = {
    flake-parts.lib.mkFlake = a: m: {
      stub = "mkFlake";
      inherit a m;
    };
    import-tree = t: {
      stub = "tree";
      inherit t;
    };
    self = { };
  };
  rootResult = mkDendriticRoot {
    inputs = rootInputs;
    tree = ./.;
  };
in
{
  # ── mkFlakeUnit: dendritic flake.modules projection ───────────────────
  flake-modules-all-three-classes = {
    expr = {
      hm = fu.flake.modules.homeManager.tend._class;
      nixos = fu.flake.modules.nixos.tend._class;
      darwin = fu.flake.modules.darwin.tend._class;
    };
    expected = {
      hm = "homeManager";
      nixos = "nixos";
      darwin = "darwin";
    };
  };

  # ── legacy aliases: named + default, per class ─────────────────────────
  legacy-aliases-named-and-default = {
    expr = {
      hmNamed = fu.flake.homeManagerModules ? tend;
      hmDefault = fu.flake.homeManagerModules.default._class;
      nixosNamed = fu.flake.nixosModules ? tend;
      nixosDefault = fu.flake.nixosModules.default._class;
      darwinNamed = fu.flake.darwinModules ? tend;
      darwinDefault = fu.flake.darwinModules.default._class;
    };
    expected = {
      hmNamed = true;
      hmDefault = "homeManager";
      nixosNamed = true;
      nixosDefault = "nixos";
      darwinNamed = true;
      darwinDefault = "darwin";
    };
  };

  # ── reflection ─────────────────────────────────────────────────────────
  reflection-units-carries-meta = {
    expr = fu.flake.iroha.units.tend;
    expected = {
      name = "tend";
      packageAttr = "tend";
      platforms = [
        "darwin"
        "linux"
      ];
      optionPath = [
        "programs"
        "tend"
      ];
      enablePath = [
        "programs"
        "tend"
        "enable"
      ];
      hasDaemon = false;
      daemonScope = null;
      hasSettings = false;
      hasMcp = false;
      hasHttp = false;
      version = "0.1.0";
    };
  };
  file-tag-names-the-unit = {
    expr = fu._file;
    expected = "<iroha:flake-unit:tend>";
  };

  # ── package == null: no perSystem KEY, no overlay, no overlay mirror ───
  package-null-omits-persystem-and-overlay = {
    expr = {
      hasPerSystem = fu ? perSystem;
      hasOverlays = fu.flake ? overlays;
      hasOverlayMirror = fu.flake.iroha ? overlays;
    };
    expected = {
      hasPerSystem = false;
      hasOverlays = false;
      hasOverlayMirror = false;
    };
  };

  # ── package != null: perSystem function emits packages + checks ────────
  persystem-emits-package = {
    expr = perSys.packages.tend;
    expected = "DRV:x86_64-linux:stub";
  };
  persystem-checks-registered-by-default = {
    expr = perSys.checks."tend-package";
    expected = "DRV:x86_64-linux:stub";
  };
  register-checks-false-omits-checks = {
    expr =
      let
        res = fuNoChecks.perSystem {
          pkgs = stubPkgs;
          system = "x86_64-linux";
        };
      in
      {
        hasChecks = res ? checks;
        stillBuilds = res.packages.tend;
      };
    expected = {
      hasChecks = false;
      stillBuilds = "DRV:x86_64-linux:stub";
    };
  };

  # ── overlay registration ───────────────────────────────────────────────
  overlay-registered-and-resolves-via-final = {
    expr = fuP.flake.overlays.tend stubPkgs { };
    expected = {
      tend = "DRV:x86_64-linux:stub";
    };
  };
  overlay-reflection-default-layer = {
    expr = fuP.flake.iroha.overlays.tend.layer;
    expected = "base";
  };
  overlay-reflection-custom-layer = {
    expr = fuLayered.flake.iroha.overlays.tend.layer;
    expected = "fixes";
  };
  register-overlay-false-omits-both-surfaces = {
    expr = {
      hasOverlays = fuNoOverlay.flake ? overlays;
      hasOverlayMirror = fuNoOverlay.flake.iroha ? overlays;
      persystemStays = fuNoOverlay ? perSystem;
    };
    expected = {
      hasOverlays = false;
      hasOverlayMirror = false;
      persystemStays = true;
    };
  };

  # ── mkFlakeUnit typed throws (all at WHNF of the result) ───────────────
  unit-missing-throws = {
    expr = (builtins.tryEval (mkFlakeUnit { })).success;
    expected = false;
  };
  unit-bad-shape-throws = {
    expr = {
      notAttrs = (builtins.tryEval (mkFlakeUnit { unit = 42; })).success;
      missingKeys = (builtins.tryEval (mkFlakeUnit { unit = { meta.name = "x"; }; })).success;
      metaNameMissing = (builtins.tryEval (mkFlakeUnit { unit = pm // { meta = { }; }; })).success;
    };
    expected = {
      notAttrs = false;
      missingKeys = false;
      metaNameMissing = false;
    };
  };
  package-bad-shape-throws = {
    expr =
      (builtins.tryEval (mkFlakeUnit {
        unit = pm;
        package = "tend";
      })).success;
    expected = false;
  };
  knob-bad-types-throw = {
    expr = {
      layer =
        (builtins.tryEval (mkFlakeUnit {
          unit = pm;
          overlayLayer = 7;
        })).success;
      registerOverlay =
        (builtins.tryEval (mkFlakeUnit {
          unit = pm;
          registerOverlay = "yes";
        })).success;
      registerChecks =
        (builtins.tryEval (mkFlakeUnit {
          unit = pm;
          registerChecks = "yes";
        })).success;
    };
    expected = {
      layer = false;
      registerOverlay = false;
      registerChecks = false;
    };
  };

  # ── mkDendriticRoot ────────────────────────────────────────────────────
  dendritic-root-composes-mkflake-over-import-tree = {
    expr = {
      calledMkFlake = rootResult.stub;
      treeWrapped = rootResult.m.stub;
      treeIsTheGivenPath = rootResult.m.t == ./.;
      inputsThreadedThrough = rootResult.a.inputs ? self && rootResult.a.inputs ? import-tree;
    };
    expected = {
      calledMkFlake = "mkFlake";
      treeWrapped = "tree";
      treeIsTheGivenPath = true;
      inputsThreadedThrough = true;
    };
  };
  dendritic-root-requires-inputs-and-tree = {
    expr = {
      noInputs = (builtins.tryEval (mkDendriticRoot { tree = ./.; })).success;
      noTree = (builtins.tryEval (mkDendriticRoot { inputs = rootInputs; })).success;
      badTree =
        (builtins.tryEval (mkDendriticRoot {
          inputs = rootInputs;
          tree = 42;
        })).success;
    };
    expected = {
      noInputs = false;
      noTree = false;
      badTree = false;
    };
  };
  dendritic-root-missing-flake-parts-throws = {
    expr =
      (builtins.tryEval (mkDendriticRoot {
        inputs = removeAttrs rootInputs [ "flake-parts" ];
        tree = ./.;
      })).success;
    expected = false;
  };
  dendritic-root-missing-import-tree-throws = {
    expr =
      (builtins.tryEval (mkDendriticRoot {
        inputs = removeAttrs rootInputs [ "import-tree" ];
        tree = ./.;
      })).success;
    expected = false;
  };

  # ── mkDevPartition ─────────────────────────────────────────────────────
  dev-partition-defaults-exact = {
    expr = mkDevPartition { };
    expected = {
      partitionedAttrs = {
        checks = "dev";
        devShells = "dev";
        formatter = "dev";
      };
      partitions.dev.extraInputsFlake = "./dev";
    };
  };
  dev-partition-custom-attrs-and-module = {
    expr = mkDevPartition {
      module = "../dev-flake";
      attrs = [ "checks" ];
    };
    expected = {
      partitionedAttrs.checks = "dev";
      partitions.dev.extraInputsFlake = "../dev-flake";
    };
  };
  dev-partition-accepts-path-module = {
    expr = (mkDevPartition { module = ./.; }).partitions.dev.extraInputsFlake == ./.;
    expected = true;
  };
  dev-partition-bad-attrs-throws = {
    expr = {
      notAList = (builtins.tryEval (mkDevPartition { attrs = "checks"; })).success;
      emptyList = (builtins.tryEval (mkDevPartition { attrs = [ ]; })).success;
      nonString = (builtins.tryEval (mkDevPartition { attrs = [ 1 ]; })).success;
    };
    expected = {
      notAList = false;
      emptyList = false;
      nonString = false;
    };
  };
  dev-partition-bad-module-throws = {
    expr = (builtins.tryEval (mkDevPartition { module = 42; })).success;
    expected = false;
  };
}
