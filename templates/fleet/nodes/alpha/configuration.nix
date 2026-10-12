{ lib, ... }: {
  networking.hostName = "alpha";
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  pleme.site.timeZone = "UTC";
  system.stateVersion = "26.05";
}
