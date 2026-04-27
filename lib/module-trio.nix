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
#                     (<hmNamespace>.<name> for HM, services.<name> for system).
#   description       human-readable description (string).
#   binaryName        binary name in ${package}/bin/ (default: name).
#   packageAttr       overlay attr name (default: name).
#
#   hmNamespace       option-tree path for the HM module (default: "programs").
#                     Other common values: "blackmatter.components", "services".
#                     Drives where the consumer config lives:
#                       hmNamespace = "programs"               → programs.<name>
#                       hmNamespace = "blackmatter.components" → blackmatter.components.<name>
#                     Use this to match the existing fleet convention without
#                     adding extraHmOptions. Anvil-MCP / shikumi sub-namespaces
#                     remain under services.<name>.* regardless.
#
#   withMcp           bool — add programs.<name>.enableMcpBin (HM only).
#                     Writes a ~/.local/bin/<name>-mcp shim that runs
#                     `<binary> <mcpSubcommand> "$@"`.
#   mcpSubcommand     subcommand string (default: "mcp").
#
#   withAnvilMcp      bool — add services.<name>.mcp.{enable, package, scopes,
#                     agents} (HM only). Registers the binary with
#                     blackmatter-anvil so AI agents (Claude Code, Cursor,
#                     OpenCode) can drive it directly without a PATH shim.
#                     Emits blackmatter.components.anvil.mcp.servers.<name>.
#                     Independent of withMcp; both can be true (rare).
#   anvilArgs         list of args passed to the binary (default: ["<mcpSubcommand>"]
#                     if mcpSubcommand != "" else []). Override for bare-bones
#                     binaries that don't take a "mcp" subcommand (e.g. umbra).
#   anvilEnv          attrset of env vars for the anvil entry (default: {}).
#   anvilDescription  human-readable description for the anvil entry
#                     (default: spec.description).
#
#   withHttp          bool — add programs.<name>.enableHttpService (HM only).
#                     Spawns user-level launchd agent (Darwin) or systemd
#                     user unit (Linux) running `<binary> <httpSubcommand>
#                     --addr <httpAddr>`.
#   httpSubcommand    subcommand string (default: "serve").
#   defaultHttpAddr   default listen address (default: "127.0.0.1:7860").
#
#   withSystemDaemon  bool — add services.<name>.daemon to NixOS + Darwin
#                     (system-level / root). NixOS: systemd system service
#                     via mkNixOSService. Darwin: launchd daemon via
#                     mkLaunchdDaemon. Use this for tools that genuinely
#                     need root (k3s, networkd, etc.). For per-user
#                     daemons, prefer withUserDaemon.
#   daemonSubcommand  subcommand string (default: "daemon").
#
#   withUserDaemon    bool — add programs.<name>.daemon (HM only). Spawns a
#                     user-level launchd agent (Darwin) or systemd user unit
#                     (Linux). This is the dominant fleet pattern (kekkai,
#                     shirase, mamorigami, hikki, etc.) — most pleme-io
#                     daemons don't need root.
#   userDaemonSubcommand
#                     subcommand string (default: same as daemonSubcommand).
#   userDaemonExtraArgs
#                     list of additional CLI args appended after the
#                     subcommand (default: []).
#   userDaemonEnv     attrset of env vars (default: {}).
#
#   withShikumiConfig bool — add services.<name>.settings (HM only) and
#                     deploy a YAML config to ~/.config/<name>/<name>.yaml.
#                     Used by shikumi-style apps that read a YAML file at
#                     startup. anvil entries auto-pick up <NAME>_CONFIG env.
#   shikumiDefaults   attrset of default settings (default: {}).
#   shikumiConfigPath path string for the YAML, relative to ~ (default:
#                     ".config/<name>/<name>.yaml").
#
#   extraHmOptions    attrset of additional HM options to merge (default: {}).
#   extraSystemOptions attrset of additional NixOS+Darwin options (default: {}).
#   extraHmConfig     cfg → config attrset, merged into HM module (default: _: {}).
#                     Legacy positional form. For pkgs-aware extras, prefer
#                     extraHmConfigFn below.
#   extraHmConfigFn   { cfg, pkgs, lib, config } → config (default: _: {}).
#                     Same as extraHmConfig but receives pkgs/lib/config so
#                     consumers can install additional packages, generate
#                     YAML, or reference helpers without re-importing them.
#                     Both extraHmConfig and extraHmConfigFn run if both set.
#   extraNixosConfig  cfg → config attrset, merged into NixOS module (default: _: {}).
#   extraDarwinConfig cfg → config attrset, merged into Darwin module (default: _: {}).
#
#   extraPackages     list of pkgs.<attr> names to install alongside the
#                     primary package when <hmNamespace>.<name>.enable is
#                     true (default: []). Useful for apps that ship multiple
#                     binaries via separate overlay attrs (e.g. wasm-platform
#                     bundles wasmtime + wasm-tools).
#
#   darwinOnly        bool — gate the entire HM/Darwin module on
#                     pkgs.stdenv.hostPlatform.isDarwin (default: false).
#                     The package is omitted from home.packages and the
#                     option tree stays empty on Linux. NixOS module is also
#                     a no-op. Use for Darwin-exclusive tools (Apple
#                     framework wrappers, Homebrew bridges, etc.).
#   linuxOnly         bool — symmetric gate for Linux-only tools.
#
#   shikumiTypedGroups (attrset of group → field → spec, default: {})
#                     Typed nested config surface that round-trips to the
#                     shikumi YAML. Each group becomes a sub-namespace under
#                     <hmNamespace>.<name>.<group>; each field becomes a
#                     typed mkOption. Settings auto-merge into
#                     services.<name>.settings (when withShikumiConfig is on).
#                     Spec shape per field:
#                       { type = "int" | "str" | "bool" | "float" | "path" |
#                                "intRange" | types.<expr>;
#                         default = <value>;
#                         description = "<doc>";
#                         min = <int>; max = <int>;   # only for intRange
#                       }
#                     Example:
#                       shikumiTypedGroups = {
#                         appearance = {
#                           width  = { type = "int"; default = 1280; description = "Window width"; };
#                           height = { type = "int"; default = 720;  description = "Window height"; };
#                         };
#                         storage = {
#                           notes_dir = { type = "str"; default = "~/notes"; description = "Notes path"; };
#                         };
#                       };
#                     Renders to options.<hmNamespace>.<name>.{appearance,storage}.* and serializes to YAML.
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

      hmNamespace       = spec.hmNamespace      or "programs";
      hmNamespacePath   = lib.splitString "." hmNamespace;

      withMcp           = spec.withMcp          or false;
      mcpSubcommand     = spec.mcpSubcommand    or "mcp";

      withAnvilMcp        = spec.withAnvilMcp        or false;
      anvilArgs           = spec.anvilArgs           or
                            (if mcpSubcommand == "" then [] else [ mcpSubcommand ]);
      anvilEnv            = spec.anvilEnv            or {};
      anvilDescription    = spec.anvilDescription    or description;
      anvilDefaultEnable  = spec.anvilDefaultEnable  or false;
      anvilGateOnEnable   = spec.anvilGateOnEnable   or false;
      shikumiGateOnEnable = spec.shikumiGateOnEnable or false;

      withHttp          = spec.withHttp         or false;
      httpSubcommand    = spec.httpSubcommand   or "serve";
      defaultHttpAddr   = spec.defaultHttpAddr  or "127.0.0.1:7860";

      withSystemDaemon  = spec.withSystemDaemon or false;
      daemonSubcommand  = spec.daemonSubcommand or "daemon";

      withUserDaemon       = spec.withUserDaemon       or false;
      userDaemonSubcommand = spec.userDaemonSubcommand or daemonSubcommand;
      userDaemonExtraArgs  = spec.userDaemonExtraArgs  or [];
      userDaemonEnv        = spec.userDaemonEnv        or {};

      withShikumiConfig = spec.withShikumiConfig or false;
      shikumiDefaults   = spec.shikumiDefaults   or {};
      shikumiConfigPath = spec.shikumiConfigPath or ".config/${name}/${name}.yaml";
      shikumiEnvVar     = spec.shikumiEnvVar     or
                          (lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] name) + "_CONFIG");

      extraHmOptions     = spec.extraHmOptions     or {};
      extraSystemOptions = spec.extraSystemOptions or {};
      extraHmConfig      = spec.extraHmConfig      or (_: {});
      extraHmConfigFn    = spec.extraHmConfigFn    or (_: {});
      extraNixosConfig   = spec.extraNixosConfig   or (_: {});
      extraDarwinConfig  = spec.extraDarwinConfig  or (_: {});

      extraPackages      = spec.extraPackages      or [];

      darwinOnly         = spec.darwinOnly         or false;
      linuxOnly          = spec.linuxOnly          or false;

      shikumiTypedGroups = spec.shikumiTypedGroups or {};

      # ── Typed-group rendering helpers ────────────────────────────────
      # Convert a field spec ({ type = "int"; default = X; description = "..."; })
      # into an mkOption call. Strings name primitive Nix types; raw
      # types.* expressions pass through unchanged.
      resolveFieldType = field:
        if field ? type then
          if builtins.isString field.type then
            if field.type == "int" then types.int
            else if field.type == "str" then types.str
            else if field.type == "bool" then types.bool
            else if field.type == "float" then types.float
            else if field.type == "path" then types.path
            else if field.type == "intRange" then
              types.ints.between (field.min or 0) (field.max or 65535)
            else throw "module-trio: unknown shikumiTypedGroup field type '${field.type}' (use int|str|bool|float|path|intRange or pass a types.* expression directly)"
          else field.type
        else types.unspecified;

      mkTypedField = name: field: mkOption ({
        type = resolveFieldType field;
      } // optionalAttrs (field ? default) {
        inherit (field) default;
      } // optionalAttrs (field ? description) {
        inherit (field) description;
      });

      # Group spec → { <field> = mkOption ...; }
      mkTypedGroupOptions = group: lib.mapAttrs mkTypedField group;

      # All typed-group options as { <group>.<field> = mkOption ...; }
      typedGroupsOptions = lib.mapAttrs (_: mkTypedGroupOptions) shikumiTypedGroups;

      # Extract typed-group values from cfg as { <group> = { <field> = value; }; }
      # for serialization into the shikumi YAML.
      typedGroupsValues = cfg:
        lib.mapAttrs (groupName: groupSpec:
          lib.mapAttrs (fieldName: _: cfg.${groupName}.${fieldName} or null) groupSpec
        ) shikumiTypedGroups;

      mkPackageOption = pkgs: mkOption {
        type = types.package;
        default = pkgs.${packageAttr};
        defaultText = literalExpression "pkgs.${packageAttr}";
        description = "The ${name} package.";
      };

      hmOptions = pkgs: {
        enable = mkEnableOption description;
        package = mkPackageOption pkgs;
      } // typedGroupsOptions // optionalAttrs withMcp {
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
      } // optionalAttrs withUserDaemon {
        daemon = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Run ${binaryName} as a user-level daemon (launchd agent on
              Darwin, systemd user unit on Linux). The daemon is owned
              by the logged-in user — for root-level daemons, see
              services.${name}.daemon (system module).
            '';
          };
          extraArgs = mkOption {
            type = types.listOf types.str;
            default = userDaemonExtraArgs;
            description = "Extra args appended to `${binaryName} ${userDaemonSubcommand}`.";
          };
          environment = mkOption {
            type = types.attrsOf types.str;
            default = userDaemonEnv;
            description = "Environment variables for the user daemon.";
          };
        };
      } // extraHmOptions;

      # Sub-namespace options for anvil MCP and shikumi config.
      # Both nest under services.<name>.* — they share the same parent,
      # so build the inner attrset first, then attach.
      mkServiceInner = pkgs: {} // optionalAttrs withAnvilMcp {
        mcp = {
          enable = mkOption {
            type = types.bool;
            default = anvilDefaultEnable;
            description = ''
              Register ${binaryName} with blackmatter-anvil so AI agents
              (Claude Code, Cursor, OpenCode) can invoke it as an MCP
              server. Emits blackmatter.components.anvil.mcp.servers.${name}.
            '';
          };
          package = mkOption {
            type = types.package;
            default = pkgs.${packageAttr};
            defaultText = literalExpression "pkgs.${packageAttr}";
            description = "Package providing the MCP server binary.";
          };
          scopes = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Anvil scope filter; empty = available everywhere.";
          };
          agents = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Anvil agent filter; empty = every agent.";
          };
        };
      } // optionalAttrs withShikumiConfig {
        settings = mkOption {
          # `lib.types.attrs` instead of `(pkgs.formats.yaml {}).type` —
          # the latter forces `pkgs` evaluation when the module system
          # walks option types to compute `_module.freeformType` of the
          # enclosing HM submodule, and `pkgs` in this scope comes from
          # `_module.args.pkgs` which depends on `config`, which depends
          # on `freeformType` … infinite recursion. The pkgs-derived
          # YAML schema added a small amount of static validation; we
          # trade it for module-system tractability. The downstream
          # validation (`yamlFormat.generate` in the config block,
          # below) still uses pkgs and runs at activation, where pkgs
          # is fully resolved.
          type = lib.types.attrs;
          default = shikumiDefaults;
          description = ''
            shikumi-style YAML settings for ${name}. Written to
            ~/${shikumiConfigPath} on activation. Reachable via
            ${shikumiEnvVar} env var.
          '';
        };
      };

      hmServiceOptions = pkgs:
        let inner = mkServiceInner pkgs;
        in if inner == {} then {} else { services.${name} = inner; };

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
          cfg = lib.attrByPath (hmNamespacePath ++ [ name ]) {} config;
          mcpCfg = config.services.${name}.mcp or null;
          # Merge typed-group field values into the shikumi YAML payload.
          # Authored settings (services.<name>.settings) take priority;
          # typed-group values fill gaps. This means consumers can either
          # set the typed fields or override the whole settings tree.
          authoredShikumi = config.services.${name}.settings or null;
          typedShikumi    = if shikumiTypedGroups == {} then null
                            else typedGroupsValues cfg;
          shikumiCfg =
            if authoredShikumi != null && typedShikumi != null
            then lib.recursiveUpdate typedShikumi authoredShikumi
            else if authoredShikumi != null then authoredShikumi
            else typedShikumi;
          homeDir = config.home.homeDirectory;
          yamlFormat = pkgs.formats.yaml {};
          mergedHmOptions = hmOptions pkgs;
          mergedServiceOptions = hmServiceOptions pkgs;
          hmOptionsTree = lib.setAttrByPath (hmNamespacePath ++ [ name ]) mergedHmOptions;

          # Platform gate: composes with cfg.enable.
          platformOk =
            (!darwinOnly || pkgs.stdenv.hostPlatform.isDarwin)
            && (!linuxOnly || pkgs.stdenv.hostPlatform.isLinux);
        in
        {
          # recursiveUpdate, not //, so when hmNamespace = "services" the
          # inner mcp/settings options merge with the top-level enable/
          # package instead of clobbering them.
          options = lib.recursiveUpdate hmOptionsTree mergedServiceOptions;

          config = mkMerge [
            (mkIf (cfg.enable && platformOk) (mkMerge [
              {
                home.packages = [ cfg.package ]
                  ++ map (n: pkgs.${n}) extraPackages;
              }

              (mkIf (withMcp && (cfg.enableMcpBin or false)) {
                home.file.".local/bin/${name}-mcp" = {
                  executable = true;
                  text = ''
                    #!${pkgs.bash}/bin/bash
                    exec ${cfg.package}/bin/${binaryName} ${mcpSubcommand} "$@"
                  '';
                };
              })

              # Platform branches as TWO mkIfs — never as `if pkgs… then A
              # else B` inside an mkIf body. The latter forces module-system
              # type-walk to evaluate the body to determine its shape (A vs
              # B differ in attr structure), which forces `pkgs` from
              # `_module.args`, which depends on `config`, which depends
              # on `freeformType` of this same submodule. Two mkIfs make
              # the body shape predictable per platform; the platform
              # selector lives in the *condition*, which mkIf is allowed
              # to defer.
              (mkIf (withHttp && (cfg.enableHttpService or false) && pkgs.stdenv.isDarwin)
                (hmHelpers.mkLaunchdService {
                  name = "${name}-http";
                  label = "io.pleme.${name}.http";
                  command = "${cfg.package}/bin/${binaryName}";
                  args = [ httpSubcommand "--addr" cfg.httpAddr ];
                  logDir = "${homeDir}/Library/Logs";
                }))
              (mkIf (withHttp && (cfg.enableHttpService or false) && !pkgs.stdenv.isDarwin)
                (hmHelpers.mkSystemdService {
                  name = "${name}-http";
                  description = "${description} HTTP service";
                  command = "${cfg.package}/bin/${binaryName}";
                  args = [ httpSubcommand "--addr" cfg.httpAddr ];
                }))

              (mkIf (withUserDaemon && (cfg.daemon.enable or false) && pkgs.stdenv.isDarwin)
                (hmHelpers.mkLaunchdService {
                  name = "${name}-daemon";
                  label = "io.pleme.${name}.daemon";
                  command = "${cfg.package}/bin/${binaryName}";
                  args = [ userDaemonSubcommand ] ++ cfg.daemon.extraArgs;
                  env = cfg.daemon.environment;
                  logDir = "${homeDir}/Library/Logs";
                }))
              (mkIf (withUserDaemon && (cfg.daemon.enable or false) && !pkgs.stdenv.isDarwin)
                (hmHelpers.mkSystemdService {
                  name = "${name}-daemon";
                  description = "${description} daemon";
                  command = "${cfg.package}/bin/${binaryName}";
                  args = [ userDaemonSubcommand ] ++ cfg.daemon.extraArgs;
                  env = cfg.daemon.environment;
                }))

              (extraHmConfig cfg)
              (extraHmConfigFn { inherit cfg pkgs lib config; })
            ]))

            # Shikumi YAML — independent of <hmNamespace>.<name>.enable by
            # default so it can be deployed as just-config (apps that
            # consume it via in-cluster pods rather than the local PATH
            # binary). Set shikumiGateOnEnable = true to bind the YAML
            # deploy to cfg.enable.
            (mkIf (withShikumiConfig && shikumiCfg != null
                   && (!shikumiGateOnEnable || (cfg.enable or false))) {
              home.file.${shikumiConfigPath} = {
                source = yamlFormat.generate "${name}.yaml" shikumiCfg;
              };
            })

            # Anvil MCP registration — independent of cfg.enable by
            # default. Set anvilGateOnEnable = true for apps that want
            # the parent enable to gate registration too.
            (mkIf (withAnvilMcp && mcpCfg != null && mcpCfg.enable
                   && (!anvilGateOnEnable || (cfg.enable or false))) (
              hmHelpers.mkAnvilRegistration {
                inherit name;
                command = "${mcpCfg.package}/bin/${binaryName}";
                args = anvilArgs;
                env = anvilEnv // (
                  if withShikumiConfig
                  then { ${shikumiEnvVar} = "${homeDir}/${shikumiConfigPath}"; }
                  else {}
                );
                description = anvilDescription;
                scopes = mcpCfg.scopes;
                agents = mcpCfg.agents;
                package = mcpCfg.package;
              }
            ))
          ];
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
