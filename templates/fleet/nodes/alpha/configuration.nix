{ lib, ... }: {
  networking.hostName = "alpha";
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  pleme.site.selected = "utc";
  system.stateVersion = "26.05";
}
