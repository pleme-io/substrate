# Test: Verify scaffold generates valid Rust code for all 4 template variants.
#
# Checks that generated Cargo.toml is valid, app.rs has expected structure,
# and deployment specs are correct across minimal/standard/product/internal.
#
# Run:
#   nix eval --impure --expr '(import ./lib/infra/tests/scaffold-compile-test.nix { lib = (import <nixpkgs> {}).lib; }).allPassed'
{ lib ? (import <nixpkgs> {}).lib }:

let
  scaffold = import ../../build/rust/leptos-app-scaffold.nix { inherit lib; };

  # Generate all 4 template variants
  minimal = scaffold.generate ({ name = "test-minimal"; } // scaffold.templates.minimal);
  standard = scaffold.generate ({ name = "test-standard"; } // scaffold.templates.standard);
  product = scaffold.generate ({ name = "test-product"; } // scaffold.templates.product);
  internal = scaffold.generate ({ name = "test-internal"; } // scaffold.templates.internal);

  assertContains = name: str: substr:
    if builtins.isString str && builtins.match ".*${substr}.*" str != null then true
    else builtins.throw "${name}: '${substr}' not found";

  assertEqual = name: actual: expected:
    if actual == expected then true
    else builtins.throw "${name}: expected ${builtins.toJSON expected}, got ${builtins.toJSON actual}";

  # Verify generated code has correct structure for each template
  assertValidApp = name: app: features: let
    cargo = app.files."Cargo.toml";
    appRs = app.files."crates/${name}-app/src/app.rs";
    libRs = app.files."crates/${name}-app/src/lib.rs";
    mainRs = app.files."crates/${name}-app/src/main.rs";
    hasAuth = builtins.elem "auth" features;
    hasPwa = builtins.elem "pwa" features;
    hasI18n = builtins.elem "i18n" features;
  in [
    # Cargo.toml validity
    (assertContains "${name}: cargo has workspace" cargo "workspace")
    (assertContains "${name}: cargo has pleme-app-core" cargo "pleme-app-core")
    (assertContains "${name}: cargo has pleme-mui" cargo "pleme-mui")
    (assertContains "${name}: cargo has leptos" cargo "leptos")
    # main.rs has mount
    (assertContains "${name}: main mounts app" mainRs "mount_to_body")
    # lib.rs has required modules
    (assertContains "${name}: lib has app" libRs "pub mod app")
    (assertContains "${name}: lib has router" libRs "pub mod router")
    (assertContains "${name}: lib has providers" libRs "pub mod providers")
    # app.rs has providers based on features
    (if hasAuth then assertContains "${name}: app has AuthProvider" appRs "AuthProvider" else true)
    (if hasPwa then assertContains "${name}: app has PwaProvider" appRs "PwaProvider" else true)
    (if hasI18n then assertContains "${name}: app has I18nProvider" appRs "I18nProvider" else true)
    # Deployment spec
    (assertEqual "${name}: deploy port" app.deployment.port 3000)
    (assertEqual "${name}: deploy health" app.deployment.health.path "/healthz")
  ];

  minimalTests = assertValidApp "test-minimal" minimal [];
  standardTests = assertValidApp "test-standard" standard [ "auth" "pwa" "i18n" "observability" ];
  productTests = assertValidApp "test-product" product [ "auth" "pwa" "i18n" "observability" "admin" "search" "payments" ];
  internalTests = assertValidApp "test-internal" internal [ "auth" "admin" "observability" ];

  allTests = minimalTests ++ standardTests ++ productTests ++ internalTests;

in {
  testCount = builtins.length allTests;
  allPassed = builtins.all (x: x == true) allTests;

  # Individual results for debugging
  minimal = builtins.all (x: x == true) minimalTests;
  standard = builtins.all (x: x == true) standardTests;
  product = builtins.all (x: x == true) productTests;
  internal = builtins.all (x: x == true) internalTests;
}
