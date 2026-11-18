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
    home.packages = lib.optional (cfg.refusal == null) cfg.packages.${cfg.selected};
    home.sessionVariables = lib.optionalAttrs (cfg.door != null) { BLUE_DOOR = cfg.door; };
  };
}
