# spec-invariants-test.nix — eval-time tests for spec-invariants.nix.
#
# Mirrors the lockfile-loader-test.nix pattern at the same layer.
# Each assertion's `pred` must hold; the file evaluates to
# `{ total = N; passed = N; }` if every assertion passes, and throws
# on the first failure. Run:
#
#   nix-instantiate --eval --strict \
#     lib/build/rust/tests/spec-invariants-test.nix
#
# Covers the 7 invariant classes the Nix-side spec-invariants.nix
# enforces (the mirror of gen-cargo's invariants.rs). Each class has
# a positive case (violation fires) and a negative case (well-formed
# spec produces no violation in that class).
let
  check = import ../spec-invariants.nix;

  # ─── Fixture builders ───────────────────────────────────────────
  base = {
    workspace_members = [];
    root_crate = null;
    crates = {};
  };

  mkRegistryCrate = name: version: sha256: {
    inherit name version;
    source = { kind = "registry"; url = "https://static.crates.io/x"; inherit sha256; name_with_ext = "x.tar.gz"; };
    runtime_dependencies = [];
    build_dependencies = [];
    crate_renames = {};
    binaries = [];
    lib_target = null;
    proc_macro = false;
  };

  mkPathCrate = name: version: relPath: {
    inherit name version;
    source = { kind = "path"; relative_path = relPath; };
    runtime_dependencies = [];
    build_dependencies = [];
    crate_renames = {};
    binaries = [];
    lib_target = null;
    proc_macro = false;
  };

  mkDep = name: package_key: kind: { inherit name package_key kind; };

  # ─── Each invariant: positive (violation expected) + negative ───

  # 1) unresolved-dep
  unresolvedDepPositive = check (base // {
    crates.a = (mkPathCrate "a" "1.0.0" ".") // {
      dependencies = [ (mkDep "ghost" "ghost-9.9.9" "normal") ];
    };
  });
  unresolvedDepNegative = check (base // {
    crates.a = (mkPathCrate "a" "1.0.0" ".");
    crates.b = (mkPathCrate "b" "1.0.0" "crates/b");
  });

  # 2) registry-without-sha256
  registryNoShaPositive = check (base // {
    crates.x = mkRegistryCrate "x" "1.0.0" "";
  });
  registryNoShaNegative = check (base // {
    crates.x = mkRegistryCrate "x" "1.0.0" "deadbeef";
  });

  # 3) workspace-member-not-in-crates
  unknownMemberPositive = check (base // {
    workspace_members = [ "missing-0.1.0" ];
  });

  # 4) root-crate-not-in-crates
  rootNotInCratesPositive = check (base // {
    root_crate = "nowhere-0.1.0";
  });

  # 5) dev-dep-in-runtime-or-build
  devInRuntimePositive = check (base // {
    crates.a = (mkPathCrate "a" "1.0.0" ".") // {
      runtime_dependencies = [ (mkDep "b" "b-1.0.0" "dev") ];
    };
    crates.b = mkPathCrate "b" "1.0.0" "crates/b";
  });

  # 6) rename-version-mismatch
  renameMismatchPositive = check (base // {
    crates.a = (mkPathCrate "a" "1.0.0" ".") // {
      crate_renames.b = [ { version = "9.9.9"; rename = "bee"; } ];
    };
    crates.b = mkPathCrate "b" "1.0.0" "crates/b";  # b exists at 1.0.0, not 9.9.9
  });

  # 7) I1 — workspace-member-missing-lib-target (the directive's
  # foundational invariant — encoder side: gen-cargo emits
  # WorkspaceMemberMissingLibTarget; interpreter side: mirrored here).
  i1Positive = check (base // {
    workspace_members = [ "ishou-render-0.1.0" ];
    crates."ishou-render-0.1.0" =
      mkPathCrate "ishou-render" "0.1.0" "crates/ishou-render";
      # default: binaries=[], lib_target=null → unbuildable.
  });
  i1NegativeWithLib = check (base // {
    workspace_members = [ "ishou-render-0.1.0" ];
    crates."ishou-render-0.1.0" =
      (mkPathCrate "ishou-render" "0.1.0" "crates/ishou-render") // {
        lib_target = { name = "ishou_render"; path = "src/lib.rs"; };
      };
  });
  i1NegativeWithBinary = check (base // {
    workspace_members = [ "ryn-cli-0.1.0" ];
    crates."ryn-cli-0.1.0" =
      (mkPathCrate "ryn-cli" "0.1.0" "crates/ryn-cli") // {
        binaries = [ { name = "ryn-cli"; path = "src/main.rs"; } ];
      };
  });

  # ─── Assertions ─────────────────────────────────────────────────
  contains = substr: list:
    builtins.any (s: builtins.match ".*${substr}.*" s != null) list;

  hasAny = list: list != [];
  isEmpty = list: list == [];

  assertions = [
    { label = "1+ unresolved-dep violation when dep target missing";
      pred = contains "unresolved-dep" unresolvedDepPositive; }
    { label = "0 unresolved-dep violations when deps resolve";
      pred = !(contains "unresolved-dep" unresolvedDepNegative); }

    { label = "registry-without-sha256 fires on empty sha";
      pred = contains "registry-without-sha256" registryNoShaPositive; }
    { label = "registry-without-sha256 silent on non-empty sha";
      pred = !(contains "registry-without-sha256" registryNoShaNegative); }

    { label = "workspace-member-not-in-crates fires on dangling key";
      pred = contains "workspace-member-not-in-crates" unknownMemberPositive; }

    { label = "root-crate-not-in-crates fires on dangling root";
      pred = contains "root-crate-not-in-crates" rootNotInCratesPositive; }

    { label = "dev-dep-in-runtime fires when dev edge in runtime list";
      pred = contains "dev-dep-in-runtime" devInRuntimePositive; }

    { label = "rename-version-mismatch fires on bogus rename version";
      pred = contains "rename-version-mismatch" renameMismatchPositive; }

    { label = "I1 fires on workspace member with no lib_target and no binaries";
      pred = contains "workspace-member-missing-lib-target" i1Positive; }
    { label = "I1 silent when workspace member has lib_target";
      pred = !(contains "workspace-member-missing-lib-target" i1NegativeWithLib); }
    { label = "I1 silent when workspace member has only binaries";
      pred = !(contains "workspace-member-missing-lib-target" i1NegativeWithBinary); }
  ];

  failures = builtins.filter (a: !a.pred) assertions;
in
  if failures == []
  then { total = builtins.length assertions; passed = builtins.length assertions; }
  else throw ''
    spec-invariants-test: ${toString (builtins.length failures)} of ${toString (builtins.length assertions)} assertions failed:
    ${builtins.concatStringsSep "\n" (map (a: "  - " + a.label) failures)}
  ''
