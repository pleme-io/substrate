# Migrating an app to substrate's `module-trio` macro

> **★★★ CSE / Knowable Construction.** This guide is the canonical
> playbook for porting a hand-rolled `module/default.nix` to the
> trio macro. Methodology spec:
> [`pleme-io/theory/CONSTRUCTIVE-SUBSTRATE-ENGINEERING.md`](https://github.com/pleme-io/theory/blob/main/CONSTRUCTIVE-SUBSTRATE-ENGINEERING.md).

The trio macro at `substrate/lib/module-trio.nix` consumes a single
typed spec and emits all three of `nixosModule`, `darwinModule`,
`homeManagerModule`. Migrating an app to this macro typically:

- collapses ~230 lines of hand-rolled module code into ~120 lines of
  declarative typed spec inside `flake.nix`
- eliminates the standalone `module/default.nix` directory entirely
- centralizes the YAML-config / launchd / systemd boilerplate inside
  the substrate (one fix everywhere instead of one fix per app)

The first three reference migrations:

| App      | Commit       | Demonstrates                                          |
|----------|--------------|--------------------------------------------------------|
| kekkai   | `2fc3c84`    | Standard template — typed groups, withUserDaemon, withShikumiConfig |
| hikki    | `ec91444`    | Enum-typed fields + custom daemon gate (`sync.enable`) |
| shashin  | `4bf9f53`    | Bare-binary daemon + `processType = "Interactive"` via extraHmConfigFn |

Bucket-E candidates pending (per the original migration audit):
shirase, mamorigami, ayatsuri, alicerce, arnes, kura, hikyaku, kagi
(if any not yet migrated). Each follows one of the three templates
with minor adaptations.

---

## Required substrate state

The trio + extensions need to be at substrate `1f61f45` or later.
Bump the consumer's `flake.lock`:

```bash
cd ~/code/github/pleme-io/<repo>
NIX_CONFIG="access-tokens = github.com=$(cat ~/.config/github/drzln/token)" \
  nix flake update substrate --refresh
```

Substrate features used by the trio:
- `module-trio.nix` with `shikumiTypedGroups`, `extraHmConfigFn`,
  `extraHmOptions` (commit `0553227`)
- Type-alias dictionary (`int|str|bool|float|path|nullOrStr|listOfStr|...`)
  in `resolveFieldType` (commit `1f61f45`)

---

## Procedure

### 1. Read the existing module

```bash
cat ~/code/github/pleme-io/<repo>/module/default.nix
cat ~/code/github/pleme-io/<repo>/flake.nix
```

Identify:
- **Option namespace** — `programs.<name>` vs `services.<name>` vs
  `blackmatter.components.<name>`. Set `hmNamespace` accordingly.
- **Typed groups** — nested attrsets whose fields have `mkOption`
  declarations. Each becomes a `shikumiTypedGroups.<group>` entry.
- **YAML emission** — does the module write
  `xdg.configFile."<name>/<name>.yaml"`? If yes, set
  `withShikumiConfig = true`. The trio's renderer takes
  `services.<name>.settings` and emits the YAML; typed groups feed
  into that automatically.
- **Daemon** — what subcommand does it run? What's the gate
  (`cfg.daemon.enable`, `cfg.sync.enable`, unconditional)? What's the
  `processType` (Adaptive / Background / Interactive)?
- **Bespoke fields** — anything outside the typed groups: top-level
  options (e.g. `favorites` list, `extraSettings` attrs), nullable
  fields, custom validators.

### 2. Write the new `flake.nix`

Use this skeleton (kekkai is the canonical model):

```nix
(import "${substrate}/lib/rust-tool-release-flake.nix" {
  inherit nixpkgs crate2nix flake-utils;
}) {
  toolName = "<name>";
  src = self;
  repo = "pleme-io/<name>";

  module = {
    description = "...";
    hmNamespace = "blackmatter.components";   # or "programs" / "services"

    # Daemon. Two patterns:
    #   (a) trio's withUserDaemon — fits when subcommand exists +
    #       gate is `cfg.daemon.enable` + processType = Adaptive
    withUserDaemon = true;
    userDaemonSubcommand = "daemon";
    #   (b) custom — wire via extraHmConfigFn (see hikki / shashin)
    #       when gate or processType differ

    # Shikumi YAML config at ~/.config/<name>/<name>.yaml.
    withShikumiConfig = true;

    shikumiTypedGroups = {
      <group1> = {
        <field> = { type = "<alias>"; default = ...; description = "..."; };
      };
      # Repeat per group from the legacy module
    };

    # Top-level options that don't fit a group.
    extraHmOptions = {
      extraSettings = nixpkgs.lib.mkOption {
        type = nixpkgs.lib.types.attrs;
        default = { };
        description = "...";
      };
    };

    # Bespoke config (custom daemons, activation hooks, escape-hatch
    # YAML merging).
    extraHmConfigFn = { cfg, pkgs, lib, config, ... }: { ... };
  };
}
```

### 3. Type-alias dictionary

For `shikumiTypedGroups.<group>.<field>.type`, the trio supports:

| Alias            | Equivalent                          |
|------------------|--------------------------------------|
| `"int"`          | `types.int`                          |
| `"str"`          | `types.str`                          |
| `"bool"`         | `types.bool`                         |
| `"float"`        | `types.float`                        |
| `"path"`         | `types.path`                         |
| `"nullOrStr"`    | `types.nullOr types.str`             |
| `"nullOrInt"`    | `types.nullOr types.int`             |
| `"nullOrBool"`   | `types.nullOr types.bool`            |
| `"nullOrPath"`   | `types.nullOr types.path`            |
| `"listOfStr"`    | `types.listOf types.str`             |
| `"listOfInt"`    | `types.listOf types.int`             |
| `"listOfBool"`   | `types.listOf types.bool`            |
| `"listOfPath"`   | `types.listOf types.path`            |
| `"attrsOfStr"`   | `types.attrsOf types.str`            |
| `"attrsOfInt"`   | `types.attrsOf types.int`            |
| `"attrsOfBool"`  | `types.attrsOf types.bool`           |
| `"attrs"`        | `types.attrs`                        |
| `"intRange"`     | `types.ints.between min max`         |

For anything else (e.g. enums, complex submodules, custom validators),
pass the raw `nixpkgs.lib.types.*` expression as `field.type`:

```nix
format = {
  type = nixpkgs.lib.types.enum [ "markdown" "asciidoc" ];
  default = "markdown";
  description = "Note format.";
};
```

### 4. Custom daemon wiring (extraHmConfigFn)

Use this when:
- The daemon gate isn't `cfg.daemon.enable` (e.g. `cfg.sync.enable`)
- The daemon has no subcommand (bare binary)
- `processType` isn't the trio default (`Adaptive`)
- Multiple daemons or activation hooks needed

Pattern (from hikki / shashin):

```nix
extraHmConfigFn = { cfg, pkgs, lib, config, ... }:
  let
    hmHelpers = import "${substrate}/lib/hm/service-helpers.nix" {
      inherit lib;
    };
    isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
    logDir =
      if isDarwin then "${config.home.homeDirectory}/Library/Logs"
      else "${config.home.homeDirectory}/.local/share/<name>/logs";
  in lib.mkMerge [
    {
      home.activation.<name>-log-dir =
        lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          run mkdir -p "${logDir}"
        '';
    }

    (lib.mkIf (cfg.<gate> && isDarwin)
      (hmHelpers.mkLaunchdService {
        name = "<name>";
        label = "io.pleme.<name>";
        command = "${cfg.package}/bin/<name>";
        args = [ ... ];
        logDir = logDir;
        processType = "Interactive";  # or Background / Adaptive
        keepAlive = true;
      }))

    (lib.mkIf (cfg.<gate> && !isDarwin)
      (hmHelpers.mkSystemdService {
        name = "<name>";
        description = "<name> daemon";
        command = "${cfg.package}/bin/<name>";
        args = [ ... ];
      }))
  ];
```

### 5. Delete the legacy module

```bash
cd ~/code/github/pleme-io/<repo>
rm -rf module
```

### 6. Verify

```bash
NIX_CONFIG="access-tokens = github.com=$(cat ~/.config/github/drzln/token)" \
  nix eval .#homeManagerModules.default --apply 'm: builtins.typeOf m'
# Should print: "lambda"

NIX_CONFIG="access-tokens = github.com=$(cat ~/.config/github/drzln/token)" \
  nix eval --impure --expr '
    let
      f = builtins.getFlake "git+file:///Users/drzzln/code/github/pleme-io/<repo>";
      pkgs = import <nixpkgs> { system = "aarch64-darwin"; };
      mod = f.homeManagerModules.default { lib = pkgs.lib; pkgs = pkgs; config = { home.homeDirectory = "/x"; }; };
    in builtins.attrNames (mod.options.<namespace>.<name> or {})
  '
# Should list every option from the legacy module — drop-in compat.
```

### 7. Commit + push

```bash
git add -A
git commit -m "<repo>: migrate to substrate module-trio + shikumiTypedGroups"
NIX_CONFIG="access-tokens = github.com=$(cat ~/.config/github/drzln/token)" \
  git push origin main
```

---

## Common pitfalls

### "option already declared"
The blackmatter aggregator at `pleme-io/blackmatter/flake.nix:300-326`
imports several apps' HM modules transitively (namimado, repo-forge,
blackmatter-cli, arnes, tatara-lisp). If you ALSO add the same app to
the consumer's inline `home-manager.sharedModules` list, the option
is declared twice. Fix: don't add aggregator-imported apps to inline
lists.

