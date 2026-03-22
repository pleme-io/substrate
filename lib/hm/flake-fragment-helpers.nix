# Home-manager helpers for nix-place flake fragment composition
#
# Declares the `blackmatter.flakeFragments` option type and provides
# builders + activation script generator for composing managed flake.nix files.
#
# Usage (in flake.nix):
#   fragmentHelpers = import "${substrate}/lib/hm/flake-fragment-helpers.nix" { lib = nixpkgs.lib; };
#
# Usage (in aggregator module — uses pkgs.nix-place from overlay):
#   imports = [ (fragmentHelpers.mkFlakeFragmentModule {}) ];
#
# Usage (in component modules, after mkFlakeFragmentModule is imported):
#   blackmatter.flakeFragments."code/github/pleme-io" = [
#     (fragmentHelpers.mkOrgFragment { org = "pleme-io"; extraApps = { ... }; })
#   ];
#
# Priority convention:
#   50  = standard workspace fragments (the default for all builders and the type)
#   100+ = specialized override fragments (e.g. gem tools layered on top)
{ lib }:
with lib;
let
  # ── Shared Constants ────────────────────────────────────────────────

  nixpkgsUrl = "github:NixOS/nixpkgs/nixos-25.11";
  flakeUtilsUrl = "github:numtide/flake-utils";
  fleetUrl = "github:pleme-io/fleet";

  # ── Option Types ──────────────────────────────────────────────────────

  flakeInputType = types.submodule {
    options = {
      url = mkOption {
        type = types.str;
        description = "Flake input URL";
      };
      follows = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Input follows relationships";
      };
    };
  };

  appDefType = types.submodule {
    options = {
      script = mkOption {
        type = types.str;
        description = "Shell script body for the app";
      };
      description = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Human-readable description";
      };
    };
  };

  flowStepType = types.submodule {
    options = {
      id = mkOption {
        type = types.str;
        description = "Step identifier";
      };
      action = mkOption {
        type = types.attrs;
        description = "Action definition (type + command)";
      };
      depends_on = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "IDs of steps this step depends on";
      };
    };
  };

  flowDefType = types.submodule {
    options = {
      description = mkOption {
        type = types.str;
        default = "";
        description = "Flow description";
      };
      steps = mkOption {
        type = types.listOf flowStepType;
        description = "Ordered list of flow steps";
      };
    };
  };

  flakeFragmentType = types.submodule {
    options = {
      id = mkOption {
        type = types.str;
        description = "Unique identifier for this fragment (e.g. pleme-workspace)";
      };
      priority = mkOption {
        type = types.int;
        default = 50;
        description = "Priority for merge conflicts (higher wins). Convention: 50 = base, 100+ = specialized overrides.";
      };
      inputs = mkOption {
        type = types.attrsOf flakeInputType;
        default = {
          nixpkgs = { url = nixpkgsUrl; };
          flake-utils = { url = flakeUtilsUrl; };
        };
        description = "Flake inputs. Defaults to nixpkgs + flake-utils.";
      };
      apps = mkOption {
        type = types.attrsOf appDefType;
        default = {};
        description = "Apps contributed by this fragment";
      };
      flows = mkOption {
        type = types.attrsOf flowDefType;
        default = {};
        description = "Fleet flows contributed by this fragment";
      };
      systems = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Target systems (empty = nix-place default: aarch64-darwin, x86_64-linux, aarch64-linux)";
      };
    };
  };

  # ── Fragment → JSON Serialization ──────────────────────────────────

  fragmentToJson = fragment: let
    base = { inherit (fragment) id priority; };
    withInputs = if fragment.inputs == {} then base else base // {
      inputs = mapAttrs (_: input:
        { inherit (input) url; }
        // optionalAttrs (input.follows != {}) { inherit (input) follows; }
      ) fragment.inputs;
    };
    withApps = if fragment.apps == {} then withInputs else withInputs // {
      apps = mapAttrs (_: app:
        { inherit (app) script; }
        // optionalAttrs (app.description != null) { inherit (app) description; }
      ) fragment.apps;
    };
    withFlows = if fragment.flows == {} then withApps else withApps // {
      flows = mapAttrs (_: flow: {
        inherit (flow) description;
        steps = map (step:
          { inherit (step) id action; }
          // optionalAttrs (step.depends_on != []) { inherit (step) depends_on; }
        ) flow.steps;
      }) fragment.flows;
    };
    withSystems = if fragment.systems == [] then withFlows
      else withFlows // { inherit (fragment) systems; };
  in withSystems;

  # ── Shared Defaults ─────────────────────────────────────────────────

  defaultInputs = {
    nixpkgs = { url = nixpkgsUrl; };
    flake-utils = { url = flakeUtilsUrl; };
  };

  fleetInput = {
    fleet = { url = fleetUrl; follows = { nixpkgs = "nixpkgs"; }; };
  };

  # ── Fragment Builders ───────────────────────────────────────────────

  mkTendStatusApp = workspace: {
    description = "Repo status${optionalString (workspace != null) " for ${workspace}"} (via tend)";
    script = "tend status${optionalString (workspace != null) " --workspace ${workspace}"}";
  };

  mkFragment = {
    id,
    priority ? 50,
    apps ? {},
    flows ? {},
    inputs ? {},
    systems ? [],
  }: {
    inherit id priority systems flows apps;
    inputs = defaultInputs // inputs;
  };

  mkOrgFragment = {
    org,
    id ? org,
    priority ? 50,
    extraApps ? {},
    extraInputs ? {},
    flows ? {},
  }: {
    inherit id priority flows;
    inputs = defaultInputs // extraInputs;
    apps = { tend-status = mkTendStatusApp org; } // extraApps;
    systems = [];
  };

