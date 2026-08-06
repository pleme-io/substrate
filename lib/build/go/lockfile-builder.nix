# lockfile-builder.nix (Go) — priority-ladder resolver for the Go build-spec.
#
# The Go analogue of substrate/lib/build/rust/lockfile-builder.nix. Resolves
# the typed `buildGoModule` args (esp. `vendorHash`) for a Go module from gen's
# produced artifacts, via the SAME delta > build-spec > IFD priority ladder the
# rust side uses:
#
#   0) deltaSpec  = lockfile-delta.reconstruct src   (HIGHEST — IFD-free,
#                   pure-Nix reconstruct from go.mod/go.sum + the slim
#                   Go.gen.lock, with the D2 freshness gate).
#   1) Go.build-spec.json committed  → builtins.fromJSON (full spec).
#   2) IFD via mk-build-spec.nix     → `gen build .` in a __noChroot sandbox.
#
# The `vendorHash` honors gen's `has_external_deps` contract: gen emits a
# vendorHash ONLY when the module declares external `require` edges; for
# in-tree / dep-free modules the spec carries no vendorHash and this builder
# returns `vendorHash = null` (nixpkgs "vendor/ already in source / no deps").
#
# This file is a PURE RESOLVER — it returns the typed args attrset; it does not
# itself call buildGoModule. mkGoTool consumes `resolve { src; … }` and spreads
# the result. Keeping the resolver pure makes it trivially testable via
# `nix eval` (the delta-reconstruct oracle) without a heavy buildGoModule run.
{ pkgs, lib ? pkgs.lib }:

let
  inherit (builtins) fromJSON readFile pathExists;

  lockfileDelta = import ./lockfile-delta.nix { inherit lib; };

  # Pick the single PackageSpec out of a full-spec-shaped attrset. gen-gomod is
  # single-module today (one `[package]`, no multi-member workspace), so the
  # root package is the workload-facing spec. Falls back to the first package
  # when `root_package` is absent.
  rootPackage = spec:
    let
      key =
        if (spec.root_package or null) != null
        then spec.root_package
        else lib.head (builtins.attrNames spec.packages);
    in
      spec.packages.${key};

  # Resolve the full spec for `src` via the priority ladder. Returns null only
  # when NOTHING is available AND gen is unreachable (handled by the throw in
  # the IFD branch).
  resolveSpec =
    { src
    , gen ? null
    , hostPkgs ? pkgs.buildPackages
    }:
    let
      # 0) Highest-priority: the slim Go.gen.lock delta, reconstructed in PURE
      #    NIX (readFile go.mod + fromTOML-free go.sum hash + the slim delta).
      #    IFD-free, cache-shared. `null` when no Go.gen.lock present.
      deltaSpec = lockfileDelta.reconstruct src;

      # 1) Committed full build-spec.
      committedPath = src + "/Go.build-spec.json";
      committedSpec =
        if pathExists committedPath
        then fromJSON (readFile committedPath)
        else null;

      # 2) IFD fallback via mk-build-spec.nix → `gen build .`.
      ifdNeeded = deltaSpec == null && committedSpec == null;
      ifdSpecDrv =
        if ifdNeeded
        then import ./mk-build-spec.nix { inherit hostPkgs gen src; }
        else null;
      ifdSpec =
        if ifdSpecDrv != null
        then fromJSON (readFile (ifdSpecDrv + "/Go.build-spec.json"))
        else null;
    in
      if deltaSpec != null then deltaSpec
      else if committedSpec != null then committedSpec
      else ifdSpec;

  # Public: resolve the typed buildGoModule args (the workload-facing view).
  # The shape mirrors gen-gomod's `PackageArgs` (camelCase keys ready to spread
  # into buildGoModule). `vendorHash` is null when the module has no external
  # deps (gen's `has_external_deps = false`).
  resolve =
    { src
    , gen ? null
    , hostPkgs ? pkgs.buildPackages
    }:
    let
      spec = resolveSpec { inherit src gen hostPkgs; };
      pkg = rootPackage spec;
      args = pkg.args or { };

      # WHICH NODE CARRIES has_external_deps. gen emits it on the MODULE
      # (gen-gomod/src/build_spec.rs, ModuleSpec), computed correctly as
      # `!requires.is_empty()` (gomod.rs). It is NOT on the package node —
      # PackageSpec's args carry only gcflags/ldflags/env.
      #
      # This read used to be `pkg.has_external_deps or false`, against the
      # package. The field is never there, so `or false` made EVERY module
      # look dep-free, which forced vendorHash to null, which put
      # buildGoModule into vendor mode, which failed "inconsistent vendoring"
      # on 25 repos that track no vendor/ directory at all. The shape it was
      # written against is lockfile-delta.nix's synthesized package, not
      # gen's real output — so only the delta rung ever worked.
      #
      # Read the module first, fall back to the package so the delta rung
      # keeps working, and THROW when neither carries it. A missing field
      # must never again be silently read as "dep-free": that is the exact
      # conflation that produced a green eval and an unbuildable derivation.
      hasExternalDeps =
        spec.module.has_external_deps
          or pkg.has_external_deps
          or (throw ("substrate.lockfile-builder: neither spec.module nor the root "
            + "package carries `has_external_deps`. Refusing to assume dep-free — "
            + "that assumption forces vendorHash=null and puts buildGoModule into "
            + "vendor mode. Re-run `gen build` to produce a current spec."));
    in
      args // {
        # null is CORRECT for a genuinely dep-free module — buildGoModule skips
        # the vendor FOD. It is a LIE for a module with deps: nixpkgs reads null
        # as "vendor/ is already in the source", and a repo that tracks no
        # vendor/ then dies "inconsistent vendoring" deep in buildPhase.
        #
        # So the deps case demands a real hash. gen does not emit one today
        # (gen-gomod/src/interp.rs passes vendor_hash: None unconditionally),
        # and `or null` silently papered over that — turning a missing hash
        # into the exact wrong answer instead of a question. Throw instead, and
        # name where the hash has to come from.
        vendorHash =
          if !hasExternalDeps then null
          else args.vendorHash or spec.module.vendorHash or (throw
            ("substrate.lockfile-builder: the module declares external deps but the "
              + "spec carries no vendorHash, and null would put buildGoModule into "
              + "vendor mode against a tree with no vendor/ directory. Pass vendorHash "
              + "explicitly at the call site, or fix gen to emit vendor_hash "
              + "(gen-gomod interp.rs hardcodes None + DepMode::Vendored)."));
      };

  # Convenience: just the resolved vendorHash (what mkGoTool needs when the
  # consumer omits it). Honors has_external_deps → null contract.
  resolveVendorHash = a: (resolve a).vendorHash;

in {
  inherit resolve resolveSpec resolveVendorHash rootPackage;
}
