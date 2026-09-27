# substrate/lib/nix-builders/tehai.nix
#
# `services.tehai`: nix's remote builders chosen by who is up, not by who is
# declared. The node's system config still declares every builder (nix-darwin
# and NixOS render them to /etc/nix/machines); tehai, blue's `tehai` bidama,
# checks each one on an interval over ssh and writes only the live ones to a
# second machines file, and nix is pointed at that file. A builder that is down
# costs nothing; one that comes back is used again within one interval; no one
# flips `enable` by hand for liveness again. The ssh Host blocks that carry each
# builder's address and key stay where they are declared.
#
# Returns { darwinModule, nixosModule }. Both need a `blue` that resolves the
# `tehai` bidama (the fleet's `pkgs.blue-with-bidamas`, blue's mkBlueWithBidamas).
#
#   imports = [ (import "${substrate}/lib/nix-builders/tehai.nix").darwinModule ];
#   services.tehai.enable = true;
let
  common = { platform }: { config, lib, pkgs, ... }:
    let
      cfg = config.services.tehai;
      helpers = import ../blue-service-helpers.nix { inherit lib; };
      mkBlueProgramPackage = import ../build/scripting/blue-program-package.nix { inherit pkgs; };
      live = "${cfg.stateDir}/machines";
      environment = {
        TEHAI_DECLARED = cfg.declaredPath;
        TEHAI_LIVE = live;
        TEHAI_STATE = "${cfg.stateDir}/state.json";
        TEHAI_TIMEOUT_S = toString cfg.timeoutSeconds;
        # By absolute path, so tehai runs the ssh nix itself uses and its state
        # names which one (`ssh` in state.json). macOS: /usr/bin/ssh, which
        # reads /etc/ssh/ssh_config like nix does.
        TEHAI_SSH = if platform == "nixos" then "${pkgs.openssh}/bin/ssh" else "/usr/bin/ssh";
      };
      package = mkBlueProgramPackage {
        name = "tehai";
        blue = cfg.blue;
        # The same entry as blue's own `tehai` package (blue flake.nix
        # `commands`); this one bakes in the module's environment. The wrapper
        # runs `blue run --quiet`, so the log holds only what tehai writes.
        source = ''
          use("tehai")
          th_main()
        '';
        # macOS: /usr/bin/ssh, which reads /etc/ssh/ssh_config like nix does.
        extraPath = lib.optionals (platform == "nixos") [ pkgs.openssh ];
        env = environment;
      };
    in
    {
      options.services.tehai = {
        enable = lib.mkEnableOption "tehai: point nix at the remote builders that answer, checked every interval";
        blue = lib.mkOption {
          type = lib.types.package;
          default = pkgs.blue-with-bidamas or (throw "services.tehai.blue: no pkgs.blue-with-bidamas; pass a blue that resolves the tehai bidama");
          defaultText = lib.literalExpression "pkgs.blue-with-bidamas";
          description = "A blue binary that resolves the `tehai` bidama.";
        };
        intervalSeconds = lib.mkOption {
          type = lib.types.ints.positive;
          default = 15;
          description = "Seconds between checks: how long a builder that just died or came back can go unnoticed.";
        };
        timeoutSeconds = lib.mkOption {
          type = lib.types.ints.positive;
          default = 2;
          description = "ssh connect and keep-alive timeout for each check.";
        };
        declaredPath = lib.mkOption {
          type = lib.types.str;
          default = "/etc/nix/machines";
          description = "The declared machines file (what the system config renders).";
        };
        stateDir = lib.mkOption {
          type = lib.types.str;
          default = if platform == "darwin" then "/var/run/tehai" else "/run/tehai";
          description = "Where the live machines file and state.json are written.";
        };
        steerNix = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Point nix's `builders` at the live file. Off: tehai only observes.";
        };
        package = lib.mkOption {
          type = lib.types.package;
          readOnly = true;
          default = package;
          description = "The tehai program as built (bin/tehai); also on PATH for a manual run.";
        };
      };

      config = lib.mkIf cfg.enable (lib.mkMerge [
        (if platform == "darwin"
          then helpers.mkBlueIntervalDarwin { name = "tehai"; inherit package environment; intervalSeconds = cfg.intervalSeconds; }
          else helpers.mkBlueIntervalNixos { name = "tehai"; inherit package environment; intervalSeconds = cfg.intervalSeconds; })
        { environment.systemPackages = [ package ]; }
        (lib.mkIf cfg.steerNix { nix.settings.builders = lib.mkForce "@${live}"; })
      ]);
    };
in
{
  darwinModule = common { platform = "darwin"; };
  nixosModule = common { platform = "nixos"; };
}
