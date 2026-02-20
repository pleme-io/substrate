# Substrate

Reusable Nix build patterns for Rust services, web apps, and deployment.

## Quick Start

Add as a flake input:

```nix
{
  inputs.substrate.url = "github:pleme-io/substrate";

  outputs = { substrate, ... }:
    let
      substrateLib = substrate.libFor {
        inherit pkgs system;
        forge = myForge; # deployment orchestrator (optional)
      };
    in {
      packages = substrateLib.mkPackages { ... };
      devShells.default = substrateLib.mkDevShell { ... };
      apps = substrateLib.mkCrate2nixServiceApps { ... };
    };
}
```

## Capabilities

- **Rust services** - crate2nix with per-crate caching, multi-arch Docker images (amd64/arm64)
- **Web apps** - dream2nix for NPM/Vite builds, Hanabi BFF server
- **WASM** - Yew/Rust WASM with wasm-bindgen + wasm-opt
- **TypeScript tools** - pleme-linker for Nix-native TS packaging
- **Ruby builds** - bundix/bundler with Docker images
- **Docker images** - multi-arch, minimal, reproducible via `dockerTools.buildLayeredImage`
- **Deployment** - build/push/deploy/release workflows via forge
- **Dev shells** - pre-configured with all tooling
- **CI checks** - clippy, rustfmt, tests

## API Reference

### Rust Services

| Function | Description |
|---|---|
| `mkCrate2nixProject` | Build Rust project with per-crate caching |
| `mkCrate2nixDockerImage` | Multi-arch Docker image (musl static linking) |
| `mkCrate2nixServiceApps` | Complete app set: build, push, deploy, release, test, lint, fmt |
| `mkCrate2nixTestImage` | Test runner image for CI (Kenshi TestGates) |
| `mkRustTestImage` | Standalone test image |
| `mkCrate2nixTool` | Build standalone Rust CLI tools |

### Web

| Function | Description |
|---|---|
| `mkDream2nixBuild` | Build NPM project with dream2nix (automatic dependency resolution) |
| `mkViteBuild` | Build Vite/React app with `buildNpmPackage` |
| `mkNodeDockerImage` | Docker image for web apps (Hanabi server) |
| `mkWebDeploymentApps` | Build/push/deploy/release apps for web |
| `mkWebDevShell` | Web development shell with Node, Playwright, Docker |
| `mkWebLocalApps` | Local Docker testing apps |

### WASM

| Function | Description |
|---|---|
| `mkWasmBuild` | Build Yew/WASM apps with wasm-bindgen + wasm-opt |
| `mkWasmDockerImage` | WASM Docker image (nginx) |
| `mkWasmDockerImageWithHanabi` | WASM Docker image (Hanabi) |
| `mkWasmDevShell` | WASM development shell |

### Overlays

| Function | Description |
|---|---|
| `mkRustOverlay` | Fenix stable overlay for `buildRustCrate` (crate2nix compat) |
| `getRustToolchain` | Get fenix stable toolchain directly |

### Deployment

| Function | Description |
|---|---|
| `mkServiceApps` | Staging deployment apps (build/push/deploy/release/rollout) |
| `mkEnvironmentServiceApps` | Staging + production with safety confirmations |
| `mkEnvironmentWebDeploymentApps` | Web deployment with environment support |
| `mkImagePushApp` | Reusable image push helper |
| `mkMigrationJob` | Kubernetes migration Job manifest |
| `mkComprehensiveReleaseApp` | Full release with testing |

### Development

| Function | Description |
|---|---|
| `mkDevShell` | Rust development shell with all tooling |
| `mkChecks` | CI checks (clippy, fmt, tests) |
| `mkTestRunners` | Unit + integration test runners |
| `mkDockerComposeConfig` | PostgreSQL + Redis test stack |
| `mkPackages` | Standard package outputs |

### TypeScript

| Function | Description |
|---|---|
| `mkTypescriptToolAuto` | Auto-discover TS tool from package.json |
| `mkTypescriptTool` | Build TS CLI tool with pleme-linker |
| `mkTypescriptPackage` | Build TS library package |
| `mkPlemeLinker` | Build pleme-linker from source |

### Platform Services

| Function | Description |
|---|---|
| `mkPlatformService` | Complete platform service (binary + image + apps) |

### Ruby

| Function | Description |
|---|---|
| `mkRubyDockerImage` | Docker image for Ruby apps |
| `mkRubyServiceApps` | Full regen/push/release app set |

## High-Level Abstraction

For Rust services, `lib/rust-service.nix` provides a single-function interface:

```nix
let rustService = import "${substrate}/lib/rust-service.nix" {
  inherit system nixpkgs;
  nixLib = substrate;
  crate2nix = inputs.crate2nix;
  forge = inputs.forge.packages.${system}.forge;
};
in rustService {
  serviceName = "email";
  src = ./.;
  productName = "myapp";
  registryBase = "ghcr.io/myorg";
  enableAwsSdk = true;
}
# Returns: { packages, devShells, apps }
```

## Configuration

### Tokens

Set environment variables before running deployment commands:

```bash
export ATTIC_TOKEN="your-attic-jwt-token"
export GHCR_TOKEN="your-github-token"
```

For CI/CD, inject via Kubernetes secrets or GitHub Actions secrets.

### Forge

Forge is the deployment orchestrator. Pass it via `forge` parameter:

```nix
substrateLib = substrate.libFor {
  inherit pkgs system;
  forge = inputs.forge.packages.${system}.forge;
};
```

When `forge` is not provided, commands fall back to looking for `forge` on `$PATH`.

## License

MIT License - see [LICENSE](LICENSE) for details.
