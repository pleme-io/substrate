# TypeScript Tool Builders
#
# High-level abstractions for building TypeScript CLI tools using pleme-linker
# (Nix-native package management, no npm/pnpm in sandbox).
#
# Usage:
#   let
#     substrateLib = substrate.libFor { inherit pkgs system; };
#     plemeLinker = substrateLib.mkPlemeLinker { plemeLinkerSrc = ...; };
#   in substrateLib.mkTypescriptTool {
#     name = "curupira-mcp-server";
#     src = ./mcp-server;
#     inherit plemeLinker;
#     workspaceDeps = {
#       "@curupira/shared" = sharedBuild;
#     };
#     cliEntry = "cli.js";
#     binName = "curupira-mcp";
#   }
{ pkgs, forgeCmd ? "forge" }:

rec {
  # Build pleme-linker tool from source
  mkPlemeLinker = {plemeLinkerSrc}:
    let
      cargoNix = plemeLinkerSrc + "/Cargo.nix";
      project = import cargoNix {
        inherit pkgs;
        defaultCrateOverrides =
          pkgs.defaultCrateOverrides
          // {
            pleme-linker = oldAttrs: {
              nativeBuildInputs = (oldAttrs.nativeBuildInputs or []) ++ (with pkgs; [cmake perl git]);
            };
          };
      };
    in
      project.rootCrate.build;

  # Helper: Fetch npm packages from deps.nix
  fetchTypescriptDeps = depsNixPath:
    let
      manifest = import depsNixPath;
    in {
      inherit manifest;
      fetchedPackages = pkgs.lib.mapAttrs (name: pkg:
        pkgs.fetchurl {
          inherit (pkg) url;
          hash = pkg.integrity;
          name = "${pkg.pname}-${pkg.version}.tgz";
        })
      manifest.packages;
    };

  # Helper: Create manifest JSON for pleme-linker
  mkTypescriptManifestJson = {
    fetchedPackages,
    manifest,
    workspacePackages ? [],
  }:
    builtins.toJSON {
      packages =
        pkgs.lib.mapAttrsToList (key: pkg: {
          pname = pkg.pname;
          version = pkg.version;
          tarball = fetchedPackages.${key};
          dependencies = pkg.dependencies or [];
          hasBin = pkg.hasBin or false;
        })
        manifest.packages;
      inherit workspacePackages;
    };

  # Build a TypeScript library package (no CLI wrapper)
  mkTypescriptPackage = {
    name,
    src,
    plemeLinker,
    parentTsconfig ? null,
    workspaceDeps ? {},
  }:
    let
      depsNixPath = src + "/deps.nix";
      deps = fetchTypescriptDeps depsNixPath;
      manifestJson = mkTypescriptManifestJson {
        inherit (deps) fetchedPackages manifest;
      };
      safeName = builtins.replaceStrings ["@" "/"] ["" "-"] name;
      manifestFile = pkgs.writeText "${safeName}-manifest.json" manifestJson;

      workspaceDepArgs = pkgs.lib.concatMapStringsSep " " (pair:
        "--workspace-dep \"${pair.name}=${pair.value}\"")
      (pkgs.lib.mapAttrsToList (n: v: {
        name = n;
        value = v;
      })
      workspaceDeps);

      parentTsconfigArg =
        if parentTsconfig != null
        then "--parent-tsconfig ${parentTsconfig}"
        else "";
    in
      pkgs.runCommand safeName {
        nativeBuildInputs = [plemeLinker];
      } ''
        ${plemeLinker}/bin/pleme-linker build-project \
          --manifest ${manifestFile} \
          --project ${src} \
          --output $out \
          --node-bin ${pkgs.nodejs_20}/bin/node \
          ${parentTsconfigArg} \
          ${workspaceDepArgs}
      '';

  # Build a TypeScript CLI tool with wrapper script
  # workspaceDeps: attrset of pre-built workspace packages { name = derivation; }
  mkTypescriptTool = {
    name,
    src,
    cliEntry,
    binName,
    plemeLinker,
    parentTsconfig ? null,
    workspaceDeps ? {},
  }:
    let
      depsNixPath = src + "/deps.nix";
      deps = fetchTypescriptDeps depsNixPath;
      manifestJson = mkTypescriptManifestJson {
        inherit (deps) fetchedPackages manifest;
      };
      manifestFile = pkgs.writeText "${name}-manifest.json" manifestJson;

      workspaceDepArgs = pkgs.lib.concatMapStringsSep " " (pair:
        "--workspace-dep \"${pair.name}=${pair.value}\"")
      (pkgs.lib.mapAttrsToList (n: v: {
        name = n;
        value = v;
      })
      workspaceDeps);

      parentTsconfigArg =
        if parentTsconfig != null
        then "--parent-tsconfig ${parentTsconfig}"
        else "";
    in
      pkgs.runCommand name {
        nativeBuildInputs = [plemeLinker];
      } ''
        ${plemeLinker}/bin/pleme-linker build-project \
          --manifest ${manifestFile} \
          --project ${src} \
          --output $out \
          --node-bin ${pkgs.nodejs_20}/bin/node \
          --cli-entry ${cliEntry} \
          --bin-name ${binName} \
          ${parentTsconfigArg} \
          ${workspaceDepArgs}
      '';

  # Build a TypeScript CLI tool with workspace packages built from source
  # This builds everything in a single derivation (simpler but less granular caching)
  # workspaceSrcs: list of { name, src } for workspace packages to build from source
  #                If null, auto-discovers from deps.nix workspacePackages (requires workspaceRoot)
  # workspaceRoot: root directory for resolving workspace package paths (required for auto-discovery)
  mkTypescriptToolWithWorkspace = {
    name,
    src,
    cliEntry,
    binName,
    plemeLinker,
    parentTsconfig ? null,
    workspaceSrcs ? null,
    workspaceRoot ? null,
  }:
    let
      depsNixPath = src + "/deps.nix";
      deps = fetchTypescriptDeps depsNixPath;
      manifestJson = mkTypescriptManifestJson {
        inherit (deps) fetchedPackages manifest;
      };
      manifestFile = pkgs.writeText "${name}-manifest.json" manifestJson;

      # Auto-discover workspace packages from deps.nix if not explicitly provided
      discoveredWorkspaceSrcs =
        if workspaceSrcs != null
        then workspaceSrcs
        else if deps.manifest ? workspacePackages && workspaceRoot != null
        then
          map (wp: {
            name = wp.name;
            src = workspaceRoot + "/" + (builtins.baseNameOf wp.path);
          })
          deps.manifest.workspacePackages
        else [];

      # Fetch deps and create manifests for each workspace package
      workspaceManifests = map (ws:
        let
          wsDepsPath = ws.src + "/deps.nix";
          wsDeps = fetchTypescriptDeps wsDepsPath;
          wsManifestJson = mkTypescriptManifestJson {
            inherit (wsDeps) fetchedPackages manifest;
          };
          safeName = builtins.replaceStrings ["@" "/"] ["" "-"] ws.name;
        in {
          inherit (ws) name src;
          manifest = pkgs.writeText "${safeName}-manifest.json" wsManifestJson;
        })
      discoveredWorkspaceSrcs;

      workspaceSrcArgs = pkgs.lib.concatMapStringsSep " " (ws:
        "--workspace-src \"${ws.name}=${ws.manifest}=${ws.src}\"")
      workspaceManifests;

      parentTsconfigArg =
        if parentTsconfig != null
        then "--parent-tsconfig ${parentTsconfig}"
        else "";
    in
      pkgs.runCommand name {
        nativeBuildInputs = [plemeLinker];
      } ''
        ${plemeLinker}/bin/pleme-linker build-project \
          --manifest ${manifestFile} \
          --project ${src} \
          --output $out \
          --node-bin ${pkgs.nodejs_20}/bin/node \
          --cli-entry ${cliEntry} \
          --bin-name ${binName} \
          ${parentTsconfigArg} \
          ${workspaceSrcArgs}
      '';

  # Build a TypeScript CLI tool - auto-discovers everything from package.json
  # This is the most minimal interface - just provide src with package.json
  # workspaceRoot: required if the project has workspace packages (for resolving relative paths)
  mkTypescriptToolAuto = {
    src,
    plemeLinker,
    parentTsconfig ? null,
    workspaceRoot ? null,
  }:
    let
      packageJsonPath = src + "/package.json";
      packageJson = builtins.fromJSON (builtins.readFile packageJsonPath);
      name = packageJson.name or "typescript-tool";
      binEntries = packageJson.bin or {};
      binNames = builtins.attrNames binEntries;
      binName =
        if binNames != []
        then builtins.head binNames
        else name;
      cliEntry =
        if binNames != []
        then
          let
            path = binEntries.${binName};
          in
            builtins.replaceStrings ["./dist/" "dist/"] ["" ""] path
        else "index.js";
    in
      mkTypescriptToolWithWorkspace {
        inherit name src plemeLinker parentTsconfig cliEntry binName workspaceRoot;
      };

  # Create a regeneration app for TypeScript projects.
  # Delegates to `forge typescript regenerate`.
  mkTypescriptRegenApp = {
    name,
    plemeLinker,
    projectDirs,
  }:
    pkgs.writeShellScript "regen-${name}" ''
      set -euo pipefail
      export PATH="${plemeLinker}/bin:$PATH"
      exec ${forgeCmd} typescript regenerate \
        ${pkgs.lib.concatMapStringsSep " " (dir: "--project ${dir}") projectDirs}
    '';
}
