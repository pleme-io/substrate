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

  wireguard = {
    file = "wireguard.nix";
    tier = "kernel";
    maturity = "Working";
    since = "2026-06-13";
    description = "Per-node WireGuard projection over a typed link registry — both topologies (point-to-point + hub-and-spoke), 10 helpers (linksForNode/secretsForNode/k8sLinksForNode/tlsSansForNode/systemdDepsForNode/linkNamesForNode/hubForLink/isJitLink/addrFromCIDR/spokeAllowedIps). Same per-node shape regardless of topology; undeployable (unlocked-hub) links skipped.";
    subsumes = "nix repo lib/vpn.nix (promoted — the link registry was the only fleet-specific input, now a parameter; the nix repo's copy becomes a frozen parity oracle).";
    dependsOn = [ ];
    exports = [ "mkWireguardLinks" ];
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
    description = "mkFleet: one call from validated blanks to the complete fleet-repo output surface — domains + ssh-aliases + wireguard + users module + app manifest + host matrix (nixos/darwin configurations, deploy data) + aggregated cross-checked invariants + buildable check. The fleet primitive STANDS ON the lib letters: ssh-aliases derives from domains, wireguard from the vpnLinks blank — composed for free.";
    subsumes = "The hand-assembled glue between lib/nodes.nix, lib/hm-modules.nix, darwinConfigurations/default.nix, lib/deploy.nix, lib/ssh-aliases.nix, lib/vpn.nix, and the profile imports in the nix repo (consumed via iroha.mkHostMatrix/mkManifest).";
    dependsOn = [
      "domains"
      "ssh-aliases"
      "wireguard"
      "users"
      "fleet-config"
    ];
    exports = [ "mkFleet" ];
  };

  kubeconfig = {
    file = "kubeconfig.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-13";
    description = "Renders a per-cluster kubeconfig artifact (Nix attrset, apiVersion=v1/kind=Config) from typed cluster-access facts (token or clientCert auth, CA ref/data/insecure). Pure data: secret refs stay placeholders, materialized at the consumer. Deterministic (sorted).";
    subsumes = "The >=3x duplicated hand-typed kubeconfig YAML (fleet-rio-kubectl, fleet-pleme-dev-kubectl, darwin k3s-cluster.nix, nixos-k3s-server kubeconfig.nix).";
    dependsOn = [ ];
    exports = [ "mkKubeconfig" ];
  };

  secret-seed = {
    file = "secret-seed.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-13";
    description = "The sops-nix -> systemd-oneshot -> kubectl-apply Kubernetes Secret bootstrap pattern as one typed module factory: deterministic sops.secrets + an idempotent oneshot (create --dry-run=client -o yaml | apply -f -). Composes iroha.mkOptionSurface + core.tag.";
    subsumes = "The rio hand-rolled seed-grafana-admin/seed-grafana-oidc/seed-rio-cloudflare-credentials services + the copy-paste-documented pattern in nodes/rio/CLAUDE.md.";
    dependsOn = [ ];
    exports = [ "mkSecretSeed" ];
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
