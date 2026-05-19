# Home-manager helpers for declarative estante shell-package consumption.
#
# Patterns:
#
#   1. Plain package list — install the lockfile's packages, write the
#      lockfile into ~/.config/frost/shellpkg.lock.lisp, and append a
#      `(defsource :path "…")` line to ~/.frostrc.lisp.
#
#   2. Per-package enabled toggles — like blackmatter's hm-tool-helpers
#      pattern. Operator picks which lockfile entries to actually load.
#
#   3. Inline scripts — declare a list of `mkScriptBinary`-shaped entries
#      and they get installed as wrapped CLIs.
#
# Usage (in a blackmatter component):
#
#   { hmShellpkgHelpers }: { config, lib, pkgs, ... }:
#   let
#     inherit (hmShellpkgHelpers) mkShellpkgComponent;
#     estante = import "${substrate}/lib/build/estante" { inherit pkgs; };
#   in mkShellpkgComponent {
#     inherit config lib pkgs estante;
#     componentName = "frostmourne";
#     lockfile = ./shellpkg.lock.nix;
#     defaultEnabled = true;
#   }
#
# Returns a partial HM-component shape — options + config pieces — that
# composes with the rest of the component's settings.
{ lib }:
with lib;
{
  # Build the standard options shape for a shellpkg-consuming HM
  # component. Returns an attrset of options to merge into
  # `options.blackmatter.components.<componentName>`.
  mkShellpkgOptions = {
    componentName,
    defaultEnabled ? true,
    description ? "estante shell-package set",
  }: {
    enable = mkOption {
      type = types.bool;
      default = defaultEnabled;
      description = "Enable the ${componentName} shell-package set.";
    };

    packages = mkOption {
      type = types.attrsOf (types.submodule {
        options.enable = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to load this package via defload.";
        };
      });
      default = {};
      description = ''
        Per-package enable toggles. Every package in the consumed
        lockfile is enabled by default; this attrset lets the operator
        suppress specific packages without re-rendering the lockfile.

        Example:
          packages.zsh-you-should-use.enable = false;
      '';
    };

    extraScripts = mkOption {
      type = types.listOf (types.submodule {
        options.name = mkOption {
          type = types.str;
          description = "Binary name installed via home-manager.";
        };
        options.script = mkOption {
          type = types.path;
          description = "Path to the tatara-lisp script source.";
        };
        options.lockfile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Optional per-script lockfile (defaults to component lockfile).";
        };
      });
      default = [];
      description = "Inline tatara-lisp scripts wrapped as installable binaries.";
    };

    inherit description;
  };

  # Build the config-side of a shellpkg HM component. Returns an
  # attrset suitable for `mkIf cfg.enable { ... }`.
  mkShellpkgConfig = {
    cfg,                    # the component's resolved config (cfg)
    estante,                # substrate's estante lib for this system
    lockfile,               # path to shellpkg.lock.nix
    frost ? null,           # frost binary derivation (for wrapping scripts)
    componentName,
  }:
    let
      shellEnv = estante.mkShellEnv { inherit lockfile; };

      scriptBinaries = map (s: estante.mkScriptBinary {
        inherit (s) name script;
        lockfile = if s.lockfile == null then lockfile else s.lockfile;
        inherit frost;
      }) cfg.extraScripts;

      enabledNamesFromCfg = builtins.attrNames (filterAttrs (_: p: p.enable) cfg.packages);
      # If the operator hasn't named anything explicitly, default to "all"
      # (every package in the lockfile loads).
      explicitEnable = cfg.packages != {};
    in {
      home.packages = [ shellEnv ] ++ scriptBinaries;

      # Materialized lockfile into XDG_CONFIG_HOME so frost-lisp can
      # defsource it. The path is stable across rebuilds because it's
      # a Nix store path with a content hash.
      xdg.configFile."frost/shellpkg.lock.lisp" = mkIf (builtins.pathExists "${shellEnv}/shellpkg.lock.lisp") {
        source = "${shellEnv}/shellpkg.lock.lisp";
      };

      # Drop a manifest into the HM state dir so the operator can
      # introspect what's installed.
      xdg.configFile."frost/${componentName}-manifest.json".text = builtins.toJSON {
        component = componentName;
        explicitEnable = explicitEnable;
        enabledPackages = if explicitEnable then enabledNamesFromCfg
                          else shellEnv.meta.estante.envContents;
        extraScripts = map (s: s.name) cfg.extraScripts;
      };
    };
}
