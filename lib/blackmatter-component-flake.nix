# blackmatter-component-flake.nix
#
# Canonical flake output shape for blackmatter-* component repos.
#
# Most blackmatter components are thin wrappers around a home-manager module,
# sometimes with an accompanying NixOS/Darwin module, a small package, or an
# overlay. This helper produces the standard flake outputs for that shape so
# every repo exposes the same surface: modules, optional packages/overlay,
# a uniform devShell, and evalModules checks.
#
# Usage (in a consumer flake.nix):
#
#   {
#     description = "Blackmatter Foo — does foo";
#     inputs = {
#       nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
#       substrate = {
#         url = "github:pleme-io/substrate";
#         inputs.nixpkgs.follows = "nixpkgs";
#       };
#     };
#     outputs = inputs@{ self, nixpkgs, substrate, ... }:
#       (import "${substrate}/lib/blackmatter-component-flake.nix") {
#         inherit self nixpkgs;
#         name = "blackmatter-foo";
#         modules.homeManager = ./module;
#         # optional:
#         # modules.nixos = ./module/nixos;
#         # modules.darwin = ./module/darwin;
#         # package = pkgs: pkgs.callPackage ./package.nix {};
#         # overlay = final: prev: { foo = ...; };
#       };
#   }
#
# Produces:
#   homeManagerModules.default, nixosModules.default, darwinModules.default
#     (only those with a module path set)
#   packages.<system>.default         (if `package` is set)
#   overlays.default                  (if `overlay` is set)
#   devShells.<system>.default        (always — nixpkgs-fmt, nil, nixd)
#   checks.<system>.eval-<kind>-module (one per module, evaluates with enable = false)
#   checks.<system>.<name>            (merged with `extraChecks pkgs`)

{
  self,
  nixpkgs,
  name,
  description ? name,
  modules ? {},
  package ? null,
  overlay ? null,
  systems ? [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ],
  extraDevShellPackages ? (_pkgs: []),
  extraChecks ? (_pkgs: {}),
  # The option path under which a module's `enable` flag lives. Default is
  # blackmatter.components.<last-segment-of-name>, matching the fleet convention.
  # Override when a repo uses a different namespace (e.g. services.blackmatter.*).
  enableOptionPath ? null,
}:

