# Substrate factory — emit the standard pleme-io fleet app module trio.
#
# Every operator-facing fleet app (mado, tear, frost, frostmourne,
# escriba, ayatsuri, namimado) ships nixosModules + darwinModules +
# homeManagerModules at its flake's outputs. This factory codifies
# the SHAPE so each app's wiring is one helper call + per-app schema,
# not 200 lines of hand-rolled module boilerplate.
#
# # Operator-facing surface every fleet app exposes (uniformly)
#
#   programs.<name>.enable           — toggle (HM); services.<name>.enable
#                                       (NixOS+Darwin if the app supervises
#                                       a daemon)
#   programs.<name>.tier             — enum: bare | discovered | default
#   programs.<name>.extraSettings    — typed attrs overlaid on the tier
#                                       baseline; rendered to YAML
#   programs.<name>.manageConfig     — when false, mado/frost/etc. read
#                                       their own ~/.config/<name>/<name>.yaml
#                                       without nix overwriting
#   programs.<name>.package          — override the installed package
#
# # Tier semantics (matches shikumi::TieredConfig)
#
#   `bare`       — every field at the zero-opinion floor. Operator gets
#                  the minimum viable config; ideal for diffing.
#   `discovered` — bare + the app's runtime auto-detect outputs (display
#                  dims, theme detection, font probe). No prescribed
#                  fleet opinions.
#   `default`    — bare + discovered + the prescribed fleet defaults
#                  (from ishou_tokens::FleetDefaults). The 90% case.
#
# In all three tiers `extraSettings` is the typed escape hatch that
# layers per-field YAML overrides on top.
#
# # Theme uniformity
#
# Every fleet app's default tier reads from
# `ishou_tokens::FleetDefaults::prescribed()` — so the same nord-dark
# palette + JetBrainsMono Nerd Font Mono + cursor + scrollback choices
# propagate through every app. Touching FleetDefaults is one diff that
# updates the entire fleet.
#
# # Usage
#
#   { inputs, system, ... }:
#   let
#     trio = (import "${inputs.substrate}/lib/build/nix/fleet-app-module.nix" {
#       inherit (inputs.nixpkgs) lib;
#     }) {
#       name = "escriba";
#       package = inputs.escriba.packages.${system}.default;
#       configRelPath = "escriba/escriba.yaml";
#       description = "Lisp-driven shader composer for the pleme-io fleet";
#     };
#   in
#   {
#     homeManagerModules.default = trio.homeManager;
#     nixosModules.default = trio.nixos;
#     darwinModules.default = trio.darwin;
#   }

{ lib }:
{
  # App identity.
  name,                            # "mado" / "escriba" / "tear" / ...
  package,                         # the derivation that ships the binary
  configRelPath,                   # "mado/mado.yaml" — relative to $XDG_CONFIG_HOME
  description ? "pleme-io fleet app",

  # Optional: a callback that takes the resolved settings attrs and
  # returns an attrset of additional `home.*` fields (used by apps
  # that also want to install fonts, set XDG handlers, register a
  # launchd agent, etc.). Defaults to no additions.
  extraHomeWiring ? (settings: {}),

  # Optional NixOS + Darwin systemd / launchd unit when the app
  # supervises a daemon (tear, future kenshi, etc.). Both default to
  # null = pure HM (no system service).
  nixosService ? null,
  darwinService ? null,
}:

let
  yamlGen = pkgsArg: pkgsArg.formats.yaml { };

  # The HM module — the load-bearing one. Most fleet apps need only
  # this; NixOS + Darwin wrappers re-export via home-manager.sharedModules.
  homeManagerModule = { config, lib, pkgs, ... }:
    let
      cfg = config.programs.${name};
      yaml = yamlGen pkgs;
      # The rendered YAML payload — extraSettings IS the full
      # override surface (operators describe what they want, the
      # app loader merges with its own tier-resolved baseline).
      yamlPayload = cfg.extraSettings;
    in
    {
      options.programs.${name} = {
        enable = lib.mkEnableOption description;

        package = lib.mkOption {
          type = lib.types.package;
          default = package;
          defaultText = lib.literalExpression "<flake input>.${name}.packages.<system>.default";
          description = "The ${name} package to install.";
        };

        tier = lib.mkOption {
          type = lib.types.enum [ "bare" "discovered" "default" ];
          default = "default";
          description = ''
            Config tier per `shikumi::TieredConfig`:
              * bare       — zero-opinion floor
              * discovered — bare + runtime auto-detect outputs
              * default    — bare + discovered + prescribed fleet defaults
            The 90% case is `default`. Operators who want minimum-viable
            config OR want to layer their own on the bare floor pick the
            relevant tier here.

            Passed to the app at launch via the
            `${lib.toUpper name}_TIER` env var; the app's TieredConfig
            constructor resolves accordingly.
          '';
        };

        extraSettings = lib.mkOption {
          type = lib.types.attrs;
          default = { };
          description = ''
            YAML override fields layered onto whatever the selected
            `tier` resolves to. Operators get full per-field control
            without losing the typed tier baseline.
          '';
        };

        manageConfig = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            When true (default), Nix writes the rendered YAML to
            `${configRelPath}`. Set to false when you edit the
            file by hand and want Nix to leave it alone.
          '';
        };
      };

      config = lib.mkIf cfg.enable (lib.mkMerge [
        {
          home.packages = [ cfg.package ];

          # Env: pass the tier selection through so the app's typed
          # TieredConfig constructor can pick the right base before
          # layering on extraSettings.
          home.sessionVariables = {
            "${lib.toUpper name}_TIER" = cfg.tier;
          };

          # YAML emission — typed attrs → YAML via nixpkgs.formats.yaml.
          # When extraSettings is empty + tier == default, the file is
          # effectively a marker stating "the operator accepts the
          # prescribed defaults"; the app reads it + acts accordingly.
          home.file."${configRelPath}" = lib.mkIf cfg.manageConfig {
            source = yaml.generate "${name}.yaml" yamlPayload;
          };
        }
        (extraHomeWiring yamlPayload)
      ]);
    };

  # NixOS wrapper — installs the package via environment.systemPackages
  # for global PATH availability AND wires the HM module into every
  # user's home-manager config via the shared-modules slot. If the
  # caller supplied a `nixosService`, also enable it.
  nixosModule = { config, lib, pkgs, ... }: {
    options.programs.${name} = {
      enable = lib.mkEnableOption description;
      package = lib.mkOption {
        type = lib.types.package;
        default = package;
        description = "${name} package (system-wide install).";
      };
    };

    config = lib.mkIf config.programs.${name}.enable (lib.mkMerge [
      {
        environment.systemPackages = [ config.programs.${name}.package ];
        # Forward into HM via the home-manager NixOS module's
        # sharedModules slot (set by every pleme-io fleet host).
        home-manager.sharedModules = lib.mkAfter [ homeManagerModule ];
      }
      (lib.mkIf (nixosService != null) (nixosService { inherit config lib pkgs; }))
    ]);
  };

  # Darwin wrapper — same shape, environment.systemPackages →
  # `environment.systemPackages` works on nix-darwin too. Optional
  # darwinService callback for launchd integration.
  darwinModule = { config, lib, pkgs, ... }: {
    options.programs.${name} = {
      enable = lib.mkEnableOption description;
      package = lib.mkOption {
        type = lib.types.package;
        default = package;
        description = "${name} package (Darwin system-wide install).";
      };
    };

    config = lib.mkIf config.programs.${name}.enable (lib.mkMerge [
      {
        environment.systemPackages = [ config.programs.${name}.package ];
        home-manager.sharedModules = lib.mkAfter [ homeManagerModule ];
      }
      (lib.mkIf (darwinService != null) (darwinService { inherit config lib pkgs; }))
    ]);
  };
in
{
  homeManager = homeManagerModule;
  nixos = nixosModule;
  darwin = darwinModule;
}
