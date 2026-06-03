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
# Output shape == `Go.build-spec.json` (fed where `committedSpec` is fed in
# lockfile-builder.nix, so the whole downstream ladder is unchanged):
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
        perPackage = delta.per_package or { };

        # ── D2 freshness gate — hard eval throw on stale delta ──────────
        # Tie is over go.sum CONTENT (empty-string hash when the module is
        # dependency-free / has no go.sum, matching gen-gomod). Compared to
        # the committed `go_sum_sha256` from the slim delta.
        goSumSha =
          if pathExists goSumPath
          then hashFile "sha256" goSumPath
          else emptyGoSumSha256;
        d2ok =
          if (delta.go_sum_sha256 or null) == goSumSha then true
          else throw ''
            lockfile-delta(go): Go.gen.lock is STALE (D2 freshness tie failed).
              committed go_sum_sha256       = ${toString (delta.go_sum_sha256 or "<missing>")}
              hashFile "sha256" go.sum      = ${goSumSha}
            Re-run `gen build` to regenerate Go.gen.lock from the current go.sum.
          '';

        # Reconstruct one PackageSpec (full build-spec shape) from the slim
        # per-package delta. The delta key IS the build-spec package key, so
        # the consumer's downstream lookups are unchanged. `has_external_deps`
        # is derived from the presence of a `vendor_hash` in the delta — gen
        # only emits a vendorHash when the module declared external deps, and
        # leaves it null/absent for in-tree / dep-free modules.
        mkPackage = key: pd:
          let
            hasVendorHash = (pd.vendor_hash or null) != null;
            args = {
              pname = pd.pname or key;
              version = pd.version or "0.0.0";
              tags = pd.tags or [ ];
              ldflags = pd.ldflags or [ ];
              subPackages = pd.sub_packages or [ ];
              env = pd.env or { };
              nativeBuildInputs = pd.native_build_inputs or [ ];
              buildInputs = pd.build_inputs or [ ];
            }
            # vendorHash is only present in the spec when the module has
            # external deps; otherwise it stays absent (→ nixpkgs null).
            // (lib.optionalAttrs hasVendorHash { vendorHash = pd.vendor_hash; })
            // (lib.optionalAttrs (pd ? proxy_vendor && pd.proxy_vendor != null) { proxyVendor = pd.proxy_vendor; })
            // (lib.optionalAttrs (pd ? do_check && pd.do_check != null) { doCheck = pd.do_check; });
          in {
            name = pd.module or modulePath;
            version = pd.version or "0.0.0";
            inherit args;
            has_external_deps = hasVendorHash;
            quirks = pd.quirks or [ ];
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
        root_package =
          if packageKeys == [ ] then null else head packageKeys;
        workspace_members =
          map (k: (perPackage.${k}.module or modulePath)) packageKeys;
      in
      seq d2ok {
        version = delta.schema_version or 1;
        inherit packages root_package workspace_members;
        go_sum_sha256 = delta.go_sum_sha256;
      };
in
{
  inherit reconstruct emptyGoSumSha256;
}
