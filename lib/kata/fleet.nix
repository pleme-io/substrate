# kata.fleet — mkFleet: ONE call turns a validated fleet config (THE
# BLANKS, see fleet-config.nix) into the complete private-repo output
# surface: domains helpers, users module, app manifest, host matrix
# (nixos/darwin configurations + deploy data), and an aggregated
# invariants suite. The private fleet repo supplies config + node
# hardware + secrets; every behavior comes from the vocabulary below
# (kata letters -> iroha letters -> nixpkgs module system).
#
# Exports (pure { lib }):
#
#   mkFleet :: {
#     config :: attrs            — the kata.fleet blanks (validated here
#                                  via fleet-config.validateFleet; schema
#                                  violations are typed eval errors);
#     inputs ? { }               — flake inputs (feeds iroha.mkManifest
#                                  when config.apps is non-empty);
#     universes ? { }            — { nixosSystem ?, darwinSystem ? }
#                                  (iroha.mkHostMatrix contract: injected,
#                                  never imported);
#     profiles ? { }             — attrsOf module: the consumer's profile
#                                  TABLE. Node profile NAMES resolve here;
#                                  an unknown name is a typed throw naming
#                                  node + profile + the known table;
#     hmModules ? { }            — attrsOf module: per-user HM module
#                                  table (node users lists resolve here);
#     base ? { nixos ? [ ]; darwin ? [ ]; }
#                                — modules baked into every node;
#     shell ? null               — fleet shell drv for interactive users;
#     usersModulePlacement ? "base"
#                                — where kata.mkUsers' NixOS module lands:
#                                  "base" (default) bakes users.module into
#                                  base.nixos on every nixos node;
#                                  "external" leaves account materialization
#                                  to the consumer's profiles (a fleet whose
#                                  profiles already declare the canonical
#                                  accounts would double-define shell/groups
#                                  otherwise — config decides, never a hidden
#                                  hard-code). users.module stays exported and
#                                  the users invariants run either way.
#                                  Unknown value is a typed throw;
#     extraInvariants ? { }      — consumer suites merged into invariants;
#   } -> {
#     config       — the VALIDATED blanks (defaults applied);
#     domains      — kata.mkDomains result;
#     sshAliases   — kata.mkSshAliases over the fleet domains (full set);
#     sshAliasesFor — node -> kata.mkSshAliases skipping that node (self);
#     wireguard    — kata.mkWireguardLinks over config.vpnLinks, or null
#                    when no vpnLinks blank is set;
#     report       — pure-data fleet summary composed from every letter:
#                    { name, hostCount, nodes.<n> = { class, system, tags,
#                      status, statusReason, fqdn, allFqdns, sshUser,
#                      deploys, profiles, wireguardLinks } } — one query
#                    over the whole fleet. `deploys` is the EFFECTIVE
#                    deployability (a "down" node reports false even
#                    though its deploy block is still declared);
#     users        — kata.mkUsers result (keys threaded from trust.*);
#     manifest     — iroha.mkManifest result | null (when apps == { });
#     hostMatrix   — iroha.mkHostMatrix result (nodes projected: profile
#                    names resolved, sshUser defaulted from domains,
#                    a "down" node's deploy block NULLED — a retired host
#                    leaves deployRs + colmena by construction,
#                    users module names resolved via hmModules,
#                    users.module (at placement "base") + caches module
#                    baked into base);
#     nixosConfigurations / darwinConfigurations — re-exported from
#                    hostMatrix (the flake outputs);
#     deployRs / colmena / byTag / registry — re-exported;
#     invariants   — aggregated suite (domains + users + manifest +
#                    hostMatrix + cross-checks: every node with a deploy
#                    block appears in domains.locations; every node
#                    profile name resolved; no "down" node reaches a
#                    deploy projection) ++ extraInvariants;
#     checksFor    — pkgs -> { "kata-fleet-<name>" = drv; } (the
#                    aggregate invariants as a buildable check);
#   }
{ lib }:
let
  domainsLib = import ./domains.nix { inherit lib; };
  sshAliasesLib = import ./ssh-aliases.nix { inherit lib; };
  wireguardLib = import ./wireguard.nix { inherit lib; };
  usersLib = import ./users.nix { inherit lib; };
  fleetConfig = import ./fleet-config.nix { inherit lib; };
  iroha = import ../iroha { inherit lib; };

  mkFleet =
    {
      config,
      inputs ? { },
      universes ? { },
      profiles ? { },
      hmModules ? { },
      base ? { },
      shell ? null,
      usersModulePlacement ? "base",
      extraInvariants ? { },
    }:
    let
      usersModulePlacements = [
        "base"
        "external"
      ];

      _placementGuard =
        if !(builtins.elem usersModulePlacement usersModulePlacements) then
          throw "kata.fleet.mkFleet: unknown usersModulePlacement '${toString usersModulePlacement}' — expected ${lib.concatStringsSep " or " (map (p: "\"${p}\"") usersModulePlacements)}."
        else
          true;

      cfg = fleetConfig.validateFleet config;

      domains = domainsLib.mkDomains cfg.domains;

      # ── Composed letters: the fleet primitive STANDS ON the lib letters ──
      # ssh-aliases derives from the fleet domains; wireguard derives from
      # the vpnLinks registry blank. A fleet repo gets both for free from
      # one mkFleet call — no separate letter wiring.
      sshAliases = sshAliasesLib.mkSshAliases { fleet = domains; };
      sshAliasesFor = node: sshAliasesLib.mkSshAliases {
        fleet = domains;
        skipHosts = [ node ];
      };
      wireguard =
        if cfg.vpnLinks == { } then null else wireguardLib.mkWireguardLinks { registry = cfg.vpnLinks; };

      users = usersLib.mkUsers (
        cfg.users
        // {
          # Thread fleet trust into every user lacking explicit keys.
          users = lib.mapAttrs (
            _: u:
            u
            // lib.optionalAttrs (!(u ? keys)) {
              keys = if (u.kind or "") == "automation" then cfg.trust.automationKeys else cfg.trust.fleetKeys;
            }
          ) (cfg.users.users or { });
        }
        // lib.optionalAttrs (shell != null) { inherit shell; }
      );

      manifest =
        if cfg.apps == { } then
          null
        else
          iroha.mkManifest {
            inherit inputs;
            apps = cfg.apps;
            classes = cfg.appClasses;
          };

      resolveProfile =
        nodeName: pname:
        profiles.${pname}
          or (throw "kata.fleet.mkFleet: node '${nodeName}' references unknown profile '${pname}' — known: ${lib.concatStringsSep ", " (builtins.attrNames profiles)}.");

      resolveHm =
        nodeName: userName: mname:
        hmModules.${mname}
          or (throw "kata.fleet.mkFleet: node '${nodeName}' user '${userName}' references unknown HM module '${mname}' — known: ${lib.concatStringsSep ", " (builtins.attrNames hmModules)}.");

      cachesModule = lib.optionalAttrs (cfg.caches != [ ]) {
        nix.settings = {
          extra-substituters = map (c: c.url) cfg.caches;
          extra-trusted-public-keys = map (c: c.publicKey) cfg.caches;
        };
      };

      # ── Liveness projection: declarations stay, deploy targets drop ─────
      # A node whose `status` is "down" (retired / offline / unreachable)
      # keeps its full declaration — it still builds
      # (nixos/darwinConfigurations), still appears in `registry`, `byTag`
      # and `report`. What it loses is its DEPLOY block: projectNode nulls
      # it, so iroha's deployRs + colmena cannot even name the node and
      # nothing blindly attempts + retries a host that can't answer.
      # "a down node is not a deploy target" is therefore structural here,
      # not a runtime guard; the crossInvariant below re-proves it
      # throw-free (same idiom as node-profiles-resolve, which re-proves a
      # throw that construction already raises).
      isLive = node: node.status == "live";

      projectNode =
        name: node:
        {
          inherit (node) class system tags;
          hostname = if node.hostname != null then node.hostname else name;
          sshUser = if node.sshUser != null then node.sshUser else domains.sshUserFor name;
          profiles = map (resolveProfile name) node.profiles;
          modules = lib.optional (cfg.caches != [ ]) cachesModule;
          users = lib.mapAttrs (u: mods: map (resolveHm name u) mods) node.users;
        }
        // lib.optionalAttrs (node.deploy != null && isLive node) {
          deploy = {
            inherit (node.deploy) method;
          };
        };

      hostMatrix = iroha.mkHostMatrix {
        inherit universes;
        manifest = manifest;
        base = {
          nixos = (base.nixos or [ ]) ++ lib.optional (usersModulePlacement == "base") users.module;
          darwin = base.darwin or [ ];
        };
        nodes = lib.mapAttrs projectNode cfg.nodes;
      };

      deployNodes = builtins.attrNames (lib.filterAttrs (_: n: n.deploy != null) cfg.nodes);

      crossInvariants = {
        deployed-nodes-have-domains = {
          expr = builtins.filter (n: !(cfg.domains.locations or { } ? ${n})) deployNodes;
          expected = [ ];
        };
        # Scoped to LIVE nodes on purpose. A node declared "down" is never
        # built and never deployed, so requiring its profile to resolve
        # asserts something the fleet does not rely on — and it punishes the
        # honest case: a retired node whose profile table entry has since
        # been removed is CORRECTLY down, yet would fail this check forever
        # and hold the whole suite red (rai did exactly that from
        # 2026-06-23 until 2026-07-20, so `nix flake check` could not be
        # green on the consuming repo at all).
        #
        # The guarantee that matters is preserved: a profile must resolve
        # for every node that will actually be realized. Reviving a down
        # node flips it to "live", at which point this check demands the
        # profile — failing at revive, which is the moment it is actionable,
        # instead of perpetually.
        node-profiles-resolve = {
          expr = lib.concatMap (
            n: builtins.filter (p: !(profiles ? ${p})) cfg.nodes.${n}.profiles
          ) (builtins.filter (n: isLive cfg.nodes.${n}) (builtins.attrNames cfg.nodes));
          expected = [ ];
        };
        # Liveness regression guard: a node declared "down" must not reach
        # ANY deploy projection. projectNode already makes this structural
        # (it nulls a down node's deploy block); this is the throw-free
        # re-proof, so a future refactor that reintroduces the target
        # fails a check instead of silently retrying a retired host.
        down-nodes-are-not-deploy-targets = {
          expr =
            let
              down = builtins.attrNames (lib.filterAttrs (_: n: n.status != "live") cfg.nodes);
              targeted = (builtins.attrNames hostMatrix.deployRs.nodes) ++ (builtins.attrNames hostMatrix.colmena);
            in
            builtins.filter (n: builtins.elem n targeted) down;
          expected = [ ];
        };
        # Cross-letter consistency: every node named in a WireGuard link
        # must be a known fleet host (domains.hosts). Catches a typo in a
        # vpnLinks entry before it silently projects to nothing.
        wireguard-nodes-are-fleet-hosts = {
          expr =
            let
              knownHost = h: builtins.elem h domains.hosts;
              linkNodes =
                link:
                (lib.optional (link ? a) link.a.node)
                ++ (lib.optional (link ? b) link.b.node)
                ++ (lib.optionals (link ? spokes) (
                  lib.mapAttrsToList (n: _: n) link.spokes
                ));
              allLinkNodes = lib.concatMap linkNodes (builtins.attrValues cfg.vpnLinks);
            in
            builtins.filter (n: !(knownHost n)) (lib.unique allLinkNodes);
          expected = [ ];
        };
      };

      # ── Encapsulated fleet report — one typed query over every letter ──
      # Pure data: per-node facts pulled from domains, ssh-aliases,
      # wireguard, and the node spec. Operators introspect the whole fleet
      # with `nix eval .#... .report --json` instead of reading N files.
      report = {
        name = cfg.name;
        hostCount = builtins.length domains.hosts;
        nodes = lib.mapAttrs (
          name: node:
          {
            inherit (node) class system tags status statusReason;
            fqdn = if domains.locations or { } ? ${name} then domains.fqdn name else null;
            allFqdns = if domains.locations or { } ? ${name} then domains.allFqdns name else [ ];
            sshUser = if node.sshUser != null then node.sshUser else domains.sshUserFor name;
            # EFFECTIVE deployability, not the raw declaration — a "down"
            # node keeps its deploy block but is dropped from every deploy
            # projection, so reporting the declaration here would lie.
            deploys = node.deploy != null && isLive node;
            profiles = node.profiles;
            wireguardLinks = if wireguard == null then [ ] else wireguard.linkNamesForNode name;
          }
        ) cfg.nodes;
      };

      prefix = p: lib.mapAttrs' (n: v: lib.nameValuePair "${p}:${n}" v);

      invariants =
        prefix "domains" domains.invariants
        // prefix "users" users.invariants
        // lib.optionalAttrs (manifest != null) (prefix "manifest" manifest.invariants)
        // prefix "hosts" hostMatrix.invariants
        // prefix "fleet" crossInvariants
        // extraInvariants;
    in
    builtins.seq _placementGuard {
      config = cfg;
      inherit
        domains
        sshAliases
        sshAliasesFor
        wireguard
        users
        manifest
        hostMatrix
        report
        invariants
        ;
      inherit (hostMatrix)
        nixosConfigurations
        darwinConfigurations
        deployRs
        colmena
        byTag
        registry
        ;
      checksFor =
        pkgs:
        {
          "kata-fleet-${cfg.name}" =
            (iroha.mkEvalChecks {
              name = "kata-fleet-${cfg.name}";
              tests = invariants;
            }).asCheck
              pkgs;
        };
    };
in
{
  inherit mkFleet;
}
