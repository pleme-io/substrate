# Tests — iroha.host-matrix (typed node registry: per-class configuration
# emission via injected universes, manifest + HM wiring, users module,
# hostname band, deploy projections, registry, invariants).
{ lib, iroha }:
let
  inherit (iroha)
    mkHostMatrix
    mkEvalChecks
    bandOf
    at
    ;

  # Universe functions are INJECTED data — stubs return inspectable
  # attrsets so the suite stays pure-eval.
  stubUniverses = {
    nixosSystem = args: {
      kind = "nixos";
      inherit args;
    };
    darwinSystem = args: {
      kind = "darwin";
      inherit args;
    };
  };

  # Honours the manifest letter's frozen contract (hmModulesFor /
  # nixosModules / darwinModules).
  fakeManifest = {
    hmModulesFor = p: [ { fake = p; } ];
    nixosModules = [ "NM" ];
    darwinModules = [ "DM" ];
  };

  luisMarker = {
    marker = "luis-import";
  };

  # The good matrix: plo (nixos, colmena), cid (darwin, per-user HM
  # imports), rio (nixos, deploy-rs, explicit hostname).
  m = mkHostMatrix {
    universes = stubUniverses;
    manifest = fakeManifest;
    base = {
      nixos = [ "BASE-NIXOS" ];
      darwin = [ "BASE-DARWIN" ];
    };
    hmWiring.sharedModulesExtra = [ "EXTRA" ];
    specialArgs = {
      flag = true;
    };
    nodes = {
      plo = {
        class = "nixos";
        system = "x86_64-linux";
        sshUser = "ops";
        tags = [ "k3s" ];
        profiles = [ "PROF" ];
        modules = [ "MOD" ];
        deploy.method = "colmena";
      };
      cid = {
        class = "darwin";
        system = "aarch64-darwin";
        users.luis = [ luisMarker ];
      };
      rio = {
        class = "nixos";
        system = "x86_64-linux";
        hostname = "rio.fleet";
        sshUser = "admin";
        tags = [
          "k3s"
          "edge"
        ];
        deploy = { };
      };
    };
  };

  ploModules = m.nixosConfigurations.plo.args.modules;
  rioModules = m.nixosConfigurations.rio.args.modules;
  cidModules = m.darwinConfigurations.cid.args.modules;

  moduleByFile =
    file: mods:
    lib.findFirst (
      mod: builtins.isAttrs mod && (mod._file or null) == file
    ) (throw "test fixture: module ${file} missing") mods;
  hasWiring =
    mods:
    lib.any (
      mod: builtins.isAttrs mod && lib.hasPrefix "<iroha:host-matrix:hm-wiring" (mod._file or "")
    ) mods;
  hasUsers =
    mods:
    lib.any (mod: builtins.isAttrs mod && (mod._file or null) == "<iroha:host-matrix:users>") mods;

  ploWiring = moduleByFile "<iroha:host-matrix:hm-wiring:linux>" ploModules;
  cidWiring = moduleByFile "<iroha:host-matrix:hm-wiring:darwin>" cidModules;
  cidUsers = moduleByFile "<iroha:host-matrix:users>" cidModules;
  ploHostname = moduleByFile "<iroha:host-matrix:hostname>" ploModules;
  rioHostname = moduleByFile "<iroha:host-matrix:hostname>" rioModules;
  cidHostname = moduleByFile "<iroha:host-matrix:hostname>" cidModules;

  # ── HM wiring proved through a real evalModules universe ─────────────
  sharedModulesUniverse = {
    options.home-manager.sharedModules = lib.mkOption {
      type = lib.types.listOf lib.types.raw;
      default = [ ];
    };
  };

  wiringEval = lib.evalModules {
    modules = [
      sharedModulesUniverse
      cidWiring
    ];
  };

  # Role-band proof: a node-band definition REPLACES the fleet wiring.
  wiringOverrideEval = lib.evalModules {
    modules = [
      sharedModulesUniverse
      cidWiring
      { home-manager.sharedModules = at "node" [ "OVERRIDE" ]; }
    ];
  };

  # Mirrors home-manager's real option type: submoduleWith (NOT plain
  # types.submodule, whose shorthand treats attrset defs as config-only) —
  # `{ imports = [ … ]; }` definition values are full modules there.
  usersUniverse = {
    options.home-manager.users = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submoduleWith {
          modules = [
            {
              options.marker = lib.mkOption {
                type = lib.types.str;
                default = "unset";
              };
            }
          ];
        }
      );
      default = { };
    };
  };
  usersEval = lib.evalModules {
    modules = [
      usersUniverse
      cidUsers
    ];
  };

  # ── auxiliary matrices (each violation / variant isolated) ───────────
  noDarwinUniverseM = mkHostMatrix {
    universes = {
      inherit (stubUniverses) nixosSystem;
    };
    nodes.cid = {
      class = "darwin";
      system = "aarch64-darwin";
    };
  };

  classTypoM = mkHostMatrix {
    universes = stubUniverses;
    nodes.oops = {
      class = "macos";
      system = "aarch64-darwin";
    };
  };

  missingClassM = mkHostMatrix {
    universes = stubUniverses;
    nodes.oops.system = "aarch64-darwin";
  };

  missingSystemM = mkHostMatrix {
    universes = stubUniverses;
    nodes.oops.class = "nixos";
  };

  badDeployM = mkHostMatrix {
    universes = stubUniverses;
    nodes.oops = {
      class = "nixos";
      system = "x86_64-linux";
      deploy.method = "ansible";
    };
  };

  # No manifest, no hmWiring — no wiring module at all.
  bareM = mkHostMatrix {
    universes = stubUniverses;
    nodes.solo = {
      class = "nixos";
      system = "x86_64-linux";
    };
  };

  # hmWiring alone (no manifest) still wires the extras.
  extrasOnlyM = mkHostMatrix {
    universes = stubUniverses;
    hmWiring.sharedModulesExtra = [ "ONLY" ];
    nodes.solo = {
      class = "nixos";
      system = "x86_64-linux";
    };
  };
  extrasOnlyWiring = moduleByFile "<iroha:host-matrix:hm-wiring:linux>" extrasOnlyM.nixosConfigurations.solo.args.modules;

  # viaOption = false: plain definition priority (concatenating layer).
  unbandedM = mkHostMatrix {
    universes = stubUniverses;
    manifest = fakeManifest;
    hmWiring.viaOption = false;
    nodes.solo = {
      class = "nixos";
      system = "x86_64-linux";
    };
  };
  unbandedWiring = moduleByFile "<iroha:host-matrix:hm-wiring:linux>" unbandedM.nixosConfigurations.solo.args.modules;

  # Invariant violations are DATA, not throws: nixos node on a darwin
  # system, a class typo, and a deploy node with empty hostname + no
  # sshUser.
  badInvariantsM = mkHostMatrix {
    universes = stubUniverses;
    nodes = {
      mismatch = {
        class = "nixos";
        system = "aarch64-darwin";
      };
      typo = {
        class = "macos";
        system = "x86_64-linux";
      };
      anon = {
        class = "darwin";
        system = "aarch64-darwin";
        hostname = "";
        deploy = { };
      };
    };
  };
