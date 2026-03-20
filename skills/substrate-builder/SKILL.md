---
name: substrate-builder
description: Build patterns in substrate -- find the right builder, add new ones, follow the import DAG
domain: nix
triggers:
  - substrate
  - builder
  - flake input
  - build pattern
  - nix build
  - mkCrate2nix
  - mkGoTool
  - devShell
  - overlay
---

# Substrate Builder Skill

Substrate is a library of parameterized Nix functions at
`~/code/github/pleme-io/substrate/`. It produces no packages of its own --
consumers import it and call its builders.

## Module Hierarchy

```
lib/
  build/          Language build patterns (rust/, go/, zig/, swift/, typescript/,
                  ruby/, python/, dotnet/, java/, wasm/, web/)
  infra/          IaC patterns (pangea, terraform, pulumi, ansible)
  service/        Service lifecycle (deploy, helm, migration, health)
  hm/             home-manager helpers (standalone, only needs nixpkgs.lib)
  codegen/        Code generation (OpenAPI SDKs, source registry)
  util/           Foundation layer (config, darwin, docker, test, release)
  devenv/         devenv.sh modules (standalone)
```

## Finding the Right Builder

### By language

| Language | Directory | Key builders |
|----------|-----------|-------------|
| Rust | `build/rust/` | `mkCrate2nixProject`, `mkCrate2nixServiceApps`, `mkCrate2nixTool`, rust-service.nix (high-level) |
| Go | `build/go/` | `mkGoTool`, `mkGoMonorepoSource`, `mkGoMonorepoBinary`, `mkGoGrpcService` |
| Zig | `build/zig/` | `mkZigToolRelease`, zig-tool-release-flake.nix |
| Swift | `build/swift/` | `mkSwiftOverlay`, sdk-helpers.nix |
| TypeScript | `build/typescript/` | `mkTypescriptToolAuto`, `mkTypescriptTool`, `mkTypescriptPackage` |
| Ruby | `build/ruby/` | `mkRubyDockerImage`, `mkRubyServiceApps`, ruby-gem-flake.nix |
| Python | `build/python/` | `mkPythonPackage`, `mkUvPythonPackage` |
| .NET | `build/dotnet/` | `mkDotnetPackage` |
| Java | `build/java/` | `mkJavaMavenPackage` |
| WASM | `build/wasm/` | `mkWasmBuild`, `mkWasmDockerImage` |
| Web | `build/web/` | `mkViteBuild`, `mkDream2nixBuild`, `mkNodeDockerImage` |

### By use case

| I want to... | Use this |
|--------------|----------|
| Build a Rust CLI tool | `build/rust/tool-release-flake.nix` or `mkCrate2nixTool` |
| Build a Rust service with Docker | `build/rust/service-flake.nix` or `mkCrate2nixServiceApps` |
| Build a Rust library | `build/rust/library.nix` |
| Build a Go CLI tool | `mkGoTool` |
| Build a Ruby gem | `build/ruby/gem-flake.nix` |
| Build Pangea infrastructure | `infra/pangea-infra-flake.nix` |
| Build a Terraform provider | `infra/terraform-provider.nix` |
| Build a Helm chart | `service/helm-build.nix` |
| Generate SDKs from OpenAPI | `codegen/openapi-sdk.nix` or `codegen/openapi-rust-sdk.nix` |
| Add HM service module | `hm/service-helpers.nix` |
| Add MCP server to agent | `hm/mcp-helpers.nix` |
| Deploy Claude Code skills | `hm/skill-helpers.nix` |

## Cross-Reference Rules (Import DAG)

These rules prevent circular imports. Violating them breaks evaluation.

```
ALLOWED:
  build/ ----> util/
  service/ --> build/ and util/
  infra/ ----> util/
  codegen/ --> util/

PROHIBITED:
  util/ -----> build/, service/, infra/       (would create cycles)
  build/ ----> service/, infra/               (build is lower layer)
  build/rust/ -> build/go/                    (cross-language forbidden)
  hm/ -------> anything internal              (standalone)
  devenv/ ---> anything internal              (standalone)
```

Within a language directory, files may import each other freely:
`build/rust/service.nix` can import `build/rust/overlay.nix`.

## Adding a New Builder -- Checklist

Full guide: `docs/adding-a-builder.md`

1. **Create the file**: `lib/build/{lang}/{pattern}.nix`
2. **Export from `lib/default.nix`**: Add import in `let` block, inherit in `rec`
3. **Create backward-compat shim** (if replacing old path):
   ```nix
   # lib/{lang}-{pattern}.nix
   # Shim -- moved to build/{lang}/{pattern}.nix
   import ./build/{lang}/{pattern}.nix
   ```
