# Migration Guide

Moving from the old flat `lib/` layout to the new categorized module structure.

---

## What Changed

The `lib/` directory was reorganized from a flat layout:

```
lib/
├── default.nix
├── rust-overlay.nix
├── rust-service.nix
├── go-tool.nix
├── config.nix
├── service-helpers.nix
├── hm-service-helpers.nix
├── ...
└── (50+ files at one level)
```

Into a categorized hierarchy:

```
lib/
├── default.nix                 # Root aggregation (unchanged API)
├── build/
│   ├── rust/overlay.nix        # was: rust-overlay.nix
│   ├── rust/service.nix        # was: rust-service.nix
│   ├── go/tool.nix             # was: go-tool.nix
│   └── ...
├── infra/
│   ├── pangea-workspace.nix    # was: pangea-workspace.nix
│   └── ...
├── service/
│   ├── helpers.nix             # was: service-helpers.nix
│   └── ...
├── hm/
│   ├── service-helpers.nix     # was: hm-service-helpers.nix
│   └── ...
├── codegen/
│   ├── openapi-forge.nix       # was: openapi-forge.nix
│   └── ...
├── util/
│   ├── config.nix              # was: config.nix
│   └── ...
└── devenv/                     # unchanged
```

---

## Backward Compatibility

**All old paths are preserved as one-line shims.** No consumer breakage.

Every file that moved has a shim at its old location:

```nix
# lib/rust-overlay.nix
# Shim -- moved to build/rust/overlay.nix
import ./build/rust/overlay.nix
```

The shim transparently forwards the import. Since Nix imports are lazy,
there is zero performance cost -- the shim is evaluated once and the
result is the same as importing the new path directly.

---

## Old Path to New Path Mapping

### Build patterns

| Old path | New path |
|----------|----------|
| `lib/rust-overlay.nix` | `lib/build/rust/overlay.nix` |
| `lib/rust-library.nix` | `lib/build/rust/library.nix` |
| `lib/rust-service.nix` | `lib/build/rust/service.nix` |
| `lib/rust-service-flake.nix` | `lib/build/rust/service-flake.nix` |
| `lib/rust-tool-release.nix` | `lib/build/rust/tool-release.nix` |
| `lib/rust-tool-release-flake.nix` | `lib/build/rust/tool-release-flake.nix` |
| `lib/rust-devenv.nix` | `lib/build/rust/devenv.nix` |
| `lib/crate2nix-builders.nix` | `lib/build/rust/crate2nix-builders.nix` |
| `lib/crate2nix-apps.nix` | `lib/build/rust/crate2nix-apps.nix` |
| `lib/go-overlay.nix` | `lib/build/go/overlay.nix` |
| `lib/go-tool.nix` | `lib/build/go/tool.nix` |
| `lib/go-monorepo.nix` | `lib/build/go/monorepo.nix` |
| `lib/go-monorepo-binary.nix` | `lib/build/go/monorepo-binary.nix` |
| `lib/go-library-check.nix` | `lib/build/go/library-check.nix` |
| `lib/go-docker.nix` | `lib/build/go/docker.nix` |
| `lib/go-grpc-service.nix` | `lib/build/go/grpc-service.nix` |
| `lib/zig-overlay.nix` | `lib/build/zig/overlay.nix` |
| `lib/zig-tool-release.nix` | `lib/build/zig/tool-release.nix` |
| `lib/zig-tool-release-flake.nix` | `lib/build/zig/tool-release-flake.nix` |
| `lib/swift-overlay.nix` | `lib/build/swift/overlay.nix` |
| `lib/typescript-tool.nix` | `lib/build/typescript/tool.nix` |
| `lib/typescript-library.nix` | `lib/build/typescript/library.nix` |
| `lib/typescript-library-flake.nix` | `lib/build/typescript/library-flake.nix` |
| `lib/ruby-config.nix` | `lib/build/ruby/config.nix` |
| `lib/ruby-build.nix` | `lib/build/ruby/build.nix` |
| `lib/ruby-gem.nix` | `lib/build/ruby/gem.nix` |
| `lib/ruby-gem-flake.nix` | `lib/build/ruby/gem-flake.nix` |
| `lib/python-package.nix` | `lib/build/python/package.nix` |
| `lib/python-uv.nix` | `lib/build/python/uv.nix` |
| `lib/dotnet-build.nix` | `lib/build/dotnet/build.nix` |
| `lib/java-maven.nix` | `lib/build/java/maven.nix` |
| `lib/wasm-build.nix` | `lib/build/wasm/build.nix` |
| `lib/web-build.nix` | `lib/build/web/build.nix` |
| `lib/web-docker.nix` | `lib/build/web/docker.nix` |
| `lib/github-action.nix` | `lib/build/web/github-action.nix` |

### Service patterns

| Old path | New path |
|----------|----------|
| `lib/service-helpers.nix` | `lib/service/helpers.nix` |
| `lib/environment-apps.nix` | `lib/service/environment-apps.nix` |
| `lib/product-sdlc.nix` | `lib/service/product-sdlc.nix` |
| `lib/image-release.nix` | `lib/service/image-release.nix` |
| `lib/health-supervisor.nix` | `lib/service/health-supervisor.nix` |
| `lib/helm-build.nix` | `lib/service/helm-build.nix` |
| `lib/db-migration.nix` | `lib/service/db-migration.nix` |
| `lib/platform-service.nix` | `lib/service/platform-service.nix` |

