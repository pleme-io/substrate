# Home-manager tool module helpers
#
# Reusable patterns for multi-tool HM components with profile-based
# selection, per-tool overrides, platform-conditional filtering,
# and safe package access.
#
# Used by blackmatter-android, potentially blackmatter-kubernetes,
# blackmatter-security, and any future multi-tool component.
#
# Usage (in flake.nix):
#   homeManagerModules.default = import ./module {
#     hmToolHelpers = import "${substrate}/lib/hm-tool-helpers.nix" { lib = nixpkgs.lib; };
#   };
#
# Usage (in module/default.nix):
#   { hmToolHelpers }: { lib, config, pkgs, ... }:
#   let inherit (hmToolHelpers) mkSafeToolMap mkEnabledPackages; in { ... }
{ lib }:
with lib;
{
  # ─── Safe tool map ───────────────────────────────────────────────────
  # Build a tool map from a raw definition, filtering out packages
  # that don't exist in nixpkgs. Packages use `or null` to safely
  # handle missing attributes; this function strips the nulls.
  #
  # Example:
  #   mkSafeToolMap {
  #     all = { scrcpy = pkgs.scrcpy or null; localsend = pkgs.localsend or null; };
  #     linux = { waydroid = pkgs.waydroid or null; };
  #   }
  #   # → { scrcpy = <pkg>; localsend = <pkg>; waydroid = <pkg>; } on Linux
  #   # → { scrcpy = <pkg>; localsend = <pkg>; } on macOS
  mkSafeToolMap = { all ? {}, linux ? {}, darwin ? {} }:
    filterAttrs (_: v: v != null) all
    // filterAttrs (_: v: v != null) linux
    // filterAttrs (_: v: v != null) darwin;

  # ─── Enabled packages ───────────────────────────────────────────────
  # Given a tool map and an enablement map (tool name → bool),
  # return only the packages for enabled tools.
  #
  # Example:
  #   mkEnabledPackages toolMap enabledTools
  #   # → [ <scrcpy> <localsend> ] (only enabled tools)
  mkEnabledPackages = toolMap: enabledTools:
    let
      # Catch packages whose transitive deps fail platform checks
      # (e.g., android-file-transfer → fuse on macOS).
      # builtins.tryEval catches the throw from meta.platforms assertions
      # without actually building anything — only forces derivation eval.
      isBuildable = pkg:
        let result = builtins.tryEval pkg.drvPath;
        in result.success;
    in filter (p: p != null) (mapAttrsToList (name: pkg:
      if (enabledTools.${name} or false) && isBuildable pkg then pkg else null
    ) toolMap);

  # ─── Profile resolution ─────────────────────────────────────────────
  # Resolve which tools are enabled from a profile definition and
  # per-tool overrides. Returns an attrset of tool name → bool.
  #
  # Example:
  #   mkResolvedTools {
  #     profileToolNames = [ "adb" "scrcpy" "localsend" ];
  #     toolOverrides = { jadx.enable = true; scrcpy.enable = false; };
  #   }
  #   # → { adb = true; scrcpy = false; localsend = true; jadx = true; }
  mkResolvedTools = { profileToolNames, toolOverrides ? {} }:
    let
      profileDefaults = listToAttrs (map (name: nameValuePair name true) profileToolNames);
      overrides = mapAttrs (_: t: t.enable) (filterAttrs (_: t: t ? enable) toolOverrides);
    in profileDefaults // overrides;

  # ─── Profile options ─────────────────────────────────────────────────
  # Standard option definitions for profile-based tool components.
  # Returns an attrset of options to merge into the component.
  #
  # Example:
  #   options.blackmatter.components.android = mkProfileToolOptions {
  #     profiles = [ "minimal" "standard" "development" "security" "full" ];
  #     defaultProfile = "standard";
  #     profileDescription = "...";
  #   };
  mkProfileToolOptions = {
    profiles,
    defaultProfile ? "standard",
    profileDescription ? "Tool profile",
  }: {
    profile = mkOption {
      type = types.enum profiles;
      default = defaultProfile;
      description = profileDescription;
    };

    tools = mkOption {
      type = types.attrsOf (types.submodule {
        options.enable = mkOption {
          type = types.bool;
          description = "Whether to enable this tool (overrides profile default)";
        };
      });
      default = {};
      description = "Per-tool overrides. Takes precedence over the selected profile.";
    };
  };

  # ─── Shell aliases ───────────────────────────────────────────────────
  # Apply shell aliases to both zsh and bash, conditional on a tool
  # being enabled and the shell program being active.
  #
  # Example:
  #   mkConditionalAliases {
  #     config = config;
  #     enabledTools = enabledTools;
  #     toolName = "adb";
  #     aliases = { adevices = "adb devices"; apush = "adb push"; };
  #   }
  mkConditionalAliases = { config, enabledTools, toolName, aliases }:
    let
      isEnabled = enabledTools.${toolName} or false;
    in {
      programs.zsh.shellAliases = mkIf (config.programs.zsh.enable && isEnabled) aliases;
      programs.bash.shellAliases = mkIf (config.programs.bash.enable && isEnabled) aliases;
    };
}