in
{
  # ── configurations via injected universes ────────────────────────────
  nixos-configurations-created-per-class = {
    expr = {
      names = builtins.attrNames m.nixosConfigurations;
      kind = m.nixosConfigurations.plo.kind;
    };
    expected = {
      names = [
        "plo"
        "rio"
      ];
      kind = "nixos";
    };
  };
  darwin-configurations-created-per-class = {
    expr = {
      names = builtins.attrNames m.darwinConfigurations;
      kind = m.darwinConfigurations.cid.kind;
    };
    expected = {
      names = [ "cid" ];
      kind = "darwin";
    };
  };
  system-and-special-args-passed-through = {
    expr = {
      inherit (m.nixosConfigurations.plo.args) system specialArgs;
    };
    expected = {
      system = "x86_64-linux";
      specialArgs = {
        flag = true;
      };
    };
  };

  # ── per-node module list (one order, base → manifest → … ) ───────────
  nixos-module-order-base-manifest-profiles-modules = {
    expr = {
      head4 = lib.take 4 ploModules;
      # + hm-wiring + hostname (no users on plo).
      len = builtins.length ploModules;
    };
    expected = {
      head4 = [
        "BASE-NIXOS"
        "NM"
        "PROF"
        "MOD"
      ];
      len = 6;
    };
  };
  darwin-gets-darwin-base-and-manifest-modules = {
    expr = {
      hasBase = builtins.elem "BASE-DARWIN" cidModules;
      hasDM = builtins.elem "DM" cidModules;
      hasNM = builtins.elem "NM" cidModules;
    };
    expected = {
      hasBase = true;
      hasDM = true;
      hasNM = false;
    };
  };
  hostname-modules-role-banded-on-both-classes = {
    expr = {
      ploBand = bandOf ploHostname.config.networking.hostName;
      plo = ploHostname.config.networking.hostName.content;
      cid = cidHostname.config.networking.hostName.content;
      rio = rioHostname.config.networking.hostName.content;
    };
    expected = {
      ploBand = "role";
      plo = "plo";
      cid = "cid";
      rio = "rio.fleet";
    };
  };

  # ── HM wiring ─────────────────────────────────────────────────────────
  hm-wiring-content-and-band-per-platform = {
    expr = {
      band = bandOf cidWiring.config.home-manager.sharedModules;
      darwin = cidWiring.config.home-manager.sharedModules.content;
      linux = ploWiring.config.home-manager.sharedModules.content;
    };
    expected = {
      band = "role";
      darwin = [
        { fake = "darwin"; }
        "EXTRA"
      ];
      linux = [
        { fake = "linux"; }
        "EXTRA"
      ];
    };
  };
  hm-wiring-extracted-via-eval-modules = {
    expr = wiringEval.config.home-manager.sharedModules;
    expected = [
      { fake = "darwin"; }
      "EXTRA"
    ];
  };
  hm-wiring-node-band-override-wins = {
    expr = wiringOverrideEval.config.home-manager.sharedModules;
    expected = [ "OVERRIDE" ];
  };
  hm-wiring-unbanded-when-via-option-false = {
    expr = {
      band = bandOf unbandedWiring.config.home-manager.sharedModules;
      value = unbandedWiring.config.home-manager.sharedModules;
    };
    expected = {
      band = null;
      value = [ { fake = "linux"; } ];
    };
  };
  hm-wiring-presence-rules = {
    expr = {
      bare = hasWiring bareM.nixosConfigurations.solo.args.modules;
      extrasOnly = extrasOnlyWiring.config.home-manager.sharedModules.content;
    };
    expected = {
      bare = false;
      extrasOnly = [ "ONLY" ];
    };
  };

  # ── users module ──────────────────────────────────────────────────────
  users-module-emits-hm-user-imports = {
    expr = usersEval.config.home-manager.users.luis.marker;
    expected = "luis-import";
  };
  users-module-absent-when-no-users = {
    expr = hasUsers ploModules;
    expected = false;
  };

  # ── projections: byTag / colmena / deployRs / registry ───────────────
  by-tag-sorted-membership = {
    expr = {
      k3s = m.byTag "k3s";
      edge = m.byTag "edge";
      nope = m.byTag "nope";
    };
    expected = {
      k3s = [
        "plo"
        "rio"
      ];
      edge = [ "rio" ];
      nope = [ ];
    };
  };
  colmena-entry-shape-and-membership = {
    expr = {
      names = builtins.attrNames m.colmena;
      deployment = m.colmena.plo.deployment;
      # Same module list as the universe call — shared builder.
      importCount = builtins.length m.colmena.plo.imports;
    };
    expected = {
      names = [ "plo" ];
      deployment = {
        targetHost = "plo";
        targetUser = "ops";
        tags = [ "k3s" ];
      };
      importCount = 6;
    };
  };
  deploy-rs-typed-data-shape = {
    expr = m.deployRs;
    expected = {
      nodes.rio = {
        hostname = "rio.fleet";
        sshUser = "admin";
        configName = "rio";
        profile = "system";
      };
    };
  };
  registry-pure-data = {
    expr = {
      plo = m.registry.plo;
      cid = m.registry.cid;
    };
    expected = {
      plo = {
        class = "nixos";
        system = "x86_64-linux";
        hostname = "plo";
        tags = [ "k3s" ];
        deploy = {
          method = "colmena";
          profile = "system";
        };
      };
      cid = {
        class = "darwin";
        system = "aarch64-darwin";
        hostname = "cid";
        tags = [ ];
        deploy = null;
      };
    };
  };
  registry-never-throws-on-bad-class = {
    expr = classTypoM.registry.oops;
    expected = {
      class = "macos";
      system = "aarch64-darwin";
      hostname = "oops";
      tags = [ ];
      deploy = null;
    };
  };

  # ── typed throws (lazy — force the offending field) ──────────────────
  class-missing-or-typo-throws = {
    expr = {
      missing =
        (builtins.tryEval (builtins.seq (builtins.attrNames missingClassM.nixosConfigurations) true))
        .success;
      typo =
        (builtins.tryEval (builtins.seq (builtins.attrNames classTypoM.nixosConfigurations) true)).success;
    };
    expected = {
      missing = false;
      typo = false;
    };
  };
  missing-system-throws = {
    expr = (builtins.tryEval missingSystemM.nixosConfigurations.oops.args.system).success;
    expected = false;
  };
  missing-universe-throws-naming-node = {
    expr = (builtins.tryEval (builtins.seq noDarwinUniverseM.darwinConfigurations.cid true)).success;
    expected = false;
  };
  deploy-method-typo-throws = {
    expr = (builtins.tryEval (builtins.seq (builtins.attrNames badDeployM.colmena) true)).success;
    expected = false;
  };
  hm-wiring-bad-type-throws-at-construction = {
    expr =
      (builtins.tryEval (mkHostMatrix {
        universes = stubUniverses;
        hmWiring = 42;
        nodes = { };
      })).success;
    expected = false;
  };

  # ── invariants ────────────────────────────────────────────────────────
  invariants-pass-for-good-matrix = {
    expr =
      (mkEvalChecks {
        name = "host-matrix-invariants-good";
        tests = m.invariants;
      }).passed;
    expected = true;
  };
  invariants-fail-as-data-naming-violators = {
    expr = {
      passed =
        (mkEvalChecks {
          name = "host-matrix-invariants-bad";
          tests = badInvariantsM.invariants;
        }).passed;
      classViolators = badInvariantsM.invariants.node-classes-valid.expr;
      systemViolators = badInvariantsM.invariants.node-system-matches-class.expr;
      hostnameViolators = badInvariantsM.invariants.node-hostnames-non-empty.expr;
      deployViolators = badInvariantsM.invariants.deploy-nodes-have-target.expr;
    };
    expected = {
      passed = false;
      classViolators = [ "typo" ];
      systemViolators = [ "mismatch" ];
      hostnameViolators = [ "anon" ];
      deployViolators = [ "anon" ];
    };
  };
}