let
  lib = nixpkgs.lib;

  # Canonical naming — strip leading "blackmatter-" once for the default option path.
  shortName = let
    prefix = "blackmatter-";
    n = builtins.stringLength prefix;
  in
    if lib.hasPrefix prefix name
    then builtins.substring n (builtins.stringLength name - n) name
    else name;

  defaultEnablePath = [ "blackmatter" "components" shortName ];
  optionPath = if enableOptionPath != null then enableOptionPath else defaultEnablePath;

  forAllSystems = f: lib.genAttrs systems (system: f {
    inherit system;
    pkgs = nixpkgs.legacyPackages.${system};
  });

  testHelpers = import ./util/test-helpers.nix { inherit lib; };

  hasHm = modules ? homeManager && modules.homeManager != null;
  hasNixos = modules ? nixos && modules.nixos != null;
  hasDarwin = modules ? darwin && modules.darwin != null;

  # Modules may be supplied as a path (imported lazily) or as an already-
  # imported value (a function, attrset, or list of modules). Some consumers
  # pass a function invocation because they need to thread helper libs in:
  #
  #   modules.homeManager = import ./module {
  #     mcpHelpers = import "${substrate}/lib/hm-mcp-helpers.nix" { inherit lib; };
  #   };
  loadModule = m:
    if builtins.isPath m || builtins.isString m
    then import m
    else m;

  # ─── evalModules smoke check ───────────────────────────────────────
  # Imports the module with enable = false and verifies it evaluates without
  # throwing. Guards against: missing imports, stale option paths, module
  # system errors, and accidental breakage from dependency updates.
  mkModuleEvalCheck = { pkgs, kind, modulePath }: let
    module = loadModule modulePath;
    disabledConfig = lib.setAttrByPath (optionPath ++ [ "enable" ]) false;

    # Permissive stubs for options blackmatter modules write to. Using
    # `types.anything` (aka lazily merged) avoids conflicts with modules
    # that declare their own nested sub-options under these namespaces
    # (e.g. services.blackmatter.tend.*, launchd.user.agents.*).
    anyAttrs = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = {}; };
    commonStubs = {
      options = {
        home.homeDirectory = lib.mkOption { type = lib.types.str; default = "/tmp/bm-eval"; };
        home.username = lib.mkOption { type = lib.types.str; default = "bm-eval"; };
        home.stateVersion = lib.mkOption { type = lib.types.str; default = "25.11"; };
        home.packages = lib.mkOption { type = lib.types.listOf lib.types.package; default = []; };
        home.sessionPath = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; };
        home.file = anyAttrs;
        home.activation = anyAttrs;
        home.sessionVariables = anyAttrs;
        programs = anyAttrs;
        services = anyAttrs;
        launchd = anyAttrs;
        systemd = anyAttrs;
        xdg = anyAttrs;
        sops = anyAttrs;
        targets = anyAttrs;
        nix = anyAttrs;
        fonts = anyAttrs;
        security = anyAttrs;
        system = anyAttrs;
      };
    };

    result = lib.evalModules {
      modules = [
        module
        { config = disabledConfig; }
        commonStubs
        (if kind == "nixos" then testHelpers.mkNixOSModuleStubs {} else {})
        { _module.args = { inherit pkgs; }; }
      ];
    };

    # Force evaluation: walk the options tree so missing imports, type errors,
    # and duplicate option definitions surface. Stops short of forcing the
    # config tree, which may reference packages or activation scripts that
    # require a real HM/NixOS evaluator.
    optionsForced = builtins.seq (builtins.attrNames result.options) "ok";
  in
    pkgs.runCommand "eval-${kind}-module-${name}" {} ''
      echo "${optionsForced}: ${kind} module evaluates (options tree parsed)" > $out
    '';

  # ─── Aggregate outputs ─────────────────────────────────────────────
  moduleOutputs =
    (lib.optionalAttrs hasHm { homeManagerModules.default = loadModule modules.homeManager; })
    // (lib.optionalAttrs hasNixos { nixosModules.default = loadModule modules.nixos; })
    // (lib.optionalAttrs hasDarwin { darwinModules.default = loadModule modules.darwin; });

  packageOutputs = lib.optionalAttrs (package != null) {
    packages = forAllSystems ({ pkgs, ... }: {
      default = package pkgs;
    });
  };

  overlayOutputs = lib.optionalAttrs (overlay != null) {
    overlays.default = overlay;
  };

  devShellOutputs = {
    devShells = forAllSystems ({ pkgs, ... }: {
      default = pkgs.mkShellNoCC {
        packages = with pkgs; [
          nixpkgs-fmt
          nil
          nixd
          jq
        ] ++ extraDevShellPackages pkgs;
        shellHook = ''
          echo "${name} dev shell"
          echo "  nixpkgs-fmt  — format Nix files"
          echo "  nil / nixd   — Nix LSP"
        '';
      };
    });
  };

  checkOutputs = {
    checks = forAllSystems ({ pkgs, system, ... }: let
      moduleChecks =
        (lib.optionalAttrs hasHm {
          eval-hm-module = mkModuleEvalCheck { inherit pkgs; kind = "hm"; modulePath = modules.homeManager; };
        })
        // (lib.optionalAttrs hasNixos {
          eval-nixos-module = mkModuleEvalCheck { inherit pkgs; kind = "nixos"; modulePath = modules.nixos; };
        })
        // (lib.optionalAttrs hasDarwin {
          eval-darwin-module = mkModuleEvalCheck { inherit pkgs; kind = "darwin"; modulePath = modules.darwin; };
        });
    in
      moduleChecks // (extraChecks pkgs));
  };

in
  moduleOutputs
  // packageOutputs
  // overlayOutputs
  // devShellOutputs
  // checkOutputs
  // {
    # Metadata surfaced on the flake for tooling (audits, sweep scripts).
    blackmatter = {
      component = {
        inherit name description shortName systems;
        hasHomeManagerModule = hasHm;
        hasNixosModule = hasNixos;
        hasDarwinModule = hasDarwin;
        hasPackage = package != null;
        hasOverlay = overlay != null;
        optionPath = optionPath;
      };
    };
  }
