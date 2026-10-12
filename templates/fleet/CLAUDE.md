# Fleet repo

A private Nix fleet repo cast from `substrate#fleet` (standard `fleet-repo`,
version 1). It holds configuration only: the fleet's blanks, its machines, its
secrets. Behaviour comes from the vocabulary (kata, iroha, blackmatter) as flake
inputs.

The standard's rules live in one place, the kijun rule registry: run
`kijun rules` for the list and `kijun check .` to hold this repo to it. Do not
restate a rule here; point at it. `kijun.b` declares the standard this repo is
held to (`fleet_repo(1)`) and is where its waivers go.

## Layers

```
modules/pleme (typed surfaces)  →  profiles/ (composed)  →  nodes/<n>/ (identity)
```

- `fleet.nix` is WHAT each machine is: `class`, `system`, `tags`, liveness. It is
  validated against kata's strict schema, so a typo fails evaluation.
- `lib/nodes.nix` and `lib/darwin-nodes.nix` are HOW each machine composes: one
  `mkNode` / `mkDarwinNode` entry per machine, through `kata.mkNodeDeclarer`.
  `system` and `tags` are read from the blank, never restated.
- `lib/node-layers.nix` holds the fleet's stacks: the ordered module lists a
  class of machine takes. Adding a machine picks a stack; it never writes one.
- `nodes/<n>/` is one directory per machine. `layers.nix` catalogues the
  machine's layers; `default.nix` only selects them through
  `kata.selectNodeLayers`; `configuration.nix` states the machine's own facts
  (hostname, platform). `base` is the machine itself and is always selected.
  Parking a role is removing its name from the selection; no file is deleted.
- `profiles/` are thin enable-flips over vocabulary modules.
- `modules/pleme/shared/<x>.nix` declares one concept through the module-trio
  factory (`inputs.substrate.moduleTrio.mkModuleTrio`, kind `binary`,
  `package`, `registry` or `service`), which gives it the same typed surface on
  the nixos, darwin and home-manager arms; an arm that cannot host it refuses
  with a typed reason. A registry concept names its renderers in
  `modules/pleme/{nixos,darwin}/<x>.nix`; `parts/<x>.nix` is its proof. The
  examples are `site` (registry), `tools` (package) and `hello` (binary); the
  law is `theory/MODULE-TRIO.md`. A concept a second fleet needs moves to the
  vocabulary.
- `parts/` wires the flake. Each renderer (`nixos`, `darwin`, `deploy`, every
  surface) has a proof under `checks`.
- Secrets go only through the backend `fleet.nix` declares (`sops`, recipients
  in `.sops.yaml`).

## Verbs

| Command | What |
|---|---|
| `nix flake check` | every renderer's proof plus the fleet invariants |
| `nix eval .#fleetReport --json` | one typed view of the whole fleet |
| `nix eval .#nixosConfigurations.<n>.config.kata.nodeLayers` | what a machine is made of |
