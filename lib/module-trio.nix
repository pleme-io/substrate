# Module trio macro — emit NixOS + nix-darwin + home-manager modules from one spec.
#
# This is the macro that ends the duplication of `// { homeManagerModules.default = ...; }`
# scattered across consumer flakes. One spec → three modules with consistent option surface.
#
# ── Usage in a flake ────────────────────────────────────────────────────────
#
#   outputs = { self, nixpkgs, substrate, ... }: let
#     trio = (import "${substrate}/lib/module-trio.nix" { lib = nixpkgs.lib; }).mkModuleTrio {
#       name = "namimado";
#       description = "Namimado desktop browser";
#       withMcp = true;          # adds programs.namimado.enableMcpBin
#       withHttp = true;         # adds programs.namimado.enableHttpService + httpAddr
#       withSystemDaemon = true; # adds services.namimado.daemon for NixOS + Darwin
#     };
#   in {
#     homeManagerModules.default = trio.homeManagerModule;
#     nixosModules.default       = trio.nixosModule;
#     darwinModules.default      = trio.darwinModule;
#   };
#
# ── Or via builder helper (rust-tool-release-flake.nix) ────────────────────
#
#   (import "${substrate}/lib/rust-tool-release-flake.nix" { ... }) {
#     toolName = "namimado";
#     module = {
#       description = "Namimado desktop browser";
#       withMcp = true; withHttp = true; withSystemDaemon = true;
#     };
#   };
#
#   The builder auto-emits nixosModules / darwinModules / homeManagerModules
#   from `module`, so consumers get all three for free.
#
# ── Spec fields ────────────────────────────────────────────────────────────
#
#   name              tool/service identifier (string). Drives option namespace
#                     (programs.<name> for HM, services.<name> for system).
#   description       human-readable description (string).
#   binaryName        binary name in ${package}/bin/ (default: name).
#   packageAttr       overlay attr name (default: name).
#
#   withMcp           bool — add programs.<name>.enableMcpBin (HM only).
#                     Writes a ~/.local/bin/<name>-mcp shim that runs
#                     `<binary> <mcpSubcommand> "$@"`.
#   mcpSubcommand     subcommand string (default: "mcp").
#
#   withHttp          bool — add programs.<name>.enableHttpService (HM only).
#                     Spawns user-level launchd agent (Darwin) or systemd
#                     user unit (Linux) running `<binary> <httpSubcommand>
#                     --addr <httpAddr>`.
#   httpSubcommand    subcommand string (default: "serve").
#   defaultHttpAddr   default listen address (default: "127.0.0.1:7860").
#
#   withSystemDaemon  bool — add services.<name>.daemon to NixOS + Darwin.
#                     NixOS: systemd system service via mkNixOSService.
#                     Darwin: launchd daemon via mkLaunchdDaemon.
#   daemonSubcommand  subcommand string (default: "daemon").
#
#   extraHmOptions    attrset of additional HM options to merge (default: {}).
#   extraSystemOptions attrset of additional NixOS+Darwin options (default: {}).
#   extraHmConfig     cfg → config attrset, merged into HM module (default: _: {}).
#   extraNixosConfig  cfg → config attrset, merged into NixOS module (default: _: {}).
#   extraDarwinConfig cfg → config attrset, merged into Darwin module (default: _: {}).
#
# ── Returns ────────────────────────────────────────────────────────────────
#
#   {
#     homeManagerModule = { lib, config, pkgs, ... }: { options, config };
#     nixosModule       = { lib, config, pkgs, ... }: { options, config };
#     darwinModule      = { lib, config, pkgs, ... }: { options, config };
#   }
#
{ lib }:
let
  hmHelpers     = import ./hm/service-helpers.nix         { inherit lib; };
  nixosHelpers  = import ./hm/nixos-service-helpers.nix   { inherit lib; };
  darwinHelpers = import ./hm/darwin-service-helpers.nix  { inherit lib; };

  inherit (lib) mkOption mkEnableOption mkIf mkMerge optionalAttrs types literalExpression;
