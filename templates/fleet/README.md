# kata fleet repo

A private fleet-configuration repo cast from the pleme-io **kata** mold
(型 — "the standard form"). Instantiated with:

```sh
nix flake init -t github:pleme-io/substrate#fleet
```

## What lives here (and ONLY here)

| Surface | File | What you fill in |
|---|---|---|
| The blanks | `fleet.nix` | name, domains, users, trust keys, nodes, apps, caches, secrets backend |
| Profiles | `profiles/*.nix` | thin enable-flips over vocabulary modules |
| Node hardware | `nodes/<host>/` | hardware-configuration.nix, disk layout |
| Secrets | `secrets.yaml` | SOPS/age encrypted |

Everything else — option surfaces, package modules, daemons, overlays,
manifests, host assembly, deploy data, checks — comes from the vocabulary:

```
fleet.nix (this repo, private)        <- you
  kata     (substrate/lib/kata)       <- fleet shape: mkFleet, domains, users, the blanks schema
    iroha  (substrate/lib/iroha)      <- composition alphabet: 19 letters
      blackmatter (pleme-io/*)        <- component behavior
        nixpkgs module system
```

## Proof

`nix flake check` runs the fleet invariant suite (domains/users/manifest/
host cross-checks). A schema typo in `fleet.nix` fails evaluation with a
named error — unknown keys are rejected, never ignored.

## Rules

1. Never write behavior modules here. Extend the vocabulary, then consume it.
2. Every host is one `nodes.<name>` entry + one hardware dir.
3. Every app is one `apps.<name>` manifest entry.
4. Secrets only through the declared backend; no plaintext, ever.