4. **Add devenv module** (optional): `lib/devenv/{lang}.nix`, register in
   `default.nix` devenvModulePaths and `flake.nix` devenvModules
5. **Add overlay** (if applicable): `lib/build/{lang}/overlay.nix`
6. **Add flake wrapper** (optional): `lib/build/{lang}/{pattern}-flake.nix`
7. **Update docs**: CLAUDE.md module hierarchy, docs/architecture.md, API tables

### Naming conventions

| Pattern | File | Export |
|---------|------|--------|
| Overlay | `overlay.nix` | `mk{Lang}Overlay` |
| CLI tool | `tool.nix` | `mk{Lang}Tool` |
| Library | `library.nix` | `mk{Lang}Library` |
| Service | `service.nix` | `mk{Lang}Service` |
| Flake wrapper | `{pattern}-flake.nix` | `{lang}{Pattern}FlakeBuilder` |
| Docker image | `docker.nix` | `mk{Lang}DockerImage` |

### Builder file structure

Every builder accepts dependencies and returns functions:

```nix
# lib/build/{lang}/{pattern}.nix
{ pkgs, ... }:
{
  mk{Lang}{Pattern} = { pname, version ? "0.0.0", src, ... }:
    pkgs.stdenv.mkDerivation {
      inherit pname version src;
      # ...
    };
}
```

## Backward Compat Shim Pattern

When moving a file, always create a two-line shim at the old location:

```nix
# Shim -- moved to build/{lang}/{pattern}.nix
import ./build/{lang}/{pattern}.nix
```

Rules:
- Never remove a shim (external consumers depend on old paths)
- New code should use new paths
- Shims forward all arguments transparently (Nix import is lazy, zero cost)
- The format is exactly two lines: comment + import

## Common Patterns

### Rust tool (standalone CLI binary)

```nix
# flake.nix
outputs = (import "${substrate}/lib/build/rust/tool-release-flake.nix" {
  inherit nixpkgs crate2nix flake-utils;
}) {
  toolName = "kindling";
  src = self;
  repo = "pleme-io/kindling";
};
```

### Rust service (binary + Docker + deploy apps)

```nix
let rustService = import "${substrate}/lib/build/rust/service.nix" {
  inherit system nixpkgs;
  nixLib = substrate;
  crate2nix = inputs.crate2nix;
  forge = inputs.forge.packages.${system}.forge;
};
in rustService {
  serviceName = "hanabi";
  src = ./.;
  productName = "nexus";
  registryBase = "ghcr.io/pleme-io";
}
# Returns: { packages, devShells, apps }
```

### Ruby gem

```nix
outputs = (import "${substrate}/lib/build/ruby/gem-flake.nix" {
  inherit nixpkgs ruby-nix flake-utils substrate forge;
}) { inherit self; name = "pangea-core"; };
```

### Pangea infrastructure

```nix
outputs = (import "${substrate}/lib/infra/pangea-infra-flake.nix" {
  inherit nixpkgs ruby-nix flake-utils substrate forge;
}) { inherit self; name = "my-infra"; };
# Produces: test, validate, plan, apply, destroy, verify, drift, regen apps
```

### TypeScript library

```nix
outputs = (import "${substrate}/lib/build/typescript/library-flake.nix" {
  inherit nixpkgs flake-utils substrate;
}) { inherit self; name = "@pleme/my-lib"; };
```

### Overlay application

```nix
pkgs = import nixpkgs {
  inherit system;
  overlays = [
    (substrateLib.mkRustOverlay { inherit fenix system; })
    (substrateLib.mkGoOverlay {})
    (substrateLib.mkZigOverlay {})
    (substrateLib.mkSwiftOverlay {})
  ];
};
```

### home-manager service

```nix
hmHelpers = import "${substrate}/lib/hm/service-helpers.nix" { lib = nixpkgs.lib; };
# Use hmHelpers.mkServiceConfig for launchd (macOS) + systemd (Linux)
```

## Conventions

- Edition 2024, Rust 1.89.0+, MIT, clippy pedantic for all Rust
- Use `mkShellNoCC` for dev shells (not `mkShell`)
- Always follow nixpkgs through: `inputs.substrate.inputs.nixpkgs.follows = "nixpkgs"`
- Supported systems: x86_64-linux, aarch64-linux, x86_64-darwin, aarch64-darwin
- flake-parts for monorepos, plain flake outputs for single-product repos
- All repos are PUBLIC on GitHub
