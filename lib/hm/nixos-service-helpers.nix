# NixOS module helpers for system-level services
#
# Reusable patterns for NixOS modules that manage systemd services,
# firewall rules, kernel configuration, kubeconfig setup, and VM tests.
#
# Usage (in flake.nix):
#   nixosModules.k3s = import ./module/nixos/k3s {
#     nixosHelpers = import "${substrate}/lib/nixos-service-helpers.nix" { lib = nixpkgs.lib; };
#   };
#
# Usage (in module):
#   { nixosHelpers }: { config, lib, pkgs, ... }:
#   let inherit (nixosHelpers) mkNixOSService mkFirewallConfig mkKernelConfig ...; in { ... }
{ lib }:
with lib;
{
  # ─── Systemd service ──────────────────────────────────────────────────
  # Returns a config block: { systemd.services.<name> = { ... }; }
  #
  # Supports both Type=notify (servers) and Type=exec (agents/workers).
  # Handles Delegate=yes for container runtimes, KillMode=process for
  # services that manage child processes, and resource limits.
  #
  # Example:
  #   nixosHelpers.mkNixOSService {
  #     name = "k3s";
  #     description = "Lightweight Kubernetes";
  #     command = "${pkg}/bin/k3s";
  #     args = ["server" "--cluster-cidr" "10.42.0.0/16"];
  #     type = "notify";
  #     delegate = true;
  #     killMode = "process";
  #     after = ["network-online.target"];
  #     wants = ["network-online.target"];
  #   }
  mkNixOSService = {
    name,
    description,
    command,
    args ? [],
    type ? "simple",
    after ? ["network-online.target"],
    wants ? ["network-online.target"],
    wantedBy ? ["multi-user.target"],
    requires ? [],
    environment ? {},
    environmentFile ? null,
    execStartPre ? null,
    execStartPost ? null,
    restart ? "always",
    restartSec ? 5,
    startLimitIntervalSec ? 300,
    startLimitBurst ? 3,
    killMode ? "control-group",
    delegate ? false,
    limitNOFILE ? null,
    limitNPROC ? null,
    limitCORE ? null,
    path ? [],
  }: {
    systemd.services.${name} = {
      inherit description wantedBy;
      after = after;
      wants = wants;
      requires = requires;

      # ── ★ A START LIMIT THAT CAN ACTUALLY BE REACHED ──────────────────
      # Same class as mkSystemdService in ./service-helpers.nix — read that
      # header for the rio 2026-08-05 measurement. Here it is sharper: this
      # helper defaults `restart = "always"` with `restartSec = 5`, and
      # systemd's default limit is 5 starts / 10s, so only ~2 starts land in a
      # window and the limit is UNREACHABLE. A unit whose failure is permanent
      # restarts forever in `activating` — which `systemctl --failed` does not
      # list, so nothing surfaces it.
      #
      # Top-level attrs, NOT serviceConfig: these are [Unit] keys, and NixOS
      # renders serviceConfig into [Service] where systemd logs "Unknown key
      # name" and IGNORES them. A limit that reads as set and enforces nothing
      # is the same invisible-failure class.
      #
      # Overridable because a unit whose permanent death is worse than its
      # looping wants unbounded retry — upstream nixpkgs ships `sshd` and `k3s`
      # at `StartLimitIntervalSec=0` for exactly that reason (0 DISABLES the
      # limit rather than tightening it).
      # mkDefault so an explicit local decision always wins — see the note in
      # iroha/service-module.nix; a hard value here collided with nix's
      # `pleme.power.lifelineRestart` (deliberate 0) and broke eval.
      startLimitIntervalSec = lib.mkDefault startLimitIntervalSec;
      startLimitBurst = lib.mkDefault startLimitBurst;

      serviceConfig = {
        Type = type;
        ExecStart = concatStringsSep " " ([command] ++ args);
        Restart = restart;
        RestartSec = restartSec;
        KillMode = killMode;
      }
      // optionalAttrs delegate { Delegate = "yes"; }
      // optionalAttrs (environmentFile != null) { EnvironmentFile = environmentFile; }
      // optionalAttrs (limitNOFILE != null) { LimitNOFILE = limitNOFILE; }
      // optionalAttrs (limitNPROC != null) { LimitNPROC = limitNPROC; }
      // optionalAttrs (limitCORE != null) { LimitCORE = limitCORE; }
      // optionalAttrs (execStartPre != null) { ExecStartPre = execStartPre; }
      // optionalAttrs (execStartPost != null) { ExecStartPost = execStartPost; };

      environment = environment;
    }
    // optionalAttrs (path != []) {
      systemd.services.${name}.path = path;
    };
  };

  # ─── Firewall configuration ──────────────────────────────────────────
  # Returns a config block: { networking.firewall = { ... }; }
  #
  # Example:
  #   nixosHelpers.mkFirewallConfig {
  #     tcpPorts = [6443 10250 80 443];
  #     udpPorts = [8472];
  #     trustedInterfaces = ["cni0" "flannel.1"];
  #   }
  mkFirewallConfig = {
    tcpPorts ? [],
    udpPorts ? [],
    trustedInterfaces ? [],
  }: {
    networking.firewall = {}
      // optionalAttrs (tcpPorts != []) { allowedTCPPorts = tcpPorts; }
      // optionalAttrs (udpPorts != []) { allowedUDPPorts = udpPorts; }
      // optionalAttrs (trustedInterfaces != []) { inherit trustedInterfaces; };
  };

  # ─── Kernel configuration ────────────────────────────────────────────
  # Returns a config block: { boot.kernelModules = [...]; boot.kernel.sysctl = {...}; }
  #
  # Example:
  #   nixosHelpers.mkKernelConfig {
  #     modules = ["overlay" "br_netfilter"];
  #     sysctl = {
  #       "net.bridge.bridge-nf-call-iptables" = 1;
  #       "net.ipv4.ip_forward" = 1;
  #     };
  #   }
  mkKernelConfig = {
    modules ? [],
    sysctl ? {},
  }: {}
    // optionalAttrs (modules != []) { boot.kernelModules = modules; }
    // optionalAttrs (sysctl != {}) { boot.kernel.sysctl = sysctl; };

  # ─── Kubeconfig setup service ────────────────────────────────────────
  #
  # ★ SUPERSEDED 2026-08-17 by `seibi kubeconfig`. DO NOT WIRE THIS.
  #
  # Kept, not deleted (★★ MODULARIZE, DON'T DELETE): the declaration stays so
  # the retirement is a readable decision rather than a rebuild from memory.
  # But it must not acquire a consumer, and the reason is not style.
  #
  # WHO OWNS THIS CAPABILITY NOW — and the supersession is PARTIAL, which was
  # established by reading plo rather than by inference. A first draft of this
  # note claimed seibi already performs the 127.0.0.1 substitution in
  # production; measured over ssh on plo 2026-08-17, that is FALSE, and the
  # correction is the useful part:
  #
  #   `nix/modules/nixos/k3s-kubeconfig-export.nix` runs `seibi kubeconfig
  #   --json` (a typed Rust tool) behind `iroha.mkServiceUnit`. The unit
  #   `export-plo-kubeconfig.service` is active (exited), and what it produces
  #   is TWO /etc files, fresh as of Aug 16 17:00:
  #     /etc/k3s-admin-kubeconfig    server: https://127.0.0.1:6443
  #     /etc/k3s-remote-kubeconfig   server: https://192.168.50.3:6443
  #   So seibi does not rewrite 127.0.0.1 to `localhost` at all — it keeps the
  #   loopback for the admin config and substitutes the node's REACHABLE IP for
  #   the remote one.
  #
  # WHAT IS THEREFORE STILL UNOWNED: seeding a per-user ~/.kube/config, which
  # is the half this helper did. On plo, /home/luis/.kube/config is dated
  # 2026-03-05 and carries `server: https://localhost:6443` — a value NOTHING
  # in the current closure produces. It is a stale artifact that no unit
  # reconciles, the same class the nix repo records for cid's `UserShell`
  # (green build, green activation, nothing written). Do not read the presence
  # of a plausible-looking ~/.kube/config as evidence that something maintains
  # it. Closing that gap belongs in seibi (a per-user export mode) or in a
  # typed HM module — not here.
  #
  # CONSUMERS: zero. Measured 2026-08-17 over 49,744 .nix files in ~/code
  # (worktrees excluded); the only file naming `mkKubeconfigService` is this
  # one. So it is an unwired shell predecessor of a live typed capability —
  # duplicating it would violate "solve problems once, in one place".
  #
  # WHY NOT SIMPLY PORT THE SHELL TO A .tlisp. Because the shell body below is
  # not merely shell — it is a chain of side effects whose failure modes are
  # each individually SILENT, and a faithful port would carry them across:
  #   * the `sed -i` replacements exit 0 when the pattern does not match, so a
  #     node ships a kubeconfig pointing at the wrong host with a GREEN
  #     activation — the same class as the LUA_ROOT sed that never matched
  #     because a character class held spaces where the file had a tab;
  #   * `rm -f` exits 0 on a permission error inside the tree;
  #   * a partly-failed `cp` leaves a stale file that the following `chmod`
  #     reports success on;
  #   * `if id -u <user>` skips the ENTIRE per-user block silently when the
  #     account does not exist — the same shape as nix-darwin's uid guard
  #     discarding every managed property with one yellow warning.
  # seibi answers this by CONSTRUCTING the kubeconfig rather than pattern-
  # matching a copy of it, which is why the destination is the tool and not a
  # translation. (deshellify's ladder, rung 3: own the file, do not patch it.)
  #
  # TO REVIVE: don't revive the SHELL. The per-user seeding gap above is real,
  # so the capability may genuinely be wanted again — build it as a seibi
  # subcommand and render it through `iroha.mkServiceUnit`, matching
  # nix/modules/nixos/k3s-kubeconfig-export.nix. A tool that CONSTRUCTS the
  # file has somewhere to put "which server URL does this user need"; a sed
  # over a copy does not, which is why the original could only express it as a
  # regex that silently matches nothing when it is wrong.
  #
  # pending-kubeconfig-per-user: no owner for ~/.kube/config on k3s nodes
  #
  # Returns a systemd oneshot service that waits for a kubeconfig file
  # to appear, then copies it to specified users' home directories with
  # optional sed replacements.
  #
  # Example:
  #   nixosHelpers.mkKubeconfigService {
  #     pkgs = pkgs;
  #     name = "k3s-kubeconfig-setup";
  #     description = "Setup kubeconfig for users";
  #     kubeconfigPath = "/etc/rancher/k3s/k3s.yaml";
  #     users = ["drzzln"];
  #     after = ["k3s.service"];
  #     requires = ["k3s.service"];
  #     replacements = { "127.0.0.1" = "localhost"; };
  #   }
  mkKubeconfigService = {
    pkgs,
    name,
    description,
    kubeconfigPath,
    users,
    after ? [],
    requires ? [],
    wants ? [],
    replacements ? {},
  }: {
    systemd.services.${name} = {
      inherit description after requires wants;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript name ''
          while [ ! -f ${kubeconfigPath} ]; do
            echo "Waiting for ${kubeconfigPath}..."
            sleep 2
          done

          ${concatMapStrings (user: ''
            if id -u ${user} >/dev/null 2>&1; then
              USER_HOME="/home/${user}"
              mkdir -p $USER_HOME/.kube
              rm -f $USER_HOME/.kube/config
              cp ${kubeconfigPath} $USER_HOME/.kube/config
              chown -R ${user}:users $USER_HOME/.kube
              chmod 600 $USER_HOME/.kube/config
              ${concatStringsSep "\n" (mapAttrsToList (from: to:
                "${pkgs.gnused}/bin/sed -i 's/${from}/${to}/g' $USER_HOME/.kube/config"
              ) replacements)}
              echo "Kubeconfig setup for user ${user}"
            fi
          '') users}
        '';
      };
      wantedBy = ["multi-user.target"];
    };
  };

  # ─── NixOS VM test wrapper ───────────────────────────────────────────
  # Standardized wrapper around pkgs.testers.runNixOSTest (or nixosTest).
  # Returns a derivation suitable for `checks.<system>.<name>`.
  #
  # Example:
  #   nixosHelpers.mkNixOSTest {
  #     pkgs = pkgs;
  #     name = "k3s-single-node";
  #     nodes.machine = { ... }: {
  #       services.blackmatter.k3s.enable = true;
  #       virtualisation.memorySize = 1536;
  #     };
  #     testScript = ''
  #       machine.wait_for_unit("k3s")
  #       machine.succeed("kubectl cluster-info")
  #     '';
  #   }
  mkNixOSTest = {
    pkgs,
    name,
    nodes,
    testScript,
    extraModules ? [],
    skipLint ? false,
  }: pkgs.testers.runNixOSTest {
    inherit name nodes testScript skipLint;
    # Allow tests to import extra modules (e.g., the k3s module being tested)
    defaults = { imports = extraModules; };
  };
}
