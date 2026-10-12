# Fleet docs

Operator-facing notes for this fleet: runbooks, decisions, measurements. The
structure of the repo is stated once, in `CLAUDE.md`; the standard it follows is
`kijun rules`.

## Adding a machine

1. Add its blank to `fleet.nix` `nodes` (class, system, tags, `profiles = [ "node/<n>" ]`).
2. Add one `mkNode` (NixOS) or `mkDarwinNode` (darwin) entry to `lib/nodes.nix` or
   `lib/darwin-nodes.nix`.
3. Create `nodes/<n>/` with `default.nix` (the selection), `layers.nix` (the
   catalogue, `base` first) and `configuration.nix` (hostname, platform), plus
   `hardware-configuration.nix` for a NixOS machine.
4. `nix flake check`.
