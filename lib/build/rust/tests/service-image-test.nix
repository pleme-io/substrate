{ lib, rust }:

let
  testHelpers = import ../../../util/test-helpers.nix { inherit lib; };

  src = ./fixtures/service-image;

  throws = expr: !(builtins.tryEval (builtins.deepSeq expr expr)).success;

  service = rust.service { inherit src; };
  amd64Only = rust.service { inherit src; architectures = [ "amd64" ]; };
  imagesOff = rust.service { inherit src; architectures = [ ]; };
  tool = rust.tool { inherit src; };

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

    (testHelpers.mkTest "tool-shape-emits-no-image"
      (!(has tool "x86_64-linux" "dockerImage-amd64"))
      "only the service shape emits images")
  ];

  result = testHelpers.runTests tests;

in {
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;

  asCheck = testHelpers.mkAsCheck { name = "rust-service-image-test"; label = "rust/service-image"; } result;
}
