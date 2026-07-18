# Pure-dispatch Rust builder over gen's typed Cargo.build-spec.json.
#
# Rust (gen-cargo) does the parsing + sha256 prefetch + URL
# normalization + workspace inheritance. This file is the Nix
# composition layer: tagged-enum source dispatch, lazy mapAttrs over
# the dep graph, attrset assembly. No string munging, no regex, no
# fromTOML, no override-as-data decoding.
#
# Override composition: callers compose `defaultCrateOverrides` upstream
# (nixpkgs defaults + plemeCrateOverrides + user overrides) and pass the
# merged attrset in. Single composition channel — same shape nixpkgs
# uses everywhere.
{ pkgs, lib ? pkgs.lib }:

let
  inherit (builtins) fromJSON readFile pathExists map;

  loadBuildSpec = src:
    let path = src + "/Cargo.build-spec.json"; in
    if pathExists path
    then fromJSON (readFile path)
    else throw ''
      lockfile-builder: ${toString src}/Cargo.build-spec.json not found.
      Run `gen build .` in the workspace root to produce it.
    '';

  # Strip any `?branch=…` / `?ref=…` query string from a git URL.
  #
  # gen is supposed to pre-clean URLs into pkgs.fetchgit's expected
  # shape, but historically it has lifted the literal Cargo.lock
  # `source` URL (which is `git+https://host/repo?branch=main#<rev>`)
  # and emitted `https://host/repo?branch=main` into Cargo.build-spec.
  # json. git CLI then interprets the `?branch=main` as part of the
  # repo path — `git ls-remote https://github.com/foo/bar?branch=main`
  # asks GitHub for the repo named `bar?branch=main`, which 404s.
  #
  # The substrate's load-bearing fix is here: normalize the URL once
  # before handing to fetchgit, so every consumer (namimado, nami,
  # future Cargo.build-spec.json builds) is immune to that gen bug
  # class without touching individual repos. Per the prime-directive
  # "fix upstream, not the local symptom" rule.
  stripUrlQuery = url:
    let m = builtins.match "([^?]+)\\?.*" url; in
    if m == null then url else builtins.head m;

  # Registry URL canonicalization. Old gen versions (< 70774a2) emitted
  # `https://crates.io/api/v1/crates/<name>/<ver>/download`, which is
  # the redirect entrypoint. crates.io has started serving HTTP 403 on
  # that URL for any request without a `User-Agent` header — and
  # nixpkgs' fetchurl invokes curl without one by default. Rewrite to
  # the canonical immutable CDN URL (`static.crates.io`) the redirect
  # would have pointed at. Idempotent: URLs already in CDN form pass
  # through unchanged.
  canonicalRegistryUrl = name: version: url:
    let
      apiPrefix = "https://crates.io/api/v1/crates/";
      isApiUrl = lib.hasPrefix apiPrefix url;
    in if isApiUrl
       then "https://static.crates.io/crates/${name}/${name}-${version}.crate"
       else url;

  # Tagged-enum dispatch on source.kind. URLs are pre-cleaned by gen
  # — `stripUrlQuery` is belt-and-suspenders for the documented gen
  # `?branch=main`-leak class.
  #
  # Workspace-subdir narrowing for git deps: gen-cargo emits one
  # `source` entry per crate, but multiple crates can share the same
  # git rev when the repo is a Cargo workspace (e.g. tatara-lisp
  # ships tatara-lisp + tatara-lisp-derive + 14 others at the same
  # rev). For those, the fetched tarball is the workspace root, not
  # the crate root. We narrow by name when `${full}/${crateName}/
  # Cargo.toml` exists — that's the conventional layout. Falls
  # through to the unnarrowed root when the repo is a single-crate
  # source.
  # Factory: produce `srcOf` closed over `fetchPkgs` (host pkgs, not
  # the cross-target pkgs). When `pkgs` is pkgsStatic (cross-musl),
  # `pkgs.fetchgit` inherits the pkgsStatic cross-build stdenv
  # (NIX_CFLAGS_LINK=-static, --host=x86_64-unknown-linux-musl, etc.).
  # FODs running under that stdenv lose host network — fetchgit's
  # git-clone fails with "Could not resolve host: github.com" on hosts
  # whose DNS is dnsmasq-mediated (rio). Use hostPkgs.fetchgit so the
  # FOD runs in the host-native stdenv with normal network access.
  # Source fetches are platform-independent — they just download bytes.
  mkSrcOf = fetchPkgs: workspaceSrc: spec:
    if spec.source.kind == "registry" then
      fetchPkgs.fetchurl {
        url = canonicalRegistryUrl spec.name spec.version spec.source.url;
        sha256 = spec.source.sha256;
        name = spec.source.name_with_ext;
      }
    else if spec.source.kind == "git" then
      let
        full = fetchPkgs.fetchgit {
          url = stripUrlQuery spec.source.url;
          rev = spec.source.rev;
          sha256 = spec.source.sha256 or lib.fakeSha256;
        };
        # Conventional workspace-member layouts we look for, in order.
        # Adding a new layout = one entry here; the first hit wins.
        # tatara/escriba ship members at `<root>/<name>` (flat); ishou
        # ships them at `<root>/crates/<name>` (the "crates/" convention).
        # Tier 3+ repos can opt in by following one of these conventions.
        candidates = [
          (full + "/${spec.name}")
          (full + "/crates/${spec.name}")
        ];
        firstMatch = lib.findFirst
          (p: builtins.pathExists (p + "/Cargo.toml"))
          null
          candidates;
      in
        if firstMatch != null
        then firstMatch
        else full
    else
      # Path source — two cases:
      #
      # 1. Workspace member (relative_path is INSIDE workspaceSrc):
      #    ALWAYS use the full workspace root so
      #    `include_str!("../../sibling.lisp")` from a member's
      #    src/lib.rs can reach files at the workspace root.
      #    libPath / build_script in build_rust_crate_args must be
      #    prefixed with relative_path to compensate — handled in
      #    `prefixForMember`.
      #
      # 2. External path-dep (relative_path starts with "../" —
      #    escapes the workspace via a cargo path = "../sibling-repo"
      #    declaration): NOT SUPPORTED. The sibling repo's source
      #    lives OUTSIDE workspaceSrc; using workspaceSrc here makes
      #    libPath dangle at "../sibling/src/lib.rs" which doesn't
      #    exist in the build sandbox, producing a silent empty drv
      #    (the buildPhase runs but rustc never finds the lib, no
      #    rlib emitted). Downstream consumers fail with the cryptic
      #    "extern location for <crate> does not exist".
      #
      #    Fail loud with a typed error directing the operator to
      #    convert the path-dep to a git or registry dep in the
      #    consuming workspace's Cargo.toml — that's the only correct
      #    fix today. Future substrate work could fetch the external
      #    path-dep's source from a flake-input mapping emitted by
      #    gen-cargo, but that doesn't exist yet.
      if lib.hasPrefix ".." (spec.source.relative_path or "")
      then throw ''
        substrate/lockfile-builder: external path-dep not supported.

        Crate `${spec.name}` (version ${spec.version}) declared with
        a cargo `path = "${spec.source.relative_path}"` that escapes
        the workspace root. The sibling repo's source is not present
        in the Nix build sandbox (src = workspaceSrc) — buildRustCrate
        would silently produce an empty drv and the consuming crate
        fails with "extern location does not exist".

        Fix: change the dep in the consuming workspace's Cargo.toml
        to use git (or registry) instead of path. Example:

          # before (broken in Nix builds)
          ${spec.name} = { path = "${spec.source.relative_path}" }

          # after (works in Nix builds)
          ${spec.name} = { git = "https://github.com/pleme-io/${spec.name}.git" }

        Re-run `gen lock-build` after editing, then commit + push the
        regenerated Cargo.build-spec.json.
      ''
      else workspaceSrc;

  # Triple-aware: imported as a function `triple -> overrides`. Each
  # tree-builder specializes the overrides for its target triple, so
  # substrate-level safety nets (e.g. apple-only feature strip on
  # notify) fire only on the targets they're protecting.
  plemeCrateOverridesFor = import ./pleme-crate-overrides.nix;
  # Mechanical dispatch layer for typed `CrateQuirk` variants emitted
  # by gen-cargo. Class-helper functions (forceCfg /
  # foldNormalIntoBuild / substituteSource); per-crate knowledge of
  # WHICH crates need WHICH quirks lives in
  # `gen-cargo/src/quirks.rs::REGISTRY` (Rust source of truth).
  quirkApply = import ./quirk-apply.nix { inherit lib; };
  overrideCompose = import ./crate-override-compose.nix { inherit lib; };
  mkProject = {
    src,
    # Optional human-readable workspace identifier used in error
    # messages (e.g. "mkRustWorkspace: ${name} — Cargo.build-spec.json
    # missing"). Callers like mk-rust-workspace.nix pass this through;
    # the lockfile-builder itself only forwards it for diagnostic
    # surface. Present so the API doesn't reject "name = ..." with
    # `unexpected argument` when callers attach context for richer
    # error reporting.
    name ? "<unnamed-workspace>",
    # Substrate guarantee: every fleet-wide buildRustCrate quirk in
    # plemeCrateOverrides applies by default. Callers can still pass an
    # explicit `defaultCrateOverrides` to extend — the merge order is
    # nixpkgs defaults → pleme overrides → caller overrides (later wins).
    # Default merges plemeCrateOverrides specialized to the *target*
    # triple — host-tree builds further specialize via overrideFor's
    # triple-aware path inside mkBuiltTree. Callers that pass their
    # own defaultCrateOverrides override the default entirely. The
    # triple is computed from `pkgs` directly (rather than referencing
    # the `targetTriple` let-binding defined later in mkProject) to
    # keep the parameter default self-contained.
    defaultCrateOverrides ? (pkgs.defaultCrateOverrides // (plemeCrateOverridesFor pkgs.stdenv.hostPlatform.rust.rustcTarget)),
    buildRustCrateForPkgs ? (p: p.buildRustCrate),
    # Current-gen guarantee (theory/TOOLCHAIN-FRESHNESS.md §X.2.1): the
    # build-time gen used for the IFD auto-regen is ALWAYS the pinned
    # gen from `gen-pin.json`, never the operator's profile/overlay
    # `pkgs.gen`. The overlay/profile gen drifts — a stale profile gen
    # (e.g. 0.1.0 vs source 0.1.8) silently does the pre-delta-only
    # thing, writing the RETIRED Cargo.build-spec.json and leaving the
    # delta un-refreshed, which poisons every downstream regen. Pinning
    # the IFD gen makes that class unrepresentable. Only the stale-delta
    # IFD path invokes gen at all (fresh deltas reconstruct in pure Nix
    # via lockfile-delta.nix), so this strictly fixes the already-broken
    # path. A caller may still override by passing `gen` explicitly —
    # this is only the default. Per the GEN TYPED-SPEC CONTRACT
    # (`theory/GEN-TYPED-SPEC-CONTRACT.md`), regeneration is
    # BACKGROUND TO REBUILD — never a manual step.
    gen ?
      let
        # gen rev from substrate's `gen-pin.json` (NOT flake.lock — gen
        # is no longer a flake input, which broke the substrate↔gen lock
        # cycle). `gen-pin.json` lives next to this file and is the single
        # source of truth for the gen pin. This IFD-time `getFlake`
        # against the locked rev does NOT grow any lock. Kept current by
        # AUTO-RELEASE bumping the pin on every gen release.
        genPin = builtins.fromJSON (builtins.readFile ./gen-pin.json);
        genRev = genPin.rev;
        autoGenFlake = builtins.getFlake "github:pleme-io/gen/${genRev}";
        autoGen = autoGenFlake.packages.${pkgs.stdenv.hostPlatform.system}.host-tool
          or autoGenFlake.packages.${pkgs.stdenv.hostPlatform.system}.default;
      in
        autoGen,
    # Host pkgs for the IFD auto-regen. When `pkgs` is pkgsStatic (cross
    # builds), `pkgs.buildPackages` is pkgsStatic itself — not the
    # build-machine's darwin/linux native pkgs. The IFD always runs at
    # eval time on the build host, so it needs native cargo/rustc/cacert.
    # Default falls back to `pkgs.buildPackages` for native builds where
    # the two are equivalent; cross consumers (tool-release.nix) pass
    # the explicit darwin/linux host pkgs.
    hostPkgs ? pkgs.buildPackages,
    # Transient-lock contract — see comment block around
    # `committedLockSha256` below. When `true` (default), substrate
    # refuses builds where the committed spec's hash disagrees with
    # the current `Cargo.lock`'s sha256 (gen-cargo's `Drifted` state).
    # The build throws a typed error pointing the operator at
    # `gen lock --update`. Silent IFD-regen of an operator's
    # deliberate snapshot is a surprise; the strict default makes
    # the deterministic-lock contract a fleet invariant. Per-consumer
    # opt-out via `strictTransientLock = false` is supported for
    # legacy repos mid-migration but should not be permanent.
    strictTransientLock ? true,
  }: let
    specInvariants = import ./spec-invariants.nix;
    # I4 — per-platform spec emission. gen-cargo's --filter-platform
    # has cargo resolve cfg(target_os=…) / cfg(target_vendor=…) /
    # cfg(any/all/not(…)) / custom-cfg expressions for the given
    # triple; substrate consumes the resolved dep edges directly. No
    # Nix-side cfg parsing, no risk of getting it wrong on the
    # gnarly nested cfg expressions real-world crates emit
    # (rustix_use_experimental_asm, getrandom_backend, …). For
    # cross-builds the target tree and host tree get separate
    # platform-filtered specs.
    # rustc-style triple (aarch64-apple-darwin) vs Nix-style
    # (arm64-apple-darwin); nixpkgs exposes the canonical rustc form
    # under `.rust.rustcTarget` on every platform object. Use that
    # consistently so `gen build --filter-platform=<triple>` matches
    # what rustc expects.
    targetTriple = pkgs.stdenv.hostPlatform.rust.rustcTarget;
    # Must use the explicit hostPkgs — NOT pkgs.buildPackages. For
    # pkgsStatic, `pkgs.buildPackages` is pkgsStatic itself (same
    # store path), so its rustcTarget == targetTriple and isCross
    # falsely reports false. Without this fix, cross-musl builds
    # never engage the dual-tree dispatch.
    hostTriple = hostPkgs.stdenv.hostPlatform.rust.rustcTarget;
    isCross = targetTriple != hostTriple;

    # 1) Try the committed spec first (cheap, no IFD). Note: committed
    #    specs are typically multi-platform (no --filter-platform was
    #    passed when emitted), so they may contain cfg-conditional
    #    deps that don't apply to the current target. For native
    #    builds where the committed spec was generated on the same
    #    platform, this is usually fine. For cross-builds or where
    #    cfg-impossible deps exist, regen via IFD with the explicit
    #    target triple is required.
    # 0) Highest-priority spec source: the slim `Cargo.gen.lock` delta,
    #    reconstructed in PURE NIX (fromTOML Cargo.lock + the committed
    #    delta) — IFD-free, cache-shared, 3.4× smaller committed artifact.
    #    `null` when no Cargo.gen.lock is present → falls through to the
    #    full committed build-spec, then IFD. Proven build-equivalent to
    #    the build-spec path on gen (crate set, per-crate source/scalars,
    #    target_resolves, root_crate all identical). See lockfile-delta.nix
    #    + gen/docs/CARGO-LOCK-DELTA-CONTRACT.md (D1–D4). This is the
    #    deliberate `fromTOML` path the file header's "no fromTOML" note
    #    predates — the delta trades reconstruction for a smaller artifact.
    deltaSpec = (import ./lockfile-delta.nix { inherit lib; }).reconstruct src;
    committedPath = src + "/Cargo.build-spec.json";
    committedSpec =
      if deltaSpec != null then deltaSpec
      else if builtins.pathExists committedPath
      then fromJSON (readFile committedPath)
      else null;
    committedViolations =
      if committedSpec == null then [ "spec-missing" ]
      else specInvariants committedSpec;

    # Transient-lock contract (gen-cargo `LockLifecycleState`):
    #   - Unlocked   = no committedSpec, IFD-regen fine
    #   - Locked     = committedSpec + fresh hash, reuse
    #   - Drifted    = committedSpec but stale → REFUSE if strict
    #   - MissingLock = no Cargo.lock, can't build
    # When `strictTransientLock` is true (off by default for backward
    # compat), substrate refuses Drifted builds with a typed error
    # pointing the operator at `gen lock --update`. Auto-regen
    # silently rewriting an operator's deliberate snapshot is a
    # surprise; the strict path forces an explicit acknowledgement.

    # ── Spec-source policy (aligned with operator-surface doctrine) ──
    #
    # Substrate trusts the committed spec unconditionally when it
    # exists and passes structural invariants. Spec freshness is
    # gen's responsibility — gen's auto-commit CI in bootstrap-
    # exception repos keeps committed specs synced with Cargo.lock
    # changes. Substrate's only job is to consume what gen produced.
    #
    # The previous `cargo_lock_sha256` freshness comparison was the
    # wrong primitive — it compared two derived artifacts against
    # each other, then asked operators to manually re-run gen and
    # commit. CI auto-commit eliminates that toil at the source.
    # `strictTransientLock` is retained as a no-op argument for
    # backward compatibility with consumer flake call sites.
    _strictTransientLockArgRetainedForBackcompat = strictTransientLock;
    _driftAssert = null;

    # Regenerate via IFD when:
    #   - gen is unreachable → can't regen; consume committed spec.
    #   - committed spec is missing or invariant-violating.
    # Trust committed spec when present + structurally valid.
    needsRegenTarget =
      if gen == null then false
      else committedSpec == null || committedViolations != [];

    # 2) Per-tree IFD: each tree gets its own platform-filtered spec
    #    when gen is reachable. Native builds reuse the target spec
    #    for the host tree (targetTriple == hostTriple so the filter
    #    yields identical results). Cross-builds emit two specs.
    targetSpecDrv =
      if needsRegenTarget && gen != null
      then import ./mk-build-spec.nix {
        inherit hostPkgs gen src;
        target = targetTriple;
      }
      else null;
    hostSpecDrv =
      if needsRegenTarget && gen != null && isCross
      then import ./mk-build-spec.nix {
        inherit hostPkgs gen src;
        target = hostTriple;
      }
      else targetSpecDrv;  # native: reuse.

    # The delta carries every fleet target's resolve (base // overrides[t]),
    # so one reconstructed spec serves both trees — the per-triple selection
    # happens downstream in target_resolves[triple], exactly as for the full
    # build-spec. So when deltaSpec is present it is BOTH trees' spec.
    specTarget =
      if deltaSpec != null then deltaSpec
      else if targetSpecDrv != null
      then loadBuildSpec targetSpecDrv
      else loadBuildSpec src;
    specHost =
      if deltaSpec != null then deltaSpec
      else if hostSpecDrv != null && hostSpecDrv != targetSpecDrv
      then loadBuildSpec hostSpecDrv
      else specTarget;

    # `spec` retained for upstream callers that read it from the
    # return value (workspaceMembers, root_crate). Use the target
    # spec since that's the workload-facing view.
    spec = specTarget;
    needsRegen = needsRegenTarget;  # legacy alias for _regenAssert.

    # Workspace-root orphan filter — kills the auto-detect class of bug.
    #
    # Repos that split a former monolithic crate into N workspace
    # members (tatara is the canonical example: workspace-root `./src/`
    # contains api/, cli/, drivers/, etc. from the pre-split monolith
    # that cargo no longer compiles) leave the orphan tree at workspace
    # root. nixpkgs' buildRustCrate `build-crate.nix`:
    #
    #   if   [[ -e "$LIB_PATH" ]] then build_lib "$LIB_PATH"
    #   elif [[ -e src/lib.rs  ]] then build_lib src/lib.rs
    #
    # ...has an `elif` that fires on that workspace-root orphan for
    # every bin-only path-source member built via `src = workspaceSrc`,
    # compiling a lib named after the wrong crate with the wrong deps
    # → cascade of E0432/E0433 errors that look like missing externs.
    #
    # Symmetric trap exists for `src/main.rs` — a lib-only member with
    # `crateBin = []` is safe, but an unexpected orphan `src/main.rs`
    # at workspace root would also be picked up.
    #
    # **Workspace-root orphan = an `src/` directory at the workspace
    # root that a GIVEN crate does not itself claim.** A member claims
    # the root when its `source.relative_path` is `""` or `"."` —
    # that's cargo's convention for a root crate co-located with the
    # workspace.
    #
    # CORRECTED (task #91, escuta-breathe-bridge): filtering used to be
    # an ALL-OR-NOTHING decision for the whole tree — `hasRootCrate`
    # asked only "does ANY member claim the root?" and, if so, skipped
    # filtering for EVERY crate (root src/ stays visible tree-wide).
    # That's correct for the crate that legitimately IS the root (it
    # needs its own `src/lib.rs`/`src/main.rs` to exist), but wrong for
    # every OTHER path-source member built against the SAME shared
    # `src = workspaceSrc` tree: nixpkgs' `build-crate.nix` has an
    # unconditional fallback —
    #
    #   if   [[ -e "$LIB_PATH" ]] then build_lib "$LIB_PATH"
    #   elif [[ -e src/lib.rs  ]] then build_lib src/lib.rs
    #
    # — that fires on the literal `src/lib.rs` file regardless of
    # whatever `libPath` substrate passes (a nonexistent-by-design
    # synthesized path does not suppress it). For a workspace shaped
    # "real root package + bin-only sibling member" (escuta at the
    # root + escuta-breathe-bridge as a member — as opposed to
    # tatara's "orphan-only" shape, where NO crate claims the root),
    # `hasRootCrate` was true, filtering was skipped tree-wide, and
    # every non-root member's build silently picked up the ROOT
    # crate's real `src/lib.rs` and compiled it under the MEMBER's
    # crate name — a wrong-source-file build (E0432/E0433-style
    # cascade, or worse, an `E0277` deep inside the wrong file that
    # reads like a real bug in the root crate).
    #
    # The fix makes the decision PER CRATE instead of tree-wide: the
    # crate that legitimately claims the root sees the real `src/`;
    # every other path-source member sees a tree with the root's
    # `src/` filtered out, so nixpkgs' fallback correctly finds
    # nothing and falls through to `crateBin` only. Pure Nix
    # `lib.cleanSourceWith`, decided once per crate at the
    # source-derivation level — no bash, no per-crate preBuild.
    crateClaimsRoot = crate:
      (crate.source.kind or null) == "path"
      && ((crate.source.relative_path or "") == ""
          || (crate.source.relative_path or "") == ".");

    rootOrphanFilteredSrc =
      let
        srcStr = toString src;
      in
        lib.cleanSourceWith {
          inherit src;
          name = "workspace-src-no-root-orphan";
          filter = path: type:
            let
              rel = lib.removePrefix (srcStr + "/") (toString path);
              isWorkspaceRootSrcDir = type == "directory" && rel == "src";
              isUnderWorkspaceRootSrc = lib.hasPrefix "src/" rel;
            in
              !(isWorkspaceRootSrcDir || isUnderWorkspaceRootSrc);
        };

    filteredWorkspaceSrcFor = crate:
      if crateClaimsRoot crate then src else rootOrphanFilteredSrc;
    # If regen wasn't possible (gen unavailable) but the committed spec
    # had violations, surface a traced warning so the operator knows
    # the build is running on synthesized fallbacks instead of a true
    # regen. Hard error only when the synthesis can't cover (e.g.
    # missing-spec without gen).
    _regenAssert =
      if needsRegen && gen == null then
        if committedSpec == null then
          throw ''
            substrate/lockfile-builder: ${toString src}/Cargo.build-spec.json
            not found AND `gen` is not reachable (pkgs.gen is unset).
            Either:
              (a) compose substrate's rust overlay (provides pkgs.gen) →
                  auto-regen will take over, OR
              (b) pass `gen = substrate.packages.<system>.gen` to
                  lockfileBuilder.mkProject explicitly, OR
              (c) run `gen build .` once in the workspace root to
                  produce the committed spec.
            Per the GEN TYPED-SPEC CONTRACT, (a) is the directive-
            aligned default — no per-repo regen toil.
          ''
        else builtins.trace ''
          substrate/lockfile-builder: committed Cargo.build-spec.json has
          invariant violations:
          ${builtins.concatStringsSep "\n  " (map (v: "  - " + v) committedViolations)}
          `gen` is unreachable (pkgs.gen unset) — falling back to
          spec-side synthesis (lib_target etc.). Compose substrate's
          rust overlay or pass `gen` to mkProject for true auto-regen.
        '' null
      else null;
    # Single sentinel forces evaluation of both side-effect-only
    # bindings (`builtins.seq` chains them deterministically).
    _ = builtins.seq _specVersionAssert _regenAssert;
    # Invariant E: schema-version gate. Substrate's lockfile-builder
    # is contracted against `Cargo.build-spec.json` v3+ (pre-shaped
    # `build_rust_crate_args`). Older specs must be regenerated; we
    # accept v2 transitionally during M5 with a warning that points
    # operators at `gen build .`. Sunset at M6.
    _specVersionAssert =
      let v = spec.version or 0; in
      if v >= 3 then null
      else if v == 2 then builtins.trace ''
        substrate/lockfile-builder: ${toString src}/Cargo.build-spec.json is v2.
        Regenerate with `gen build .` (gen >= c9a0067) — legacyArgs
        backward-compat will sunset at M6. Spec v3 adds typed
        `build_rust_crate_args` + universal `preBuild` + `links`.
      '' null
      else throw ''
        substrate/lockfile-builder: ${toString src}/Cargo.build-spec.json
        has unsupported schema version ${toString v}. Run `gen build .`
        in the workspace root (gen >= c9a0067) to regenerate against
        SCHEMA_VERSION 3.
      '';
    # I2 — proc-macro host placement (GEN TYPED-SPEC CONTRACT invariant).
    #
    # Proc-macro crates run INSIDE rustc at compile time on the BUILD
    # (host) architecture — never the workload's target arch. cargo
    # follows this rule by default. substrate's earlier single-pkgs
    # design collapsed this distinction and cross-compiled proc-macros
    # to the workload's target (e.g. musl), producing a `-lgcc_s` link
    # failure (musl static linking lacks libgcc_s).
    #
    # Two parallel built trees mirror crate2nix-internal-helpers.nix:
    # - `built` uses `pkgs.buildRustCrate` (workload/target arch).
    #   runtime_dependencies dispatch by spec.crates.${id}.proc_macro:
    #   true → builtBuild (host); false → built (target).
    #   build_dependencies ALWAYS route to builtBuild (build.rs runs on
    #   host).
    # - `builtBuild` uses `pkgs.buildPackages.buildRustCrate` (host
    #   arch); EVERY dep routes to builtBuild — the proc-macro graph is
    #   transitively host.
    #
    # For native builds (hostPkgs == pkgs), the two trees yield
    # identical derivations — the dispatch is a no-op. Real divergence
    # only happens for cross-builds (musl-from-gnu, darwin-from-linux,
    # etc.). hostPkgs is required here (NOT pkgs.buildPackages) because
    # pkgsStatic.buildPackages == pkgsStatic, which collapses the
    # host/target distinction and routes proc-macro builds to the
    # workload's static musl stdenv → autocfg/E0461 target mismatch.
    buildRustCrateTarget = buildRustCrateForPkgs pkgs;
    buildRustCrateHost = buildRustCrateForPkgs hostPkgs;

    workspaceKeys = builtins.listToAttrs
      (map (k: { name = k; value = true; }) spec.workspace_members);
    isWorkspaceMember = key: workspaceKeys ? ${key};

    # Workspace members declare their [[bin]]s explicitly from the
    # spec. Transitive deps get `crateBin = []` to SUPPRESS
    # buildRustCrate's `src/bin/*.rs` auto-detection — those bin
    # files (alloc-no-stdlib's `heap_alloc.rs`, brotli's `brotli.rs`,
    # dotenvy's `dotenvy.rs`, etc.) typically require feature-gated
    # deps (clap, --extern <crate>) that the substrate doesn't pass
    # in, so the bin build fails even though every consumer only
    # ever needs the lib. The explicit `crateBin = []` sets
    # `hasCrateBin` in buildRustCrate, which short-circuits the
    # auto-detection and still allows the lib to build normally.
    # Per-crate overrides in `pleme-crate-overrides.nix` are no
    # longer needed for the alloc-no-stdlib / brotli class of bug —
    # the fix is uniform here.
    # crateBin is the one buildRustCrate arg that depends on
    # workspace-membership context (Nix-side knowledge), so it's
    # computed here rather than in gen. Workspace members keep their
    # declared bins; transitive deps get `crateBin = []` to suppress
    # buildRustCrate's `src/bin/*.rs` auto-detection.
    binsFor = key: crate:
      let bins = map (b: { inherit (b) name path; }) (crate.binaries or []);
      in
        if isWorkspaceMember key
        # ANY workspace member: if the spec says no bins, declare
        # `crateBin = []` explicitly to suppress buildRustCrate's
        # default `src/main.rs` auto-detection. Workspace-relative
        # src means that detection lands on the workspace ROOT's
        # src/main.rs (an orphan file in repos like tatara that
        # split into a multi-crate layout), compiling it as a bin
        # named after the wrong package and failing on dozens of
        # unresolved imports the orphan source uses. The empty list
        # matches cargo metadata's authoritative "no bin targets".
        then (if bins != [] then { crateBin = bins; } else { crateBin = []; })
        else { crateBin = []; };

    # Always layer plemeCrateOverrides in — even when the caller passed
    # their own `defaultCrateOverrides`. Consumers that import
    # lockfile-builder directly (escriba's flake.nix is the canonical
    # example) would otherwise silently drop every fleet-wide quirk we
    # ship (wgpu-hal cfg, openraft BTreeSet patch, document-features
    # lib_target, etc.). Per-crate composition is delegated to
    # `composeOverrideMaps` (./crate-override-compose.nix): the caller's
    # `defaultCrateOverrides` is the `base`, plemeCrateOverrides is the
    # `winner`. The fleet safety-net wins on field collision so a caller's
    # raw nixpkgs default cannot re-introduce the very bug pleme fixes
    # (e.g. proc-macro-crate 3.5.0's broken `--replace-fail` postPatch).
    # Full rationale + regression test live alongside that function
    # (crate-override-compose-test.nix).
    #
    # Triple-aware: each tree-builder (target or host) builds the winner
    # map specialized to the triple it's building for, so substrate
    # safety nets (apple-only feature strip on notify, etc.) fire only on
    # the triples they protect.
    overrideFor = triple: overrideCompose.composeOverrideMaps {
      base = defaultCrateOverrides;
      # The always-applied fleet winner (fires even when a caller passes its own
      # `defaultCrateOverrides`, which the workspace/library path does), PLUS the
      # pkgs-ful crate quirks that `plemeCrateOverridesFor` (pure/pkgs-free)
      # cannot express. `protobuf-src`'s build.rs vendors + builds protobuf via
      # the `cmake` crate, which execs the `cmake` binary — absent from the
      # workspace crate-build's native inputs (the SERVICE path's
      # `[pkg-config cmake perl]` had it), so the build panicked `is \`cmake\`
      # not installed?` (os error 2) → exit 101. Add cmake for this crate here,
      # in the always-applied winner, so every consumer of substrate.rust.*
      # (vigy, …) gets it. Foundational crate requirement, not a repo accident
      # (GEN-TYPED-SPEC-CONTRACT: refine the build at the precise point). Appends
      # so any existing native inputs are preserved.
      winner = (plemeCrateOverridesFor triple) // {
        protobuf-src = attrs: {
          nativeBuildInputs = (attrs.nativeBuildInputs or [ ]) ++ [ pkgs.cmake ];
        };
      };
    };

    # gen ≥ 3e9fbc6 emits `build_rust_crate_args` pre-shaped for
    # buildRustCrate (procMacro, build, links, libName, libPath, …).
    # Nix spreads it verbatim and fills only what it must: `src`
    # (path resolution + workspace narrowing) and the cross-derivation
    # `dependencies` / `buildDependencies`. For older specs that
    # predate the field, reconstruct from the legacy fields so the
    # transition is silent.
    # Rustc crate-name = `[lib].name` when set, else package name with
    # `-` → `_`. Used to set CARGO_CRATE_NAME universally for crates
    # that read it at compile time (rmcp etc). Matches gen-cargo's
    # computation for `build_rust_crate_args.preBuild`.
    rustcCrateName = crate:
      if (crate.lib_target or null) != null
      then crate.lib_target.name
      else builtins.replaceStrings [ "-" ] [ "_" ] crate.name;

    # I1 — Workspace-member lib_target synthesis (stale-spec defense).
    # Per the GEN TYPED-SPEC CONTRACT (theory/GEN-TYPED-SPEC-CONTRACT.md,
    # invariant I1), gen-cargo ≥ 09f6311 always emits lib_target for
    # workspace-member lib crates. Pre-09f6311 specs (still committed in
    # some downstream repos like ishou pre-regeneration) suppressed it
    # for default-named members → substrate would pass no libName/libPath
    # to buildRustCrate → with src = workspaceSrc, rustc resolved
    # `src/lib.rs` against the workspace root (no such file) → no rlib
    # built → consumer's --extern hard-failed.
    #
    # Synthesis is the interpreter side of the contract: when a
    # path-source member with a non-trivial relative_path arrives
    # WITHOUT lib_target, assume the conventional `src/lib.rs` +
    # `rustcCrateName` and let `prefixForMember` glue the relative_path
    # on. The fleet self-heals against stale specs without every
    # consumer needing to push a regen.
    #
    # CORRECTED (task #91, escuta-breathe-bridge): the condition used to
    # also require `binaries == []`, so it only fired for members with
    # NO declared targets at all — contradicting this very function's
    # OWN downstream consumer (`applySynthLibTarget`'s doc-comment
    # below), which explicitly describes handling "the spec carries
    # `binaries` but no `lib_target` (a bin-only workspace member)".
    # With the old `binaries == []` guard, that exact case (an
    # ACCURATELY-reported bin-only member — gen-cargo correctly emits
    # `binaries: [...]`, `lib_target: null`) fell through with NO
    # libPath synthesized at all. nixpkgs' `buildRustCrate` then applied
    # ITS OWN default (`libPath = "src/lib.rs"`, unprefixed, evaluated
    # against `src = workspaceSrc` i.e. the WORKSPACE ROOT) — which, for
    # any workspace laid out as "root package + path-dependency member"
    # (the root Cargo.toml carries a REAL `[package]` with its own
    # `src/lib.rs`, e.g. escuta at the root + escuta-breathe-bridge as a
    # member — as opposed to a virtual `[workspace]`-only root), silently
    # resolved to the ROOT package's real `src/lib.rs` and compiled it
    # under the MEMBER's crate name (`--crate-name escuta_breathe_bridge
    # src/lib.rs --crate-type lib`) — a wrong-source-file build that
    # fails downstream on whatever feature-gated code the root crate
    # exposes. Dropping the `binaries == []` clause routes this case
    # through the SAME synthesis + `prefixForMember` glue as the
    # original I1 fix: `libPath` becomes `<relative_path>/src/lib.rs`,
    # which for a genuine bin-only member does NOT exist, so
    # buildRustCrate's existence check skips the lib build entirely and
    # only the (correctly relative_path-prefixed) `crateBin` gets built —
    # exactly what `applySynthLibTarget`'s comment always promised.
    synthLibTarget = crate:
      let
        srcKind = crate.source.kind or null;
        rel = crate.source.relative_path or "";
        hasMember = srcKind == "path" && rel != "" && rel != ".";
        hasNoLibTarget = (crate.lib_target or null) == null;
      in
        if hasMember && hasNoLibTarget
        then { libName = rustcCrateName crate; libPath = "src/lib.rs"; }
        else {};

    legacyArgs = crate:
      { crateName = crate.name; version = crate.version; edition = crate.edition;
        features = crate.features; crateRenames = crate.crate_renames; release = true;
        preBuild = "export CARGO_CRATE_NAME=${rustcCrateName crate};"; }
      // (if (crate.proc_macro or false) then { procMacro = true; } else {})
      // (if (crate.build_script or null) != null then { build = crate.build_script; } else {})
      // (if (crate.links or null) != null then { links = crate.links; } else {})
      // (if (crate.lib_target or null) != null
          then { libName = crate.lib_target.name; libPath = crate.lib_target.path; }
          else {});

    # Apply lib_target synthesis to ANY args-source missing libName/libPath
    # (legacyArgs OR spread build_rust_crate_args). Idempotent: if the args
    # already declare libName, the synthesis no-ops. When the spec
    # carries `binaries` but no `lib_target` (a bin-only workspace
    # member), explicitly point `libPath` at the member's own
    # `<relative_path>/src/lib.rs` — which doesn't exist — so
    # buildRustCrate's existence check skips the lib build instead
    # of auto-detecting the workspace ROOT's orphan src/lib.rs
    # (present in repos like tatara that split a former monolithic
    # crate into N workspace members; the orphan lib.rs at root
    # gets compiled as a lib named after EVERY bin-only member and
    # fails on dozens of unresolved imports the orphan source uses).
    applySynthLibTarget = crate: args:
      # NOTE: `args ? libName` is `true` even when the attr's value is
      # `null` (Rust's `lib_name: Option<String> = None` serializes to
      # JSON null which Nix reads as the value null, with the attr
      # PRESENT). Filter explicitly on null so the synth branch fires
      # when build_rust_crate_args carries libName=null.
      #
      # Workspace-root orphan `src/lib.rs` / `src/main.rs` (present in
      # repos like tatara that split a former monolithic crate into N
      # workspace members) used to be removed here via a preBuild bash
      # `rm`. That moved upstream — `mkSrcOf` now filters the
      # workspace src derivation with `lib.cleanSourceWith` so bin-only
      # workspace members see a tree where the orphan isn't present
      # at all. Pure Nix, no bash glue, decided once at the source
      # level instead of per-crate at preBuild time.
      if (args ? libName) && args.libName != null then args
      else args // synthLibTarget crate;

    # Path-source workspace members now use src = workspaceSrc (so
    # include_str! to sibling files works). libPath / build / crateBin
    # entries need a `<relative_path>/` prefix to compensate. Pure
    # string transform on the args attrset.
    prefixForMember = crate: args:
      if crate.source.kind != "path" then args
      else let rel = crate.source.relative_path or ""; in
        if rel == "" || rel == "." then args
        else let p = path: rel + "/" + path; in args
          // (if args ? libPath then { libPath = p args.libPath; } else {})
          // (if args ? build then { build = p args.build; } else {})
          // (if args ? crateBin && args.crateBin != []
              then { crateBin = map (b: b // { path = p b.path; }) args.crateBin; }
              else {});

    # Typed per-tree construction. Each tree iterates ITS OWN
    # platform-filtered spec (per I4) — `specTarget` for the workload
    # tree, `specHost` for the build-arch tree. `depFor`/`buildDepFor`
    # close over the appropriate target/host trees per I2 dispatch.
    # `buildRustCrate` is the per-tree builder (target vs. host pkgs).
    #
    # Multi-target spec support (schema v5+, #25): when the spec
    # carries `target_resolves[triple]`, dep edges come from that
    # target's section — eliminates the gen-bootstrap chicken-and-egg.
    # Fall back to per-crate `runtime_dependencies` / `build_dependencies`
    # for older specs (schema < 5).
    # Reconstruct a target's { crates = <key→edges> } section, handling
    # BOTH shapes purely by structure (no version gate):
    #   • compact v10: target_resolves = { base; targets; }; a target's
    #     crates = base // targets.<triple>.overrides. `base` holds crates
    #     whose resolved edges are byte-identical across ALL fleet targets
    #     (stored once); `overrides` holds the per-target remainder.
    #   • legacy v5–v9: target_resolves.<triple> = { crates; }.
    # gen-cargo owns the base/override split (rust-for-logic); this is the
    # trivial attrset-merge expansion — pure dispatch, no computation.
    sectionFor = treeSpec: triple:
      let tr = treeSpec.target_resolves or null; in
      if tr == null then null
      else if tr ? base
        then { crates = tr.base // ((tr.targets.${triple} or {}).overrides or {}); }
        else tr.${triple} or null;

    depsFor = treeSpec: triple: key: crate:
      let
        section = sectionFor treeSpec triple;
        edges = if section != null then section.crates.${key} or null else null;
      in
        if edges != null
        then { runtime = edges.runtime_dependencies; build = edges.build_dependencies; }
        else { runtime = crate.runtime_dependencies; build = crate.build_dependencies; };

    # Edge-derived crate renames — renamed deps à la
    # `serde = { package = "serde_core" }` (semver 1.0.28+).
    #
    # v9+ specs serialize the per-crate `crate_renames` field empty
    # (skip_serializing) and the delta reconstruction defaults it to {},
    # so the ONLY surviving source of rename truth is the resolve edge
    # itself: `name` is cargo metadata's NodeDep.name (the extern name
    # as written in consumer source — the rename when renamed, else the
    # dep's lib target name) while `package_key` is the actual package.
    # When the edge name differs from the dep's rustc crate name, emit a
    # buildRustCrate `crateRenames` entry (keyed by dep crateName, in
    # the versioned-list form) so rustc gets `--extern <alias>=…` to
    # match the consumer's `use <alias>::…`. Without this, semver
    # 1.0.28 builds with `--extern serde_core` and dies E0433 on
    # `use serde::…`.
    edgeRenamesFor = treeSpec: edges:
      let
        normalize = builtins.replaceStrings [ "-" ] [ "_" ];
        renameOf = e:
          let t = treeSpec.crates.${e.package_key} or null;
          in
            if t == null || (e.name or null) == null
               || normalize e.name == normalize (rustcCrateName t)
            then null
            else { crateName = t.name; entry = { version = t.version; rename = e.name; }; };
        renames = builtins.filter (r: r != null) (map renameOf edges);
      in
        lib.foldl'
          (acc: r: acc // {
            ${r.crateName} = (acc.${r.crateName} or [ ]) ++ [ r.entry ];
          })
          { }
          renames;

    mkBuiltTree = { treeSpec, triple, buildRustCrate, depFor, buildDepFor }:
      let
        # Multi-target spec (#25): iterate only crates ACTUALLY REACHABLE
        # for the current target — restricts `built` to the per-target
        # subset. Without this, apple-only crates (wgpu-core-deps-apple,
        # core-graphics-types, objc-sys) exist as keys in `built` for
        # linux trees because they live in the spec's universe
        # (`spec.crates`). Some dep paths transitively reach those keys
        # through the per-crate `runtime_dependencies` fallback for
        # crates missing from target_resolves — which builds apple-only
        # sources on linux and fails with E0455 "link kind framework
        # is only supported on Apple targets".
        #
        # Restricting iteration to target_resolves[triple].crates keys
        # closes the leak. Old specs (no target_resolves) fall back to
        # spec.crates — the legacy single-target behavior.
        targetCrates =
          let section = sectionFor treeSpec triple;
          in
            if section != null
            then builtins.intersectAttrs section.crates treeSpec.crates
            else treeSpec.crates;
        # ── co-fresh build-only binary-vendor leaves (E0460 fix) ──────
        # Crate-name prefixes for the "vendored binary, non-reproducible
        # rlib SVH" family. `protoc-bin-vendored{,-<plat>-<arch>}` each
        # embed a ~5 MB protoc binary via include_bytes!; substrate sets
        # no SOURCE_DATE_EPOCH / --remap-path-prefix, so the compiled
        # rlib's strict-version-hash (SVH) is NOT bit-reproducible across
        # independent builds of the SAME .drv. On a PARTIAL cache hit the
        # parent rlib (substituted from nexus, baked against an OLD child
        # SVH) is linked against a freshly-rebuilt child (NEW SVH) →
        # rustc E0460 "found possibly newer version of crate
        # protoc_bin_vendored_linux_x86_64 which protoc_bin_vendored
        # depends on" (build.rs of any tonic/prost consumer). Forcing the
        # whole family to build LOCALLY (allowSubstitutes = false) makes
        # parent AND child realise CO-FRESH in one run, so the parent
        # always records the exact child SVH present on the -L path —
        # the skew becomes structurally unreachable. Fixes every musl
        # container-image build with a gRPC/protoc build-dependency
        # (~14 fleet repos). DESTINATION (not yet shipped): bit-
        # reproducible rlibs (SOURCE_DATE_EPOCH + --remap-path-prefix +
        # CA derivations) so a partial hit is HARMLESS rather than
        # avoided — then this prefix list retires.
        coFreshLeafPrefixes = [ "protoc-bin-vendored" ];
        isCoFreshLeaf = name: lib.any (p: lib.hasPrefix p name) coFreshLeafPrefixes;
      in
      lib.mapAttrs (key: crate: let
        deps = depsFor treeSpec triple key crate;
        # Per-target features (schema v5+): cargo's resolver computes
        # different features per target due to cfg-conditional feature
        # activations (e.g. macos_fsevent on apple-only). Without this,
        # substrate passed crate.features (the universe) to rustc on
        # every target, leaking apple features into linux builds.
        # Fall back to crate.features for old specs.
        featuresFor =
          let
            section = sectionFor treeSpec triple;
            sectionCrate = if section != null then section.crates.${key} or null else null;
          in
            if sectionCrate != null && sectionCrate ? features
            then sectionCrate.features
            else crate.features;
        # Spec-declared args (build_rust_crate_args spread or legacy
        # reconstruction). Factored out so crateRenames can layer the
        # edge-derived renames over whatever the spec declared (older
        # full specs carried real per-crate crate_renames; v9+ read
        # empty — see edgeRenamesFor). NOTE: build_rust_crate_args may
        # carry `crateRenames = null` (Rust Option → JSON null), so
        # filter on null, not just attr presence.
        specArgs = if crate ? build_rust_crate_args && crate.build_rust_crate_args != {}
                then crate.build_rust_crate_args
                else legacyArgs crate;
        declaredRenames =
          let r = specArgs.crateRenames or null;
          in if r == null then { } else r;
        baseArgs = specArgs // {
          src = (mkSrcOf hostPkgs) (filteredWorkspaceSrcFor crate) crate;
          dependencies = map depFor deps.runtime;
          buildDependencies = map buildDepFor deps.build;
          features = featuresFor;
          crateRenames = declaredRenames
            // edgeRenamesFor treeSpec (deps.runtime ++ deps.build);
        } // binsFor key crate
        # Defensive: ALWAYS forward `links` from the top-level
        # CrateSpec field (gen-cargo populates this from cargo
        # metadata's pkg.links — set IF the upstream Cargo.toml has
        # a `[package].links` declaration). Without this, ring
        # 0.17.14's build.rs:286 `assert_eq!(env, "ring_core_0_17_14_")`
        # fires (it inspects CARGO_MANIFEST_LINKS, which buildRustCrate
        # exports verbatim from the args' `links` attr) and the build
        # crashes. The build_rust_crate_args spread above ALSO carries
        # `links` when present, but legacyArgs only sets links
        # conditionally — and consumer call paths that go through
        # crate2nix's overrideAttrs can shadow it. This belt-and-
        # suspenders extraction guarantees substrate ↔ buildRustCrate
        # never lose links for the *-sys class of crate.
          // (if (crate.links or null) != null
              then { links = crate.links; }
              else {});
        # Apply lib_target synthesis BEFORE prefixForMember so the
        # synthesized libPath gets the same `<relative_path>/` glue as a
        # declared one. Self-heals stale specs (pre-09f6311 gen-cargo
        # emission) without requiring every consumer repo to regenerate.
        argsSynth = applySynthLibTarget crate baseArgs;
        argsPrefixed = prefixForMember crate argsSynth;
        # Mechanical dispatch from typed CrateQuirk variants (emitted by
        # gen-cargo into `crate.quirks`) to their class-helper apply
        # functions. Zero per-crate Nix-attrset knowledge — the registry
        # is in Rust at `gen-cargo/src/quirks.rs::REGISTRY`. Quirks
        # contribute additional override fields that merge on top of the
        # base args; the consumer's own override (overrideFor) wins on
        # collision.
        quirkAttrs = quirkApply.applyQuirks (crate.quirks or []) argsPrefixed;
        # NativeBuildInputs-kind quirks emit nixpkgs attribute-name
        # STRINGS, not derivations (quirk-apply.nix is deliberately
        # pkgs-free — see its header). Resolve names to real
        # derivations here via `hostPkgs` (NOT `pkgs`/`pkgs.buildPackages`
        # directly — `hostPkgs` is this file's existing build-platform
        # pkgs binding, already used for `mkSrcOf hostPkgs` above, and
        # native build TOOLS must run on the build machine, not the
        # target). Assumes no other source ever seeds
        # `argsPrefixed.nativeBuildInputs` with real derivations — true
        # today (no spec field, no override does), so the quirk fold's
        # accumulated list is string-only end to end.
        args = argsPrefixed // quirkAttrs // (
          lib.optionalAttrs (quirkAttrs ? nativeBuildInputs) {
            nativeBuildInputs = map (n: hostPkgs.${n}) quirkAttrs.nativeBuildInputs;
          }
        );
        # ── propagatedBuildInputs gap-fill ──────────────────────────
        # nixpkgs' buildRustCrate (pkgs/build-support/rust/build-rust-crate/default.nix)
        # reads `crate.buildInputs` + `crate.nativeBuildInputs` but
        # *not* `crate.propagatedBuildInputs`. Overrides like
        # `defaultCrateOverrides.curl-sys` that set
        # `propagatedBuildInputs = [pkgs.curl]` get silently dropped
        # — final binaries linking against curl-sys see "library not
        # found for -lcurl" because curl never reaches stdenv's
        # NIX_LDFLAGS path.
        #
        # We close the gap substrate-side without touching nixpkgs:
        #   1. Extract `propagatedBuildInputs` from the override's
        #      output BEFORE merging into the buildRustCrate args.
        #   2. Fold the crate's own propagated set + every dep's
        #      transitive propagated set into `buildInputs` of THIS
        #      crate's mkDerivation. Mechanical equivalent of what
        #      stdenv would do if buildRustCrate forwarded the attr.
        #   3. Stash the union on the resulting derivation as
        #      `propagatedFromOverride` so direct dependents pick it
        #      up via the same fold (transitive closure by induction).
        overrideExtras = overrideFor triple crate.name args;
        ownPropagated = overrideExtras.propagatedBuildInputs or [];
        depDrvs = (map depFor deps.runtime) ++ (map buildDepFor deps.build);
        depPropagated = lib.unique
          (lib.concatMap (d: d.propagatedFromOverride or []) depDrvs);
        # Drop `propagatedBuildInputs` via removeAttrs — setting it to
        # `null` here flows through buildRustCrate to stdenv's
        # make-derivation, which calls `length propagatedBuildInputs`
        # and throws "expected a list but found null". The override's
        # propagated set has already been folded into `buildInputs`
        # above, so the attr is redundant; just take it out of the
        # attrset entirely.
        mergedExtras = (removeAttrs overrideExtras [ "propagatedBuildInputs" ]) // {
          buildInputs = (overrideExtras.buildInputs or [])
            ++ ownPropagated
            ++ depPropagated;
        };
        # Iterate `targetCrates` (per-target subset), NOT treeSpec.crates
        # (the multi-target universe). Restricts `built` to crates actually
        # reachable for this target — keeps apple-only drvs out of linux
        # trees and vice versa. See targetCrates definition above.
        rawDrv =
          let d = buildRustCrate (args // mergedExtras);
          in if isCoFreshLeaf crate.name
             then d.overrideAttrs (_: { allowSubstitutes = false; })
             else d;
      in rawDrv // {
        propagatedFromOverride =
          lib.unique (ownPropagated ++ depPropagated);
      }) targetCrates;

    # Target tree: workload arch + target-filtered dep edges (I4).
    # Dispatch runtime deps via the typed `dep.tree` field gen-cargo
    # populates per the BuildTree enum (#12). Old specs (schema < 4)
    # don't carry `tree` — fall back to the proc_macro lookup for
    # backward compat. New specs (schema >= 4) bypass that and read
    # the typed field directly — the dispatch decision lives in Rust
    # at spec-emission time, not in Nix at evaluation time.
    built = mkBuiltTree {
      treeSpec = specTarget;
      triple = targetTriple;
      buildRustCrate = buildRustCrateTarget;
      depFor = d:
        let
          legacy = specTarget.crates.${d.package_key}.proc_macro or false;
          tree = d.tree or (if legacy then "host" else "target");
        in if tree == "host"
           then builtBuild.${d.package_key}
           else built.${d.package_key};
      buildDepFor = d: builtBuild.${d.package_key};
    };

    # Host tree: build/native arch + host-filtered dep edges (I4).
    # Transitively all-host.
    builtBuild = mkBuiltTree {
      treeSpec = specHost;
      triple = hostTriple;
      buildRustCrate = buildRustCrateHost;
      depFor = d: builtBuild.${d.package_key};
      buildDepFor = d: builtBuild.${d.package_key};
    };

    memberRecord = key: let c = spec.crates.${key}; in {
      name = c.name;
      value = { packageId = c.name; build = built.${key}; debug = built.${key}; };
    };
  in {
    rootCrate = { packageId = spec.crates.${spec.root_crate}.name; build = built.${spec.root_crate}; debug = built.${spec.root_crate}; };
    workspaceMembers = builtins.listToAttrs (map memberRecord spec.workspace_members);
    crates = spec.crates;
    allWorkspaceMembers = pkgs.symlinkJoin {
      name = "all-workspace-members";
      paths = map (k: built.${k}) spec.workspace_members;
    };
  };
in {
  inherit mkProject loadBuildSpec;
}
