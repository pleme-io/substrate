# Go Tool Builder
#
# Reusable pattern for building Go CLI tools from upstream source.
# Wraps buildGoModule with common conventions: version ldflags injection,
# shell completion generation, and standard meta attributes.
#
# Usage (standalone):
#   goToolBuilder = import "${substrate}/lib/go-tool.nix";
#   kubectl-tree = goToolBuilder.mkGoTool pkgs {
#     pname = "kubectl-tree";
#     version = "0.4.6";
#     src = pkgs.fetchFromGitHub { ... };
#     vendorHash = "sha256-...";
#   };
#
# Usage (via substrate lib):
#   substrateLib = substrate.libFor { inherit pkgs system; };
#   kubectl-tree = substrateLib.mkGoTool { ... };
#
# The builder provides:
#   - mkGoTool — build a single Go tool from source
#   - mkGoToolOverlay — create an overlay providing multiple tools
{
  # Build a Go CLI tool from upstream source.
  #
  # Required attrs:
  #   pname       — package name
  #   version     — version string (without "v" prefix)
  #   src         — source derivation (fetchFromGitHub, etc.)
  #   vendorHash  — hash for Go module dependencies (null if vendored in-tree)
  #
  # Optional attrs:
  #   subPackages     — list of Go packages to build (default: builds all)
  #   ldflags         — explicit ldflags list (overrides versionLdflags)
  #   versionLdflags  — attrset of -X ldflags for version injection
  #                     e.g., { "main.version" = version; "main.commit" = src.rev; }
  #   tags            — Go build tags (e.g., ["netcgo"])
  #   proxyVendor     — use proxy vendor mode (default: false)
  #   modRoot         — Go module root within source (for monorepos)
  #   doCheck         — run tests (default: false — most K8s tools need a cluster)
  #   completions     — shell completion config (see below)
  #   extraBuildInputs     — additional nativeBuildInputs
  #   extraPostInstall     — additional postInstall script
  #   extraAttrs           — any extra attrs passed to buildGoModule
  #   description     — package description for meta
  #   homepage        — package homepage URL for meta
  #   license         — license (default: lib.licenses.asl20)
  #   platforms       — supported platforms (default: lib.platforms.all)
  #
  # Completions config (optional):
  #   completions = {
  #     install = true;
  #     # One of:
  #     command = "helm";           — binary name that supports `completion {bash,zsh,fish}`
  #     fromSource = "completion";  — directory in source containing *.bash, *.zsh, *.fish
  #   };
  mkGoTool = pkgs: {
    pname,
    version,
    src,
    vendorHash,
    subPackages ? null,
    ldflags ? null,
    versionLdflags ? {},
    tags ? [],
    proxyVendor ? false,
    modRoot ? null,
    doCheck ? false,
    completions ? null,
    extraBuildInputs ? [],
    extraPostInstall ? "",
    extraAttrs ? {},
    description ? "${pname} - Kubernetes tool",
    homepage ? null,
    license ? pkgs.lib.licenses.asl20,
    platforms ? pkgs.lib.platforms.all,
  }: let
    lib = pkgs.lib;
    check = import ../../types/assertions.nix;
    _ = check.all [
      (check.nonEmptyStr "pname" pname)
      (check.nonEmptyStr "version" version)
      (check.list "tags" tags)
      (check.bool "proxyVendor" proxyVendor)
      (check.bool "doCheck" doCheck)
      (check.list "extraBuildInputs" extraBuildInputs)
      (check.str "extraPostInstall" extraPostInstall)
      (check.attrs "extraAttrs" extraAttrs)
      (check.attrs "versionLdflags" versionLdflags)
    ];
    completionsHelper = import ../../util/completions.nix;

    # Build ldflags: explicit ldflags take priority, otherwise construct from versionLdflags
    effectiveLdflags =
      if ldflags != null then ldflags
      else if versionLdflags != {} then
        ["-s" "-w"] ++ (lib.mapAttrsToList (key: val: "-X ${key}=${val}") versionLdflags)
      else ["-s" "-w"];

    # Shell completion support (via completions.nix)
    completionAttrs = completionsHelper.mkCompletionAttrs pkgs {
      inherit pname completions src;
    };

    # Substrate is the single source of truth for the Go toolchain version
    # (pkgs.go is overridden to our from-source goToolchain via the go overlay).
    # Enforce, at build time, that a consuming go.mod never declares a `go`
    # directive AHEAD of that toolchain — otherwise the build fails deep inside
    # `go mod download` with the cryptic "requires go >= X (running Y;
    # GOTOOLCHAIN=local)". This turns it into one clear, actionable error.
    # Fleet rule: authored go.mod declares the MINOR only (e.g. `go 1.25`),
    # never a patch ahead of the builder.
    goVersionGuard = ''
      _gomod="${if modRoot != null then modRoot else "."}/go.mod"
      if [ -f "$_gomod" ]; then
        _req=$(grep -m1 '^go ' "$_gomod" | awk '{print $2}')
        _tool="${pkgs.go.version}"
        if [ -n "$_req" ] \
          && [ "$(printf '%s\n%s\n' "$_tool" "$_req" | sort -V | tail -1)" = "$_req" ] \
          && [ "$_req" != "$_tool" ]; then
          echo "substrate.mkGoTool: ${pname} go.mod requires 'go $_req' but the substrate goToolchain is $_tool." >&2
          echo "  Pin go.mod to the minor only ('go ${pkgs.lib.versions.majorMinor pkgs.go.version}'), never a patch ahead of the builder." >&2
          exit 1
        fi
      fi
    '';

  in pkgs.buildGoModule ({
    inherit pname version src vendorHash proxyVendor doCheck tags;

    nativeBuildInputs = completionAttrs.nativeBuildInputs ++ extraBuildInputs;

    ldflags = effectiveLdflags;

    preBuild = goVersionGuard + (extraAttrs.preBuild or "");

    postInstall = completionAttrs.postInstallScript + extraPostInstall;

    meta = {
      inherit description license platforms;
      mainProgram = pname;
    } // lib.optionalAttrs (homepage != null) { inherit homepage; };
  }
  // lib.optionalAttrs (subPackages != null) { inherit subPackages; }
  // lib.optionalAttrs (modRoot != null) { inherit modRoot; }
  # preBuild already merged above (guard + caller's); don't let the spread clobber it.
  // (builtins.removeAttrs extraAttrs ["preBuild"]));

  # Create a Nix overlay that provides multiple Go tools.
  #
  # Usage:
  #   goToolOverlay = goToolBuilder.mkGoToolOverlay {
  #     kubectl-tree = { pname = "kubectl-tree"; ... };
  #     stern = { pname = "stern"; ... };
  #   };
  #   pkgs = import nixpkgs { overlays = [ goToolOverlay ]; };
  #   # pkgs.blackmatter-kubectl-tree, pkgs.blackmatter-stern, etc.
  mkGoToolOverlay = toolDefs: final: prev: let
    mkGoTool' = import ./tool.nix;
  in builtins.mapAttrs
    (name: def: mkGoTool'.mkGoTool final def)
    toolDefs;
}