in {
  # Expose types for external use
  inherit flakeFragmentType flakeInputType appDefType flowDefType flowStepType;

  # Shared defaults and builders
  inherit defaultInputs fleetInput mkTendStatusApp mkFragment mkOrgFragment;

  # ── Module Factory ───────────────────────────────────────────────────
  #
  # Creates a home-manager module that:
  #   1. Declares the blackmatter.flakeFragments option
  #   2. Generates a home.activation script to sync all directories via nix-place
  #
  # nixPlacePkg: override the nix-place package (default: pkgs.nix-place from overlay)
  # skipGitTargets: list of relative paths where git init should be skipped
  mkFlakeFragmentModule = {
    nixPlacePkg ? null,
    skipGitTargets ? [""],
  }: args @ { config, pkgs, ... }: let
    cfg = config.blackmatter.flakeFragments;
    homeDir = config.home.homeDirectory;
    nixPlace = if nixPlacePkg != null then nixPlacePkg else pkgs.nix-place;
    # home-manager's lib includes lib.hm.dag — use module arg, not outer lib
    hmLib = args.lib;

    sortedTargets = sort (a: b:
      let depthOf = p: length (filter (s: s != "") (splitString "/" p));
      in depthOf a > depthOf b
    ) (attrNames cfg);

    materializeFragments = fragments:
      map (frag:
        pkgs.writeText "fragment-${frag.id}.json"
          (builtins.toJSON (fragmentToJson frag))
      ) fragments;

    mkSyncCommand = target: let
      fragments = cfg.${target};
      fragmentFiles = materializeFragments fragments;
      fragmentArgs = concatMapStringsSep " " (f: "--fragments ${f}") fragmentFiles;
      targetDir = if target == "" then homeDir else "${homeDir}/${target}";
      description = if target == "" then "Home" else target;
      skipGit = elem target skipGitTargets;
    in ''
      $VERBOSE_ECHO "Syncing flake fragments for ${description}..."
      ${nixPlace}/bin/nix-place sync \
        --target "${targetDir}" \
        ${fragmentArgs} \
        --description "Managed workspace: ${description}"${optionalString skipGit " --no-git"}
    '';

  in {
    options.blackmatter.flakeFragments = mkOption {
      type = types.attrsOf (types.listOf flakeFragmentType);
      default = {};
      description = ''
        Registry of flake fragments, keyed by path relative to $HOME.
        Any blackmatter module can contribute fragments to any directory.
        Multiple fragments per directory are merged by nix-place using
        priority-based composition (higher priority wins on conflicts).

        Priority convention: 50 = base workspace, 100+ = specialized overrides.

        Example:
          blackmatter.flakeFragments."code/github/pleme-io" = [
            { id = "pleme-workspace"; apps = { ... }; }
          ];
      '';
    };

    # Expose builders to all child modules via _module.args
    # so consumers can access them as: { flakeFragmentLib, ... }: ...
    config._module.args.flakeFragmentLib = {
      inherit mkTendStatusApp mkFragment mkOrgFragment;
      inherit defaultInputs fleetInput;
    };

    config.home.activation = mkIf (cfg != {}) {
      syncWorkspaceFlakes = hmLib.hm.dag.entryAfter ["writeBoundary"] ''
        PATH="${makeBinPath (with pkgs; [ git nix ])}:$PATH"
        ${concatMapStringsSep "\n" mkSyncCommand sortedTargets}
      '';
    };
  };
}
