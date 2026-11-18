{ config, lib, ... }:
let
  cfg = config.pleme.blueToolchain;
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.refusal == null;
        message = toString cfg.refusal;
      }
    ];
    environment.systemPackages = lib.optional (cfg.refusal == null) cfg.packages.${cfg.selected};
    environment.variables = lib.optionalAttrs (cfg.door != null) { BLUE_DOOR = cfg.door; };
  };
}
