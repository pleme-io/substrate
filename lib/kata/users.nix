# kata.users — typed fleet user registry -> NixOS users module
# (generalization of the nix repo's lib/fleet-users.nix, whose factory
# hard-coded the drzzln/luis/automation registry; here the registry is
# the argument and the machinery is the vocabulary).
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
#         keys        ? [ ] (authorized ssh public keys);
#         identitySecret ? null | { sopsPath :: str } — per-user ssh
#                       identity: emits sops.secrets.<sopsPath> landing at
#                       <home>/.ssh/id_ed25519 (owner/mode set) + a
#                       tmpfiles rule pre-creating <home>/.ssh;
#       };
#     groups ? { } (attrsOf int — standalone groups, e.g. media = 980);
#     shell  ? null — drv applied to every interactive user (mkForce, the
#              fleet-shell-wins rule from fleet-users.nix) ; automation
#              users always get pkgs.bashInteractive;
#     uidMigration ? true — emit the idempotent chown-on-UID-drift
#              activation script (generated from the registry; the one
#              sanctioned bash, compiled from typed data);
#   } -> {
#     uids / gids   — pure attrsets (registry projections);
#     module        — NixOS module declaring every account at canonical
#                     UIDs (mkDefault everywhere except shell), automation
#                     sshd Match hardening blocks, identity secrets +
#                     tmpfiles, uid-migration activation script;
#     registry      — { interactive = [names]; automation = [names]; };
#     invariants    — throw-free suite: uid uniqueness, gid uniqueness
#                     (vs groups too), interactive uid >= 1000,
#                     automation uid < 1000;
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
          }
      ) users;

      names = builtins.attrNames norm;
      interactive = builtins.filter (n: norm.${n}.kind == "interactive") names;
      automation = builtins.filter (n: norm.${n}.kind == "automation") names;

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

      identityUsers = builtins.filter (n: norm.${n}.identitySecret != null) names;

      sshdHardening = lib.concatMapStrings (n: ''
        Match User ${n}
          PermitTTY no
          AllowTcpForwarding no
          AllowAgentForwarding no
          X11Forwarding no
          AllowStreamLocalForwarding no
          PermitUserRC no
      '') automation;

      migrateScript = lib.concatMapStrings (n: ''
        migrate_home ${n} ${toString norm.${n}.uid} ${toString norm.${n}.gid} ${norm.${n}.home}
      '') names;

      module =
        { lib, pkgs, ... }:
        {
          config = lib.mkMerge (
            map (mkUser pkgs) names
            ++ [
              {
                users.groups = lib.mapAttrs (_: gid: { gid = lib.mkDefault gid; }) groups;

                sops.secrets = lib.listToAttrs (
                  map (
                    n:
                    lib.nameValuePair norm.${n}.identitySecret.sopsPath {
                      owner = n;
                      group = n;
                      mode = "0600";
                      path = "${norm.${n}.home}/.ssh/id_ed25519";
                    }
                  ) identityUsers
                );

                systemd.tmpfiles.rules = map (n: "d ${norm.${n}.home}/.ssh 0700 ${n} ${n} -") identityUsers;
              }
              (lib.mkIf (automation != [ ]) {
                services.openssh.extraConfig = lib.mkAfter sshdHardening;
              })
              (lib.mkIf uidMigration {
                # Idempotent chown-on-UID-drift migration, compiled from the
                # registry (the one sanctioned bash — generated, not authored).
                system.activationScripts.kataUsersUidMigrate = {
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
                  + migrateScript;
                  deps = [ "users" ];
                };
              })
            ]
          );
        };

      allGids = builtins.attrValues gids;
      allUids = builtins.attrValues uids;
    in
    builtins.seq _guard (builtins.seq (builtins.deepSeq (lib.mapAttrs (_: u: u.kind) norm) true) {
      inherit
        uids
        gids
        module
        ;
      registry = {
        inherit interactive automation;
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
      };
    });
in
{
  inherit mkUsers;
}
