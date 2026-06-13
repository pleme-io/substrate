# server-base — example profile. Profiles in a fleet repo should be THIN:
# enable-flips + settings over vocabulary modules (blackmatter components,
# kata/iroha-built behavior), pinned to a priority axis. Behavior that
# wants to live here belongs in the vocabulary instead.
{ lib, ... }:
{
  services.openssh.enable = lib.mkDefault true;
  networking.firewall.enable = lib.mkDefault true;
}
