# fleet.nix — THE BLANKS.
#
# This file is the ENTIRE fleet-specific surface (plus per-node hardware
# files under nodes/ and your encrypted secrets file). It is validated
# against kata's strict typed schema (substrate/lib/kata/fleet-config.nix)
# — unknown keys and type errors fail evaluation with a named error.
#
# Everything behavioral comes from the vocabulary: kata (fleet shape) ->
# iroha (composition alphabet) -> blackmatter (components). If you are
# writing a module in THIS repo, stop — extend the vocabulary instead.
{
  name = "example";

  # ── DNS / reachability ────────────────────────────────────────────────
  domains = {
    tld = "example.org";
    locations = {
      # host -> primary sub-zone: <host>.<location>.<tld>
      alpha = "home";
    };
    transports = [ ]; # e.g. [ "tailscale" ] for <host>.tailscale.<tld>
    sshUsers = { }; # host -> ssh login user (else defaultSshUser)
    defaultSshUser = "admin";
  };

  # ── People + accounts ─────────────────────────────────────────────────
  users.users = {
    admin = {
      kind = "interactive";
      uid = 1000;
    };
    automation = {
      kind = "automation";
      uid = 990;
    };
  };

  trust = {
    # SSH public keys trusted fleet-wide (interactive accounts).
    fleetKeys = [
      # "ssh-ed25519 AAAA... admin@example"
    ];
    # Keys for headless deploy/CI accounts.
    automationKeys = [ ];
  };

  # ── Machines ──────────────────────────────────────────────────────────
  nodes = {
    alpha = {
      class = "nixos";
      system = "x86_64-linux";
      tags = [ "server" ];
      profiles = [ "server-base" ];
      deploy = { }; # deploy-rs by default; null = local-only
    };
  };

  # ── Apps (iroha.mkManifest ecosystem schema) ──────────────────────────
  # One entry per fleet app: drives module imports + overlay registration
  # + profile enables. See substrate/lib/iroha/manifest.nix.
  apps = { };
  appClasses = { };

  # ── Binary caches ─────────────────────────────────────────────────────
  caches = [
    # { url = "https://cache.example.org"; publicKey = "cache.example.org-1:..."; }
  ];

  # ── Secrets ───────────────────────────────────────────────────────────
  secrets = {
    backend = "sops";
    # defaultSopsFile = ./secrets.yaml;
    # ageKeyFile = "/var/lib/sops/age/keys.txt";
  };
}
