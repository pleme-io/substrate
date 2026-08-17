# lockfile-delta.nix — reconstruct a full Go BuildSpec-shaped attrset from the
# repo's `go.mod` / `go.sum` (parsed in PURE NIX via builtins/lib) + the slim
# `Go.gen.lock` delta.
#
# Consumer half of gen-gomod's gomod-parity contract — the Go analogue of
# substrate/lib/build/rust/lockfile-delta.nix. The slim delta carries ONLY the
# facts go.mod/go.sum cannot express on their own (principally the per-package
# `vendorHash`, plus the build-shaping scalars tags/ldflags/subPackages/quirks).
# Everything go.mod/go.sum already pins (module path, dep versions, dep hashes)
# is reconstructed here from `builtins.readFile` of go.mod — never restated in
# the delta. This trades a small reconstruction for an IFD-free, cache-shared,
# slim committed artifact (mirrors the rust delta path).
#
# ── ★ THE OUTPUT SHAPE IS A GENERATION BEHIND THE ENCODER (2026-08-17) ──
#
# This header used to claim "Output shape == `Go.build-spec.json`". MEASURED:
# it is not. This reader reconstructs the **v1 COARSE** shape below, while
# gen-gomod's encoder emits **v2 INCREMENTAL**
# (`gen/crates/gen-gomod/src/build_spec.rs:35`, `SCHEMA_VERSION = 2`; coarse is
# `:48`, = 1). So the delta rung and the full-spec rung produce DIFFERENT
# shapes, and the claim of equality is what makes that invisible.
#
# WHY THIS MATTERS BEFORE ANYONE "JUST WIRES THE EMITTER". gen-gomod's
# `write_gen_delta` has zero call sites and emits no `per_package` at all, so
# the obvious next step looks like completing the producer. That was attempted
# and MEASURED against four real repos (akeyless-funnel, -gateway-migrator,
# -go-test, -go): with a complete `per_package`, the reader ACCEPTS every delta
# and the D2 tie round-trips byte-exact — and parity still FAILS, 1085 raw
# diffs collapsing to 27 classes, all 27 on all four subjects. Only 6 are the
# documented absent-vs-`[ ]` defaults. The rest follow from the version gap:
#
#   - `$.version` is 1 from the delta and 2 from the encoder — two version
#     namespaces sharing one field name
#   - `$.module` (whole attrset) and `$.renderer` have NO home in the closed
#     topLevel set, yet `lockfile-builder.nix:118` reads
#     `spec.module.has_external_deps` and THROWS without it, and
#     `package-builder.nix:11` dispatches on `spec.renderer`
#   - `has_external_deps` reconstructs `false` on every node where the encoder
#     says `true`
#   - `workspace_members` comes back as MODULE PATHS where the encoder emits
#     NODE KEYS, asserting buildable mains that do not exist
#
# So the missing link is THIS READER reconstructing v2, not the producer. Doing
# the producer first yields a delta that is accepted and still wrong.
#
# TWO TRAPS FOUND WHILE MEASURING, both worth knowing before touching either
# half:
#
#   1. `vendor_hash` absence is OVERLOADED. perPackage documents it as "ABSENT
#      IS MEANINGFUL: no external deps", but the real corpus has a third state:
#      deps exist, `dep_mode = vendored`, and no hash was ever computed. An
#      emitter that omits the hash in that case makes this reader derive
#      `has_external_deps = false` for a module where it is true. Reproduced
#      both directions on akeyless-funnel.
#   2. `root_package = head packageKeys` picks the LEXICOGRAPHICALLY FIRST key,
#      not the main module's node. Every one of the four subjects happens to
#      have an alphabetically-minimal main module, so a corpus of those four
#      cannot fail on root selection — a green result there carries no
#      information.
#
# CEILING, so nobody plans against 90: gen's per-node encoder REFUSES packages
# with assembly sources (`interp phase reject-asm`, deferred to M-asm). Of 90
# fleet repos with a root `go.mod`: 41 encode, 42 reject on asm, 7 fail for
# unrelated reasons. Anything depending on `golang.org/x/sys/unix` is in the 42.
#
# The v1 coarse shape this reader currently produces (fed where `committedSpec`
# is fed in lockfile-builder.nix):
#
#   { version; packages = { <key> = { name; version; args = { pname; version;
#       vendorHash?; proxyVendor?; tags; ldflags; subPackages; doCheck?; env;
#       nativeBuildInputs; buildInputs; }; has_external_deps; quirks; }; };
#     root_package; workspace_members; }
#
# D2 FRESHNESS GATE (mirrors cargo's D2 `cargo_lock_sha256` tie): `throw` if
# `delta.go_sum_sha256 != builtins.hashFile "sha256" "${src}/go.sum"`. A match
# means the committed `vendorHash` is still valid (the dep set is unchanged).
# When the module is dependency-free and has no go.sum, the tie is the SHA-256
# of the empty string (matches gen-gomod's `sha256_hex(b"")`).
#
# `reconstruct src` returns `null` when no `Go.gen.lock` is present → the
# builder falls through to the full `Go.build-spec.json`, then to IFD.
{ lib }:
let
  inherit (builtins)
    fromJSON readFile pathExists hashFile listToAttrs map head match seq;

  # The one compare-and-throw shape, shared with build/rust/lockfile-delta.nix
  # and build/rust/cargo-nix-tie.nix.
  tie = import ../shared/freshness-tie.nix { };

  # The closed schema. Every read of the delta goes through it; a bare `or`
  # in this file is the defect it exists to prevent (see delta-schema.nix).
  schema = import ./delta-schema.nix { inherit lib; };

  # gen-gomod's freshness tie when a module has no go.sum: the SHA-256 of the
  # empty string. Matches `gen_delta::sha256_hex(b"")` exactly.
  emptyGoSumSha256 =
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

  # Parse the module path out of `go.mod`'s `module <path>` directive. Pure
  # Nix line scan — no subprocess, no regex over the whole file.
  goModModulePath = goModSrc:
    let
      lines = lib.splitString "\n" goModSrc;
      modLine = lib.findFirst (l: lib.hasPrefix "module " l) null lines;
    in
      if modLine == null
      then throw "lockfile-delta(go): go.mod has no `module` directive"
      else lib.head (lib.splitString " " (lib.removePrefix "module " modLine));

  reconstruct = src:
    let
      genLockPath = src + "/Go.gen.lock";
      goModPath = src + "/go.mod";
      goSumPath = src + "/go.sum";
    in
    if !(pathExists genLockPath && pathExists goModPath)
    then null
    else
      let
        delta = fromJSON (readFile genLockPath);
        goModSrc = readFile goModPath;
        modulePath = goModModulePath goModSrc;
        where = tie.hint src;
        perPackage = schema.field schema.topLevel delta where "per_package";

        # ── D2 freshness gate — hard eval throw on stale delta ──────────
        # Tie is over go.sum CONTENT (empty-string hash when the module is
        # dependency-free / has no go.sum, matching gen-gomod). Compared to
        # the committed `go_sum_sha256` from the slim delta.
        goSumSha =
          if pathExists goSumPath
          then hashFile "sha256" goSumPath
          else emptyGoSumSha256;
        #
        # NAME THE WORKSPACE — same fix as the Rust sibling, same reason. A
        # throw carrying only hashes surfaces inside an unrelated consumer's
        # module trace, leaving the operator to find which of ~600
        # workspaces is at fault by hashing all of them. `src` is already in
        # scope; spending it costs nothing. The compare-and-throw itself now
        # lives in ../shared/freshness-tie.nix, so this message and the Rust
        # one cannot drift apart again.
        committedGoSum = schema.field schema.topLevel delta where "go_sum_sha256";

        d2ok = tie.held {
          subject = "lockfile-delta(go) (D2)";
          artifact = "Go.gen.lock";
          where = tie.hint src;
          # Read through the schema, NOT `or null`. `go_sum_sha256` is a
          # REQUIRED field, so its absence is a shape violation, not a
          # staleness verdict — and reporting a missing tie subject as
          # "STALE" would send the operator to `gen build` to fix a
          # producer-contract break that `gen build` does not cause.
          fresh = committedGoSum == goSumSha;
          sides = [
            ''committed go_sum_sha256  = ${toString committedGoSum}''
            ''hashFile "sha256" go.sum = ${goSumSha}''
          ];
          cause = ''
            go.sum moved without a matching `gen build`, so the committed delta
            no longer describes it. This is a HARD EVAL FAILURE for every
            consumer of this workspace, not a warning.'';
          fix = "cd <that workspace> && gen build && git commit Go.gen.lock";
          fleetFix = "gen fleet-check ~/code/github/pleme-io";
        };

        # Reconstruct one PackageSpec (full build-spec shape) from the slim
        # per-package delta. The delta key IS the build-spec package key, so
        # the consumer's downstream lookups are unchanged. `has_external_deps`
        # is derived from the presence of a `vendor_hash` in the delta — gen
        # only emits a vendorHash when the module declared external deps, and
        # leaves it null/absent for in-tree / dep-free modules.
        mkPackage = key: pd:
          let
            f = schema.field schema.perPackage pd where;
            pdClosed = schema.closed schema.perPackage pd where "package `${key}`";
            vendorHashV = f "vendor_hash";
            pnameV = f "pname";
            hasVendorHash = vendorHashV != null;
            args = {
              pname = if pnameV == null then key else pnameV;
              version = f "version";
              tags = f "tags";
              ldflags = f "ldflags";
              subPackages = f "sub_packages";
              env = f "env";
              nativeBuildInputs = f "native_build_inputs";
              buildInputs = f "build_inputs";
            }
            # vendorHash is only present in the spec when the module has
            # external deps; otherwise it stays absent (→ nixpkgs null).
            // (lib.optionalAttrs hasVendorHash { vendorHash = vendorHashV; })
            // (lib.optionalAttrs (f "proxy_vendor" != null) { proxyVendor = f "proxy_vendor"; })
            // (lib.optionalAttrs (f "do_check" != null) { doCheck = f "do_check"; });
          in seq pdClosed {
            name = f "module";
            version = f "version";
            inherit args;
            has_external_deps = hasVendorHash;
            quirks = f "quirks";
          };

        packages = listToAttrs
          (lib.mapAttrsToList (key: pd: { name = key; value = mkPackage key pd; })
            perPackage);

        # Root + members. gen's single-module convention: the sole package's
        # key is the root, and `workspace_members` carries its module path.
        # Reconstructed from the delta key set (declaration order preserved by
        # IndexMap → JSON object order, which Nix's fromJSON preserves as the
        # attrset; `head` of attrNames is the gen root convention).
        packageKeys = builtins.attrNames perPackage;
        # NO `if packageKeys == [ ] then null` BRANCH. That branch is exactly
        # what the current gen shape reconstructed to — a null root behind a
        # green tie — and it is safe to delete only because `nonEmptyOk`
        # below refuses an empty set first.
        root_package = head packageKeys;
        workspace_members =
          map (k: schema.field schema.perPackage perPackage.${k} where "module") packageKeys;

        # ── The three checks, all FORCED below ────────────────────────────
        closedTop = schema.closed schema.topLevel delta where "Go.gen.lock top level";
        nonEmptyOk = schema.nonEmpty perPackage where "per_package";
      in
      # ★ FORCING IS THE WHOLE POINT — the critic's mandatory override.
      #
      # Nix is lazy. `seq d2ok { … }` forces ONE binding; an unreferenced
      # `closedTop` or `nonEmptyOk` would never evaluate, so the checks would
      # be dead in production while a test suite using `deepSeq` reported them
      # green. That is the vacuous-guard class this whole change exists to
      # remove, reproduced inside its own fix. All three are forced here.
      seq d2ok (seq closedTop (seq nonEmptyOk {
        version = schema.field schema.topLevel delta where "schema_version";
        inherit packages root_package workspace_members;
        go_sum_sha256 = schema.field schema.topLevel delta where "go_sum_sha256";
      }));
in
{
  inherit reconstruct emptyGoSumSha256;
}
