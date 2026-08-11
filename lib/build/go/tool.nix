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
  #
  # vendorHash (spec-sourced when omitted — backward-compatible):
  #   The hash for Go module dependencies (null if vendored in-tree / no deps).
  #
  #   * When the consumer PASSES vendorHash explicitly — including an explicit
  #     `null` for in-tree modules — that value WINS verbatim. This preserves
  #     full backward compatibility for every existing mkGoTool caller.
  #   * When the consumer OMITS vendorHash, the builder consults gen's produced
  #     Go build-spec for `src` via the Go lockfile-builder (delta > build-spec
  #     > IFD ladder). The vendorHash comes from the spec when the module has
  #     external deps (gen's `has_external_deps`), and is `null` otherwise.
  #
  #   The sentinel default `"__from-spec__"` distinguishes "omitted" from a
  #   real consumer-supplied value (including null) — a string default that no
  #   real SRI hash collides with.
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
    # Sentinel default → "consult the spec". A consumer-supplied value
    # (including explicit `null` for in-tree modules) overrides the sentinel
    # and wins verbatim. See the vendorHash doc block above.
    vendorHash ? "__from-spec__",
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
    # Rewrite a bare-minor `go 1.N` to `go 1.N.0` in go.mod at build time.
    #
    # OPT-IN, and it must stay opt-in. The bare-minor trace below exists to
    # push the fix UPSTREAM, where it belongs and where it is one line. Turning
    # this on fleet-wide would silence that signal for every repo we can
    # actually fix, converting a tracked, counted class into an invisible one.
    #
    # It is for the case where upstream is genuinely unreachable: a third-party
    # source we do not own and cannot push to. Set it there, with the reason at
    # the call site, and nowhere else.
    #
    # CAVEAT, MEASURED NOT ASSUMED: this edits go.mod before vendoring, so it
    # can in principle move `vendorHash`. `1.N` and `1.N.0` are the same
    # minimum language version and select the same module-graph pruning, so
    # resolution should be identical — but "should" is not evidence. A shift
    # fails LOUDLY as a hash mismatch, never silently, so the failure mode is
    # recoverable; recompute and pin.
    normalizeGoDirective ? false,
    description ? "${pname} - Kubernetes tool",
    homepage ? null,
    license ? pkgs.lib.licenses.asl20,
    platforms ? pkgs.lib.platforms.all,
  }: let
    lib = pkgs.lib;

    # ── Spec-sourced vendorHash (backward-compatible) ─────────────────
    # The sentinel `"__from-spec__"` means the consumer OMITTED vendorHash →
    # consult gen's produced Go build-spec for `src` via the Go lockfile-builder
    # (delta > build-spec > IFD ladder). Any other value — including an explicit
    # `null` for in-tree modules — was passed by the consumer and wins verbatim.
    # `modRoot` narrows the spec lookup to the module subdir for monorepos.
    vendorHashFromSpec = vendorHash == "__from-spec__";
    specSrc =
      if modRoot != null then (src + "/${modRoot}") else src;
    goLockfileBuilder = import ./lockfile-builder.nix { inherit pkgs lib; };
    effectiveVendorHash =
      if vendorHashFromSpec
      then goLockfileBuilder.resolveVendorHash { src = specSrc; }
      else vendorHash;

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
    goOverlayLib = import ./overlay.nix;

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

    # Substrate's from-source goToolchain (pkgs.go) is the single source of truth
    # for the fleet Go version. Assert — at EVAL time, typed via the canonical
    # builtins.compareVersions (NOT fragile shell parsing) — that the consuming
    # go.mod's `go` directive is not AHEAD of the toolchain. Otherwise the build
    # would fail deep in `go mod download` with the cryptic "requires go >= X
    # (running Y; GOTOOLCHAIN=local)". Fleet rule: authored go.mod declares a
    # version NOT AHEAD of the builder — that, and only that, is the predicate.
    #
    # DO NOT prescribe the bare minor (`go 1.26`). MEASURED 2026-08-06 with a
    # two-module reproduction: cmd/go orders a bare `1.N` STRICTLY BELOW `1.N.0`,
    # and a module's `go` directive must be >= every module in its graph. So
    # `go 1.25` against a dependency declaring `go 1.25.0` fails with "updates to
    # go.mod needed", and `go 1.26` fails against `go 1.26.0`. Today that floor is
    # raised by every current golang.org/x/*, k8s.io/*, crossplane, connectrpc and
    # validator release, so bare-minor is unsatisfiable for most real modules.
    # `1.N.0` is the lowest form that clears it, which is why the remediation below
    # suggests that rather than the minor.
    #
    # Reading go.mod is tryEval-guarded, so a non-path / unreadable src silently
    # skips the check rather than breaking the build.
    # The go.mod directive read + its verdict, bound ONCE. Both consumers — the
    # eval-time assert below and `goDirectiveNormalization`'s rewrite — read
    # this. They used to be two scopes: `req`/`verdict` lived inside
    # `goVersionAssert`'s own `let`, so the normalization's guard referenced an
    # undefined variable and every mkGoTool consumer failed to evaluate.
    goDirectiveFacts =
      let
        directive = import ./directive.nix { inherit lib; };
        gomodPath = "${src}/${lib.optionalString (modRoot != null) (modRoot + "/")}go.mod";
        read = builtins.tryEval (builtins.readFile gomodPath);
        goLine =
          if read.success
          then lib.findFirst (l: lib.hasPrefix "go " l) null (lib.splitString "\n" read.value)
          else null;
        req =
          if goLine == null then null
          else lib.head (lib.splitString " " (lib.removePrefix "go " goLine));
        tool = pkgs.go.version;

        # ── ONE PREDICATE, 2026-08-08 ────────────────────────────────
        # The ordering rule used to be re-derived here inline. That is the
        # second-copy shape that let Go.gen.lock's producer and consumer
        # disagree on 12 of 13 fields, so the comparison now lives in
        # ./directive.nix and is driven by directive-vectors.json — the same
        # table gen's Rust half reads.
        verdict = directive.classify { directive = if req == null then "" else req; fleetGo = tool; };
      in { inherit req tool verdict; };

    goVersionAssert =
      let
        inherit (goDirectiveFacts) req tool verdict;
      in
        # THROW SCOPED TO `above-fleet-toolchain` ONLY. cmd/go genuinely
        # refuses that one, and it has 0 fleet offenders today, so the throw
        # ships with nothing to break.
        #
        # BARE-MINOR IS A TRACE, NOT A THROW, and that is deliberate. Measured
        # on go1.25.10: bare-minor BUILDS under -mod=mod (go silently rewrites
        # go.mod to the patch form) and fails only under -mod=readonly/vendor.
        # 29 of 69 Nix-Go repos are bare-minor, so throwing here breaks 29
        # repos in one commit to fix a class that self-heals on the loose
        # path. Escalation has a COUNTED done-predicate — `gen adopt-go
        # --dry-run --all` reporting bare-minor-directive == 0 — not a
        # judgement call.
        if verdict.verdict == "above-fleet-toolchain"
        then throw ("substrate.mkGoTool: ${pname} go.mod requires 'go ${req}' but the substrate "
          + "goToolchain is ${tool}. ${verdict.why} Lower go.mod to at most 'go ${tool}' — the lowest "
          + "form that still clears a dependency floor is 'go ${lib.versions.majorMinor tool}.0'; a bare "
          + "'go ${lib.versions.majorMinor tool}' sorts BELOW it. "
          + "Otherwise raise the fleet pin in lib/build/go/go-toolchain-pin.json.")
        else if verdict.verdict == "bare-minor" && normalizeGoDirective
        # Normalized locally because upstream is unreachable. One line, not a
        # paragraph: there is no action for a reader to take, so the long
        # remediation text would be noise repeated per package.
        then builtins.trace
          "substrate.mkGoTool: ${pname} 'go ${req}' -> 'go ${req}.0' (normalized locally; upstream not ours)"
          null
        else if verdict.verdict == "bare-minor"
        then builtins.trace
          ("substrate.mkGoTool: ${pname} declares a bare-minor 'go ${req}'. ${verdict.why} "
            + "This builds today; it fails under -mod=readonly/-mod=vendor. Fix is one line: 'go ${req}.0'.")
          null
        else null;

      # The rewrite itself. Anchored to the directive line so it cannot touch a
      # `go 1.N` appearing anywhere else (a require line, a comment), and a
      # no-op when the directive is already patch-form.
      goDirectiveNormalization =
        lib.optionalString (
          normalizeGoDirective
          && goDirectiveFacts.req != null
          && goDirectiveFacts.verdict.verdict == "bare-minor"
        ) ''
          sed -i -E 's|^go[[:space:]]+([0-9]+\.[0-9]+)$|go \1.0|' ''${modRoot:-.}/go.mod
        '';

  in builtins.seq goVersionAssert (goOverlayLib.assertGoFloor { what = pname; drv = pkgs.buildGoModule ({
    inherit pname version src proxyVendor doCheck tags;
    vendorHash = effectiveVendorHash;

    nativeBuildInputs = completionAttrs.nativeBuildInputs ++ extraBuildInputs;

    ldflags = effectiveLdflags;

    postInstall = completionAttrs.postInstallScript + extraPostInstall;

    # Runs before vendoring, which is exactly why it can move vendorHash — see
    # the caveat on `normalizeGoDirective`. Empty string when the option is off
    # or the directive is already patch-form, so the default path is untouched.
    postPatch = goDirectiveNormalization + (extraAttrs.postPatch or "");

    meta = {
      inherit description license platforms;
      mainProgram = pname;
    } // lib.optionalAttrs (homepage != null) { inherit homepage; };
  }
  // lib.optionalAttrs (subPackages != null) { inherit subPackages; }
  // lib.optionalAttrs (modRoot != null) { inherit modRoot; }
  // extraAttrs); });

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
