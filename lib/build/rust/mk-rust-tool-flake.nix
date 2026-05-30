# mkRustToolFlake — zero-argument consumer flake for a Rust binary.
#
# Pure dispatch over `Cargo.build-spec.json` (gen-cargo's typed output).
# Reads `spec.flake_metadata.<member>` for tool name + repo slug — all
# TOML parsing happens in Rust.
#
# Consumer flake:
#
#   {
#     inputs.substrate.url = "github:pleme-io/substrate";
#     outputs = i: i.substrate.mkRustToolFlake {
#       inputs = i;
#       src = ./.;                           # MUST be `./.`, not `i.self`.
#       member = "<workspace-member>";       # only when multi-member workspace.
#     };
#   }
#
# `src = ./.` is required (not `inputs.self`) because we read the spec
# at eval time and `self` triggers an outputs-attrset cycle.
{
  inputs ? {},             # consumer flake inputs; substrate pre-binds defaults
  src,
  member ? null,           # workspace member name (defaults to single member)
  toolName ? null,         # override default_bin from spec
  repo ? null,             # override repo from spec
  crateOverrides ? {},
  buildInputs ? [],
  nativeBuildInputs ? [],
  module ? null,           # optional HM/NixOS/Darwin module trio spec
  shape ? "tool",          # tool | workspace | library | service | binary
}:
let
  inherit (builtins) fromJSON readFile pathExists length;

  # ── Spec resolution: committed spec OR Cargo.toml fallback ─────────
  #
  # Transient-lock support. Repositories in the canonical
  # transient-lock shape `.gitignore` `Cargo.build-spec.json` so the
  # nix-side `mkRustToolFlake` cannot rely on a committed file. When
  # the committed spec is absent, synthesize the MINIMAL fields this
  # file needs (toolName / repo / module_trio) directly from
  # `Cargo.toml`'s typed metadata. Pure-eval nix via
  # `builtins.fromTOML`, no IFD, no system dependency.
  #
  # The committed-spec path remains the fast-path (no TOML parse, full
  # dep graph available downstream); the TOML path is a graceful
  # fallback that makes `gen lock --reset` repos work seamlessly with
  # the canonical `substrate.rust.tool { src = ./.; }` flake.
  cargoTomlPath = src + "/Cargo.toml";
  cargoToml =
    if pathExists cargoTomlPath
    then builtins.fromTOML (readFile cargoTomlPath)
    else throw "mkRustToolFlake: ${toString src}/Cargo.toml missing — not a cargo workspace?";

  hasCommittedSpec = pathExists (src + "/Cargo.build-spec.json");
  committedSpec =
    if hasCommittedSpec
    then fromJSON (readFile (src + "/Cargo.build-spec.json"))
    else null;

  # Parse `owner/repo` from a GitHub-style URL string. Mirrors
  # gen-cargo::parse_owner_repo — handles SSH, HTTPS, .git suffix.
  parseOwnerRepo = url:
    let
      strip = s: prefix:
        let
          plen = builtins.stringLength prefix;
          slen = builtins.stringLength s;
        in
          if slen < plen then null
          else if builtins.substring 0 plen s == prefix
            then builtins.substring plen (slen - plen) s
            else null;
      stripSuffix = s: suffix:
        let
          plen = builtins.stringLength suffix;
          slen = builtins.stringLength s;
        in
          if slen < plen then s
          else if builtins.substring (slen - plen) plen s == suffix
            then builtins.substring 0 (slen - plen) s
            else s;
      after =
        strip url "https://github.com/"
        ;
      afterSshShort =
        strip url "git@github.com:"
        ;
      afterAny =
        if after != null then after
        else if afterSshShort != null then afterSshShort
        else null;
    in
      if afterAny == null then null
      else stripSuffix afterAny ".git";

  # CamelCase keys to match gen-cargo's ModuleTrioSpec wire shape
  # (#[serde(rename_all = "camelCase")]). When the consumer authors
  # `[package.metadata.pleme]` in Cargo.toml, build the
  # `module_trio` map here so substrate consumes it verbatim.
  plemeMetaFor = pkg:
    let
      pkgPleme = (pkg.metadata.pleme or {});
      packageName = pkg.name;
      defaultBin = pkgPleme."hm-leaf" or packageName;
      defaultBinaryName = pkgPleme."binary-name" or defaultBin;
      defaultPackageAttr = pkgPleme."package-attr" or defaultBin;
      hasPleme = pkgPleme != {};
    in
      {
        default_bin = defaultBin;
        repo =
          if pkg ? repository
          then parseOwnerRepo pkg.repository
          else null;
      } // (
        if !hasPleme then {}
        else {
          module_trio = {
            name = defaultBin;
            description =
              pkgPleme.description
                or (pkg.description or "${packageName} CLI tool");
            packageAttr = defaultPackageAttr;
            binaryName = defaultBinaryName;
            hmNamespace = pkgPleme."hm-namespace" or "programs";
            withMcp = pkgPleme."with-mcp" or false;
            withHttp = pkgPleme."with-http" or false;
            withSystemDaemon = pkgPleme."with-system-daemon" or false;
          };
        }
      );

  # Synthesize the MINIMAL spec shape this file consults. The full
  # spec (with crates, target_resolves, etc.) is built by
  # `lockfile-builder.nix` via IFD; this fallback only needs the
  # fields driving toolName / repo / module_trio resolution.
  synthesizedSpec =
    let
      members =
        if cargoToml ? workspace && cargoToml.workspace ? members
        then cargoToml.workspace.members
        else [ "." ];
      # For the trivial single-package case, the manifest's [package]
      # IS the member.
      singlePackage = cargoToml ? package;
      pkg = cargoToml.package or null;
      packageName = if pkg != null then pkg.name else "unknown-package";
    in
      if singlePackage then {
        workspace_members = [ { name = packageName; relative_path = "."; } ];
        root_crate = "${packageName}-${pkg.version or "0.0.0"}";
        crates."${packageName}-${pkg.version or "0.0.0"}" = { name = packageName; };
        flake_metadata."${packageName}" = plemeMetaFor pkg;
      } else null;  # workspace case → IFD path below

  # Workspace IFD fallback: when no committed spec AND consumer is a
  # workspace, regenerate via mk-build-spec.nix (gen running inside
  # the nix sandbox). Uses substrate's own flake.lock to discover the
  # gen rev — self-consistent with substrate's own pin, no consumer
  # wiring required. The IFD pays a one-time cost per (gen rev × src
  # state); subsequent evals hit nix's drv cache.
  substrateFlakeLock = fromJSON (readFile (./. + "/../../../flake.lock"));
  genRev = substrateFlakeLock.nodes.gen.locked.rev;
  ifdSystem = "x86_64-linux";  # Fixed: IFD-host-arbitrary; the spec is system-agnostic JSON.
  ifdHostPkgs = (import inputs.nixpkgs { system = ifdSystem; });
  ifdGenFlake = builtins.getFlake "github:pleme-io/gen/${genRev}";
  ifdGen = ifdGenFlake.packages.${ifdSystem}.host-tool or ifdGenFlake.packages.${ifdSystem}.default;
  ifdSpecDrv = (import ./mk-build-spec.nix) {
    inherit src;
    hostPkgs = ifdHostPkgs;
    gen = ifdGen;
  };
  ifdSpec = fromJSON (readFile "${ifdSpecDrv}/Cargo.build-spec.json");

  spec =
    if committedSpec != null then committedSpec
    else if synthesizedSpec != null then synthesizedSpec
    else ifdSpec;  # workspace fallback via IFD

  multiMember = length spec.workspace_members > 1;
  pickedMember =
    if member != null then member
    else if !multiMember then spec.crates.${spec.root_crate}.name
    else throw ''
      mkRustToolFlake: workspace has ${toString (length spec.workspace_members)} members; pass `member = "<one>"`.
      Members: ${builtins.concatStringsSep ", " (map (k: spec.crates.${k}.name) spec.workspace_members)}
    '';

  meta = spec.flake_metadata.${pickedMember}
    or (throw "mkRustToolFlake: spec has no flake_metadata for `${pickedMember}` — regenerate at gen v2+.");

  resolvedToolName = if toolName != null then toolName else (meta.default_bin or pickedMember);
  resolvedRepo = if repo != null then repo
    else meta.repo or (throw "mkRustToolFlake: no repo for `${pickedMember}` — pass `repo` or set [package].repository.");

  # The typed `module_trio` struct that gen emits when the consumer
  # authors `[package.metadata.pleme]` in Cargo.toml. Already in
  # mkModuleTrio's camelCase shape (gen-cargo `ModuleTrioSpec` uses
  # `#[serde(rename_all = "camelCase")]`), so substrate consumes it
  # verbatim — zero translation, zero per-field logic, zero defaults.
  # Every behavior change lives in gen-cargo.
  effectiveModule =
    if module != null then module
    else meta.module_trio or null;

  toolFlake = import ./tool-release-flake.nix {
    inherit (inputs) nixpkgs crate2nix flake-utils;
    fenix = inputs.fenix or null;
    devenv = inputs.devenv or null;
    forge = inputs.forge or null;
    # gen flows as a flake input here; the inner tool-release-flake.nix
    # resolves it to the host-tool variant (or default) for IFD use.
    gen = inputs.gen or null;
  };
in toolFlake (
  {
    toolName = resolvedToolName;
    inherit src;
    repo = resolvedRepo;
    inherit crateOverrides buildInputs nativeBuildInputs;
  }
  // (if multiMember then { packageName = pickedMember; } else {})
  // (if effectiveModule != null then { module = effectiveModule; } else {})
)
