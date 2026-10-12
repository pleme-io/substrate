# kata fleet repo

A private fleet-configuration repo cast from the pleme-io **kata** mold
(型, "the standard form"):

```sh
nix flake init -t github:pleme-io/substrate#fleet
```

## What lives here

| Surface | Path | What you fill in |
|---|---|---|
| The blanks | `fleet.nix` | name, domains, users, trust keys, nodes, apps, caches, secrets backend |
| Machine declarations | `lib/nodes.nix`, `lib/darwin-nodes.nix` | one entry per machine |
| Fleet stacks | `lib/node-layers.nix` | the ordered module lists a class of machine takes |
| Machines | `nodes/<host>/` | `layers.nix`, `default.nix`, `configuration.nix`, hardware |
| Typed surfaces | `modules/pleme/{shared,nixos,darwin}` | options + one renderer per platform |
| Profiles | `profiles/*.nix` | thin enable-flips over vocabulary modules |
| Proofs | `parts/*.nix` | one proof per renderer |
| Secrets | `secrets.yaml`, `.sops.yaml` | SOPS/age |

Everything else comes from the vocabulary:

```
fleet.nix (this repo, private)        <- you
  kata     (substrate/lib/kata)       <- fleet shape: mkFleet, mkNodeDeclarer, selectNodeLayers
    iroha  (substrate/lib/iroha)      <- composition alphabet
      blackmatter (pleme-io/*)        <- component behaviour
        nixpkgs module system
```

## Proof

`nix flake check` runs the fleet invariants and one proof per renderer. CI runs
the same through `.github/workflows/checks.yml`. The rules are `kijun rules`.
