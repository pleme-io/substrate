let
  ipv4 = lib: lib.types.strMatching "([0-9]{1,3}\\.){3}[0-9]{1,3}";

  common = { platform }: { config, lib, pkgs, ... }:
    let
      cfg = config.services.ukai;
      helpers = import ../blue-service-helpers.nix { inherit lib; };
      mkBlueProgramPackage = import ../build/scripting/blue-program-package.nix { inherit pkgs; };
      tailscaleExe = "${cfg.tailscalePackage}/bin/tailscale";
      environment = {
        UKAI_PLATFORM = platform;
        UKAI_CORP_PATTERN = cfg.corpInterfacePattern;
        UKAI_CONTROL_HOST = cfg.overlayControlHost;
        UKAI_GATEWAY = if cfg.gateway == null then "" else cfg.gateway.address;
        UKAI_GATEWAY_IFACE = if cfg.gateway == null then "" else cfg.gateway.interface;
        UKAI_EXTRA_HOSTS = lib.concatStringsSep "," cfg.extraHosts;
        UKAI_TAILSCALE = tailscaleExe;
        UKAI_DRY_RUN = if cfg.dryRun then "1" else "0";
        UKAI_STATE = "${cfg.stateDir}/state.json";
      } // lib.optionalAttrs (platform == "nixos") {
        UKAI_IP = "${pkgs.iproute2}/bin/ip";
        UKAI_GETENT = "${lib.getBin pkgs.glibc}/bin/getent";
        UKAI_TABLE = toString cfg.policyRouting.table;
        UKAI_PRIORITY = toString cfg.policyRouting.priority;
      };
      built = mkBlueProgramPackage {
        name = "ukai";
        blue = cfg.blue;
        source = ''
          use("ukai", [:main])
          main()
        '';
        extraPath = [ cfg.tailscalePackage ] ++ lib.optionals (platform == "nixos") [ pkgs.iproute2 ];
        env = environment;
      };
      service =
        if platform == "darwin"
        then helpers.mkBlueIntervalDarwin { name = "ukai"; package = cfg.package; inherit environment; intervalSeconds = cfg.refreshIntervalSeconds; }
        else helpers.mkBlueIntervalNixos { name = "ukai"; package = cfg.package; inherit environment; intervalSeconds = cfg.refreshIntervalSeconds; };
    in
    {
      options.services.ukai = {
        enable = lib.mkEnableOption "ukai: keep the overlay VPN's control plane and DERP relays routed around a full-tunnel corporate VPN";
        blue = lib.mkOption {
          type = lib.types.package;
          default = pkgs.blue-with-bidamas or (throw "services.ukai.blue: no pkgs.blue-with-bidamas; pass a blue that resolves the ukai bidama");
          defaultText = lib.literalExpression "pkgs.blue-with-bidamas";
          description = "A blue binary that resolves the `ukai` bidama.";
        };
        tailscalePackage = lib.mkOption {
          type = lib.types.package;
          default = config.services.tailscale.package or pkgs.tailscale;
          defaultText = lib.literalExpression "config.services.tailscale.package";
          description = "The tailscale whose CLI ukai reads (netcheck, status, debug derp-map), run by absolute path.";
        };
        corpInterfacePattern = lib.mkOption {
          type = lib.types.strMatching "[A-Za-z][A-Za-z0-9]*";
          default = if platform == "darwin" then "utun" else "ppp";
          description = "Interface-name prefix of the corporate tunnel. The interface that carries the overlay's 100.64/10 is never taken for it.";
        };
        overlayControlHost = lib.mkOption {
          type = lib.types.strMatching "[A-Za-z0-9.-]+";
          default = "controlplane.tailscale.com";
          description = "The overlay's control-plane host, resolved every run (its addresses rotate).";
        };
        extraHosts = lib.mkOption {
          type = lib.types.listOf (ipv4 lib);
          default = [ ];
          description = "IPv4 addresses always routed around the tunnel, beside the resolved control plane and every DERP node.";
        };
        gateway = lib.mkOption {
          type = lib.types.nullOr (lib.types.submodule {
            options = {
              address = lib.mkOption { type = ipv4 lib; description = "Physical next hop."; };
              interface = lib.mkOption { type = lib.types.strMatching "[A-Za-z][A-Za-z0-9.]*"; description = "Physical interface."; };
            };
          });
          default = null;
          description = "Override the physical gateway. null: read it from the routing table (the default route not on the corporate or overlay interface).";
        };
        refreshIntervalSeconds = lib.mkOption {
          type = lib.types.ints.between 5 3600;
          default = 30;
          description = "Seconds between reconciles.";
        };
        dryRun = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Observe, decide and record the planned commands in state.json without changing the routing table.";
        };
        stateDir = lib.mkOption {
          type = lib.types.str;
          default = if platform == "darwin" then "/var/run/ukai" else "/run/ukai";
          description = "Where state.json (last outcome, planned and failed commands, the hosts ukai installed) is written.";
        };
        policyRouting = {
          table = lib.mkOption {
            type = lib.types.ints.between 1 4294967295;
            default = 5280;
            description = "NixOS: the routing table holding the bypass host routes.";
          };
          priority = lib.mkOption {
            type = lib.types.ints.between 1 32765;
            default = 5200;
            description = "NixOS: the ip-rule priority; below tailscale's 5210 fwmark rule so the bypass is looked up first.";
          };
        };
        package = lib.mkOption {
          type = lib.types.package;
          default = built;
          defaultText = lib.literalExpression "the ukai blue program with this module's environment";
          description = "The ukai program (bin/ukai).";
        };
      };

      config = lib.mkIf cfg.enable (lib.mkMerge [
        {
          assertions = [
            {
              assertion = if platform == "darwin" then pkgs.stdenv.hostPlatform.isDarwin else pkgs.stdenv.hostPlatform.isLinux;
              message = "services.ukai: the ${platform} arm writes the ${if platform == "darwin" then "BSD routing table with /sbin/route" else "Linux policy routing with ip rule"} and cannot run on ${pkgs.stdenv.hostPlatform.system}.";
            }
            {
              assertion = !(platform == "nixos" && cfg.policyRouting.priority >= 5210);
              message = "services.ukai.policyRouting.priority must sit below tailscale's 5210 rule, or tailscaled's marked traffic never reaches the bypass table.";
            }
          ];
          environment.systemPackages = [ cfg.package ];
        }
        service
      ]);
    };
in
{
  darwinModule = common { platform = "darwin"; };
  nixosModule = common { platform = "nixos"; };
}
