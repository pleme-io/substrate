{ lib, builders }:

let
  testHelpers = import ../test-helpers.nix { inherit lib; };
  callablePath = import ../callable-path.nix;

  stubFile = ../callable-path.nix;
  stub = callablePath.mk stubFile (args: args.x + 1);

  shapes = {
    rustToolReleaseFlakeBuilder = "tool-release-flake.nix";
    rustWorkspaceReleaseFlakeBuilder = "workspace-release-flake.nix";
  };

  perBuilder = name: file: let b = builders.${name}; in [
    (testHelpers.mkTest "${name}-is-callable"
      (lib.isFunction b && (lib.functionArgs b) ? src)
      "substrate.lib.<system>.${name} { inherit pkgs; name; src; } is the caixa-rendered call shape")

    (testHelpers.mkTest "${name}-imports-as-the-two-stage-builder"
      (builtins.isFunction (import b) && (builtins.functionArgs (import b)) ? nixpkgs)
      "import substrate.lib.<system>.${name} { inherit nixpkgs ...; } is the path call shape")

    (testHelpers.mkTest "${name}-coerces-to-its-file"
      (lib.hasSuffix "/${file}" (toString b))
      "\"\${builder}\" and toString must still name the builder file")
  ];

  tests = [
    (testHelpers.mkTest "helper-calls"
      (stub { x = 41; } == 42)
      "a callable path applies its function")

    (testHelpers.mkTest "helper-imports"
      (import stub == import stubFile)
      "a callable path imports as its file")

    (testHelpers.mkTest "helper-recognises-itself"
      (callablePath.isCallablePath stub && !(callablePath.isCallablePath stubFile))
      "isCallablePath separates the two shapes")
  ] ++ lib.concatLists (lib.mapAttrsToList perBuilder shapes);

  result = testHelpers.runTests tests;

in {
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;

  asCheck = testHelpers.mkAsCheck { name = "callable-path-test"; label = "callable-path"; } result;
}
