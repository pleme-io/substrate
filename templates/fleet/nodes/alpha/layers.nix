{ inputs, lib }: {
  base = [
    ./configuration.nix
    ./hardware-configuration.nix
  ];
  server = [ ../../profiles/server-base.nix ];
}