### Infrastructure patterns

| Old path | New path |
|----------|----------|
| `lib/pangea-workspace.nix` | `lib/infra/pangea-workspace.nix` |
| `lib/pangea-infra.nix` | `lib/infra/pangea-infra.nix` |
| `lib/pangea-infra-flake.nix` | `lib/infra/pangea-infra-flake.nix` |
| `lib/infra-workspace.nix` | `lib/infra/infra-workspace.nix` (DEPRECATED) |
| `lib/infra-state-backend.nix` | `lib/infra/infra-state-backend.nix` (DEPRECATED) |
| `lib/terraform-module.nix` | `lib/infra/terraform-module.nix` |
| `lib/terraform-provider.nix` | `lib/infra/terraform-provider.nix` |
| `lib/pulumi-provider.nix` | `lib/infra/pulumi-provider.nix` |
| `lib/ansible-collection.nix` | `lib/infra/ansible-collection.nix` |
| `lib/environment-config.nix` | `lib/infra/environment-config.nix` |

### Home-manager helpers

| Old path | New path |
|----------|----------|
| `lib/hm-service-helpers.nix` | `lib/hm/service-helpers.nix` |
| `lib/hm-mcp-helpers.nix` | `lib/hm/mcp-helpers.nix` |
| `lib/hm-skill-helpers.nix` | `lib/hm/skill-helpers.nix` |
| `lib/hm-typed-config-helpers.nix` | `lib/hm/typed-config-helpers.nix` |
| `lib/nixos-service-helpers.nix` | `lib/hm/nixos-service-helpers.nix` |
| `lib/secret-helpers.nix` | `lib/hm/secret-helpers.nix` |
| `lib/workspace-helpers.nix` | `lib/hm/workspace-helpers.nix` |

### Codegen patterns

| Old path | New path |
|----------|----------|
| `lib/openapi-forge.nix` | `lib/codegen/openapi-forge.nix` |
| `lib/openapi-sdk.nix` | `lib/codegen/openapi-sdk.nix` |
| `lib/openapi-rust-sdk.nix` | `lib/codegen/openapi-rust-sdk.nix` |
| `lib/source-registry.nix` | `lib/codegen/source-registry.nix` |

### Utilities

| Old path | New path |
|----------|----------|
| `lib/config.nix` | `lib/util/config.nix` |
| `lib/darwin.nix` | `lib/util/darwin.nix` |
| `lib/docker-helpers.nix` | `lib/util/docker-helpers.nix` |
| `lib/release-helpers.nix` | `lib/util/release-helpers.nix` |
| `lib/completions.nix` | `lib/util/completions.nix` |
| `lib/test-helpers.nix` | `lib/util/test-helpers.nix` |
| `lib/flake-wrapper.nix` | `lib/util/flake-wrapper.nix` |
| `lib/repo-flake.nix` | `lib/util/repo-flake.nix` |
| `lib/monorepo-parts.nix` | `lib/util/monorepo-parts.nix` |
| `lib/versioned-overlay.nix` | `lib/util/versioned-overlay.nix` |

### Unchanged

| Path | Notes |
|------|-------|
| `lib/devenv/*.nix` | No changes -- same location |
| `lib/default.nix` | Same location, same public API |

---

## How to Update an Existing Consumer

### Step 1: Check current import style

Determine how your repo consumes substrate:

**Style A: Via `substrate.lib.${system}` or `substrate.libFor`**

```nix
substrateLib = substrate.lib.${system};
apps = substrateLib.mkCrate2nixServiceApps { ... };
```

No changes needed. The `default.nix` API is unchanged.

**Style B: Direct file imports**

```nix
rustService = import "${substrate}/lib/rust-service.nix" { ... };
hmHelpers = import "${substrate}/lib/hm-service-helpers.nix" { ... };
```

These still work via shims. Optionally update to new paths:

```nix
rustService = import "${substrate}/lib/build/rust/service.nix" { ... };
hmHelpers = import "${substrate}/lib/hm/service-helpers.nix" { ... };
```

### Step 2: Update direct imports (optional)

If you want to use the new paths for clarity:

```diff
- rustService = import "${substrate}/lib/rust-service.nix" { ... };
+ rustService = import "${substrate}/lib/build/rust/service.nix" { ... };

- hmHelpers = import "${substrate}/lib/hm-service-helpers.nix" { lib = nixpkgs.lib; };
+ hmHelpers = import "${substrate}/lib/hm/service-helpers.nix" { lib = nixpkgs.lib; };

- goTool = import "${substrate}/lib/go-tool.nix";
+ goTool = import "${substrate}/lib/build/go/tool.nix";
```

### Step 3: Verify

```bash
nix flake check
nix build
```

---

## Rules

1. **Old paths are never removed.** Shims stay forever for backward compat.
2. **New code should use new paths.** When writing new imports, prefer
   `lib/build/rust/overlay.nix` over `lib/rust-overlay.nix`.
3. **No urgency to migrate.** Existing consumers work without changes.
   The old paths forward transparently.
4. **The `default.nix` public API is unchanged.** The attribute names
   (`mkCrate2nixProject`, `mkGoTool`, etc.) are the same. Only file
   paths changed, not the programmatic interface.
5. **Deprecated modules keep their shims.** `infra-workspace.nix` and
   `infra-state-backend.nix` are deprecated but their shims remain.
   New code should use `pangea-workspace.nix` instead.
