# pnpm Tool Builder
#
# The pnpm sibling of ./tool.nix's mkNpmTool — for upstream (third-party
# / vendor) CLIs whose lockfile is `pnpm-lock.yaml`, not
# `package-lock.json`. nixpkgs' `buildNpmPackage` only understands npm's
# own lockfile format; it cannot prefetch a pnpm project's dependencies.
#
# Wraps nixpkgs' NATIVE pnpm fetcher — `pnpm.fetchDeps` (a fixed-output
# derivation that runs a real `pnpm install --frozen-lockfile` once,
# network-permitted, and is hash-verified like any other FOD) +
# `pnpm.configHook` (re-installs from that already-fetched store with
# `--offline`, no network, inside the real build). This is the same
# hermetic two-phase shape `buildNpmPackage` uses for npm — nixpkgs
# ships it as its own first-class primitive, not something to
# reimplement (no "buildPnpmPackage" convenience wrapper exists upstream
# yet, so this builder is that missing layer, scoped to pleme-io's own
# needs).
#
# Usage (standalone):
#   pnpmToolBuilder = import "${substrate}/lib/build/npm/pnpm-tool.nix";
#   openwiki = pnpmToolBuilder.mkPnpmTool pkgs {
#     pname = "openwiki";
#     version = "0.0.3";
#     src = pkgs.fetchFromGitHub {
#       owner = "langchain-ai"; repo = "openwiki"; rev = "...";
#       hash = "sha256-...";
#     };
#     pnpmDepsHash = "sha256-...";
#     binEntry = "dist/cli.js";
#   };
#
# Usage (via substrate lib):
#   substrateLib = substrate.libFor { inherit pkgs system; };
#   openwiki = substrateLib.mkPnpmTool { ... };
{
  # Build a pnpm-packaged CLI tool from upstream source.
  #
  # Required attrs:
  #   pname        — package name
  #   version      — version string
  #   src          — source derivation (fetchFromGitHub, etc.)
  #   pnpmDepsHash — hash of the fetched pnpm store (get it via the
  #                  standard nixpkgs dance: set to "", build, copy the
  #                  "got: sha256-..." value back in)
  #
  # Optional attrs:
  #   binEntry        — path (relative to the built tree) to wrap as
  #                      bin/<binName>, e.g. "dist/cli.js" (default: null
  #                      — no bin wrapper, just install the built tree)
  #   binName         — bin/<name> entry exposed as meta.mainProgram
  #                     (default: pname)
  #   distDir         — build output directory to install (default: "dist")
  #   nodejs          — Node interpreter (default: pkgs.nodejs_22)
  #   pnpm            — pnpm package (default: pkgs.pnpm)
  #   fetcherVersion  — pnpm.fetchDeps fetcher format version (default: 3,
  #                     nixpkgs' current recommended/reproducible one)
  #   pnpmInstallFlags — extra flags for both the prefetch + real install
  #   pnpmWorkspaces  — `--filter` scoping for pnpm workspaces (default: [])
  #   npmBuildScript  — pnpm script to run (default: "build"; null skips
  #                     the build phase entirely)
  #   engineAssert    — enforce package.json's engines.node against
  #                     `nodejs` at eval time (default: true)
  #   doCheck         — run tests (default: false)
  #   extraBuildInputs — additional nativeBuildInputs
  #   extraAttrs      — any extra attrs passed to mkDerivation (wins over everything)
  #   description     — package description for meta
  #   homepage        — package homepage URL for meta
  #   license         — license (default: lib.licenses.mit)
  #   platforms       — supported platforms (default: lib.platforms.all)
  mkPnpmTool = pkgs: {
    pname,
    version,
    src,
    pnpmDepsHash,
    binEntry ? null,
    binName ? pname,
    distDir ? "dist",
    nodejs ? pkgs.nodejs_22,
    pnpm ? pkgs.pnpm,
    fetcherVersion ? 3,
    pnpmInstallFlags ? [],
    pnpmWorkspaces ? [],
    npmBuildScript ? "build",
    engineAssert ? true,
    doCheck ? false,
    extraBuildInputs ? [],
    extraAttrs ? {},
    description ? "${pname} - CLI tool",
    homepage ? null,
    license ? pkgs.lib.licenses.mit,
    platforms ? pkgs.lib.platforms.all,
  }: let
    lib = pkgs.lib;

    check = import ../../types/assertions.nix;
    _ = check.all [
      (check.nonEmptyStr "pname" pname)
      (check.nonEmptyStr "version" version)
      (check.nonEmptyStr "pnpmDepsHash" pnpmDepsHash)
      (check.list "pnpmInstallFlags" pnpmInstallFlags)
      (check.list "pnpmWorkspaces" pnpmWorkspaces)
      (check.bool "doCheck" doCheck)
      (check.list "extraBuildInputs" extraBuildInputs)
      (check.attrs "extraAttrs" extraAttrs)
    ];

    # Shared with mkNpmTool (../npm/tool.nix) — see node-engine-assert.nix.
    nodeEngineAssert = (import ../shared/node-engine-assert.nix { inherit lib; }).assertNodeEngine;
    engineNodeAssert =
      if !engineAssert then null
      else nodeEngineAssert { caller = "mkPnpmTool"; inherit pname src nodejs; };

    # Many upstream projects pin an exact pnpm via package.json's
    # `packageManager` field. pnpm >=10's own self-management then tries
    # to download THAT exact version and re-exec through it — which
    # ENOENTs the moment it runs offline (no network in the sandbox) and
    # falls through to a broken invocation ("Unknown option:
    # 'frozen-lockfile'"). `pnpm config set manage-package-manager-
    # versions false` (what nixpkgs' own pnpmConfigHook already runs)
    # comes too late — it needs a working `pnpm` call to set it, but the
    # very first `pnpm --version` check is what triggers the ENOENT. The
    # env-var form of the same config key is read at process startup,
    # before any command runs, closing the chicken-and-egg gap.
    disablePnpmSelfManage = {
      npm_config_manage_package_manager_versions = "false";
    };

    pnpmDeps = pnpm.fetchDeps ({
      inherit pname version src fetcherVersion pnpmInstallFlags pnpmWorkspaces;
      hash = pnpmDepsHash;
    } // disablePnpmSelfManage);

  in builtins.seq engineNodeAssert (pkgs.stdenv.mkDerivation ({
    inherit pname version src doCheck pnpmDeps;

    # NOT `inherit pnpmInstallFlags pnpmWorkspaces` here, even when the
    # caller passes non-empty lists: nixpkgs' pnpmConfigHook reads
    # `pnpmInstallFlags` back as a bash ARRAY (`"${pnpmInstallFlags[@]}"`),
    # but a plain Nix-list derivation attr always serializes to ONE
    # space-joined string env var. A bash scalar var referenced as
    # `${var[@]}` yields exactly one element (even "" for an empty/unset
    # string) — so passing the empty default here contributed one stray
    # empty positional argument to `pnpm install`, which pnpm's CLI
    # misparsed entirely (surfaced as "Unknown option: 'frozen-lockfile'"
    # / "pnpm help add", not an obviously-empty-arg error). Leaving the
    # attr genuinely unset makes `${pnpmInstallFlags[@]}` expand to zero
    # words, matching what the hook script actually wants.
    # KNOWN LIMITATION (undo when a real consumer needs it): a caller
    # passing >1 pnpmInstallFlags entry hits the same one-joined-string
    # problem — fix via `__structuredAttrs = true` (real bash arrays) if
    # that day comes; today's callers (mkPnpmTool's only consumer,
    # ponte's openwiki package) pass none.
    nativeBuildInputs = [ nodejs pnpm.configHook pkgs.makeWrapper ] ++ extraBuildInputs;

    buildPhase = ''
      runHook preBuild
      ${lib.optionalString (npmBuildScript != null) "pnpm run ${npmBuildScript}"}
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/libexec/${pname}"
      cp -r node_modules "$out/libexec/${pname}/node_modules"
      cp -r ${distDir} "$out/libexec/${pname}/${distDir}"
      cp package.json "$out/libexec/${pname}/package.json"
      ${lib.optionalString (binEntry != null) ''
        mkdir -p "$out/bin"
        makeWrapper ${nodejs}/bin/node "$out/bin/${binName}" \
          --add-flags "$out/libexec/${pname}/${binEntry}"
      ''}
      runHook postInstall
    '';

    meta = {
      inherit description license platforms;
      mainProgram = binName;
    } // lib.optionalAttrs (homepage != null) { inherit homepage; };
  }
  // disablePnpmSelfManage
  // extraAttrs));

  # Create a Nix overlay that provides multiple pnpm tools.
  mkPnpmToolOverlay = toolDefs: final: prev: let
    mkPnpmTool' = import ./pnpm-tool.nix;
  in builtins.mapAttrs
    (name: def: mkPnpmTool'.mkPnpmTool final def)
    toolDefs;
}