in
{
  mkModuleTrio = spec:
    let
      name              = spec.name;
      description       = spec.description;
      binaryName        = spec.binaryName       or name;
      packageAttr       = spec.packageAttr      or name;

      withMcp           = spec.withMcp          or false;
      mcpSubcommand     = spec.mcpSubcommand    or "mcp";

      withHttp          = spec.withHttp         or false;
      httpSubcommand    = spec.httpSubcommand   or "serve";
      defaultHttpAddr   = spec.defaultHttpAddr  or "127.0.0.1:7860";

      withSystemDaemon  = spec.withSystemDaemon or false;
      daemonSubcommand  = spec.daemonSubcommand or "daemon";

      extraHmOptions     = spec.extraHmOptions     or {};
      extraSystemOptions = spec.extraSystemOptions or {};
      extraHmConfig      = spec.extraHmConfig      or (_: {});
      extraNixosConfig   = spec.extraNixosConfig   or (_: {});
      extraDarwinConfig  = spec.extraDarwinConfig  or (_: {});

      mkPackageOption = pkgs: mkOption {
        type = types.package;
        default = pkgs.${packageAttr};
        defaultText = literalExpression "pkgs.${packageAttr}";
        description = "The ${name} package.";
      };

      hmOptions = pkgs: {
        enable = mkEnableOption description;
        package = mkPackageOption pkgs;
      } // optionalAttrs withMcp {
        enableMcpBin = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Install a `${name}-mcp` shim on PATH that runs
            `${binaryName} ${mcpSubcommand}` (stdio transport) — useful for
            registering with blackmatter-anvil.
          '';
        };
      } // optionalAttrs withHttp {
        enableHttpService = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Install a launchd/systemd user service that runs
            `${binaryName} ${httpSubcommand} --addr <httpAddr>`.
          '';
        };
        httpAddr = mkOption {
          type = types.str;
          default = defaultHttpAddr;
          description = "Listen address for the HTTP service.";
        };
      } // extraHmOptions;

      systemOptions = pkgs: {
        enable = mkEnableOption description;
        package = mkPackageOption pkgs;
      } // optionalAttrs withSystemDaemon {
        daemon = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = "Run ${name} as a system-level daemon.";
          };
          extraArgs = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Additional CLI args appended to `${binaryName} ${daemonSubcommand}`.";
          };
          environment = mkOption {
            type = types.attrsOf types.str;
            default = {};
            description = "Environment variables for the daemon.";
          };
        };
      } // extraSystemOptions;

    in
    {
      # ─── home-manager module ────────────────────────────────────────
      homeManagerModule = { lib, config, pkgs, ... }:
        let
          cfg = config.programs.${name};
        in
        {
          options.programs.${name} = hmOptions pkgs;

          config = mkIf cfg.enable (mkMerge [
            { home.packages = [ cfg.package ]; }

            (mkIf (withMcp && (cfg.enableMcpBin or false)) {
              home.file.".local/bin/${name}-mcp" = {
                executable = true;
                text = ''
                  #!${pkgs.bash}/bin/bash
                  exec ${cfg.package}/bin/${binaryName} ${mcpSubcommand} "$@"
                '';
              };
            })

            (mkIf (withHttp && (cfg.enableHttpService or false)) (
              if pkgs.stdenv.isDarwin
              then hmHelpers.mkLaunchdService {
                name = "${name}-http";
                label = "io.pleme.${name}.http";
                command = "${cfg.package}/bin/${binaryName}";
                args = [ httpSubcommand "--addr" cfg.httpAddr ];
                logDir = "${config.home.homeDirectory}/Library/Logs";
              }
              else hmHelpers.mkSystemdService {
                name = "${name}-http";
                description = "${description} HTTP service";
                command = "${cfg.package}/bin/${binaryName}";
                args = [ httpSubcommand "--addr" cfg.httpAddr ];
              }
            ))

            (extraHmConfig cfg)
          ]);
        };

      # ─── NixOS module (system-level systemd) ────────────────────────
      nixosModule = { lib, config, pkgs, ... }:
        let
          cfg = config.services.${name};
        in
        {
          options.services.${name} = systemOptions pkgs;

          config = mkIf cfg.enable (mkMerge [
            { environment.systemPackages = [ cfg.package ]; }

            (mkIf (withSystemDaemon && (cfg.daemon.enable or false)) (nixosHelpers.mkNixOSService {
              name = "${name}-daemon";
              description = "${description} daemon";
              command = "${cfg.package}/bin/${binaryName}";
              args = [ daemonSubcommand ] ++ cfg.daemon.extraArgs;
              environment = cfg.daemon.environment;
            }))

            (extraNixosConfig cfg)
          ]);
        };

      # ─── nix-darwin module (system-level launchd) ───────────────────
      darwinModule = { lib, config, pkgs, ... }:
        let
          cfg = config.services.${name};
        in
        {
          options.services.${name} = systemOptions pkgs;

          config = mkIf cfg.enable (mkMerge [
            { environment.systemPackages = [ cfg.package ]; }

            (mkIf (withSystemDaemon && (cfg.daemon.enable or false)) (darwinHelpers.mkLaunchdDaemon {
              name = "${name}-daemon";
              label = "io.pleme.${name}.daemon";
              command = "${cfg.package}/bin/${binaryName}";
              args = [ daemonSubcommand ] ++ cfg.daemon.extraArgs;
              env = cfg.daemon.environment;
            }))

            (extraDarwinConfig cfg)
          ]);
        };
    };
}
