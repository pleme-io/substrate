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
#   extraNixosConfigFn { cfg, pkgs, lib, config } → config (default: null).
#                     pkgs-aware peer of extraNixosConfig — receives
#                     pkgs/lib/config so a flake can render its shikumi YAML
#                     (or install packages / reference helpers) from the NixOS
#                     module, not just the HM one. Merged after (and alongside)
#                     extraNixosConfig; both run if both are set.
#   extraDarwinConfigFn { cfg, pkgs, lib, config } → config (default: null).
#                     Same as extraNixosConfigFn for the Darwin module.
#
#   extraPackages     list of pkgs.<attr> names to install alongside the
#                     primary package when <hmNamespace>.<name>.enable is
#                     true (default: []). Useful for apps that ship multiple
#                     binaries via separate overlay attrs (e.g. wasm-platform
#                     bundles wasmtime + wasm-tools).
#
#   appBundle         attrset — opt into desktop GUI-app install (default:
#                     null). When set, the HM module exposes
#                     <hmNamespace>.<name>.installApp (mkEnableOption,
#                     default false). On Darwin → a real `.app` (built by
#                     the substrate `mkDarwinAppBundle` builder — NO
#                     duplicated .app/.icns logic) symlinked into
#                     ~/Applications + Launch Services registration. On
#                     Linux → a `.desktop` entry + 256px PNG icon under
#                     ~/.local/share + update-desktop-database. Fields:
#                       appName            display name (default: name)
#                       bundleId           CFBundleIdentifier (required)
#                       iconSvg            path to source SVG (required)
#                       desktopCategories  Linux Categories= (default "Utility;")
#                       terminal           Linux Terminal= (default false)
#                       minSystemVersion   LSMinimumSystemVersion (default "11.0")
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
  irohaCore     = import ./iroha/core.nix                 { inherit lib; };

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
      # An empty daemonSubcommand means the binary serves by default with NO
      # subcommand (e.g. saber-api-server, which reads RUN_MODE / SABER_* from
      # env + clap flags, never a positional). Mirror the anvilArgs filter
      # above (L204-205): a "" subcommand must yield ZERO args, not a single
      # empty-string arg. On NixOS the empty arg is harmless (mkNixOSService
      # shell-splits `concatStringsSep " "` so a trailing "" vanishes), but on
      # Darwin mkLaunchdDaemon sets ProgramArguments = [ command "" ] — a
      # literal empty argv element clap rejects as an unexpected argument. The
      # filter makes both platforms emit a clean argv. (extraArgs still append.)
      systemDaemonBaseArgs = if daemonSubcommand == "" then [] else [ daemonSubcommand ];

      withUserDaemon       = spec.withUserDaemon       or false;
      userDaemonSubcommand = spec.userDaemonSubcommand or daemonSubcommand;
      userDaemonBaseArgs   = if userDaemonSubcommand == "" then [] else [ userDaemonSubcommand ];
      userDaemonExtraArgs  = spec.userDaemonExtraArgs  or [];
      userDaemonEnv        = spec.userDaemonEnv        or {};

      withShikumiConfig = spec.withShikumiConfig or false;
      shikumiDefaults   = spec.shikumiDefaults   or {};
      shikumiConfigPath = spec.shikumiConfigPath or ".config/${name}/${name}.yaml";
      shikumiEnvVar     = spec.shikumiEnvVar     or
                          (lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] name) + "_CONFIG");

      # `extraHmOptions` accepts EITHER a plain attrset OR a function
      # `lib: { ... }`. Function-form lets consumers use raw
      # `lib.mkOption` / `lib.types.*` without having to declare
      # nixpkgs as a flake input — substrate threads `lib` in
      # transparently. Plain-attrset form stays supported for
      # consumers that prefer pure data.
      extraHmOptions     =
        let raw = spec.extraHmOptions or {};
        in if builtins.isFunction raw then raw lib else raw;
      extraSystemOptions = spec.extraSystemOptions or {};
      extraHmConfig      = spec.extraHmConfig      or (_: {});
      extraHmConfigFn    = spec.extraHmConfigFn    or (_: {});
      extraNixosConfig   = spec.extraNixosConfig   or (_: {});
      extraDarwinConfig  = spec.extraDarwinConfig  or (_: {});
      # pkgs-aware peers of extraNixosConfig/extraDarwinConfig — null by
      # default so existing consumers are byte-identical. When set, called
      # as `fn { cfg, pkgs, lib, config }` and merged after the positional
      # extraNixosConfig/extraDarwinConfig result (mirrors extraHmConfigFn).
      extraNixosConfigFn  = spec.extraNixosConfigFn  or null;
      extraDarwinConfigFn = spec.extraDarwinConfigFn or null;

      extraPackages      = spec.extraPackages      or [];

      darwinOnly         = spec.darwinOnly         or false;
      linuxOnly          = spec.linuxOnly          or false;

      # ── GUI app-bundle install (COMPOUNDING) ─────────────────────────
      # When set, the HM module turns the binary into a desktop-installed
      # GUI app: on Darwin a real `.app` bundle (via the substrate
      # `mkDarwinAppBundle` builder — NO duplicated .app/.icns logic) is
      # symlinked into ~/Applications and registered with Launch Services;
      # on Linux a `.desktop` entry + a 256px PNG icon land under
      # ~/.local/share so the app shows up in the application menu.
      #
      # Spec shape (all under `spec.appBundle`):
      #   appName            display name, e.g. "Mado" → Mado.app (default: name)
      #   bundleId           CFBundleIdentifier, e.g. "io.pleme.mado"
      #   iconSvg            path to the source SVG (1024×1024)
      #   desktopCategories  Linux .desktop Categories= value
      #                      (default: "Utility;")
      #   terminal           Linux .desktop Terminal= (default: false — a
      #                      GUI app launches its own window)
      #   minSystemVersion   LSMinimumSystemVersion (default: "11.0")
      #
      # The whole feature is gated on `<hmNamespace>.<name>.installApp`
      # (an mkEnableOption, default false). Independent of `enable`'s
      # PATH-binary install — a consumer can install the app bundle
      # without the bare binary on PATH, or both.
      appBundle          = spec.appBundle          or null;

      shikumiTypedGroups = spec.shikumiTypedGroups or {};

      # ── Typed-group rendering helpers ────────────────────────────────
      # Convert a field spec ({ type = "int"; default = X; description = "..."; })
      # into an mkOption call. Strings name primitive Nix types; raw
      # types.* expressions pass through unchanged.
      #
      # Type alias dictionary (covers ~95% of fleet config field shapes):
      #   primitives:    int | str | bool | float | path
      #   nullable:      nullOrStr | nullOrInt | nullOrBool | nullOrPath
      #   collections:   listOfStr | listOfInt | listOfBool | listOfPath
      #                  attrsOfStr | attrsOfInt | attrsOfBool | attrs
      #   constrained:   intRange (with field.min / field.max)
      #   anything else: pass field.type as a raw types.* expression.
      resolveFieldType = field:
        if field ? type then
          if builtins.isString field.type then
            if      field.type == "int"          then types.int
            else if field.type == "str"          then types.str
            else if field.type == "bool"         then types.bool
            else if field.type == "float"        then types.float
            else if field.type == "path"         then types.path
            else if field.type == "nullOrStr"    then types.nullOr types.str
            else if field.type == "nullOrInt"    then types.nullOr types.int
            else if field.type == "nullOrBool"   then types.nullOr types.bool
            else if field.type == "nullOrPath"   then types.nullOr types.path
            else if field.type == "nullOrFloat"  then types.nullOr types.float
            else if field.type == "listOfStr"    then types.listOf types.str
            else if field.type == "listOfInt"    then types.listOf types.int
            else if field.type == "listOfBool"   then types.listOf types.bool
            else if field.type == "listOfPath"   then types.listOf types.path
            else if field.type == "attrsOfStr"   then types.attrsOf types.str
            else if field.type == "attrsOfInt"   then types.attrsOf types.int
            else if field.type == "attrsOfBool"  then types.attrsOf types.bool
            else if field.type == "attrs"        then types.attrs
            else if field.type == "intRange"     then
              types.ints.between (field.min or 0) (field.max or 65535)
            else if field.type == "enum"         then
              # `field.values = [ "a" "b" ... ]` for enum-of-strings.
              types.enum (field.values or (throw "module-trio: enum needs `values`."))
            else throw "module-trio: unknown shikumiTypedGroup field type '${field.type}' — see the type-alias dictionary in module-trio.nix's resolveFieldType, or pass field.type as a raw types.* expression."
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
      } // optionalAttrs (appBundle != null) {
        installApp = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Install ${name} as a desktop GUI application — a real
            `.app` bundle in ~/Applications on macOS (Spotlight /
            Launchpad / Dock discoverable), or a `.desktop` entry +
            icon under ~/.local/share on Linux (application menu).
            Independent of `enable` (the bare PATH binary).
          '';
        };
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

          # ── GUI app-bundle install (reuses mkDarwinAppBundle) ─────────
          # Resolved app-bundle config (null when the consumer didn't
          # opt in). appName defaults to the spec name; bundleId is
          # required when appBundle is set.
          appCfg =
            if appBundle == null then null
            else {
              appName          = appBundle.appName          or name;
              bundleId         = appBundle.bundleId
                or (throw "module-trio: appBundle for ${name} needs `bundleId`.");
              iconSvg          = appBundle.iconSvg
                or (throw "module-trio: appBundle for ${name} needs `iconSvg`.");
              desktopCategories = appBundle.desktopCategories or "Utility;";
              terminal         = appBundle.terminal         or false;
              minSystemVersion = appBundle.minSystemVersion or "11.0";
            };

          # Darwin .app — built once, reusing the substrate builder.
          # `import`ed at activation-time pkgs so it's the right arch.
          darwinAppBundle =
            if appCfg == null then null
            else (import ./build/darwin/app-bundle.nix).mkDarwinAppBundle {
              inherit pkgs;
              name             = appCfg.appName;
              exe              = cfg.package;
              exeName          = binaryName;
              iconSvg          = appCfg.iconSvg;
              bundleId         = appCfg.bundleId;
              version          = cfg.package.version or "0.1.0";
              minSystemVersion = appCfg.minSystemVersion;
            };

          # Linux 256px PNG icon rendered from the SVG (resvg, pure).
          linuxAppIcon =
            if appCfg == null then null
            else pkgs.runCommandLocal "${name}-icon-256.png" {
              nativeBuildInputs = [ pkgs.resvg ];
            } ''
              resvg -w 256 -h 256 ${appCfg.iconSvg} "$out"
            '';

          # Linux .desktop entry — rendered by the typed generator
          # (lib.generators.toINI / makeDesktopItem) rather than a hand
          # string. makeDesktopItem is the canonical typed surface.
          linuxDesktopItem =
            if appCfg == null then null
            else pkgs.makeDesktopItem {
              name        = name;
              desktopName = appCfg.appName;
              exec        = "${cfg.package}/bin/${binaryName}";
              icon        = name;
              comment     = description;
              categories  = lib.splitString ";"
                (lib.removeSuffix ";" appCfg.desktopCategories);
              terminal    = appCfg.terminal;
            };
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
                  args = userDaemonBaseArgs ++ cfg.daemon.extraArgs;
                  env = cfg.daemon.environment;
                  logDir = "${homeDir}/Library/Logs";
                }))
              (mkIf (withUserDaemon && (cfg.daemon.enable or false) && !pkgs.stdenv.isDarwin)
                (hmHelpers.mkSystemdService {
                  name = "${name}-daemon";
                  description = "${description} daemon";
                  command = "${cfg.package}/bin/${binaryName}";
                  args = userDaemonBaseArgs ++ cfg.daemon.extraArgs;
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
                # pruneNulls: an unset nullOr option must be ABSENT from
                # the rendered YAML, never `null`. Shikumi config
                # extraction (figment + serde) is ATOMIC — serde(default)
                # fills only MISSING fields, and one explicit `null` on a
                # non-Option field fails the ENTIRE extraction; the app
                # then silently falls back to full prescribed defaults
                # with only a warn log (proven live: tobira ran on
                # default config for weeks because unset nullOr color
                # options rendered as `accent_color: null`). pruneNulls
                # also descends into lists (attrsets inside lists), which
                # lib.filterAttrsRecursive alone would miss.
                source = yamlFormat.generate "${name}.yaml"
                  (irohaCore.pruneNulls shikumiCfg);
              };
            })

            # ── GUI app-bundle install ───────────────────────────────
            # Two platform-split mkIfs (same module-system-tractability
            # rule as the http/daemon services above). Gated on
            # <hmNamespace>.<name>.installApp; independent of `enable`.
            #
            # Darwin: symlink the built `.app` into ~/Applications and
            # nudge Launch Services so Spotlight/Dock pick it up.
            (mkIf (appCfg != null && (cfg.installApp or false)
                   && pkgs.stdenv.hostPlatform.isDarwin) {
              home.file."Applications/${appCfg.appName}.app".source =
                "${darwinAppBundle}/${appCfg.appName}.app";
              home.activation."register-${name}-app" =
                lib.hm.dag.entryAfter [ "linkGeneration" ] ''
                  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
                    -f "$HOME/Applications/${appCfg.appName}.app" 2>/dev/null || true
                '';
            })

            # Linux: .desktop entry + 256px icon under ~/.local/share,
            # plus an update-desktop-database nudge so menus refresh.
            (mkIf (appCfg != null && (cfg.installApp or false)
                   && pkgs.stdenv.hostPlatform.isLinux) {
              home.file.".local/share/applications/${name}.desktop".source =
                "${linuxDesktopItem}/share/applications/${name}.desktop";
              home.file.".local/share/icons/hicolor/256x256/apps/${name}.png".source =
                linuxAppIcon;
              home.activation."register-${name}-desktop" =
                lib.hm.dag.entryAfter [ "linkGeneration" ] ''
                  ${pkgs.desktop-file-utils}/bin/update-desktop-database \
                    "$HOME/.local/share/applications" 2>/dev/null || true
                '';
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
              args = systemDaemonBaseArgs ++ cfg.daemon.extraArgs;
              environment = cfg.daemon.environment;
            }))

            (extraNixosConfig cfg)
            (lib.optionalAttrs (extraNixosConfigFn != null)
              (extraNixosConfigFn { inherit cfg pkgs lib config; }))
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
              args = systemDaemonBaseArgs ++ cfg.daemon.extraArgs;
              env = cfg.daemon.environment;
            }))

            (extraDarwinConfig cfg)
            (lib.optionalAttrs (extraDarwinConfigFn != null)
              (extraDarwinConfigFn { inherit cfg pkgs lib config; }))
          ]);
        };
    };
}
