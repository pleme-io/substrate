# iroha.component-flake — L2 swallow surface: blackmatter-component-flake v2.
#
# THE BLACKMATTER SWALLOW: lib/blackmatter-component-flake.nix re-emitted
# through the alphabet. Same consumer contract — argument surface, output
# attr names, and the blackmatter.component metadata (CATALOG REFLECTION)
# are identical — so the 20+ blackmatter-* sub-repos migrate by changing
# ONE import path. Consumer-authored modules, package functions, and
# overlays pass through VERBATIM; the swallow replaces only the BOILERPLATE
# around them: the eval-check harness is iroha.checks (mkModuleEvalCheck +
# mkEvalChecks — aggregate-before-assert failure reports), the stub option
# universe is built from core.mkField, and argument validation is typed.
#
# Exports (pure { lib }, zero pkgs — pkgs binds late inside the emitted
# per-system outputs via nixpkgs.legacyPackages.<system>):
#
#   mkComponentFlake :: {
#     self                  — the consumer flake's self (required; reserved
#                             for provenance metadata, unused today —
#                             faithful to the legacy surface);
#     nixpkgs               — the nixpkgs flake input (required; provides
#                             .lib and .legacyPackages.<system>);
#     name :: str           — component name (required), e.g. "blackmatter-foo";
#     description ? name;
#     modules ? { }         — { homeManager ? null; nixos ? null; darwin ? null };
#                             each entry a path/string (imported) or an
#                             already-imported module VALUE (verbatim);
#     package ? null        — pkgs -> drv;
#     overlay ? null        — final: prev: attrs (verbatim);
#     systems ? [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
#     extraDevShellPackages ? (_pkgs: [ ]);
#     extraChecks ? (_pkgs: { });
#     enableOptionPath ? null — option path holding the module's `enable`;
#                             defaults to [ "blackmatter" "components" <shortName> ]
#                             where shortName strips one leading "blackmatter-";
#     autoEvalChecks ? false — emit an evalModules smoke check per module
#                             (module + enable=false + stub universe);
#     extraModuleArgs ? { }  — extra _module.args threaded into eval checks;
#   } -> {
#     homeManagerModules.default / nixosModules.default / darwinModules.default
#                                       (only the classes with a module set);
#     packages.<system>.default         (iff package != null);
#     overlays.default                  (iff overlay != null);
#     devShells.<system>.default        (always — nixpkgs-fmt, nil, nixd, jq
#                                        ++ extraDevShellPackages pkgs);
#     checks.<system>                   = (autoEvalChecks → eval-hm-module /
#                                        eval-nixos-module / eval-darwin-module
#                                        per present class) // extraChecks pkgs;
#     blackmatter.component = { name, description, shortName, systems,
#       hasHomeManagerModule, hasNixosModule, hasDarwinModule, hasPackage,
#       hasOverlay, optionPath }        — attr-identical to the legacy emission;
#   }
#
# v2 deviations from the legacy file (deliberate; proven in the parity
# suite — output attr names + metadata stay identical):
#   1. Call-time validation is TYPED: missing self/nixpkgs/name, unknown
#      argument keys, unknown modules.* keys, and a bad `systems` are
#      iroha-prefixed throws. The legacy pattern-match gave untyped
#      "called without required argument" errors and silently IGNORED
#      unknown modules.* keys (modules.homemanager = a dropped module).
#   2. ONE permissive stub universe serves all three module classes. The
#      legacy nixos arm layered util/test-helpers.nix mkNixOSModuleStubs
#      (systemd.services, system.activationScripts, …) over commonStubs'
#      own systemd/system anyAttrs options — an option-prefix conflict
#      that makes the legacy eval-nixos-module check THROW by construction
#      (captured as an expected-failure case in the parity suite). v2 adds
#      environment/networking/boot/users (anyAttrs) + assertions (list) to
#      the shared universe instead, so nixos/darwin checks actually run.
#   3. Check derivations are emitted via iroha.checks: a failing module
#      eval becomes a FAILING CHECK BUILD whose log lists every failed
#      probe (aggregate-before-assert), instead of a flake-eval-time throw
#      inside the derivation's script interpolation.
#
# Throws (every message prefixed "iroha.component-flake.mkComponentFlake: "):
#   - argument set is not an attrset;
#   - `self` / `nixpkgs` / `name` missing; `name` not a string;
#   - unknown argument key(s);
#   - `modules` not an attrset, or carrying keys other than
#     homeManager / nixos / darwin;
#   - `systems` not a non-empty list of strings.
{ lib }:
let
  core = import ./core.nix { inherit lib; };
  checks = import ./checks.nix { inherit lib; };

  validArgKeys = [
    "self"
    "nixpkgs"
    "name"
    "description"
    "modules"
    "package"
    "overlay"
    "systems"
    "extraDevShellPackages"
    "extraChecks"
    "enableOptionPath"
    "autoEvalChecks"
    "extraModuleArgs"
  ];
  validModuleKeys = [
    "homeManager"
    "nixos"
    "darwin"
  ];
  defaultSystems = [
    "x86_64-linux"
    "aarch64-linux"
    "x86_64-darwin"
    "aarch64-darwin"
  ];

  mkComponentFlake =
    args:
    let
      err = msg: throw "iroha.component-flake.mkComponentFlake: ${msg}";

      # ─── call-time guard (typed; forced before the outputs return) ────
      guard =
        if !(builtins.isAttrs args) then
          err "argument must be an attrset — got ${builtins.typeOf args}."
        else if !(args ? self) then
          err "`self` (the consumer flake) is required — pass `inherit self;` from the flake outputs."
        else if !(args ? nixpkgs) then
          err "`nixpkgs` (the nixpkgs flake input) is required."
        else if !(args ? name) then
          err "`name` (str) is required."
        else if !(builtins.isString args.name) then
          err "`name` must be a string — got ${builtins.typeOf args.name}."
        else if removeAttrs args validArgKeys != { } then
          err "unknown argument(s) ${lib.concatStringsSep ", " (builtins.attrNames (removeAttrs args validArgKeys))} — accepted: ${lib.concatStringsSep ", " validArgKeys}."
        else if !(builtins.isAttrs (args.modules or { })) then
          err "`modules` must be an attrset { homeManager ? …, nixos ? …, darwin ? … } — got ${builtins.typeOf args.modules}."
        else if removeAttrs (args.modules or { }) validModuleKeys != { } then
          err "`modules` accepts only the keys ${lib.concatStringsSep ", " validModuleKeys} — got unknown key(s) ${lib.concatStringsSep ", " (builtins.attrNames (removeAttrs args.modules validModuleKeys))}."
        else if
          !(builtins.isList (args.systems or defaultSystems))
          || (args.systems or defaultSystems) == [ ]
          || !(builtins.all builtins.isString (args.systems or defaultSystems))
        then
          err "`systems` must be a non-empty list of system strings — got ${builtins.toJSON (args.systems or null)}."
        else
          true;

      nixpkgs = args.nixpkgs;
      name = args.name;
      description = args.description or name;
      modules = args.modules or { };
      package = args.package or null;
      overlay = args.overlay or null;
      systems = args.systems or defaultSystems;
      extraDevShellPackages = args.extraDevShellPackages or (_pkgs: [ ]);
      extraChecks = args.extraChecks or (_pkgs: { });
      enableOptionPath = args.enableOptionPath or null;
      autoEvalChecks = args.autoEvalChecks or false;
      extraModuleArgs = args.extraModuleArgs or { };

      # Canonical naming — strip leading "blackmatter-" once for the
      # default option path (fleet convention).
      shortName = lib.removePrefix "blackmatter-" name;
      optionPath =
        if enableOptionPath != null then
          enableOptionPath
        else
          [
            "blackmatter"
            "components"
            shortName
          ];

      forAllSystems =
        f:
        lib.genAttrs systems (
          system:
          f {
            inherit system;
            pkgs = nixpkgs.legacyPackages.${system};
          }
        );

      hasHm = modules ? homeManager && modules.homeManager != null;
      hasNixos = modules ? nixos && modules.nixos != null;
      hasDarwin = modules ? darwin && modules.darwin != null;

      # Consumer modules pass through VERBATIM — a path/string is imported
      # lazily; an already-imported value (function, attrset, list) is the
      # consumer's authored artifact and is never rewrapped.
      loadModule = m: if builtins.isPath m || builtins.isString m then import m else m;

      # ─── stub option universe for the eval checks ──────────────────────
      # Permissive landing pads for everything blackmatter modules write
      # to. anyAttrs (attrsOf anything) merges lazily, so modules declaring
      # their own nested sub-options under these namespaces don't conflict.
      # One universe for all three classes (see v2 deviation 2 in the
      # header — the legacy per-kind nixos stub layer was self-conflicting).
      anyAttrs = core.mkField {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
      };
      commonStubs = {
        options = {
          home.homeDirectory = core.mkField {
            type = "str";
            default = "/tmp/bm-eval";
          };
          home.username = core.mkField {
            type = "str";
            default = "bm-eval";
          };
          home.stateVersion = core.mkField {
            type = "str";
            default = "25.11";
          };
          home.packages = core.mkField {
            type = lib.types.listOf lib.types.package;
            default = [ ];
          };
          home.sessionPath = core.mkField {
            type = "listOfStr";
            default = [ ];
          };
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
          # v2 additions — namespaces NixOS/Darwin modules write to that
          # the legacy commonStubs lacked (its nixos arm tried to cover
          # them via mkNixOSModuleStubs and prefix-conflicted instead).
          environment = anyAttrs;
          networking = anyAttrs;
          boot = anyAttrs;
          users = anyAttrs;
          assertions = core.mkField {
            type = lib.types.listOf lib.types.anything;
            default = [ ];
          };
        };
      };

      # ─── evalModules smoke check (delegated to iroha.checks) ──────────
      # Imports the module with enable = false in the stub universe and
      # asserts it evaluates. Guards against: missing imports, stale option
      # paths, module system errors, accidental breakage from dep updates.
      mkModuleCheck =
        {
          pkgs,
          kind,
          modulePath,
        }:
        let
          suite = checks.mkEvalChecks {
            name = "eval-${kind}-module-${name}";
            tests = checks.mkModuleEvalCheck {
              name = "eval-${kind}-module";
              modules = [
                (loadModule modulePath)
                { config = lib.setAttrByPath (optionPath ++ [ "enable" ]) false; }
              ];
              universe = [
                commonStubs
                { _module.args = { inherit pkgs; } // extraModuleArgs; }
              ];
            };
          };
        in
        suite.asCheck pkgs;

      # ─── aggregate outputs (attr-identical to the legacy emission) ────
      moduleOutputs =
        (lib.optionalAttrs hasHm { homeManagerModules.default = loadModule modules.homeManager; })
        // (lib.optionalAttrs hasNixos { nixosModules.default = loadModule modules.nixos; })
        // (lib.optionalAttrs hasDarwin { darwinModules.default = loadModule modules.darwin; });

      packageOutputs = lib.optionalAttrs (package != null) {
        packages = forAllSystems ({ pkgs, ... }: { default = package pkgs; });
      };

      overlayOutputs = lib.optionalAttrs (overlay != null) { overlays.default = overlay; };

      devShellOutputs = {
        devShells = forAllSystems (
          { pkgs, ... }:
          {
            default = pkgs.mkShellNoCC {
              packages = [
                pkgs.nixpkgs-fmt
                pkgs.nil
                pkgs.nixd
                pkgs.jq
              ]
              ++ extraDevShellPackages pkgs;
              shellHook = ''
                echo "${name} dev shell"
                echo "  nixpkgs-fmt  — format Nix files"
                echo "  nil / nixd   — Nix LSP"
              '';
            };
          }
        );
      };

      checkOutputs = {
        checks = forAllSystems (
          { pkgs, ... }:
          let
            moduleChecks = lib.optionalAttrs autoEvalChecks (
              (lib.optionalAttrs hasHm {
                eval-hm-module = mkModuleCheck {
                  inherit pkgs;
                  kind = "hm";
                  modulePath = modules.homeManager;
                };
              })
              // (lib.optionalAttrs hasNixos {
                eval-nixos-module = mkModuleCheck {
                  inherit pkgs;
                  kind = "nixos";
                  modulePath = modules.nixos;
                };
              })
              // (lib.optionalAttrs hasDarwin {
                eval-darwin-module = mkModuleCheck {
                  inherit pkgs;
                  kind = "darwin";
                  modulePath = modules.darwin;
                };
              })
            );
          in
          moduleChecks // (extraChecks pkgs)
        );
      };
    in
    builtins.seq guard (
      moduleOutputs
      // packageOutputs
      // overlayOutputs
      // devShellOutputs
      // checkOutputs
      // {
        # Metadata surfaced on the flake for tooling (audits, sweep
        # scripts) — CATALOG REFLECTION; attr-identical to the legacy.
        blackmatter = {
          component = {
            inherit
              name
              description
              shortName
              systems
              ;
            hasHomeManagerModule = hasHm;
            hasNixosModule = hasNixos;
            hasDarwinModule = hasDarwin;
            hasPackage = package != null;
            hasOverlay = overlay != null;
            optionPath = optionPath;
          };
        };
      }
    );
in
{
  inherit mkComponentFlake;
}
