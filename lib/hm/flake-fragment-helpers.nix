# Home-manager helpers for nix-place flake fragment composition
#
# Declares the `blackmatter.flakeFragments` option type and provides
# a function to generate the home.activation script that runs
# `nix-place sync` for each target directory.
#
# Usage (in flake.nix):
#   fragmentHelpers = import "${substrate}/lib/hm/flake-fragment-helpers.nix" { lib = nixpkgs.lib; };
#
# Usage (in aggregator module — uses pkgs.nix-place from overlay):
#   imports = [ (fragmentHelpers.mkFlakeFragmentModule {}) ];
#
# Usage (in component modules, after mkFlakeFragmentModule is imported):
#   blackmatter.flakeFragments."code/github/pleme-io" = [
#     { id = "pleme-workspace"; priority = 50; apps = { git-status = { script = "..."; }; }; }
#   ];
{ lib }:
with lib;
let
  # ── Option Types ──────────────────────────────────────────────────────

  # A single flake input (matches nix-place FlakeInput)
  flakeInputType = types.submodule {
    options = {
      url = mkOption {
        type = types.str;
        description = "Flake input URL (e.g. github:NixOS/nixpkgs/nixos-25.11)";
      };
      follows = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = "Input follows relationships (e.g. { nixpkgs = \"nixpkgs\"; })";
      };
    };
  };

  # An app definition (matches nix-place AppDef)
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

  # A fleet flow step (matches nix-place FlowStep)
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

  # A fleet flow definition (matches nix-place FlowDef)
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

  # A flake fragment (matches nix-place FlakeFragment)
  flakeFragmentType = types.submodule {
    options = {
      id = mkOption {
        type = types.str;
        description = "Unique identifier for this fragment (e.g. pleme-workspace)";
      };
      priority = mkOption {
        type = types.int;
        default = 100;
        description = "Priority for merge conflicts (higher wins)";
      };
      inputs = mkOption {
        type = types.attrsOf flakeInputType;
        default = {
          nixpkgs = { url = "github:NixOS/nixpkgs/nixos-25.11"; };
          flake-utils = { url = "github:numtide/flake-utils"; };
        };
        description = "Flake inputs contributed by this fragment. Defaults to nixpkgs + flake-utils.";
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
        description = "Target systems (empty = default: aarch64-darwin, x86_64-linux, aarch64-linux)";
      };
    };
  };

  # ── Fragment → YAML Serialization ────────────────────────────────────

  # Convert a fragment attrset to a JSON-serializable form.
  # We use JSON because pkgs.writeText + builtins.toJSON is available
  # in activation scripts, and nix-place accepts both YAML and JSON.
  fragmentToJson = fragment: let
    base = {
      inherit (fragment) id priority;
    };
    withInputs = if fragment.inputs == {} then base else base // {
        inputs = mapAttrs (_: input:
          { inherit (input) url; }
          // optionalAttrs (input.follows != {}) { inherit (input) follows; }
        ) fragment.inputs;
      };
    withApps = if fragment.apps == {} then withInputs
      else withInputs // {
        apps = mapAttrs (_: app:
          { inherit (app) script; }
          // optionalAttrs (app.description != null) { inherit (app) description; }
        ) fragment.apps;
      };
    withFlows = if fragment.flows == {} then withApps
      else withApps // {
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

