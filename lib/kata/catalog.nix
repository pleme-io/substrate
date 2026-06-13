# kata.catalog — CATALOG REFLECTION for the fleet-standard layer.
#
# kata (型 — "the form/mold"): the layer above the iroha alphabet that
# standardizes the SHAPE of a fleet repo. iroha owns how things compose;
# kata owns what a fleet IS: the typed blanks contract, the registries
# (domains, users), and the one-call assembly (mkFleet). A private fleet
# repo (the pleme-io/nix shape, or any new instantiation of the template)
# is exactly: one fleet-config value + node hardware files + a secrets
# file. Everything else is this vocabulary.
#
# Same laws as iroha's catalog: bijection with letter files, acyclic
# dependsOn, maturity partition — all test-enforced (tests/catalog.nix).
{ lib }:
{
  domains = {
    file = "domains.nix";
    tier = "kernel";
    maturity = "Working";
    since = "2026-06-12";
    description = "Typed fleet-DNS structure: host -> primary FQDN at its location sub-zone + transport-overlay FQDNs; ssh-user registry; invariants over the maps.";
    subsumes = "nix repo lib/fleet-domains.nix (promoted — it was already generic; lib/pleme-fleet.nix stays as the private argument set).";
    dependsOn = [ ];
    exports = [ "mkDomains" ];
  };

  ssh-aliases = {
    file = "ssh-aliases.nix";
    tier = "kernel";
    maturity = "Working";
    since = "2026-06-13";
    description = "ssh_config Host entries from a fleet domains value: four addressable identities per node (bare MagicDNS, .local mDNS, primary FQDN, transport FQDNs), shaped as blackmatter.components.ssh.extraHosts. Pairs with mkDomains.";
    subsumes = "nix repo lib/ssh-aliases.nix (promoted — it was already generic; the nix repo's copy becomes a frozen parity oracle).";
    dependsOn = [ ];
    exports = [ "mkSshAliases" ];
  };

  users = {
    file = "users.nix";
    tier = "kernel";
    maturity = "Working";
    since = "2026-06-12";
    description = "Typed fleet user registry -> NixOS users module: interactive/automation kinds, canonical UIDs, authorized keys, per-user ssh identity secrets, automation sshd hardening, idempotent UID-drift migration.";
    subsumes = "nix repo lib/fleet-users.nix (the factory generalized — its hard-coded drzzln/luis/automation registry becomes the argument).";
    dependsOn = [ ];
    exports = [ "mkUsers" ];
  };

  fleet-config = {
    file = "fleet-config.nix";
    tier = "kernel";
    maturity = "Working";
    since = "2026-06-12";
    description = "THE BLANKS: the strict typed schema a private fleet repo fills in (name, domains, users, trust, nodes, apps, caches, secrets backend). Unknown keys rejected — a typo fails at validation, never silently.";
    subsumes = "The implicit, undocumented contract scattered across the nix repo's lib/*.nix registries.";
    dependsOn = [ ];
    exports = [ "fleetConfigModule" "validateFleet" ];
  };

  fleet = {
    file = "fleet.nix";
    tier = "kernel";
    maturity = "Working";
    since = "2026-06-12";
    description = "mkFleet: one call from validated blanks to the complete fleet-repo output surface — domains + users module + app manifest + host matrix (nixos/darwin configurations, deploy data) + aggregated cross-checked invariants + buildable check.";
    subsumes = "The hand-assembled glue between lib/nodes.nix, lib/hm-modules.nix, darwinConfigurations/default.nix, lib/deploy.nix, and the profile imports in the nix repo (consumed via iroha.mkHostMatrix/mkManifest).";
    dependsOn = [
      "domains"
      "users"
      "fleet-config"
    ];
    exports = [ "mkFleet" ];
  };

  catalog = {
    file = "catalog.nix";
    tier = "kernel";
    maturity = "Working";
    since = "2026-06-12";
    description = "This file: kata's self-description; bijection/DAG/partition test-enforced.";
    subsumes = "Doc drift between code and description surfaces.";
    dependsOn = [ ];
    exports = [ "catalog" ];
  };
}
