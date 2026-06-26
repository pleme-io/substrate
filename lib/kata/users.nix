# kata.users — the typed pleme-io user-management surface.
#
# ONE typed declaration per person → everything the fleet needs to make
# them a member: a NixOS account (fleet-wide OR scoped to named nodes), the
# ssh identity (inbound authorized keys + the per-user `<name>@fleet`
# outbound key + its SOPS private-key path), the SOPS age recipient, and the
# git identity — plus an `onboarding` descriptor the tooling (seibi) reads
# to drive key generation + secret registration.
#
# Generalization of the nix repo's lib/fleet-users.nix (whose hard-coded
# drzzln/luis/automation registry + per-node mkInteractiveUser factory + ssh
# + sops wiring are all subsumed here as one argument-driven engine).
#
# Exports (pure { lib }):
#
#   mkUsers :: {
#     users :: attrsOf userSpec (required, non-empty — typed throw);
#       userSpec = {
#         kind        :: "interactive" | "automation" (required — typed
#                        throw otherwise). interactive => isNormalUser,
#                        uid >= 1000; automation => isSystemUser,
#                        uid < 1000, ssh hardening (no TTY/forwarding);
#         uid         :: int (required);
#         gid         ? uid;
#         description ? name;
#         groups      ? kind-default (interactive: wheel networkmanager
#                       docker libvirtd kvm dialout video audio;
#                       automation: wheel);
#         home        ? kind-default (/home/<name> | /var/lib/<name>);
#         keys        ? [ ] (authorized inbound ssh public keys);
#         identitySecret ? null | { sopsPath :: str } — the per-user ssh
#                       identity PRIVATE half: emits sops.secrets.<sopsPath>
#                       landing at <home>/.ssh/id_ed25519 + a tmpfiles rule;
#         # ── the user-management surface (all optional) ──
#         nodes       ? null | listOf str — WHERE the account is materialized.
#                       null = fleet-wide (the ops accounts: every node bakes
#                       `module`). [list] = scoped: only the named nodes
#                       materialize it, via `mkUserModule`/`scopedModuleForNode`.
#         fleetKey    ? null | str — this user's `<name>@fleet` PUBLIC key
#                       (the outbound identity pubkey; pairs with identitySecret).
#                       Pure metadata here (the authorized-keys plumbing reads it).
#         git         ? null | { name, email } — git identity (for HM consumers).
#         ageRecipient? null | str — this user's SOPS age PUBLIC recipient,
#                       for .sops.yaml membership. null = not provisioned yet.
#       };
#     groups ? { } (attrsOf int — standalone groups, e.g. media = 980);
#     shell  ? null — drv applied to every interactive user (mkForce);
#     uidMigration ? true — emit the idempotent chown-on-UID-drift activation
#              script in `module` (the one sanctioned generated bash). Scoped
#              per-node accounts (mkUserModule) NEVER emit it — a freshly
#              created account has no prior UID to migrate.
#   } -> {
#     uids / gids   — pure attrsets (registry projections);
#     module        — NixOS module materializing the FLEET-WIDE accounts
#                     (nodes == null) at canonical UIDs + identity secrets +
#                     automation hardening + uid-migration. Bake into every
#                     node (what fleet-base imports today). Backward-compatible:
#                     a registry with no `nodes` field => every user is here.
#     mkUserModule name      — a NixOS module materializing ONE account fully
#                     (account + group + identity secret + tmpfiles, NO uid
#                     migration). The per-node factory a node imports for each
#                     scoped user it hosts (was lib/fleet-users.mkInteractiveUser).
#     scopedModuleForNode n  — mkMerge of mkUserModule for every scoped user
#                     whose `nodes` includes n. Convenience for a node.
#     usersForNode n         — [names] the node materializes (scoped ∋ n).
#     registry      — { interactive, automation, fleetWide, scoped } name lists;
#     onboarding    — attrsOf the per-user onboarding descriptor (kind, uid,
#                     nodes, fleetKey, ageRecipient, identitySecret, git, and
#                     `needs` = which artifacts still have to be generated):
#                       needs.sshIdentity (identitySecret set but no fleetKey)
#                       needs.ageRecipient (interactive + ageRecipient == null);
#     invariants    — throw-free suite (uid/gid uniqueness incl. groups,
#                     interactive uid >= 1000, automation uid < 1000, scoped
#                     users have a non-empty node list, fleetKeys + ageRecipients
#                     unique where set);
#   }
{ lib }:
let
  kinds = [
    "interactive"
    "automation"
  ];

  interactiveGroups = [
    "wheel"
    "networkmanager"
    "docker"
    "libvirtd"
    "kvm"
    "dialout"
    "video"
    "audio"
  ];

  mkUsers =
    {
      users,
      groups ? { },
      shell ? null,
      uidMigration ? true,
    }:
    let
      _guard =
        if !(builtins.isAttrs users) || users == { } then
          throw "kata.users.mkUsers: `users` must be a non-empty attrset of userSpec."
        else
          true;

      norm = lib.mapAttrs (
        name: spec:
        let
          kind =
            spec.kind
              or (throw "kata.users.mkUsers: user '${name}' is missing `kind` — one of ${lib.concatStringsSep ", " kinds}.");
        in
        if !(builtins.elem kind kinds) then
          throw "kata.users.mkUsers: user '${name}' has unknown kind '${toString kind}' — one of ${lib.concatStringsSep ", " kinds}."
        else
          {
            inherit kind;
            uid = spec.uid or (throw "kata.users.mkUsers: user '${name}' is missing `uid` (int).");
            gid = spec.gid or (spec.uid or 0);
            description = spec.description or name;
            groups = spec.groups or (if kind == "interactive" then interactiveGroups else [ "wheel" ]);
            home = spec.home or (if kind == "interactive" then "/home/${name}" else "/var/lib/${name}");
            keys = spec.keys or [ ];
            identitySecret = spec.identitySecret or null;
            # ── user-management surface ──
            nodes = spec.nodes or null;
            fleetKey = spec.fleetKey or null;
            git = spec.git or null;
            ageRecipient = spec.ageRecipient or null;
          }
      ) users;

      names = builtins.attrNames norm;
      interactive = builtins.filter (n: norm.${n}.kind == "interactive") names;
      automation = builtins.filter (n: norm.${n}.kind == "automation") names;

      # WHERE: null nodes => fleet-wide (baked into every node via `module`);
      # a node list => scoped (materialized only on those nodes).
      fleetWide = builtins.filter (n: norm.${n}.nodes == null) names;
      scoped = builtins.filter (n: norm.${n}.nodes != null) names;
      usersForNode =
        node: builtins.filter (n: norm.${n}.nodes != null && builtins.elem node norm.${n}.nodes) names;

      uids = lib.mapAttrs (_: u: u.uid) norm;
      gids = lib.mapAttrs (_: u: u.gid) norm // groups;

      mkUser =
        pkgs: name:
        let
          u = norm.${name};
          isInteractive = u.kind == "interactive";
        in
        {
          users.users.${name} =
            {
              uid = lib.mkDefault u.uid;
              group = name;
              extraGroups = lib.mkDefault u.groups;
              createHome = lib.mkDefault true;
              home = lib.mkDefault u.home;
              description = lib.mkDefault u.description;
              openssh.authorizedKeys.keys = lib.mkDefault u.keys;
            }
            // (
              if isInteractive then
                {
                  isNormalUser = true;
                  # fleet-shell-wins rule (see fleet-users.nix rationale):
                  # blizzard's users-packages module emits a shell at plain
                  # priority for managed users; the registry is canonical.
                  shell = lib.mkForce (if shell != null then shell else pkgs.bashInteractive);
                }
              else
                {
                  isSystemUser = true;
                  shell = pkgs.bashInteractive;
                }
            );
          users.groups.${name} = {
            gid = lib.mkDefault u.gid;
          };
        };

      identityNamesIn = ns: builtins.filter (n: norm.${n}.identitySecret != null) ns;
      automationNamesIn = ns: builtins.filter (n: norm.${n}.kind == "automation") ns;

      sshdHardeningFor = ns: lib.concatMapStrings (n: ''
        Match User ${n}
          PermitTTY no
          AllowTcpForwarding no
          AllowAgentForwarding no
          X11Forwarding no
          AllowStreamLocalForwarding no
          PermitUserRC no
      '') (automationNamesIn ns);

      migrateScriptFor = ns: lib.concatMapStrings (n: ''
        migrate_home ${n} ${toString norm.${n}.uid} ${toString norm.${n}.gid} ${norm.${n}.home}
      '') ns;

      # ONE module builder over an arbitrary name set. `module`, `mkUserModule`,
      # and `scopedModuleForNode` are all this with different (names, flags).
      mkModuleFor =
        {
          moduleNames,
          includeGroups ? false,
          withMigration ? false,
          migrateName ? "kataUsersUidMigrate",
        }:
        { lib, pkgs, ... }:
        let
          ids = identityNamesIn moduleNames;
          autos = automationNamesIn moduleNames;
        in
        {
          config = lib.mkMerge (
            map (mkUser pkgs) moduleNames
            ++ [
              {
                sops.secrets = lib.listToAttrs (
                  map (
                    n:
                    lib.nameValuePair norm.${n}.identitySecret.sopsPath {
                      owner = n;
                      group = n;
                      mode = "0600";
                      path = "${norm.${n}.home}/.ssh/id_ed25519";
                    }
                  ) ids
                );

                systemd.tmpfiles.rules = map (n: "d ${norm.${n}.home}/.ssh 0700 ${n} ${n} -") ids;
              }
            ]
            ++ lib.optional includeGroups {
              users.groups = lib.mapAttrs (_: gid: { gid = lib.mkDefault gid; }) groups;
            }
            ++ [
              (lib.mkIf (autos != [ ]) {
                services.openssh.extraConfig = lib.mkAfter (sshdHardeningFor moduleNames);
              })
            ]
            ++ lib.optional withMigration {
              # Idempotent chown-on-UID-drift migration, compiled from the
              # registry (the one sanctioned bash — generated, not authored).
              system.activationScripts.${migrateName} = {
                text = ''
                  migrate_home() {
                    local user="$1" uid="$2" gid="$3" home="$4"
                    if [ -d "$home" ]; then
                      local cur_uid
                      cur_uid=$(stat -c '%u' "$home" 2>/dev/null || echo "")
                      if [ -n "$cur_uid" ] && [ "$cur_uid" != "$uid" ]; then
                        echo "kata-users: chown $home $cur_uid -> $uid:$gid"
                        chown -R "$uid:$gid" "$home"
                      fi
                    fi
                  }
                ''
                + migrateScriptFor moduleNames;
                deps = [ "users" ];
              };
            }
          );
        };

      # FLEET-WIDE accounts — every node bakes this (fleet-base). Backward-
      # compatible: with no `nodes` field anywhere, fleetWide == every user.
      module = mkModuleFor {
        moduleNames = fleetWide;
        includeGroups = true;
        withMigration = uidMigration;
        migrateName = "kataUsersUidMigrate";
      };

      # SCOPED accounts — the per-node factory (was lib/fleet-users
      # mkInteractiveUser). One user, NO uid-migration bash (a fresh account
      # never needs it — NO SHELL for new onboarding).
      mkUserModule = name: mkModuleFor { moduleNames = [ name ]; includeGroups = false; };
      scopedModuleForNode = node: mkModuleFor { moduleNames = usersForNode node; includeGroups = false; };

      # The onboarding descriptor — what the tooling (seibi) needs to know to
      # bring a person online: their identity coordinates + what still has to
      # be generated/registered.
      onboarding = lib.mapAttrs (
        name: u: {
          inherit (u)
            kind
            uid
            nodes
            fleetKey
            ageRecipient
            identitySecret
            git
            ;
          sopsPath = if u.identitySecret != null then u.identitySecret.sopsPath else null;
          needs = {
            # ssh identity declared (sopsPath) but the public half not captured yet
            sshIdentity = u.identitySecret != null && u.fleetKey == null;
            # an interactive operator who isn't a .sops.yaml party yet
            ageRecipient = u.kind == "interactive" && u.ageRecipient == null;
          };
        }
      ) norm;

      allGids = builtins.attrValues gids;
      allUids = builtins.attrValues uids;
      setFleetKeys = builtins.filter (k: k != null) (map (n: norm.${n}.fleetKey) names);
      setRecipients = builtins.filter (r: r != null) (map (n: norm.${n}.ageRecipient) names);
    in
    builtins.seq _guard (builtins.seq (builtins.deepSeq (lib.mapAttrs (_: u: u.kind) norm) true) {
      inherit
        uids
        gids
        module
        mkUserModule
        scopedModuleForNode
        usersForNode
        onboarding
        ;
      registry = {
        inherit
          interactive
          automation
          fleetWide
          scoped
          ;
      };
      invariants = {
        uids-unique = {
          expr = builtins.length allUids == builtins.length (lib.unique allUids);
          expected = true;
        };
        gids-unique = {
          expr = builtins.length allGids == builtins.length (lib.unique allGids);
          expected = true;
        };
        interactive-uids-in-normal-range = {
          expr = builtins.filter (n: norm.${n}.uid < 1000) interactive;
          expected = [ ];
        };
        automation-uids-in-system-range = {
          expr = builtins.filter (n: norm.${n}.uid >= 1000) automation;
          expected = [ ];
        };
        scoped-users-have-nonempty-nodes = {
          expr = builtins.filter (n: norm.${n}.nodes != null && norm.${n}.nodes == [ ]) names;
          expected = [ ];
        };
        fleet-keys-unique = {
          expr = builtins.length setFleetKeys == builtins.length (lib.unique setFleetKeys);
          expected = true;
        };
        age-recipients-unique = {
          expr = builtins.length setRecipients == builtins.length (lib.unique setRecipients);
          expected = true;
        };
      };
    });
in
{
  inherit mkUsers;
}
