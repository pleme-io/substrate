# Test: Verify scaffold generates correct content (snapshot-style assertions).
{ lib ? (import <nixpkgs> {}).lib }:

let
  scaffold = import ../../build/rust/leptos-app-scaffold.nix { inherit lib; };

  app = scaffold.generate ({
    name = "snapshot-test";
    displayName = "Snapshot Test App";
    primaryColor = "#ff0000";
    locale = "en";
    port = 4000;
  } // scaffold.templates.standard);

  assertContains = name: str: substr:
    if builtins.isString str && builtins.match ".*${substr}.*" str != null then true
    else builtins.throw "${name}: '${substr}' not found";

  assertEqual = name: actual: expected:
    if actual == expected then true
    else builtins.throw "${name}: expected ${builtins.toJSON expected}, got ${builtins.toJSON actual}";

  testCargoHasWorkspace = assertContains "cargo workspace" app.files."Cargo.toml" "workspace";
  testCargoHasEdition = assertContains "cargo edition" app.files."Cargo.toml" "2024";
  testCargoHasLeptos = assertContains "cargo leptos" app.files."Cargo.toml" "leptos";
  testFlakeHasSubstrate = assertContains "flake substrate" app.files."flake.nix" "substrate";
  testFlakeHasBuilder = assertContains "flake builder" app.files."flake.nix" "leptos-build-flake";
  testIndexHasColor = assertContains "index color" app.files."index.html" "#ff0000";
  testIndexHasLang = assertContains "index lang" app.files."index.html" "en";
  testAppHasAuth = assertContains "app auth" app.files."crates/snapshot-test-app/src/app.rs" "AuthProvider";
  testAppHasPwa = assertContains "app pwa" app.files."crates/snapshot-test-app/src/app.rs" "PwaProvider";
  testDeployPort = assertEqual "deploy port" app.deployment.port 4000;
  testMetaName = assertEqual "meta name" app.meta.name "snapshot-test";
  testTemplateStandard = assertEqual "standard features" scaffold.templates.standard.features [ "auth" "pwa" "i18n" "observability" ];

in {
  inherit testCargoHasWorkspace testCargoHasEdition testCargoHasLeptos;
  inherit testFlakeHasSubstrate testFlakeHasBuilder;
  inherit testIndexHasColor testIndexHasLang;
  inherit testAppHasAuth testAppHasPwa;
  inherit testDeployPort testMetaName testTemplateStandard;

  allPassed = builtins.all (x: x == true) [
    testCargoHasWorkspace testCargoHasEdition testCargoHasLeptos
    testFlakeHasSubstrate testFlakeHasBuilder
    testIndexHasColor testIndexHasLang
    testAppHasAuth testAppHasPwa
    testDeployPort testMetaName testTemplateStandard
  ];
}
