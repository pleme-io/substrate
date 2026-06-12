# Tests — iroha.manifest (typed fleet app manifest: resolution defaults,
# module/overlay projections, profile enables + role band, invariants).
{ lib, iroha }:
let
  inherit (iroha) mkManifest mkEvalChecks at;

  # The overlay letter is authored in parallel. Until ./overlay.nix exists
  # on disk we inject a stub honouring its frozen contract; once the real
  # file lands the seam is unused and these same cases prove the real
  # mkInputOverlay.
  haveOverlayLetter = builtins.pathExists ../overlay.nix;

  stubMkInputOverlay =
    {
      input,
      name,
      packageAttr ? name,
      preferAttrs ? [ "default" ],
      fallback ? null,
    }:
    final: prev:
    let
      provided = (input.packages or { }).${prev.stdenv.hostPlatform.system} or { };
      found = lib.findFirst (a: provided ? ${a}) null preferAttrs;
    in
    {
      ${packageAttr} =
        if found != null then
          provided.${found}
        else if fallback != null then
          fallback
        else
          throw "stub.mkInputOverlay: input '${name}' provides none of the preferred attrs.";
    };

  mk = args: mkManifest (args // lib.optionalAttrs (!haveOverlayLetter) { mkInputOverlay = stubMkInputOverlay; });

  fakeInputs = {
    tend = {
      homeManagerModules.default = {
        fake = "tend-hm";
      };
      overlays.default = final: prev: { fromUpstream = true; };
    };
    frost = {
      homeManagerModules.default = {
        fake = "frost-hm";
      };
      packages.x86_64-linux.default = "frost-drv";
    };
    mado = {
      homeManagerModules.blackmatter = {
        fake = "mado-hm";
      };
    };
  };

  # The good manifest. NOTE: vigy deliberately has NO entry in fakeInputs —
  # it is the missing-input case (lazy: only throws when its module value
  # is forced).
  m = mk {
    inputs = fakeInputs;
    apps = {
      tend = {
        class = "tui-tool";
        overlay = true;
      };
      frost = {
        class = "tui-tool";
        overlay = true;
      };
      mado = {
        class = "gpu-desktop";
        platforms = [ "darwin" ];
        namespace = "blackmatter.components";
        hmModulePath = "homeManagerModules.blackmatter";
      };
      vigy = {
        class = "opt-in";
      };
    };
    classes = {
      tui-tool.profiles = [ "dev" ];
      gpu-desktop.profiles = [ "dev" ];
      opt-in = {
        profiles = [ ];
        auditOnly = true;
      };
    };
  };

  # NixOS/Darwin module projections (positive route).
  sysM = mk {
    inputs.unit = {
      nixosModules.default = {
        fake = "unit-nixos";
      };
      darwinModules.default = {
        fake = "unit-darwin";
      };
    };
    apps.unit = {
      class = "svc";
      hmModule = false;
      nixosModule = true;
      darwinModule = true;
    };
    classes.svc.profiles = [ "srv" ];
  };

  # class.enabled = false excludes from BOTH module imports and profiles.
  disabledM = mk {
    inputs.a.homeManagerModules.default = {
      fake = "a-hm";
    };
    apps.a = {
      class = "off";
    };
    classes.off = {
      profiles = [ "p" ];
      enabled = false;
    };
  };

  # Typed-throw manifests (each violation isolated).
  missingClassM = mk {
    inputs = { };
    apps.x = { };
    classes = { };
  };
  unknownClassM = mk {
    inputs = { };
    apps.x.class = "nope";
    classes.c.profiles = [ "p" ];
  };
  badPlatformM = mk {
    inputs = { };
    apps.x = {
      class = "c";
      platforms = [ "windows" ];
    };
    classes.c.profiles = [ "p" ];
  };
  # Invariant violation (NOT a throw): auditOnly class with profiles.
  badAuditM = mk {
    inputs = { };
    apps.a.class = "broken";
    classes.broken = {
      profiles = [ "dev" ];
      auditOnly = true;
    };
  };

  # ── enables: prove through a real evalModules universe ───────────────
  enableUniverse = {
    options = {
      programs.tend.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      programs.frost.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      programs.vigy.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
      blackmatter.components.mado.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
    };
  };

  enablesCases = iroha.mkModuleEvalCheck {
    name = "enables-for-dev";
    universe = [ enableUniverse ];
    modules = [ { config = m.enablesForProfile "dev"; } ];
    asserts = [
      {
        path = [ "programs" "tend" "enable" ];
        expected = true;
      }
      {
        path = [ "programs" "frost" "enable" ];
        expected = true;
      }
      {
        path = [ "blackmatter" "components" "mado" "enable" ];
        expected = true;
      }
      # auditOnly app: option declared, but the manifest never flips it.
      {
        path = [ "programs" "vigy" "enable" ];
        expected = false;
      }
    ];
  };

  # Role-band proof: enables land at core.at "role" (mkDefault altitude),
  # so a node-band definition wins.
  nodeBeatsRole = lib.evalModules {
    modules = [
      enableUniverse
      { config = m.enablesForProfile "dev"; }
      { programs.tend.enable = at "node" false; }
    ];
  };

  # Bare-module-body proof: the return value is a PLAIN attrset (not
  # mkMerge), so it is usable directly as a module — the convention
  # profiles/*/home/ecosystem.nix consume (ecosystem.nix parity).
  bareBody = lib.evalModules {
    modules = [
      enableUniverse
      (m.enablesForProfile "dev")
    ];
  };

  overlayByName =
    name: lib.findFirst (o: o.name == name) (throw "test fixture: overlay '${name}' missing") m.overlays;
in
{
  # ── resolution: defaults + overrides ──────────────────────────────────
  app-defaults-applied = {
    expr = {
      inherit (m.apps.tend)
        input
        class
        platforms
        hmModule
        hmModulePath
        nixosModule
        darwinModule
        overlay
        packageAttr
        namespace
        optionName
        enablePath
        ;
    };
    expected = {
      input = "tend";
      class = "tui-tool";
      platforms = [
        "darwin"
        "linux"
      ];
      hmModule = true;
      hmModulePath = null;
      nixosModule = false;
      darwinModule = false;
      overlay = true;
      packageAttr = "tend";
      namespace = "programs";
      optionName = "tend";
      enablePath = [
        "tend"
        "enable"
      ];
    };
  };
  app-custom-fields-respected = {
    expr = {
      inherit (m.apps.mado)
        namespace
        hmModulePath
        platforms
        enablePath
        ;
    };
    expected = {
      namespace = "blackmatter.components";
      hmModulePath = "homeManagerModules.blackmatter";
      platforms = [ "darwin" ];
      enablePath = [
        "mado"
        "enable"
      ];
    };
  };
  class-defaults-applied = {
    expr = m.classes.tui-tool;
    expected = {
      profiles = [ "dev" ];
      enabled = true;
      auditOnly = false;
    };
  };

  # ── hmModulesFor ───────────────────────────────────────────────────────
  hm-linux-members-in-app-order = {
    expr = lib.take 2 (m.hmModulesFor "linux");
    expected = [
      { fake = "frost-hm"; }
      { fake = "tend-hm"; }
    ];
  };
  hm-linux-excludes-darwin-only-app = {
    # frost + tend + vigy (lazy member) — mado (darwin-only) excluded.
    expr = builtins.length (m.hmModulesFor "linux");
    expected = 3;
  };
  hm-darwin-resolves-custom-hm-module-path = {
    expr = builtins.elem { fake = "mado-hm"; } (m.hmModulesFor "darwin");
    expected = true;
  };
  hm-missing-input-throws-when-forced = {
    # vigy has no fakeInputs entry — deep-forcing the member list throws.
    expr = (builtins.tryEval (builtins.deepSeq (m.hmModulesFor "linux") true)).success;
    expected = false;
  };
  hm-unknown-platform-throws = {
    expr = (builtins.tryEval (m.hmModulesFor "windows")).success;
    expected = false;
  };
  hm-disabled-class-excluded = {
    expr = disabledM.hmModulesFor "linux";
    expected = [ ];
  };

  # ── nixosModules / darwinModules ───────────────────────────────────────
  nixos-modules-resolved = {
    expr = sysM.nixosModules;
    expected = [ { fake = "unit-nixos"; } ];
  };
  darwin-modules-resolved = {
    expr = sysM.darwinModules;
    expected = [ { fake = "unit-darwin"; } ];
  };
  system-modules-empty-when-unflagged = {
    expr = {
      n = m.nixosModules;
      d = m.darwinModules;
    };
    expected = {
      n = [ ];
      d = [ ];
    };
  };

  # ── overlays ───────────────────────────────────────────────────────────
  overlays-only-flagged-apps = {
    expr = map (o: o.name) m.overlays;
    expected = [
      "frost"
      "tend"
    ];
  };
  overlay-upstream-route = {
    expr =
      let
        o = overlayByName "tend";
      in
      {
        inherit (o.provenance) app kind;
        applied = (o.overlay { } { }).fromUpstream;
      };
    expected = {
      app = "tend";
      kind = "upstream-overlay";
      applied = true;
    };
  };
  overlay-input-package-route = {
    expr =
      let
        o = overlayByName "frost";
      in
      {
        inherit (o.provenance) app kind;
        pkg = (o.overlay { } { stdenv.hostPlatform.system = "x86_64-linux"; }).frost;
      };
    expected = {
      app = "frost";
      kind = "input-package";
      pkg = "frost-drv";
    };
  };

  # ── profiles ───────────────────────────────────────────────────────────
  apps-for-profile-sorted-and-audit-only-excluded = {
    expr = m.appsForProfile "dev";
    expected = [
      "frost"
      "mado"
      "tend"
    ];
  };
  apps-for-unknown-profile-empty = {
    expr = m.appsForProfile "nope";
    expected = [ ];
  };
  profile-disabled-class-excluded = {
    expr = disabledM.appsForProfile "p";
    expected = [ ];
  };
  role-band-loses-to-node-band = {
    expr = nodeBeatsRole.config.programs.tend.enable;
    expected = false;
  };
  enables-usable-as-bare-module-body = {
    expr = {
      isPlainAttrs = !((m.enablesForProfile "dev") ? _type);
      tend = bareBody.config.programs.tend.enable;
      mado = bareBody.config.blackmatter.components.mado.enable;
    };
    expected = {
      isPlainAttrs = true;
      tend = true;
      mado = true;
    };
  };

  # ── typed throws (lazy — force the offending field) ────────────────────
  missing-class-throws = {
    expr = (builtins.tryEval missingClassM.apps.x.class).success;
    expected = false;
  };
  unknown-class-throws = {
    expr = (builtins.tryEval unknownClassM.apps.x.class).success;
    expected = false;
  };
  invalid-platform-throws = {
    expr = (builtins.tryEval (builtins.deepSeq badPlatformM.apps.x.platforms true)).success;
    expected = false;
  };

  # ── invariants + catalog ───────────────────────────────────────────────
  invariants-pass-for-good-manifest = {
    expr = (mkEvalChecks {
      name = "manifest-invariants-good";
      tests = m.invariants;
    }).passed;
    expected = true;
  };
  invariants-fail-for-audit-only-with-profiles = {
    expr = (mkEvalChecks {
      name = "manifest-invariants-bad";
      tests = badAuditM.invariants;
    }).passed;
    expected = false;
  };
  catalog-app-count = {
    expr = m.catalog.appCount;
    expected = 4;
  };
  catalog-by-class = {
    expr = m.catalog.byClass;
    expected = {
      tui-tool = [
        "frost"
        "tend"
      ];
      gpu-desktop = [ "mado" ];
      opt-in = [ "vigy" ];
    };
  };
  catalog-profiles = {
    expr = m.catalog.profiles;
    expected = {
      dev = [
        "frost"
        "mado"
        "tend"
      ];
    };
  };
}
// enablesCases
