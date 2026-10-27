{ lib, rust }:

let
  testHelpers = import ../../../util/test-helpers.nix { inherit lib; };

  src = ./fixtures/service-image;

  throws = expr: !(builtins.tryEval (builtins.deepSeq expr expr)).success;

  service = rust.service { inherit src; };
  amd64Only = rust.service { inherit src; architectures = [ "amd64" ]; };
  imagesOff = rust.service { inherit src; architectures = [ ]; };
  tool = rust.tool { inherit src; };
  testsOff = rust.service {
    inherit src;
    tests = { enable = false; reason = "fixture: the off switch"; };
  };

  checkNames = flake: system: lib.genAttrs (builtins.attrNames flake.checks.${system}) (_: true);

  namesOf = flake: system: builtins.attrNames flake.packages.${system};
  has = flake: system: attr: builtins.elem attr (namesOf flake system);

  amd64 = service.packages.x86_64-linux.dockerImage-amd64 or { };

  tests = [
    (testHelpers.mkTest "service-emits-dockerImage-amd64"
      (has service "x86_64-linux" "dockerImage-amd64")
      "substrate.rust.service must emit packages.x86_64-linux.dockerImage-amd64; image-push.yml callers build exactly this attribute")

    (testHelpers.mkTest "service-emits-dockerImage-arm64"
      (has service "aarch64-linux" "dockerImage-arm64")
      "substrate.rust.service must emit packages.aarch64-linux.dockerImage-arm64")

    (testHelpers.mkTest "service-image-is-a-derivation"
      (lib.isDerivation amd64 && lib.hasSuffix ".tar.gz" (amd64.name or ""))
      "dockerImage-amd64 must be a docker-archive derivation image-push.yml can push")

    (testHelpers.mkTest "service-image-comes-from-the-hardened-set"
      (amd64 ? closureInfo)
      "dockerImage-amd64 must be built by mkHardenedImageSet (mkPackageImage carries closureInfo)")

    (testHelpers.mkTest "architectures-narrow-the-image-set"
      (has amd64Only "x86_64-linux" "dockerImage-amd64"
       && !(has amd64Only "x86_64-linux" "dockerImage-arm64"))
      "architectures = [ \"amd64\" ] must emit only the amd64 image")

    (testHelpers.mkTest "empty-architectures-configures-images-off"
      (!(has imagesOff "x86_64-linux" "dockerImage-amd64")
       && has imagesOff "x86_64-linux" "default")
      "architectures = [ ] must turn the image outputs off and keep the binaries")

    (testHelpers.mkTest "unknown-architecture-throws"
      (throws (builtins.attrNames (rust.service { inherit src; architectures = [ "riscv64" ]; }).packages.x86_64-linux))
      "an unknown image architecture must fail at eval")

    (testHelpers.mkTest "host-tool-names-its-main-program"
      ((tool.packages.x86_64-linux.host-tool.meta.mainProgram or null) == "svc-fixture")
      "packages.host-tool must carry meta.mainProgram, or `nix run` execs bin/<pname> (substrate#gen ran bin/gen-cli)")

    (testHelpers.mkTest "tool-shape-emits-no-image"
      (!(has tool "x86_64-linux" "dockerImage-amd64"))
      "only the service shape emits images")

    (testHelpers.mkTest "service-emits-checks-tests"
      (checkNames service "x86_64-linux" ? tests
       && lib.isDerivation service.checks.x86_64-linux.tests)
      "substrate.rust.service must emit checks.<system>.tests; without it kensa's CI was green over 13 red attestation tests (2026-10-27)")

    (testHelpers.mkTest "service-tests-configured-off"
      (!(checkNames testsOff "x86_64-linux" ? tests)
       && checkNames testsOff "x86_64-linux" ? build)
      "tests = { enable = false; reason = …; } must turn checks.tests off and keep checks.build")

    (testHelpers.mkTest "service-tests-off-without-reason-throws"
      (throws (builtins.attrNames (rust.service { inherit src; tests.enable = false; }).checks.x86_64-linux))
      "turning the service test gate off without a typed reason must fail at eval")

    (testHelpers.mkTest "tool-shape-keeps-tests-opt-in"
      (!(checkNames tool "x86_64-linux" ? tests))
      "the tool shape keeps the cargo-vendored runner opt-in")
  ];

  result = testHelpers.runTests tests;

in {
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;

  asCheck = testHelpers.mkAsCheck { name = "rust-service-image-test"; label = "rust/service-image"; } result;
}
