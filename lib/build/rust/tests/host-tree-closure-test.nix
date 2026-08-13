# Pure eval tests for lib/build/rust/host-tree-closure.nix.
#
# The fixture is the ensaio shape, reduced to its bones and named after the
# real crates, because that is the case that was in production and broken:
# a darwin host cross-building `aarch64-unknown-linux-musl`, where `openssl`
# is reachable only on linux and drags in a proc-macro (`openssl-macros`)
# plus two build-deps (`pkg-config`, `vcpkg`) that the darwin resolve section
# has never heard of.
#
# The tests are written around the RED arm on purpose. `pre-fix-host-section-
# is-not-closed` asserts that the old behaviour — host tree filtered by the
# host triple alone — leaves exactly those three keys unanswerable. If a
# future edit makes the merge a no-op, that test goes green-over-nothing and
# `merged-host-section-is-closed` goes red, so the pair cannot both pass
# vacuously.
{ lib }:

let
  testHelpers = import ../../../util/test-helpers.nix { inherit lib; };
  closure = import ../host-tree-closure.nix { inherit lib; };

  dep = package_key: tree: { name = package_key; inherit package_key tree; };
  edges = { runtime ? [ ], build ? [ ] }: {
    runtime_dependencies = runtime;
    build_dependencies = build;
  };

  # Shared by both triples.
  common = {
    "ensaio-0.1.0" = edges { runtime = [ (dep "kube-0.99.0" "target") ]; };
    "kube-0.99.0" = edges { runtime = [ (dep "native-tls-0.2.18" "target") ]; };
    "proc-macro2-1.0.0" = edges { };
    "quote-1.0.0" = edges { runtime = [ (dep "proc-macro2-1.0.0" "target") ]; };
  };

  # aarch64-apple-darwin: native-tls goes to Security.framework. No openssl
  # anywhere, therefore no openssl-macros and no pkg-config/vcpkg.
  hostSection.crates = common // {
    "native-tls-0.2.18" = edges {
      runtime = [ (dep "security-framework-3.7.0" "target") ];
    };
    "security-framework-3.7.0" = edges { };
  };

  # aarch64-unknown-linux-musl: native-tls goes to openssl, which carries a
  # proc-macro and whose -sys crate has two build dependencies.
  targetSection.crates = common // {
    "native-tls-0.2.18" = edges { runtime = [ (dep "openssl-0.10.81" "target") ]; };
    "openssl-0.10.81" = edges {
      runtime = [
        (dep "openssl-macros-0.1.1" "host")
        (dep "openssl-sys-0.9.117" "target")
      ];
    };
    "openssl-sys-0.9.117" = edges {
      build = [ (dep "pkg-config-0.3.33" "host") (dep "vcpkg-0.2.15" "host") ];
    };
    "openssl-macros-0.1.1" = edges {
      runtime = [ (dep "quote-1.0.0" "target") (dep "proc-macro2-1.0.0" "target") ];
    };
    "pkg-config-0.3.33" = edges { };
    "vcpkg-0.2.15" = edges { };
  };

  merged = closure.mergeHostSection { inherit hostSection targetSection; };

  unresolvedIn = section:
    closure.unresolved { inherit section targetSection; };

  theThreeKeys = [ "openssl-macros-0.1.1" "pkg-config-0.3.33" "vcpkg-0.2.15" ];

  tests = [
    # ── The defect, stated as a test ──────────────────────────────────
    (testHelpers.mkTest "pre-fix-host-section-is-not-closed"
      (unresolvedIn hostSection == theThreeKeys)
      "the host triple's section ALONE must be shown to leave exactly the three linux-only host-routed crates unanswerable — this is the `attribute missing` defect, and without it the fix below proves nothing")

    # ── The fix ───────────────────────────────────────────────────────
    (testHelpers.mkTest "merged-host-section-is-closed"
      (unresolvedIn merged == [ ])
      "after merging the target section underneath, every key the target tree routes to host must resolve in the host tree")

    (testHelpers.mkTest "merge-fills-in-the-target-only-keys"
      (builtins.all (k: merged.crates ? ${k}) theThreeKeys)
      "the target-only host-routed crates must be present as keys at all")

    # ── Host wins, because the host tree compiles the host resolution ──
    (testHelpers.mkTest "host-edges-win-on-a-key-present-in-both"
      (merged.crates."native-tls-0.2.18" == hostSection.crates."native-tls-0.2.18")
      "a crate resolved on BOTH triples must keep the HOST triple's edges — taking the target's would compile the linux openssl path into a darwin host tree")

    (testHelpers.mkTest "merge-does-not-drop-a-host-only-key"
      (merged.crates ? "security-framework-3.7.0")
      "host-only crates must survive the merge; the host tree still has to build them")

    # ── The routing rule the closure is derived from ──────────────────
    (testHelpers.mkTest "host-routed-keys-include-proc-macro-runtime-edges"
      (builtins.elem "openssl-macros-0.1.1"
        (closure.hostRoutedKeys { inherit targetSection; }))
      "a runtime edge tagged tree=host is routed to the host tree")

    (testHelpers.mkTest "host-routed-keys-include-every-build-dependency"
      (builtins.all
        (k: builtins.elem k (closure.hostRoutedKeys { inherit targetSection; }))
        [ "pkg-config-0.3.33" "vcpkg-0.2.15" ])
      "build.rs runs on the host, so EVERY build dependency is host-routed regardless of its tree tag")

    (testHelpers.mkTest "host-routed-keys-exclude-plain-target-edges"
      (!(builtins.elem "openssl-sys-0.9.117"
        (closure.hostRoutedKeys { inherit targetSection; })))
      "a plain target runtime edge must NOT be pulled into the host tree — that would cross-build a -sys crate for the wrong arch")

    # ── Legacy specs: no `tree` field, dispatch on proc_macro ─────────
    (testHelpers.mkTest "legacy-specs-route-on-the-proc-macro-flag"
      (let
        legacyTarget.crates = {
          "a-1.0.0" = { runtime_dependencies = [ { name = "m"; package_key = "m-1.0.0"; } ]; build_dependencies = [ ]; };
        };
        universe = { "m-1.0.0" = { proc_macro = true; }; };
      in closure.hostRoutedKeys { targetSection = legacyTarget; inherit universe; } == [ "m-1.0.0" ])
      "a schema<4 spec carries no `tree` field; the proc_macro flag must still route the crate to host")

    # ── Degenerate inputs ─────────────────────────────────────────────
    (testHelpers.mkTest "a-null-host-section-stays-null"
      (closure.mergeHostSection { hostSection = null; inherit targetSection; } == null)
      "a spec with no target_resolves at all must keep falling back to the legacy whole-universe path, not synthesize a section")

    (testHelpers.mkTest "a-null-target-section-leaves-the-host-untouched"
      (closure.mergeHostSection { inherit hostSection; targetSection = null; } == hostSection)
      "nothing to merge in must be byte-identical to the host section — this is the native (non-cross) case")
  ];

  result = testHelpers.runTests tests;

in {
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;

  asCheck = pkgs:
    if result.allPassed
    then pkgs.runCommand "rust-host-tree-closure-test" { } ''
      echo "rust/host-tree-closure: ${result.summary}" > $out
    ''
    else throw ''
      rust/host-tree-closure tests FAILED (${result.summary}):
        - ${builtins.concatStringsSep "\n  - " result.failures}'';
}