in {
  # Expose types for external use
  inherit flakeFragmentType flakeInputType appDefType flowDefType flowStepType;

  # ── Shared Defaults ─────────────────────────────────────────────────

  # Standard inputs — every workspace flake needs nixpkgs + flake-utils.
  # Centralizes the nixpkgs version pin. Override by merging on top.
  defaultInputs = {
    nixpkgs = { url = "github:NixOS/nixpkgs/nixos-25.11"; };
    flake-utils = { url = "github:numtide/flake-utils"; };
  };

  # Fleet input — add to fragments that use flows.
  fleetInput = {
    fleet = { url = "github:pleme-io/fleet"; follows = { nixpkgs = "nixpkgs"; }; };
  };

  # ── Fragment Builders ───────────────────────────────────────────────

  # Build a tend-status app for a workspace (or all workspaces if null).
  mkTendStatusApp = workspace: {
    description = "Repo status${optionalString (workspace != null) " for ${workspace}"} (via tend)";
    script = "tend status${optionalString (workspace != null) " --workspace ${workspace}"}";
  };

  # Build a minimal fragment with standard inputs and sensible defaults.
  #   mkFragment { id = "pleme-workspace"; apps = { ... }; }
  mkFragment = {
    id,
    priority ? 50,
    apps ? {},
    flows ? {},
    inputs ? {},
    systems ? [],
  }: {
    inherit id priority systems;
    inputs = defaultInputs // inputs;
    inherit apps flows;
  };

  # Build a standard org-level workspace fragment with git-status via tend.
  #   mkOrgFragment { org = "pleme-io"; extraApps = { test-all = { ... }; }; }
  mkOrgFragment = {
    org,
    id ? org,
    priority ? 50,
    extraApps ? {},
    extraInputs ? {},
    flows ? {},
  }: {
    inherit id priority;
    inputs = defaultInputs // extraInputs;
    apps = {
      git-status = mkTendStatusApp org;
    } // extraApps;
    inherit flows;
    systems = [];
  };

  # ── Module Factory ───────────────────────────────────────────────────
  #
  # Creates a NixOS/home-manager module that:
  #   1. Declares the blackmatter.flakeFragments option
  #   2. Generates a home.activation script to sync all directories
  #
  # nixPlacePkg: the nix-place package (or null to use pkgs.nix-place from overlay)
  mkFlakeFragmentModule = {
    nixPlacePkg ? null,
  }: { config, pkgs, ... }: let
    cfg = config.blackmatter.flakeFragments;
    homeDir = config.home.homeDirectory;
    nixPlace = if nixPlacePkg != null then nixPlacePkg else pkgs.nix-place;

    # Sort targets deepest first so children are processed before parents
    sortedTargets = sort (a: b:
      let
        depthOf = p: length (filter (s: s != "") (splitString "/" p));
      in depthOf a > depthOf b
    ) (attrNames cfg);

    # Materialize fragments for a target as JSON files in the nix store
    materializeFragments = fragments:
      map (frag:
        pkgs.writeText "fragment-${frag.id}.json"
          (builtins.toJSON (fragmentToJson frag))
      ) fragments;

    # Build the nix-place sync command for one target
    mkSyncCommand = target: let
      fragments = cfg.${target};
      fragmentFiles = materializeFragments fragments;
      fragmentArgs = concatMapStringsSep " " (f: "--fragments ${f}") fragmentFiles;
      targetDir = if target == "" then homeDir else "${homeDir}/${target}";
      description = if target == "" then "Home" else target;
      # Skip git init at $HOME (unusual, could interfere with dotfiles)
      noGitFlag = optionalString (target == "") "--no-git";
    in ''
      $VERBOSE_ECHO "Syncing flake fragments for ${description}..."
      ${nixPlace}/bin/nix-place sync \
        --target "${targetDir}" \
        ${fragmentArgs} \
        --description "Managed workspace: ${description}" \
        ${noGitFlag}
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

        Example:
          blackmatter.flakeFragments."code/github/pleme-io" = [
            { id = "pleme-workspace"; priority = 50; apps = { ... }; }
          ];
      '';
    };

    config = mkIf (cfg != {}) {
      home.activation.syncWorkspaceFlakes = lib.hm.dag.entryAfter ["writeBoundary"] ''
        PATH="${makeBinPath (with pkgs; [ git nix ])}:$PATH"
        ${concatMapStringsSep "\n" mkSyncCommand sortedTargets}
      '';
    };
  };
}
