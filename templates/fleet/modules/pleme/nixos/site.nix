{ config, lib, ... }:
{
  config = lib.mkIf config.pleme.site.enable { time.timeZone = config.pleme.site.timeZone; };
}
