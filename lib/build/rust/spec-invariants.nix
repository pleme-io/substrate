# spec-invariants.nix — Nix-side mirror of gen-cargo's invariants module.
#
# gen-cargo writes Cargo.build-spec.json with assert_well_formed
# enforced; this file lets the substrate consumer re-verify the spec
# at eval time. Useful for catching:
#   - operator hand-edits to Cargo.build-spec.json
#   - substrate-side schema-version skew (consumer expects newer fields)
#   - corrupt sidecar files
#
# Returns a list of violation strings (empty when the spec is valid).
# Consumers can guard their build with:
#
#   let violations = (import ./spec-invariants.nix) (builtins.fromJSON
#     (builtins.readFile (src + "/Cargo.build-spec.json")));
#   in if violations == [] then build else throw "spec violations: ..."
#
# Same 6 invariant classes as gen-cargo's invariants.rs:
#   - unresolved-dep
#   - registry-without-sha256
#   - workspace-member-not-in-crates
#   - root-crate-not-in-crates
#   - dev-dep-in-runtime-or-build
#   - rename-version-mismatch
spec: let
  inherit (builtins) attrNames hasAttr filter map concatLists;

  cratesAttrs = if spec ? crates then spec.crates else {};
  crateKeys = attrNames cratesAttrs;

  # ── unresolved-dep ────────────────────────────────────────────────
  unresolvedDeps = concatLists (map (fromKey:
    let c = cratesAttrs.${fromKey};
        deps = c.dependencies or [];
    in map (d: "unresolved-dep: ${fromKey} → ${d.name}/${d.package_key}")
         (filter (d: !(hasAttr d.package_key cratesAttrs)) deps)
  ) crateKeys);

  # ── registry-without-sha256 ──────────────────────────────────────
  registryNoSha = concatLists (map (key:
    let c = cratesAttrs.${key};
        src = c.source or null;
    in if src != null && (src.kind or "") == "registry" && (src.sha256 or "") == ""
       then [ "registry-without-sha256: ${key} (${c.name})" ]
       else []
  ) crateKeys);

  # ── workspace-member-not-in-crates ───────────────────────────────
  members = spec.workspace_members or [];
  unknownMembers = map (k: "workspace-member-not-in-crates: ${k}")
    (filter (k: !(hasAttr k cratesAttrs)) members);

  # ── root-crate-not-in-crates ─────────────────────────────────────
  rootCrateViolations =
    if spec ? root_crate && spec.root_crate != null && !(hasAttr spec.root_crate cratesAttrs)
    then [ "root-crate-not-in-crates: ${spec.root_crate}" ]
    else [];

  # ── dev-dep-in-runtime-or-build ──────────────────────────────────
  devInRuntime = concatLists (map (fromKey:
    let c = cratesAttrs.${fromKey};
        rd = c.runtime_dependencies or [];
        bd = c.build_dependencies or [];
        check = label: list: map
          (d: "dev-dep-in-${label}: ${fromKey} → ${d.name}")
          (filter (d: (d.kind or "") == "dev") list);
    in (check "runtime" rd) ++ (check "build" bd)
  ) crateKeys);

  # ── I1: workspace-member-missing-lib-target ──────────────────────
  # Mirrors gen-cargo's `WorkspaceMemberMissingLibTarget`
  # (invariants.rs). Per the GEN TYPED-SPEC CONTRACT, a workspace
  # member with neither binaries nor lib_target has zero build
  # targets — provably unbuildable. The stale-gen-cargo signature
  # (pre-09f6311 emission) and the surface bug that motivated the
  # auto-regen path below.
  workspaceMemberMissingLib = concatLists (map (k:
    let c = cratesAttrs.${k} or null;
    in if c == null
       then []
       else
         let
           noBins = (c.binaries or []) == [];
           noLib  = (c.lib_target or null) == null;
           # Only a PATH-sourced member is genuinely unbuildable without a
           # lib_target (substrate resolves it to workspaceSrc — the root).
           # A GIT-sourced "member" (transitive git self-reference) is
           # fetched + narrowed to its subdir by mkSrcOf, where default
           # src/lib.rs auto-detects → buildable; don't flag it. Mirrors
           # gen-cargo invariants.rs check_workspace_member_lib_targets.
           isPath = (c.source.kind or "path") == "path";
         in if noBins && noLib && isPath
            then [ "workspace-member-missing-lib-target: ${k} (${c.name or k})" ]
            else []
  ) members);

  # ── rename-version-mismatch ──────────────────────────────────────
  renameMismatches = concatLists (map (fromKey:
    let c = cratesAttrs.${fromKey};
        renames = c.crate_renames or {};
        renameKeys = attrNames renames;
        cratesByName = map (k: cratesAttrs.${k}) crateKeys;
    in concatLists (map (canonical:
        let records = renames.${canonical};
        in map (r:
          let matched = filter (cc: cc.name == canonical && cc.version == r.version) cratesByName;
          in if matched == []
             then "rename-version-mismatch: ${fromKey} → ${canonical}/${r.version}"
             else null
        ) records
      ) renameKeys)
  ) crateKeys);
  renameMismatchesFiltered = filter (x: x != null) renameMismatches;

in
  unresolvedDeps ++ registryNoSha ++ unknownMembers ++ rootCrateViolations
    ++ devInRuntime ++ renameMismatchesFiltered ++ workspaceMemberMissingLib
