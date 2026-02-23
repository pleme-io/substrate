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
