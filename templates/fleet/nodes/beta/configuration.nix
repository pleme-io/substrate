{ lib, ... }: {
  networking.hostName = "beta";
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-darwin";
  pleme.site.timeZone = "UTC";
  system.stateVersion = 6;
}
