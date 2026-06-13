# kata (型) — the pleme-io fleet-standard layer

The mold a fleet repo is cast from. kata sits **above the iroha alphabet**
(`substrate/lib/iroha`): iroha owns composition mechanics (option surfaces,
modules, overlays, manifests, host matrices); kata owns the **shape of a
fleet** — the typed blanks contract, the fleet registries, and the one-call
assembly. A private fleet repo is exactly:

> one `kata.fleet` config value + node hardware files + a secrets file.

Everything behavioral comes from the vocabulary:

```
fleet.nix blanks (private repo)            <- you fill these in
  kata   (substrate/lib/kata)              <- fleet shape: this layer
    iroha (substrate/lib/iroha)            <- composition alphabet (19 letters)
      blackmatter (pleme-io/*)             <- component behavior
        nixpkgs module system
```

Instantiate a new fleet repo:

```sh
nix flake init -t github:pleme-io/substrate#fleet
```

## Letters

Pure `{ lib }` — zero pkgs at import. Self-described by `catalog.nix`
(bijection / acyclic dependsOn / maturity partition are test-enforced);
every letter ships `tests/<letter>.nix` in the same commit. The aggregate
is `(import ./tests { inherit lib; })` and `checks.<system>.kata` builds it.

| Letter | Exports | Purpose |
|---|---|---|
| `domains` | `mkDomains` | Typed fleet-DNS: host → primary FQDN at its location sub-zone + transport-overlay FQDNs; ssh-user registry; invariants. |
| `ssh-aliases` | `mkSshAliases` | ssh_config Host entries from a fleet domains value — four identities per node (bare MagicDNS, `.local` mDNS, primary FQDN, transport FQDNs). Pairs with `mkDomains`. |
| `wireguard` | `mkWireguardLinks` | Per-node WireGuard projection over a link registry — both topologies (point-to-point + hub-and-spoke), 10 helpers (linksForNode / secretsForNode / k8sLinksForNode / tlsSansForNode / systemdDepsForNode / linkNamesForNode / hubForLink / isJitLink / addrFromCIDR / spokeAllowedIps). Undeployable (unlocked-hub) links are skipped. |
| `users` | `mkUsers` | Typed user registry → NixOS users module: interactive/automation kinds, canonical UIDs, authorized keys, per-user identity secrets, automation sshd hardening, idempotent UID-drift migration. |
| `fleet-config` | `fleetConfigModule`, `validateFleet` | **THE BLANKS** — the strict typed schema a fleet repo fills in (name, domains, users, trust, nodes, apps, caches, vpnLinks, secrets backend). Unknown keys are rejected: a typo fails at validation, never silently. |
| `fleet` | `mkFleet` | One call from validated blanks to the complete fleet-repo surface. **Stands on the letters**: domains → ssh-aliases, vpnLinks → wireguard, composed for free. Emits nixos/darwin configurations + deploy data + a cross-checked invariant suite + a buildable check + a `report`. |

## `mkFleet` result

```
mkFleet { config, universes, profiles, ... } -> {
  config         # the validated blanks
  domains        # mkDomains result
  sshAliases     # mkSshAliases over the fleet domains (full set)
  sshAliasesFor  # node -> mkSshAliases skipping that node (self)
  wireguard      # mkWireguardLinks over config.vpnLinks, or null
  users          # mkUsers result (keys threaded from trust.*)
  manifest       # iroha.mkManifest result | null
  hostMatrix     # iroha.mkHostMatrix result
  nixosConfigurations / darwinConfigurations / deployRs / colmena / byTag / registry
  report         # pure-data whole-fleet summary (one query over every letter)
  invariants     # aggregated, cross-checked (incl. wireguard-nodes-are-fleet-hosts)
  checksFor      # pkgs -> { "kata-fleet-<name>" = drv; }
}
```

`nix eval .#fleetReport --json | jq` surfaces every host's
class/system/tags/fqdn/allFqdns/sshUser/deploys/profiles/wireguardLinks.

## The farm-out pattern (how generic behavior reaches the vocabulary)

A generic nix-repo library becomes a kata letter the same way every time —
parity-gated, with the local copy frozen as an oracle (the same pattern as
the blackmatter-component-flake swallow):

1. **Promote** the generic `{ args }` engine to `kata.<letter>` (pure
   `{ lib }`), add `tests/<letter>.nix` + a `catalog.nix` entry.
2. **Repoint** consumers from `import ../lib/<x>.nix { args }` to
   `inputs.substrate.kata.<fn> { args }` (`inputs` is always in scope —
   NixOS HM via `extraSpecialArgs`, Darwin via `specialArgs`).
3. **Freeze** the local copy as `<x>-oracle.nix` (or an in-place
   frozen-oracle header).
4. **Gate** it: a `parts/kata.nix` check asserting `kata.<fn> == oracle`
   on the live fleet, forever — the vocabulary engine can never drift.

Landed this way: `domains`, `ssh-aliases`, `wireguard` (the nix repo's
`lib/fleet-domains.nix`, `lib/ssh-aliases.nix`, `lib/vpn.nix`).

## Adding a letter

Half-done until its `catalog.nix` entry lands — the bijection test fails
otherwise. Ship the `.nix` + `tests/<letter>.nix` + the catalog entry in
one commit; wire it into `default.nix` and `tests/default.nix`.
