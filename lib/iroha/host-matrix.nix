# iroha.host-matrix — L4 composition: the typed node registry.
#
# One nodeSpec declaration per host emits EVERY projection a fleet needs
# from its node set: nixosConfigurations + darwinConfigurations (through
# INJECTED universe functions), deploy-rs typed node data, a colmena hive,
# tag projections, a pure-data registry, and a throw-free invariants
# suite. This dissolves the dual HM-module-list drift (nix repo
# lib/nodes.nix vs darwinConfigurations/default.nix): HM wiring, manifest
# system modules, and the hostname all derive from ONE declaration —
# adding a node is one attrset, never three parallel edits.
#
# Exports (pure { lib }, zero pkgs; the universe functions are injected
# DATA — this file never imports nixpkgs / nix-darwin / deploy-rs):
#
#   mkHostMatrix :: {
#     universes (REQUIRED) :: {
#       nixosSystem  ? null   — a lib.nixosSystem-like function;
#       darwinSystem ? null   — a nix-darwin lib.darwinSystem-like function;
#     }                       — a node whose class needs a null universe fn
#                               is a typed throw NAMING THE NODE (lazy: on
#                               forcing that node's configuration value);
#     manifest  ? null        — a manifest.mkManifest result. When given,
#                               every node's system modules gain
#                               manifest.nixosModules / .darwinModules (by
#                               class) and the HM wiring module gains
#                               manifest.hmModulesFor <platform> (class
#                               nixos -> "linux", darwin -> "darwin");
#     base      ? { }         — { nixos ? [ ], darwin ? [ ] }: modules baked
#                               into every node of the class;
#     hmWiring  ? null        — null | { sharedModulesExtra ? [ ],
#                               viaOption ? true }. The HM wiring module is
#                               emitted iff manifest != null OR hmWiring !=
#                               null, and sets home-manager.sharedModules =
#                               (manifest.hmModulesFor <platform>, when
#                               manifest given) ++ sharedModulesExtra.
#                               viaOption = true (default): the list is
#                               role-banded (core.at "role") — one coherent
#                               fleet layer a node-band definition REPLACES
#                               wholesale. viaOption = false: plain
#                               definition priority — node definitions
#                               CONCATENATE with the fleet wiring instead.
#                               Non-null non-attrset is a typed throw at
#                               construction time (WHNF-forced);
#     specialArgs ? { }       — passed through to each universe call;
#     nodes (REQUIRED) :: attrsOf nodeSpec;
#   } -> matrix
#
# nodeSpec = {
#   class      (REQUIRED)     — "nixos" | "darwin"; missing or anything
#                               else is a typed throw (lazy, on field
#                               force — partitioning forces it);
#   system     (REQUIRED)     — str, e.g. "x86_64-linux"/"aarch64-darwin";
#                               missing is a typed throw (lazy);
#   hostname   ? <node name>;
#   sshUser    ? null;
#   tags       ? [ ];
#   profiles   ? [ ]          — listOf module (profile.mkProfile results);
#   modules    ? [ ]          — node-specific modules;
#   users      ? { }          — attrsOf (listOf module): per-user HM
#                               imports, emitted as
#                               home-manager.users.<u>.imports via the
#                               users module;
#   deploy     ? null         — null | { method ? "deploy-rs" ("deploy-rs"
#                               | "colmena" — typed throw otherwise, lazy),
#                               profile ? "system" };
# }
#
# Per-node module list (ONE order, shared verbatim by the universe call
# and the colmena entry — drift between them is unrepresentable):
#     base.<class>
#  ++ manifest system modules     (iff manifest given)
#  ++ node.profiles
#  ++ node.modules
#  ++ [ hm-wiring module ]        (iff manifest or hmWiring given;
#                                  _file "<iroha:host-matrix:hm-wiring:<platform>>")
#  ++ [ users module ]            (iff node.users != { };
#                                  _file "<iroha:host-matrix:users>")
#  ++ [ hostname module ]         (always;
#                                  _file "<iroha:host-matrix:hostname>")
# Emitted modules carry _file markers so tooling (and tests) can locate
# them structurally instead of positionally.
#
# matrix = {
#   nixosConfigurations  :: attrsOf <nixosSystem result>   — class nixos;
#   darwinConfigurations :: attrsOf <darwinSystem result>  — class darwin;
#       each = <universeFn> { system; specialArgs; modules = <list above> };
#
#   deployRs :: { nodes :: attrsOf { hostname, sshUser, configName,
#                                    profile } }
#       nodes with deploy.method == "deploy-rs". SHAPE ONLY — typed data,
#       never a faked store path: realizing
#       profiles.system.path needs the deploy-rs lib at the consumer
#       (deploy-rs.lib.<system>.activate.nixos
#        self.nixosConfigurations.<configName>);
#
#   colmena :: attrsOf { deployment = { targetHost, targetUser, tags };
#                        imports = <same module list>; }
#       nodes with deploy.method == "colmena". meta (meta.nixpkgs etc.) is
#       consumer-side — the hive entry is pure node data;
#
#   byTag :: tag -> sorted [nodeName]   (attrNames order — stable+sorted);
#
#   registry :: attrsOf { class, system, hostname, tags, deploy }
#       the NEVER-THROWING data view: class/system pass through raw (null
#       when missing, invalid values verbatim) so audits report instead of
#       abort;
#
#   invariants :: attrsOf { expr, expected }   (throw-free; feed to
#       checks.mkEvalChecks):
#         node-classes-valid          — every class ∈ {nixos, darwin};
#         node-system-matches-class   — nixos => "-linux" suffix,
#                                       darwin => "-darwin" suffix;
#         node-hostnames-non-empty;
#         deploy-nodes-have-target    — deploy nodes have sshUser or a
#                                       non-empty hostname;
# }
#
# DECISIONS (documented, load-bearing):
#   * The hostname module is emitted for BOTH classes — nix-darwin
#     declares networking.hostName too, so one shape serves both; it is
#     role-banded (core.at "role"), so any node-level plain definition
#     wins by band arithmetic.
#   * deployRs emits typed data ({ hostname, sshUser, configName,
#     profile }), not deploy-rs profile paths — path realization
#     inherently needs the deploy-rs lib + the realized configuration at
#     the consumer; faking it here would be an untyped lie.
#
# Throws:
#   iroha.host-matrix.mkHostMatrix: `hmWiring` must be null or an attrset …
#   iroha.host-matrix.mkHostMatrix: node '<n>' is missing required `class` …
#   iroha.host-matrix.mkHostMatrix: node '<n>' has unknown class '<c>' …
#   iroha.host-matrix.mkHostMatrix: node '<n>' is missing required `system` …
#   iroha.host-matrix.mkHostMatrix: node '<n>' has unknown deploy.method '<m>' …
#   iroha.host-matrix.mkHostMatrix: node '<n>' has class "<c>" but universes.<fn> is null …
{ lib }:
let
  core = import ./core.nix { inherit lib; };

  classNames = [
    "nixos"
    "darwin"
  ];

  classMeta = {
    nixos = {
      platform = "linux";
      systemSuffix = "-linux";
      universeFn = "nixosSystem";
      manifestKey = "nixosModules";
    };
    darwin = {
      platform = "darwin";
      systemSuffix = "-darwin";
      universeFn = "darwinSystem";
      manifestKey = "darwinModules";
    };
  };

  deployMethods = [
    "deploy-rs"
    "colmena"
  ];

  deployDefaults = {
    method = "deploy-rs";
    profile = "system";
  };

  nodeDefaults = {
    sshUser = null;
    tags = [ ];
    profiles = [ ];
    modules = [ ];
    users = { };
  };

  hmWiringDefaults = {
    sharedModulesExtra = [ ];
    viaOption = true;
  };

  mkHostMatrix =
    {
      universes,
      manifest ? null,
      base ? { },
      hmWiring ? null,
      specialArgs ? { },
      nodes,
    }:
    let
      universes' = {
        nixosSystem = universes.nixosSystem or null;
        darwinSystem = universes.darwinSystem or null;
      };

      base' = {
        nixos = base.nixos or [ ];
        darwin = base.darwin or [ ];
      };

      hmWiring' =
        if hmWiring == null then
          null
        else if builtins.isAttrs hmWiring then
          hmWiringDefaults // hmWiring
        else
          throw "iroha.host-matrix.mkHostMatrix: `hmWiring` must be null or an attrset { sharedModulesExtra ? [ ], viaOption ? true }, got ${builtins.typeOf hmWiring}.";

      wantHmWiring = manifest != null || hmWiring' != null;

      # Defaults-only resolution — never throws. registry / byTag /
      # invariants (everything that must REPORT rather than abort) read
      # this view.
      resolveBase =
        name: spec:
        nodeDefaults
        // spec
        // {
          inherit name;
          class = spec.class or null;
          system = spec.system or null;
          hostname = spec.hostname or name;
          deploy = if (spec.deploy or null) == null then null else deployDefaults // spec.deploy;
        };

      # Public resolution — class/system/deploy validity enforced by typed
      # throws. Lazy: forcing the offending FIELD surfaces the throw.
      resolveNode =
        name: spec:
        resolveBase name spec
        // {
          class =
            if !(spec ? class) then
              throw "iroha.host-matrix.mkHostMatrix: node '${name}' is missing required `class` — expected \"nixos\" or \"darwin\"."
            else if !(builtins.elem spec.class classNames) then
              throw "iroha.host-matrix.mkHostMatrix: node '${name}' has unknown class '${toString spec.class}' — expected \"nixos\" or \"darwin\"."
            else
              spec.class;
          system =
            spec.system
              or (throw "iroha.host-matrix.mkHostMatrix: node '${name}' is missing required `system` (e.g. \"x86_64-linux\", \"aarch64-darwin\").");
          deploy =
            if (spec.deploy or null) == null then
              null
            else
              let
                d = deployDefaults // spec.deploy;
              in
              if !(builtins.elem d.method deployMethods) then
                throw "iroha.host-matrix.mkHostMatrix: node '${name}' has unknown deploy.method '${toString d.method}' — expected \"deploy-rs\" or \"colmena\"."
              else
                d;
        };

      rawResolved = lib.mapAttrs resolveBase nodes;
      resolved = lib.mapAttrs resolveNode nodes;

      hmWiringModuleFor =
        platform:
        let
          w = if hmWiring' == null then hmWiringDefaults else hmWiring';
          mods = (if manifest == null then [ ] else manifest.hmModulesFor platform) ++ w.sharedModulesExtra;
        in
        {
          _file = "<iroha:host-matrix:hm-wiring:${platform}>";
          config.home-manager.sharedModules = if w.viaOption then core.at "role" mods else mods;
        };

      usersModule = users: {
        _file = "<iroha:host-matrix:users>";
        config.home-manager.users = lib.mapAttrs (_: mods: { imports = mods; }) users;
      };

      hostnameModule = hostname: {
        _file = "<iroha:host-matrix:hostname>";
        config.networking.hostName = core.at "role" hostname;
      };

      # ONE module-list builder — the universe call and the colmena entry
      # share it verbatim, so they cannot drift.
      moduleListFor =
        node:
        let
          meta = classMeta.${node.class};
        in
        base'.${node.class}
        ++ (if manifest == null then [ ] else manifest.${meta.manifestKey})
        ++ node.profiles
        ++ node.modules
        ++ lib.optional wantHmWiring (hmWiringModuleFor meta.platform)
        ++ lib.optional (node.users != { }) (usersModule node.users)
        ++ [ (hostnameModule node.hostname) ];

      configurationsFor =
        class:
        lib.mapAttrs (
          name: node:
          let
            fnName = classMeta.${class}.universeFn;
            fn = universes'.${fnName};
          in
          if fn == null then
            throw "iroha.host-matrix.mkHostMatrix: node '${name}' has class \"${class}\" but universes.${fnName} is null — inject your ${fnName}-equivalent function (universes are injected data, never imported)."
          else
            fn {
              inherit (node) system;
              inherit specialArgs;
              modules = moduleListFor node;
            }
        ) (lib.filterAttrs (_: n: n.class == class) resolved);

      deployRs = {
        nodes = lib.mapAttrs (name: n: {
          inherit (n) hostname sshUser;
          configName = name;
          profile = n.deploy.profile;
        }) (lib.filterAttrs (_: n: n.deploy != null && n.deploy.method == "deploy-rs") resolved);
      };

      colmena = lib.mapAttrs (name: n: {
        deployment = {
          targetHost = n.hostname;
          targetUser = n.sshUser;
          inherit (n) tags;
        };
        imports = moduleListFor n;
      }) (lib.filterAttrs (_: n: n.deploy != null && n.deploy.method == "colmena") resolved);

      # attrNames is sorted by construction — stable + sorted membership.
      byTag = t: builtins.attrNames (lib.filterAttrs (_: n: builtins.elem t n.tags) rawResolved);

      registry = lib.mapAttrs (_: n: {
        inherit (n)
          class
          system
          hostname
          tags
          deploy
          ;
      }) rawResolved;

      invariants = {
        node-classes-valid = {
          expr = builtins.attrNames (lib.filterAttrs (_: n: !(builtins.elem n.class classNames)) rawResolved);
          expected = [ ];
        };
        node-system-matches-class = {
          expr = builtins.attrNames (
            lib.filterAttrs (
              _: n:
              builtins.elem n.class classNames
              && !(builtins.isString n.system && lib.hasSuffix classMeta.${n.class}.systemSuffix n.system)
            ) rawResolved
          );
          expected = [ ];
        };
        node-hostnames-non-empty = {
          expr = builtins.attrNames (lib.filterAttrs (_: n: n.hostname == "") rawResolved);
          expected = [ ];
        };
        deploy-nodes-have-target = {
          expr = builtins.attrNames (
            lib.filterAttrs (_: n: n.deploy != null && n.hostname == "" && n.sshUser == null) rawResolved
          );
          expected = [ ];
        };
      };
    in
    # hmWiring is matrix-level (not per-node): force its typed validation
    # at WHNF so a bad value throws at construction time, not at first
    # module-list read.
    builtins.seq hmWiring' {
      nixosConfigurations = configurationsFor "nixos";
      darwinConfigurations = configurationsFor "darwin";
      inherit
        deployRs
        colmena
        byTag
        registry
        invariants
        ;
    };
in
{
  inherit mkHostMatrix;
}
