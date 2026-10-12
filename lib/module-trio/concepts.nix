{ lib }:
let
  support = import ./support.nix { inherit lib; };
  packageModule = import ../iroha/package-module.nix { inherit lib; };

  inherit (support) arms classOf renders refuses;

  allPlatforms = [
    "darwin"
    "linux"
  ];

  assemble =
    {
      where,
      kind,
      name,
      path,
      sup,
      rendering,
      refusing,
      schema,
    }:
    let
      armModule =
        arm:
        if sup.${arm}.verdict == "renders" then
          rendering arm
        else
          {
            _class = classOf.${arm};
            imports = [
              (refusing arm)
              (support.refusalModule {
                enablePath = path ++ [ "enable" ];
                inherit path arm;
                verdict = sup.${arm};
              })
            ];
          };
      modules = lib.genAttrs arms armModule;
    in
    {
      nixosModule = modules.nixos;
      darwinModule = modules.darwin;
      homeManagerModule = modules.homeManager;
      module = support.dispatch { inherit where modules schema; };
      concept = {
        inherit
          name
          kind
          path
          ;
        paths = lib.genAttrs arms (_: path);
        support = sup;
      };
    };

  hostPlatformModule =
    {
      enablePath,
      platforms,
      path,
    }:
    { config, lib, pkgs, ... }:
    let
      host = if pkgs.stdenv.hostPlatform.isDarwin then "darwin" else "linux";
    in
    {
      assertions = [
        {
          assertion = !(lib.attrByPath enablePath false config) || builtins.elem host platforms;
          message = support.messageFor {
            inherit path;
            arm = "homeManager";
            verdict = refuses "unbuildable" "this home-manager host is ${host}; the package builds for ${lib.concatStringsSep ", " platforms}";
          };
        }
      ];
    };

  mkPackaged =
    kind: spec: daemon: defaults:
    let
      name = spec.name or (throw "module-trio: a ${kind} concept needs `name`.");
      description = spec.description or (throw "module-trio: ${kind} concept ${name} needs `description`.");
      namespace = spec.namespace or "pleme";
      platforms = spec.platforms or allPlatforms;
      where = "module-trio: ${kind} ${namespace}.${name}";
      pm = packageModule.mkPackageModule (
        {
          inherit name description namespace;
          packageAttr = spec.packageAttr or name;
          binaryName = spec.binaryName or name;
          extraPackages = spec.extraPackages or [ ];
          surface = spec.surface or { };
          inherit daemon;
        }
        // lib.optionalAttrs (spec ? file) { inherit (spec) file; }
      );
      path = pm.surface.optionPath;
      sup = support.normalize {
        inherit where;
        defaults = defaults platforms;
        given = spec.support or { };
      };
      armOf = {
        nixos = pm.nixos;
        darwin = pm.darwin;
        homeManager = pm.homeManager;
      };
      restricted = !(builtins.all (p: builtins.elem p platforms) allPlatforms);
    in
    assemble {
      inherit
        where
        kind
        name
        path
        sup
        ;
      rendering =
        arm:
        if arm == "homeManager" && restricted then
          {
            _class = classOf.homeManager;
            imports = [
              armOf.homeManager
              (hostPlatformModule {
                enablePath = pm.surface.enablePath;
                inherit platforms path;
              })
            ];
          }
        else
          armOf.${arm};
      refusing = _: pm.surface.module;
      schema = pm.surface.module;
    }
    // {
      inherit (pm) surface;
    };

  platformDefaults = platforms: {
    nixos =
      if builtins.elem "linux" platforms then
        renders
      else
        refuses "unbuildable" "the package builds for ${lib.concatStringsSep ", " platforms}, not linux";
    darwin =
      if builtins.elem "darwin" platforms then
        renders
      else
        refuses "unbuildable" "the package builds for ${lib.concatStringsSep ", " platforms}, not darwin";
    homeManager = renders;
  };

  mkPackage =
    spec:
    mkPackaged "package" spec null platformDefaults;

  mkService =
    spec:
    let
      scope = spec.scope or "system";
      validScope =
        if builtins.elem scope [
          "system"
          "user"
        ] then
          scope
        else
          throw "module-trio: service ${spec.name or "?"} has scope '${toString scope}'; a service is system or user scoped.";
      daemon = {
        scope = validScope;
        subcommand = spec.subcommand or null;
        args = spec.args or [ ];
        env = spec.env or { };
        keepAlive = spec.keepAlive or true;
      };
      defaults =
        platforms:
        let
          byPlatform = platformDefaults platforms;
        in
        if validScope == "system" then
          byPlatform
          // {
            homeManager = refuses "scope" "a system-scope service runs as root under systemd or launchd; home-manager is a user scope";
          }
        else
          {
            nixos = refuses "scope" "a user-scope service runs in the user's session; enable it through home-manager";
            darwin = refuses "scope" "a user-scope service runs in the user's session; enable it through home-manager";
            homeManager = byPlatform.homeManager;
          };
    in
    mkPackaged "service" spec daemon defaults;

  projectionLeaf = x: builtins.isAttrs x && x ? type && x ? value;

  mkRegistry =
    spec:
    let
      name = spec.name or (throw "module-trio: a registry concept needs `name`.");
      description = spec.description or (throw "module-trio: registry concept ${name} needs `description`.");
      namespace = spec.namespace or "pleme";
      path = lib.splitString "." namespace ++ [ name ];
      dotted = lib.concatStringsSep "." path;
      where = "module-trio: registry ${dotted}";
      entries =
        spec.entries
          or (throw "${where}: a registry declares `entries` = { type; default; readOnly ? true; option ? \"registry\"; description; }.");
      entriesOption = entries.option or "registry";
      entriesReadOnly = entries.readOnly or true;
      selector = spec.selector or null;
      settings = spec.settings or (_: { });
      projections = spec.projections or (_: { });
      render = spec.render or { };
      enableSpec = spec.enable or { };
      unknownRenders = builtins.filter (k: !(builtins.elem k arms)) (builtins.attrNames render);

      defaults = lib.genAttrs arms (
        arm:
        if render ? ${arm} then
          renders
        else
          throw "${where}: the ${arm} arm has neither a renderer (render.${arm}) nor a refusal (support.${arm} = refuses <reason> <detail>)."
      );
      sup =
        let
          s = support.normalize {
            inherit where defaults;
            given = spec.support or { };
          };
          contradictions = builtins.filter (
            arm:
            (s.${arm}.verdict == "renders" && !(render ? ${arm}))
            || (s.${arm}.verdict == "refuses" && render ? ${arm})
          ) arms;
        in
        if unknownRenders != [ ] then
          throw "${where}: render names unknown arm(s) ${lib.concatStringsSep ", " unknownRenders}."
        else if contradictions != [ ] then
          throw "${where}: support and render disagree on ${lib.concatStringsSep ", " contradictions}: an arm that renders has a renderer, an arm that refuses has none."
        else
          s;

      withCfg = args: args // { cfg = lib.getAttrFromPath path args.config; };

      selectorType =
        args:
        let
          over = selector.over or "entries";
          values =
            if over == "entries" then
              (if entriesReadOnly then builtins.attrNames entries.default else builtins.attrNames (withCfg args).cfg.${entriesOption})
            else if builtins.isList over then
              over
            else
              throw "${where}: selector.over is \"entries\" or a list of values.";
          one = lib.types.enum values;
        in
        if selector.multiple or false then lib.types.listOf one else one;

      enableDefault =
        args:
        let
          d = enableSpec.default or false;
        in
        if builtins.isFunction d then d (withCfg args) else d;

      coreOptions =
        args:
        {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = enableDefault args;
            description = enableSpec.description or "Render the ${dotted} concept on this platform.";
          };
          ${entriesOption} = lib.mkOption (
            {
              type = lib.types.attrsOf entries.type;
              default = entries.default;
              readOnly = entriesReadOnly;
            }
            // lib.optionalAttrs (entries ? description) { inherit (entries) description; }
          );
        }
        // lib.optionalAttrs (selector != null) {
          ${selector.option or "selected"} = lib.mkOption (
            {
              type = selectorType args;
            }
            // lib.optionalAttrs (selector ? default) { inherit (selector) default; }
            // lib.optionalAttrs (selector ? description) { inherit (selector) description; }
          );
        };

      projectionOptions =
        args:
        lib.mapAttrsRecursiveCond (x: !(projectionLeaf x)) (
          _: leaf:
          lib.mkOption (
            {
              inherit (leaf) type;
              readOnly = true;
              default = leaf.value;
            }
            // lib.optionalAttrs (leaf ? description) { inherit (leaf) description; }
          )
        ) (projections (withCfg args));

      schemaModule =
        {
          config,
          lib,
          pkgs,
          ...
        }@args:
        {
          key = "module-trio:${dotted}:schema";
          imports = [
            { options = lib.setAttrByPath path (coreOptions args); }
            { options = lib.setAttrByPath path (settings (withCfg args)); }
            { options = lib.setAttrByPath path (projectionOptions args); }
          ];
        };
    in
    assemble {
      inherit
        where
        name
        path
        sup
        ;
      kind = "registry";
      rendering = arm: {
        _class = classOf.${arm};
        imports = [
          schemaModule
          render.${arm}
        ];
      };
      refusing = _: schemaModule;
      schema = schemaModule;
    }
    // {
      inherit schemaModule;
    };
in
{
  inherit
    mkPackage
    mkService
    mkRegistry
    assemble
    ;
}
