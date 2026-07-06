# package-builder-ferrite-test.nix — eval-time tests for the REALIZED ferrite
# proof node in package-builder.nix (the side-effecting realBackend), the
# realize-path complement to package-graph-test.nix (which proves the PURE
# graph over a mock backend).
#
# package-graph-test.nix asserts the ferrite proof TREE shape with a mock
# mkFerriteNode whose `pomsEmit` is hardcoded false — it can NOT assert the
# realized node's f0 branch (the real -ferrite.poms-dir emission vs the pending
# marker) because that branch lives in package-builder.nix's realBackend and
# is gated on `resolvedFerrite.passthru.pomsEmit`. This test closes that gap by
# INJECTING a mock ferriteCheck (with / without the passthru.pomsEmit marker)
# into realBackend and asserting the derivation the realize path actually
# produces — all at eval (`nix-instantiate --eval --strict`), NO `nix build`,
# NO IFD getFlake.
#
#   nix-instantiate --eval --strict \
#     lib/build/go/tests/package-builder-ferrite-test.nix
#
# Direct-expression shape (not a `{ … }:` lambda) so the assertions run and fail
# closed on `throw`; evaluates to `{ total = N; passed = N; }`.
let
  pkgs = import <nixpkgs> { };
  lib = pkgs.lib;

  builder = import ../package-builder.nix { inherit pkgs lib; };

  # A minimal src the derivation can reference at eval (never realized here —
  # we only read the derivation's string attrs).
  fakeSrc = builtins.toFile "ferrite-test-src" "package p\n";

  tuple = { goVersion = "1.25"; goos = "linux"; goarch = "amd64"; tags = [ ]; };

  # Two mock ferrite#check "packages": the f0 build carries passthru.pomsEmit;
  # the pre-f0 build does not. We only need the attrs realBackend reads
  # (passthru.pomsEmit) + a name so it can appear in nativeBuildInputs.
  mockFerriteF0 = pkgs.runCommand "mock-ferrite-f0" { passthru.pomsEmit = true; } "mkdir -p $out/bin; touch $out/bin/ferrite-check";
  mockFerritePreF0 = pkgs.runCommand "mock-ferrite-pref0" { } "mkdir -p $out/bin; touch $out/bin/ferrite-check";

  # A single buildable ferrite node argument (mirrors what package-graph.nix's
  # ferrite fold passes into backend.mkFerriteNode).
  nodeArgs = {
    key = "example.com/m/internal/util#linux-amd64";
    importPath = "example.com/m/internal/util";
    kind = "module";
    relativePath = "internal/util";
    goFiles = [ "util.go" ];
    sourceHash = "src-abc123def456";
    edges = [
      { key = "example.com/m/internal/helper#linux-amd64"; sourceHash = "src-helper999"; }
    ];
    goVersion = "1.25";
  };

  backendF0 = builder.realBackend {
    workspaceSrc = fakeSrc;
    inherit tuple;
    hostPkgs = pkgs.buildPackages;
    ferriteCheck = mockFerriteF0;
  };
  backendPreF0 = builder.realBackend {
    workspaceSrc = fakeSrc;
    inherit tuple;
    hostPkgs = pkgs.buildPackages;
    ferriteCheck = mockFerritePreF0;
  };

  nodeF0 = backendF0.mkFerriteNode nodeArgs;
  nodePreF0 = backendPreF0.mkFerriteNode nodeArgs;

  hasInfix = lib.hasInfix;

  # ── Assertions ──────────────────────────────────────────────────────────────
  assertions = [
    # ── REALIZED (f0 marker present): the real -ferrite.poms-dir emit path ──────
    { label = "f0: node.plan.pomsEmit is TRUE when the ferrite marker is present";
      pred = nodeF0.plan.pomsEmit == true; }
    { label = "f0: node.drv.pomsEmit passthru is TRUE";
      pred = nodeF0.drv.pomsEmit == true; }
    { label = "f0: the derivation buildPhase invokes the real -ferrite.poms-dir emit";
      pred = hasInfix ''ferrite-check -ferrite.poms-dir="$TMPDIR/poms" ./'' nodeF0.drv.buildPhase; }
    { label = "f0: the derivation does NOT take the pending-poms-emit interim path";
      pred = !(hasInfix "pending-poms-emit.json" nodeF0.drv.buildPhase); }
    { label = "f0: the realize path fails closed on a silent no-write (presence guard)";
      pred = hasInfix "emitted no *.poms.json" nodeF0.drv.buildPhase; }
    { label = "f0: the PoMS timestamp is pinned deterministic via SOURCE_DATE_EPOCH";
      pred = hasInfix "SOURCE_DATE_EPOCH" nodeF0.drv.buildPhase; }

    # ── Cache-key alignment survives the realize path (Go-I8) ──────────────────
    { label = "f0: the ferrite drv is keyed by FERRITE_SOURCE_HASH = the shared source_hash";
      pred = nodeF0.drv.FERRITE_SOURCE_HASH == nodeArgs.sourceHash; }
    { label = "f0: the drv name embeds the sanitized key (store-address aligns)";
      pred = hasInfix "ferrite-poms-" nodeF0.drv.name; }
    { label = "f0: the node record carries poms = \${drv}/poms and the shared sourceHash";
      pred = nodeF0.sourceHash == nodeArgs.sourceHash
        && hasInfix "/poms" nodeF0.poms; }
    { label = "f0: the plan's edgeSourceHashes name the buildable dep's source_hash (audit)";
      pred = nodeF0.plan.edgeSourceHashes == [ "src-helper999" ]; }

    # ── PRE-f0 (no marker): the honest pending-marker interim path ──────────────
    { label = "pre-f0: node.plan.pomsEmit is FALSE when the ferrite marker is absent";
      pred = nodePreF0.plan.pomsEmit == false; }
    { label = "pre-f0: node.drv.pomsEmit passthru is FALSE";
      pred = nodePreF0.drv.pomsEmit == false; }
    { label = "pre-f0: the derivation takes the pending-poms-emit interim path";
      pred = hasInfix "pending-poms-emit.json" nodePreF0.drv.buildPhase; }
    { label = "pre-f0: the derivation does NOT pass the unknown -ferrite.poms-dir flag";
      pred = !(hasInfix "-ferrite.poms-dir" nodePreF0.drv.buildPhase); }

    # ── The realize path fully evaluates (no false throw when forced) ──────────
    { label = "the realized f0 node fully evaluates (drv attrs forced, no false throw)";
      pred = (builtins.tryEval (builtins.deepSeq
        [ nodeF0.drv.buildPhase nodeF0.drv.installPhase nodeF0.plan ] true)).success; }
    { label = "the realized pre-f0 node fully evaluates (drv attrs forced, no false throw)";
      pred = (builtins.tryEval (builtins.deepSeq
        [ nodePreF0.drv.buildPhase nodePreF0.drv.installPhase nodePreF0.plan ] true)).success; }
  ];

  failures = builtins.filter (a: !a.pred) assertions;
in
if failures == [ ]
then { total = builtins.length assertions; passed = builtins.length assertions; }
else throw ''
  package-builder-ferrite-test: ${toString (builtins.length failures)} of ${toString (builtins.length assertions)} assertions failed:
  ${builtins.concatStringsSep "\n" (map (a: "  - " + a.label) failures)}
''
