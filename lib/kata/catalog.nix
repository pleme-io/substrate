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

  orgs = {
    file = "orgs.nix";
    tier = "kernel";
    maturity = "Working";
    since = "2026-08-03";
    description = "One typed declaration per code org -> the five faces a workstation renders it into: the tend workspace (clone + reconcile), the CLAUDE.md org table entry, the zoekt source, the codesearch source, and the `use_tend` .envrc. zoekt and codesearch read ONE returned list, so the copy-pasted source pairs that used to drift cannot be written. Per-org tend extras (`watch`, `flakeDeps`, `extraConfig`) are typed attrsets serialized with toJSON, not indented YAML spliced into a string. `sync`/`index` make an opt-out a visible field instead of an invisible omission; `kind`/`cloneMethod` throw on an unknown value, because an unknown kind would enumerate nothing and report success.";
    subsumes = "the hand-written org fan-out: blackmatter-pleme's plemeWorkspaceYaml + extraTendWorkspaces (types.lines) seam, blackmatter-akeyless's duplicated zoekt/codesearch source pair, and the byte-identical drzln/binti-family blocks in nix nodes cid and ryn.";
    dependsOn = [ ];
    exports = [ "mkOrgs" ];
  };

  users = {
    file = "users.nix";
    tier = "kernel";
    maturity = "Working";
    since = "2026-06-12";
    description = "The typed pleme-io user-management surface: one declaration per person -> a NixOS account (fleet-wide `module` OR per-node `mkUserModule`/`scopedModuleForNode` scoping via `nodes`), interactive/automation kinds, canonical UIDs, inbound authorized keys + the per-user `<name>@fleet` outbound key (`fleetKey`) + its SOPS private-key path (`identitySecret`), the SOPS age recipient (`ageRecipient`), the git identity (`git`), automation sshd hardening, idempotent UID-drift migration (fleet-wide only), and an `onboarding` descriptor the tooling reads to drive key generation + secret registration.";
    subsumes = "nix repo lib/fleet-users.nix in full — its hard-coded drzzln/luis/automation registry, the per-node mkInteractiveUser factory, and the scattered ssh/sops/git/scoping wiring all become this one argument-driven engine.";
    dependsOn = [ ];
    exports = [ "mkUsers" ];
  };

  fleet-config = {
    file = "fleet-config.nix";
    tier = "kernel";
    maturity = "Working";
    since = "2026-06-12";
    description = "THE BLANKS: the strict typed schema a private fleet repo fills in (name, domains, users, trust, nodes, apps, caches, secrets backend). Per-node liveness is typed (status \"live\"|\"down\" + statusReason), never a magic tag — a retired node keeps its declaration and only leaves the deploy projections. Unknown keys rejected — a typo fails at validation, never silently.";
    subsumes = "The implicit, undocumented contract scattered across the nix repo's lib/*.nix registries.";
    dependsOn = [ ];
    exports = [
      "fleetConfigModule"
      "validateFleet"
    ];
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

  k8s-seed = {
    file = "k8s-seed.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-09-07";
    description = "The ONE systemd-oneshot shape every seed letter renders through: the enable-only option root, boot ordering, KUBECONFIG binding, restartTriggers, and (load-bearing) the REACHABLE bootstrap retry bound of 900s/60. Owns no apply verb — a seed kind supplies the script and any extra config. Refuses an empty script rather than emit a unit that reports success having reconciled nothing.";
    subsumes = "The unit half of secret-seed.nix, lifted rather than copied when manifest-seed became the second consumer — so the retry bound whose absence burned 10,857 restarts over 15 hours on rio is inherited by construction, not by an author remembering to reference it.";
    dependsOn = [ ];
    exports = [ "mkSeedUnit" ];
  };

  secret-seed = {
    file = "secret-seed.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-13";
    description = "The sops-nix -> systemd-oneshot -> kubectl-apply Kubernetes Secret bootstrap pattern as one typed module factory: deterministic sops.secrets + an idempotent oneshot (create --dry-run=client -o yaml | apply -f -). Owns the secret-specific half; the unit shape is kata.k8s-seed's.";
    subsumes = "The rio hand-rolled seed-grafana-admin/seed-grafana-oidc/seed-rio-cloudflare-credentials services + the copy-paste-documented pattern in nodes/rio/CLAUDE.md.";
    dependsOn = [ "k8s-seed" ];
    exports = [ "mkSecretSeed" ];
  };

  manifest-seed = {
    file = "manifest-seed.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-09-07";
    description = "A declared Kubernetes manifest reconciled onto a node's own cluster from nix, making the node's gitops loop the reconciler for a cluster that has no Flux: a committed manifest edit changes its store path, which re-runs the seed on the rebuild the loop performs. Server-side apply (the seed owns spec, a controller owns status); force-conflicts by default because the object being adopted was, by construction, hand-applied first. Waits on requireCrds so a CR landing before its CRD is a wait, not a 5-minute red.";
    subsumes = "Hand-applied manifests on a Flux-less cluster — measured 2026-09-07, the InfrastructureTemplate CR reconciling 1005 GitHub repositories existed only in an operator's shell history.";
    dependsOn = [ "k8s-seed" ];
    exports = [ "mkManifestSeed" ];
  };

  topology = {
    file = "topology.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-13";
    description = "Projects the fleet (domains + per-node metadata + networks + optional wireguard) into nix-topology-shaped pure data + derived edges + invariants, so the topology renderer reads the kata source of truth instead of a hand-redeclared mesh.";
    subsumes = "The nix repo parts/topology.nix inline node/network mesh (duplicating the kata registry).";
    dependsOn = [ "domains" ];
    exports = [ "mkTopology" ];
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
