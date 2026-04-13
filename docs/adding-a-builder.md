# Adding a New Builder

Step-by-step guide for adding a new language or build pattern to substrate.

---

## 1. Create the Builder File

Place the new builder in the appropriate language directory under `lib/build/`:

```
lib/build/{lang}/{pattern}.nix
```

If the language directory does not exist yet, create it:

```bash
mkdir -p lib/build/{lang}
```

### Builder file structure

Every builder follows the same pattern -- a function that accepts dependencies
and returns a function or attribute set:

```nix
# lib/build/{lang}/{pattern}.nix
#
# {Lang} {Pattern} Builder
# Description of what this builder does.
#
# Usage:
#   result = mk{Lang}{Pattern} pkgs { pname = "..."; ... };
{
  pkgs,
  ...
}:
{
  # Public API
  mk{Lang}{Pattern} = {
    pname,
    version ? "0.0.0",
    src,
    ...
  }: pkgs.stdenv.mkDerivation {
    inherit pname version src;
    # ...
  };

  # Optional overlay factory
  mk{Lang}{Pattern}Overlay = mk{Lang}{Pattern}: final: prev: {
    ${pname} = mk{Lang}{Pattern} final { inherit pname version src; };
  };
}
```

### Naming conventions

| Pattern type | File name | Export name |
|-------------|-----------|-------------|
| Overlay | `overlay.nix` | `mk{Lang}Overlay` |
| CLI tool | `tool.nix` | `mk{Lang}Tool` |
| Library | `library.nix` | `mk{Lang}Library` |
| Service | `service.nix` | `mk{Lang}Service` |
| Flake wrapper | `{pattern}-flake.nix` | `{lang}{Pattern}FlakeBuilder` |
| Docker image | `docker.nix` | `mk{Lang}DockerImage` |
| Dev shell | `devenv.nix` | `mk{Lang}DevShell` |

---

## 2. Add to Root `default.nix`

Export the new builder from `lib/default.nix`. Follow the existing section
pattern with a header comment block:

```nix
# ============================================================================
# {LANG} {PATTERN} BUILDER (from {lang}-{pattern}.nix)
# ============================================================================
# Description of what the builder does.
#
# Usage:
#   result = substrateLib.mk{Lang}{Pattern} { ... };
inherit ((import ./{lang}-{pattern}.nix)) mk{Lang}{Pattern};
```

If the builder needs `pkgs` or other module-level dependencies, import it
in the `let` block at the top of `default.nix` and inherit from the module:

```nix
# In the let block:
{lang}{Pattern}Module = import ./{lang}-{pattern}.nix { inherit pkgs; };

# In the rec block:
inherit ({lang}{Pattern}Module) mk{Lang}{Pattern};
```

For standalone import paths (builders that consumers import directly),
also expose the file path:

```nix
{lang}{Pattern}Builder = ./{lang}-{pattern}.nix;
```

---

## 3. Create Backward-Compat Shim (if applicable)

If the builder replaces an existing file at the old flat path, create a
two-line shim at the old location:

```nix
# lib/{lang}-{pattern}.nix
# Shim -- moved to build/{lang}/{pattern}.nix
import ./build/{lang}/{pattern}.nix
```

**Rules:**
- The shim is exactly two lines: comment + import
- The comment format is: `# Shim -- moved to {new-path}`
- Never remove a shim -- external consumers depend on the old paths
- The shim forwards all arguments transparently (Nix import is lazy)

If this is a brand-new builder with no predecessor, no shim is needed.

---

## 4. Add Devenv Module (optional)

If the language needs a development environment module, create it in
`lib/devenv/`:

```nix
# lib/devenv/{lang}.nix
{ pkgs, lib, config, ... }:
{
  # devenv module options and config
  packages = with pkgs; [ ... ];
  languages.{lang}.enable = true;
}
```

And register it in the `devenvModulePaths` attrset in `default.nix`:

```nix
devenvModulePaths = {
  # ... existing entries ...
  {lang} = ./devenv/{lang}.nix;
};
```

Also add it to the `devenvModules` in `flake.nix`:

```nix
devenvModules = {
  # ... existing entries ...
  {lang} = ./lib/devenv/{lang}.nix;
};
```

---

## 5. Add Overlay (if applicable)

If the language needs a custom toolchain overlay, create `lib/build/{lang}/overlay.nix`:

