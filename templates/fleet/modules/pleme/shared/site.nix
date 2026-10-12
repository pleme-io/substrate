{ lib, config, ... }: {
  options.pleme.site = {
    timeZone = lib.mkOption {
      type = lib.types.str;
      default = "UTC";
      description = "The site's time zone; every renderer projects it onto its platform's clock setting.";
    };
    derived.timeZone = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "The time zone every renderer reads.";
    };
  };
  config.pleme.site.derived.timeZone = config.pleme.site.timeZone;
}