### YAML field order / casing
`shikumiTypedGroups` uses field names as-is for the YAML key. Pick
snake_case in the spec (matches the wire format directly). Don't
rely on automatic case conversion — there isn't any.

### `with lib;` boilerplate
You don't need `with lib;` in the consumer flake. The trio handles
type resolution via `resolveFieldType`. The few places you DO need
`lib` (extraHmOptions custom mkOption, raw enum types) — reach for
`nixpkgs.lib.*` directly. Keeps the spec data-shaped.

### Aggregator vs ecosystem-manifest enable
Adding a manifest entry in `pleme-io/nix/lib/ecosystem.nix` flips
`<hmNamespace>.<name>.enable = true` via the per-profile
`enableConfigForProfile` consumer. If your migrated app should be
auto-enabled fleet-wide, add it to the manifest with the appropriate
`class`. If it's only enabled per-node, leave the manifest alone.

---

## Compounding wins per migration

Each successful bucket-E migration:
- Drops one app's hand-rolled module/default.nix (~200-300 lines)
- Reduces flake.nix to declarative typed-data (no imperative logic)
- Centralizes the YAML serialization, daemon wiring, and option
  declarations in substrate (where they're maintained once)
- Adds the app to the typed manifest's reach (auto-enable, audit,
  render)
- Lifts the cse-lint `module-trio-adoption` count by 1

After all bucket-E migrations: substrate's module-trio absorbs
the entire fleet's app surface. A new app is one entry in
`ecosystem.nix` + one `module = { ... }` spec in flake.nix. No
hand-rolled options, no hand-rolled YAML, no hand-rolled daemon.
