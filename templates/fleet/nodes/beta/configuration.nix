{ lib, ... }: {
  networking.hostName = "beta";
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-darwin";
  pleme.site.selected = "utc";
  system.stateVersion = 6;
}
