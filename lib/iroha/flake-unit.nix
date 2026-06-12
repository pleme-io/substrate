# iroha.flake-unit — the flake-parts faces: outputs-as-modules.
#
# A package-module unit (the L2 keystone) is the per-app truth; this letter
# projects that truth onto a flake's OUTPUT surface. flake-parts modules are
# just modules — plain data — so a unit becomes one flake-parts module that
# simultaneously lands the dendritic `flake.modules.<class>.<name>`
# convention, the legacy `<class>Modules.<name>` + `.default` aliases
# (existing consumers keep working unmodified), a reflection entry under
# `flake.iroha.units` (the fleet inventory becomes a data query), and —
# when the unit ships its own per-system build — `perSystem.packages`,
# `perSystem.checks`, and a registered overlay. The dendritic ROOT (one
# flake.nix that auto-discovers every such module via import-tree) and the
# dev PARTITION (flake-parts partitions isolating dev-only inputs from
# consumer locks) are the two companion veneers.
#
# Exports (pure { lib }, zero pkgs — pkgs binds late: inside the emitted
# perSystem function and the emitted overlay's `final`):
#
#   mkFlakeUnit :: {
#     unit            (required) — a mkPackageModule result; must carry
#                       homeManager / nixos / darwin / meta (+ meta.name);
#     package         ? null     — per-system fn { pkgs, system } -> drv.
#                       null → NO perSystem key is emitted at all (flake-
#                       parts requires perSystem as a module; an empty
#                       function-form stub would still register) and no
#                       overlay/checks (there is nothing to build);
#     overlayLayer    ? "base"   — layer name recorded in the overlay
#                       reflection entry (feed for overlay.composeLayers);
#     registerOverlay ? true     — with package != null, also emit
#                       flake.overlays.<name> + its reflection entry;
#     registerChecks  ? true     — with package != null, also emit
#                       perSystem checks."<name>-package" (the package
#                       build IS the check);
#   } -> flake-parts module (plain data):
#     { _file = "<iroha:flake-unit:<name>>";
#       flake.modules.homeManager.<name> = unit.homeManager;   # dendritic
#       flake.modules.nixos.<name>       = unit.nixos;
#       flake.modules.darwin.<name>      = unit.darwin;
#       flake.homeManagerModules.<name> + .default = unit.homeManager;  # legacy
#       flake.nixosModules.<name>       + .default = unit.nixos;
#       flake.darwinModules.<name>      + .default = unit.darwin;
#       flake.iroha.units.<name> = unit.meta;                  # reflection
#       # only when package != null && registerOverlay:
#       flake.overlays.<name> = final: prev:
#         { <name> = package { pkgs = final;
#                              system = final.stdenv.hostPlatform.system; }; };
#       flake.iroha.overlays.<name> = { layer = overlayLayer; };
#       # only when package != null (key OMITTED entirely when null):
#       perSystem = { pkgs, system, ... }:
#         { packages.<name> = package { inherit pkgs system; }; }
#         // (registerChecks → { checks."<name>-package" = <same drv>; });
#     }
#
#   mkDendriticRoot :: {
#     inputs (required) — the root flake's inputs; MUST carry `flake-parts`
#                         and `import-tree` (typed throws name the gap);
#     tree   (required) — path import-tree walks for flake-parts modules;
#   } -> inputs.flake-parts.lib.mkFlake { inherit inputs; }
#          (inputs.import-tree tree)
#     Thin typed veneer — the whole dendritic root flake body is this call.
#
#   mkDevPartition :: {
#     module ? "./dev"  — str | path to the dev partition's extra-inputs
#                         flake (its lock never reaches consumers);
#     attrs  ? [ "checks" "devShells" "formatter" ] — non-empty listOf str:
#                         top-level perSystem attrs routed to the partition;
#   } -> flake-parts module data:
#     { partitionedAttrs = lib.genAttrs attrs (_: "dev");
#       partitions.dev.extraInputsFlake = module; }
#
# Throws (every message prefixed "iroha.flake-unit.<fn>: ", ALL surfaced at
# WHNF of the result — forcing the returned value is enough to test them):
#   mkFlakeUnit     — `unit` missing; `unit` not an attrset; `unit` missing
#                     any of homeManager/nixos/darwin/meta; `unit.meta.name`
#                     missing; `package` neither null nor a function;
#                     `overlayLayer` not a string; `registerOverlay` /
#                     `registerChecks` not bools.
#   mkDendriticRoot — `inputs` missing; `inputs` not an attrset; `inputs`
#                     lacking `flake-parts`; `inputs` lacking `import-tree`;
#                     `tree` missing; `tree` neither path nor path string.
#   mkDevPartition  — `module` neither string nor path; `attrs` not a list;
#                     `attrs` empty or carrying a non-string element.
{ lib }:
let
  requiredUnitKeys = [
    "homeManager"
    "nixos"
    "darwin"
    "meta"
  ];

  mkFlakeUnit =
    args:
    let
      unit =
        args.unit
          or (throw "iroha.flake-unit.mkFlakeUnit: `unit` (a mkPackageModule result) is required.");
      missing = builtins.filter (k: !(builtins.hasAttr k unit)) requiredUnitKeys;
      package = args.package or null;
      overlayLayer = args.overlayLayer or "base";
      registerOverlay = args.registerOverlay or true;
      registerChecks = args.registerChecks or true;
      name = unit.meta.name;
      drvFor = { pkgs, system }: package { inherit pkgs system; };
      withOverlay = package != null && registerOverlay;
    in
    if !(builtins.isAttrs unit) then
      throw "iroha.flake-unit.mkFlakeUnit: `unit` must be a mkPackageModule result (attrset) — got ${builtins.typeOf unit}."
    else if missing != [ ] then
      throw "iroha.flake-unit.mkFlakeUnit: `unit` must be a mkPackageModule result carrying ${lib.concatStringsSep "/" requiredUnitKeys} — missing key(s) ${lib.concatStringsSep ", " missing}."
    else if !(builtins.isAttrs unit.meta) || !(unit.meta ? name) then
      throw "iroha.flake-unit.mkFlakeUnit: `unit.meta.name` is missing — pass a real mkPackageModule result."
    else if !(package == null || builtins.isFunction package) then
      throw "iroha.flake-unit.mkFlakeUnit: `package` must be null or a per-system function { pkgs, system } -> drv — got ${builtins.typeOf package}."
    else if !(builtins.isString overlayLayer) then
      throw "iroha.flake-unit.mkFlakeUnit: `overlayLayer` must be a string layer name (overlay.composeLayers vocabulary) — got ${builtins.typeOf overlayLayer}."
    else if !(builtins.isBool registerOverlay && builtins.isBool registerChecks) then
      throw "iroha.flake-unit.mkFlakeUnit: `registerOverlay` and `registerChecks` must be bools — got ${builtins.typeOf registerOverlay} / ${builtins.typeOf registerChecks}."
    else
      {
        _file = "<iroha:flake-unit:${name}>";
        flake = {
          # Dendritic convention: every output module lives under
          # flake.modules.<class>.<name>.
          modules = {
            homeManager.${name} = unit.homeManager;
            nixos.${name} = unit.nixos;
            darwin.${name} = unit.darwin;
          };
          # Legacy aliases: existing `inputs.<x>.homeManagerModules.default`
          # consumers keep working unmodified.
          homeManagerModules = {
            ${name} = unit.homeManager;
            default = unit.homeManager;
          };
          nixosModules = {
            ${name} = unit.nixos;
            default = unit.nixos;
          };
          darwinModules = {
            ${name} = unit.darwin;
            default = unit.darwin;
          };
          # Reflection: the fleet inventory is a data query.
          iroha = {
            units.${name} = unit.meta;
          }
          // lib.optionalAttrs withOverlay {
            overlays.${name} = {
              layer = overlayLayer;
            };
          };
        }
        // lib.optionalAttrs withOverlay {
          overlays.${name} = final: _prev: {
            ${name} = drvFor {
              pkgs = final;
              system = final.stdenv.hostPlatform.system;
            };
          };
        };
      }
      # flake-parts requires perSystem as a MODULE — emit the function form
      # only when there is a package; otherwise omit the key entirely.
      // lib.optionalAttrs (package != null) {
        perSystem =
          { pkgs, system, ... }:
          {
            packages.${name} = drvFor { inherit pkgs system; };
          }
          // lib.optionalAttrs registerChecks {
            checks."${name}-package" = drvFor { inherit pkgs system; };
          };
      };

  mkDendriticRoot =
    args:
    let
      inputs =
        args.inputs
          or (throw "iroha.flake-unit.mkDendriticRoot: `inputs` (the root flake's inputs, carrying flake-parts + import-tree) is required.");
      tree =
        args.tree
          or (throw "iroha.flake-unit.mkDendriticRoot: `tree` (path import-tree walks for flake-parts modules) is required.");
    in
    if !(builtins.isAttrs inputs) then
      throw "iroha.flake-unit.mkDendriticRoot: `inputs` must be an attrset — got ${builtins.typeOf inputs}."
    else if !(inputs ? flake-parts) then
      throw "iroha.flake-unit.mkDendriticRoot: `inputs` lacks `flake-parts` — the dendritic root is a flake-parts veneer; add flake-parts to the root flake's inputs."
    else if !(inputs ? import-tree) then
      throw "iroha.flake-unit.mkDendriticRoot: `inputs` lacks `import-tree` — the dendritic convention auto-discovers modules via import-tree; add it to the root flake's inputs."
    # Forced HERE (not inside import-tree) so a missing/malformed tree is a
    # typed throw at WHNF, never a lazy failure deep inside mkFlake.
    else if !(builtins.isPath tree || builtins.isString tree) then
      throw "iroha.flake-unit.mkDendriticRoot: `tree` must be a path (or path string) for import-tree to walk — got ${builtins.typeOf tree}."
    else
      inputs.flake-parts.lib.mkFlake { inherit inputs; } (inputs.import-tree tree);

  mkDevPartition =
    args:
    let
      module = args.module or "./dev";
      attrs = args.attrs or [
        "checks"
        "devShells"
        "formatter"
      ];
    in
    if !(builtins.isString module || builtins.isPath module) then
      throw "iroha.flake-unit.mkDevPartition: `module` must be a string or path naming the dev partition's extra-inputs flake — got ${builtins.typeOf module}."
    else if !(builtins.isList attrs) then
      throw "iroha.flake-unit.mkDevPartition: `attrs` must be a list of top-level perSystem attr names (listOf str) — got ${builtins.typeOf attrs}."
    else if attrs == [ ] || !(builtins.all builtins.isString attrs) then
      throw "iroha.flake-unit.mkDevPartition: `attrs` must be a NON-EMPTY list of strings — got ${builtins.toJSON attrs}."
    else
      {
        partitionedAttrs = lib.genAttrs attrs (_: "dev");
        partitions.dev.extraInputsFlake = module;
      };
in
{
  inherit mkFlakeUnit mkDendriticRoot mkDevPartition;
}
