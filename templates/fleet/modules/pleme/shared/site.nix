{ lib, inputs, ... }:
let
  trio = inputs.substrate.moduleTrio;
in
{
  imports = [
    (trio.mkModuleTrio {
      kind = "registry";
      namespace = "pleme";
      name = "site";
      description = "the site's clock zone, selected from the zones this fleet knows";
      enable.default = true;
      entries = {
        option = "zones";
        type = lib.types.str;
        default = {
          utc = "UTC";
          fortaleza = "America/Fortaleza";
        };
        description = "Every time zone a site of this fleet runs in, by name.";
      };
      selector = {
        over = "entries";
        default = "utc";
        description = "The zone this machine's site runs in.";
      };
      projections =
        { cfg, ... }:
        {
          timeZone = {
            type = lib.types.str;
            value = cfg.zones.${cfg.selected};
            description = "The time zone every renderer reads.";
          };
        };
      render = {
        nixos = ../nixos/site.nix;
        darwin = ../darwin/site.nix;
      };
      support.homeManager = trio.support.refuses "scope" "the clock zone is the system's, which a user scope does not set";
    }).module
  ];
}
