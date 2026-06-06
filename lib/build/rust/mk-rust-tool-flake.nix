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
  # Delta-only repos (.gitignore Cargo.build-spec.json, commit the slim
  # Cargo.gen.lock) reconstruct the same BuildSpec shape in PURE NIX —
  # including flake_metadata / workspace_members / root_crate — so the
  # metadata resolution below stays IFD-free for them. Priority mirrors
  # lockfile-builder's loadBuildSpec: delta > committed build-spec >
  # synthesized single-package > workspace IFD. Without this, a
  # delta-only WORKSPACE repo (gen itself, post spec-retirement) fell
  # through to the IFD branch on every `nix run github:pleme-io/<tool>`
  # — eval-time `gen build` with network, which is exactly what the
  # delta exists to eliminate (and what 2h-dead gen-spec CI runs
  # bootstrapping gen-from-gen on 2-core runners looked like).
  deltaSpec =
    (import ./lockfile-delta.nix { lib = inputs.nixpkgs.lib; }).reconstruct src;
  committedSpec =
    if deltaSpec != null then deltaSpec
    else if hasCommittedSpec
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
  # Parameterized over the CONTAINING manifest (`toml`) because [[bin]]
  # lives at the manifest's top level, not under [package] — the root
  # call site passes the root cargoToml; the delta-only member-meta
  # synthesis below passes the MEMBER's own Cargo.toml.
  plemeMetaForToml = toml: pkg:
    let
      pkgPleme = (pkg.metadata.pleme or {});
      packageName = pkg.name;
      # First-[[bin]]-name defaults: many fleet crates name the binary
      # differently from the package (hibikine package → hibiki bin,
      # namimado-cli → namimado, etc.). Default `hm-leaf` to the first
      # [[bin]] name when present so HM modules land at the BINARY name
      # (operators set `programs.hibiki.enable`, not
      # `programs.hibikine.enable`). Author override:
      # `[package.metadata.pleme] hm-leaf = "<name>"`.
      firstBinName =
        if toml ? bin && builtins.length toml.bin > 0
        then (builtins.head toml.bin).name or packageName
        else packageName;
      defaultBin = pkgPleme."hm-leaf" or firstBinName;
      defaultBinaryName = pkgPleme."binary-name" or defaultBin;
      defaultPackageAttr = pkgPleme."package-attr" or defaultBin;
      hasPleme = pkgPleme != {};
    in
      {
        default_bin = defaultBin;
        repo =
          # isString: workspace members inherit via `repository.workspace
          # = true`, which fromTOML reads as an attrset — the member-meta
          # synthesis resolves inheritance before calling here, but guard
          # anyway so an unresolved attrset degrades to null instead of a
          # string-op eval error.
          if pkg ? repository && builtins.isString pkg.repository
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
        flake_metadata."${packageName}" = plemeMetaForToml cargoToml pkg;
      } else null;  # workspace case → IFD path below

  # Workspace IFD fallback: when no committed spec AND consumer is a
  # workspace, regenerate via mk-build-spec.nix (gen running inside
  # the nix sandbox). Uses substrate's `gen-pin.json` to discover the
  # gen rev — self-consistent with substrate's own pin, no consumer
  # wiring required (gen is no longer a flake input — the substrate↔gen
  # lock cycle is broken; `gen-pin.json` is the single source of truth).
  # The IFD pays a one-time cost per (gen rev × src state); subsequent
  # evals hit nix's drv cache.
  genPin = fromJSON (readFile ./gen-pin.json);
  genRev = genPin.rev;
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

  # D1-conformant member-meta synthesis: the slim delta INTENTIONALLY
  # omits `default_bin`/`repo` (both derivable in pure Nix from the
  # member's own Cargo.toml — see gen_delta.rs MemberDelta) and only
  # carries entries for members that authored `[package.metadata.pleme]`.
  # When the spec has no entry for the picked member, derive it from the
  # member's manifest with the same plemeMetaForToml the single-package
  # synthesis uses. Without this, every delta-only WORKSPACE tool repo
  # (gen itself) threw "no flake_metadata" here.
  memberKeyOf = name:
    let ms = builtins.filter (k: (spec.crates.${k}.name or null) == name) spec.workspace_members;
    in if ms == [ ] then null else builtins.head ms;
  synthesizedMemberMeta = name:
    let
      key = memberKeyOf name;
      rel = if key == null then null else spec.crates.${key}.source.relative_path or null;
      tomlPath =
        if rel == null then null
        else if rel == "." then cargoTomlPath
        else src + "/${rel}/Cargo.toml";
      toml =
        if tomlPath != null && pathExists tomlPath
        then builtins.fromTOML (readFile tomlPath)
        else null;
      # Workspace inheritance (`<field>.workspace = true` → the root
      # manifest's [workspace.package].<field>) for the fields
      # plemeMetaForToml consumes as strings. Unresolvable inheritance
      # drops the field (downstream `or` fallbacks handle absence).
      inheritedFix = pkg: field:
        let v = pkg.${field} or null;
        in
          if builtins.isAttrs v && (v.workspace or false) then
            let w = ((cargoToml.workspace or { }).package or { }).${field} or null;
            in if w == null then removeAttrs pkg [ field ] else pkg // { ${field} = w; }
          else pkg;
    in
      if toml != null && toml ? package
      then plemeMetaForToml toml
        (builtins.foldl' inheritedFix toml.package [ "repository" "description" ])
      else null;

  meta = spec.flake_metadata.${pickedMember}
    or (
      let m = synthesizedMemberMeta pickedMember;
      in
        if m != null then m
        else throw "mkRustToolFlake: spec has no flake_metadata for `${pickedMember}` — regenerate at gen v2+."
    );

  # toolName drives the overlay attribute + packages.${system}.${toolName}.
  # MUST be the cargo crate / binary name (for `pkgs.${packageAttr}` HM
  # default lookups), NOT the HM module's leaf name (`hm-leaf`, which
  # may differ — `blackmatter-cli` package + `cli` leaf →
  # `blackmatter.components.cli` HM module reads `pkgs.blackmatter-cli`).
  # Fall back chain: explicit toolName → module_trio.binaryName →
  # module_trio.packageAttr → meta.default_bin → pickedMember.
  resolvedToolName =
    if toolName != null then toolName
    else if meta ? module_trio && meta.module_trio ? binaryName then meta.module_trio.binaryName
    else if meta ? module_trio && meta.module_trio ? packageAttr then meta.module_trio.packageAttr
    else meta.default_bin or pickedMember;
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