```nix
# lib/build/{lang}/overlay.nix
{
  mk{Lang}Overlay = { version ? "X.Y.Z", ... }: final: prev: {
    {lang}Toolchain = ...;
  };
}
```

Export it from `default.nix`:

```nix
{lang}OverlayModule = import ./{lang}-overlay.nix;
inherit ({lang}OverlayModule) mk{Lang}Overlay;
{lang}Overlay = ./{lang}-overlay.nix;
```

---

## 6. Add Flake Wrapper (optional)

For patterns used by many repos, create a zero-boilerplate flake wrapper:

```nix
# lib/build/{lang}/{pattern}-flake.nix
{
  nixpkgs,
  substrate ? null,
  ...
}:
{
  self,
  name,
  ...
}: let
  systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
  eachSystem = f: nixpkgs.lib.genAttrs systems f;
in {
  packages = eachSystem (system: let
    pkgs = import nixpkgs { inherit system; };
    builder = import ./{pattern}.nix { inherit pkgs; };
  in {
    default = builder.mk{Lang}{Pattern} { inherit name; src = self; };
  });

  devShells = eachSystem (system: let
    pkgs = import nixpkgs { inherit system; };
  in {
    default = pkgs.mkShellNoCC { ... };
  });
}
```

Expose from `default.nix` and `flake.nix`:

```nix
# default.nix:
{lang}{Pattern}FlakeBuilder = ./{lang}-{pattern}-flake.nix;

# flake.nix:
{lang}{Pattern}FlakeBuilder = ./lib/{lang}-{pattern}-flake.nix;
```

---

## 7. Update Documentation

1. Add the builder to the module hierarchy in `CLAUDE.md`
2. Add it to the dependency graph in `docs/architecture.md`
3. Add an entry to the appropriate table in `CLAUDE.md` (Key Exports section)
4. If it is an infra pattern, update `docs/security.md` with required constraints

---

## 8. Test

Verify the builder works by creating a minimal consumer flake:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    substrate.url = "path:/Users/luis.d/code/github/pleme-io/substrate";
  };

  outputs = { nixpkgs, substrate, ... }: let
    system = "aarch64-darwin";
    substrateLib = substrate.lib.${system};
  in {
    packages.${system}.default = substrateLib.mk{Lang}{Pattern} {
      pname = "test-builder";
      src = ./.;
    };
  };
}
```

Run `nix build` to verify it evaluates and builds correctly.

---

## Checklist

- [ ] Created `lib/build/{lang}/{pattern}.nix`
- [ ] Exported from `lib/default.nix` (with header comment and usage example)
- [ ] Created backward-compat shim (if replacing old path)
- [ ] Added standalone import path as `*Builder` attribute (if applicable)
- [ ] Added devenv module (if applicable)
- [ ] Added overlay (if applicable)
- [ ] Added flake wrapper (if applicable)
- [ ] Updated `CLAUDE.md` module hierarchy
- [ ] Updated `docs/architecture.md`
- [ ] Tested with a minimal consumer flake
- [ ] Cross-reference rules respected (no cycles in import DAG)
- [ ] **Type assertions added** — import `../../types/assertions.nix` and add `check.all [...]` validating all parameters (nonEmptyStr for names, architecture for arch, namedPorts for ports, etc.)
- [ ] **BuildResult contract** — return shape includes `{ packages, devShells, apps }` (even if some are `{}`)
- [ ] For complex builders: create `{pattern}-module.nix` (typed options) + `{pattern}-typed.nix` (module-validated wrapper)

---

## Existing Languages

For reference, these language directories already exist under `lib/build/`:

| Directory | Builders |
|-----------|----------|
| `rust/` | overlay, library, service, service-flake, tool-release, tool-release-flake, devenv, crate2nix-builders, crate2nix-apps |
| `go/` | overlay, tool, monorepo, monorepo-binary, library-check, docker, grpc-service, bootstrap, toolchain |
| `zig/` | overlay, tool-release, tool-release-flake, bootstrap, deps, zls |
| `swift/` | overlay, bootstrap, sdk-helpers |
| `typescript/` | tool, library, library-flake |
| `ruby/` | config, build, gem, gem-flake |
| `python/` | package, uv |
| `dotnet/` | build |
| `java/` | maven |
| `wasm/` | build |
| `web/` | build, docker, github-action |
