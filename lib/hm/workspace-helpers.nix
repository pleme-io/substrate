# Home-manager workspace helpers
#
# Generic workspace abstraction for multi-identity environments.
# Each workspace gets its own terminal wrapper, shell prompt indicator,
# and AI agent configuration. The WORKSPACE env var is the pivot point.
#
# Usage (in module):
#   workspaceHelpers = import "${substrate}/lib/hm-workspace-helpers.nix" { inherit lib; };
#   options.workspaces = mkOption { type = types.attrsOf (types.submodule workspaceHelpers.workspaceOpts); };
{ lib }:
with lib;
{
  # Workspace option submodule type
  workspaceOpts = { name, ... }: {
    options = {
      displayName = mkOption {
        type = types.str;
        default = name;
        description = "Display name shown in prompts and statuslines.";
      };

      theme = {
        accent = mkOption {
          type = types.str;
          default = "#88C0D0";
          description = "Primary accent hex color for this workspace.";
        };

        cursorColor = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Terminal cursor color override.";
        };

        selectionBackground = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Terminal selection background override.";
        };
      };

      ghostty = {
        extraConfig = mkOption {
          type = types.lines;
          default = "";
          description = "Extra Ghostty config lines appended to workspace config.";
        };
      };
    };
  };

  # Generate a Ghostty workspace config file content.
  # Includes the base config and overrides visual settings.
  mkGhosttyConfig = { baseConfigPath, workspace }: let
    accent = workspace.theme.accent;
    cursor = if workspace.theme.cursorColor != null then workspace.theme.cursorColor else accent;
    selection = if workspace.theme.selectionBackground != null then workspace.theme.selectionBackground else "";
  in ''
    config-file = ${baseConfigPath}
    title = ${workspace.displayName}
    cursor-color = ${cursor}
  '' + optionalString (selection != "") ''
    selection-background = ${selection}
  '' + workspace.ghostty.extraConfig;

  # Generate a workspace wrapper script that sets WORKSPACE and launches a command.
  mkWorkspaceWrapper = pkgs: name: binaryName: command: args:
    pkgs.writeShellScriptBin binaryName ''
      export WORKSPACE="${name}"
      exec ${command} ${concatStringsSep " " (map escapeShellArg args)} "$@"
    '';
}
