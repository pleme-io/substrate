{ config, lib, ... }:
let
  cfg = config.pleme.blueToolchain;
  native = cfg.entries.${cfg.selected}.runtime == "native";
in
{
  imports = [ ./system.nix ];
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !native;
        message = "blueToolchain: entry `${cfg.selected}` runs native code, which needs S5 (Mach-O) on darwin";
      }
    ];
  };
}
