# Test: Verify the Leptos app scaffold generates correct file structures.
{ lib ? (import <nixpkgs> {}).lib }:

let
  scaffold = import ../../build/rust/leptos-app-scaffold.nix { inherit lib; };

  # Generate a standard app
  app = scaffold.generate {
    name = "test-app";
    displayName = "Test Application";
    description = "A test app";
    primaryColor = "#ff0000";
    features = [ "auth" "pwa" "i18n" "observability" ];
  };

  # Generate a minimal app
  minimal = scaffold.generate ({
    name = "mini";
  } // scaffold.templates.minimal);

  # Helper
  assertEqual = name: actual: expected:
    if actual == expected then true
    else builtins.throw "${name}: expected ${builtins.toJSON expected}, got ${builtins.toJSON actual}";

  assertHasKey = name: set: key:
    if set ? ${key} then true
    else builtins.throw "${name}: missing key ${key}";

  # Run all assertions in let bindings so they can be referenced by allPassed
  testHasCargoToml = assertHasKey "Cargo.toml" app.files "Cargo.toml";
  testHasFlakeNix = assertHasKey "flake.nix" app.files "flake.nix";
  testHasIndexHtml = assertHasKey "index.html" app.files "index.html";
  testHasManifest = assertHasKey "manifest" app.files "public/manifest.json";
  testHasCrateCargo = assertHasKey "crate Cargo.toml" app.files "crates/test-app-app/Cargo.toml";
  testHasAppRs = assertHasKey "app.rs" app.files "crates/test-app-app/src/app.rs";

  testMetaName = assertEqual "meta.name" app.meta.name "test-app";
  testMetaColor = assertEqual "meta.primaryColor" app.meta.primaryColor "#ff0000";
  testMetaFeatures = assertEqual "meta.features" app.meta.features [ "auth" "pwa" "i18n" "observability" ];

  testDeployPort = assertEqual "deploy.port" app.deployment.port 3000;
  testDeployHealth = assertEqual "deploy.health.path" app.deployment.health.path "/healthz";

  testMinimalHasFiles = assertHasKey "minimal has Cargo.toml" minimal.files "Cargo.toml";
  testMinimalNoAuth = assertEqual "minimal features" minimal.meta.features [];

  testTemplateStandard = assertEqual "standard template"
    scaffold.templates.standard.features
    [ "auth" "pwa" "i18n" "observability" ];

  testTemplateProduct = assertEqual "product template has admin"
    (builtins.elem "admin" scaffold.templates.product.features)
    true;

in {
  # Re-export individual tests for inspection
  inherit testHasCargoToml testHasFlakeNix testHasIndexHtml testHasManifest;
  inherit testHasCrateCargo testHasAppRs;
  inherit testMetaName testMetaColor testMetaFeatures;
  inherit testDeployPort testDeployHealth;
  inherit testMinimalHasFiles testMinimalNoAuth;
  inherit testTemplateStandard testTemplateProduct;

  allPassed = builtins.all (x: x == true) [
    testHasCargoToml testHasFlakeNix testHasIndexHtml testHasManifest
    testHasCrateCargo testHasAppRs
    testMetaName testMetaColor testMetaFeatures
    testDeployPort testDeployHealth
    testMinimalHasFiles testMinimalNoAuth
    testTemplateStandard testTemplateProduct
  ];
}
