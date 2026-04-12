# Test: Verify scaffold generates ALL required files for compilation.
{ lib ? (import <nixpkgs> {}).lib }:

let
  scaffold = import ../../build/rust/leptos-app-scaffold.nix { inherit lib; };
  app = scaffold.generate ({
    name = "completeness-test";
    displayName = "Completeness Test";
  } // scaffold.templates.standard);

  # Also test minimal template (no auth/pwa/i18n)
  minimal = scaffold.generate ({
    name = "minimal-test";
  } // scaffold.templates.minimal);

  assertHasFile = name: path:
    if app.files ? ${path} then true
    else builtins.throw "Missing file: ${path}";

  assertMinimalHasFile = name: path:
    if minimal.files ? ${path} then true
    else builtins.throw "Minimal missing file: ${path}";

  assertMinimalLacksFile = name: path:
    if !(minimal.files ? ${path}) then true
    else builtins.throw "Minimal should NOT have file: ${path}";

  # Core files
  testCargoToml = assertHasFile "Cargo.toml" "Cargo.toml";
  testFlakeNix = assertHasFile "flake.nix" "flake.nix";
  testIndexHtml = assertHasFile "index.html" "index.html";
  testManifest = assertHasFile "manifest" "public/manifest.json";
  testVersion = assertHasFile "version" "public/version.json";
  testGitignore = assertHasFile "gitignore" ".gitignore";
  testLicense = assertHasFile "license" "LICENSE";
  testTrunk = assertHasFile "trunk" "Trunk.toml";

  # Crate files
  testCrateCargo = assertHasFile "crate Cargo" "crates/completeness-test-app/Cargo.toml";
  testMainRs = assertHasFile "main.rs" "crates/completeness-test-app/src/main.rs";
  testLibRs = assertHasFile "lib.rs" "crates/completeness-test-app/src/lib.rs";
  testAppRs = assertHasFile "app.rs" "crates/completeness-test-app/src/app.rs";
  testRouterRs = assertHasFile "router.rs" "crates/completeness-test-app/src/router.rs";

  # Provider modules
  testProvidersMod = assertHasFile "providers/mod" "crates/completeness-test-app/src/providers/mod.rs";
  testThemeProvider = assertHasFile "providers/theme" "crates/completeness-test-app/src/providers/theme.rs";

  # Feature-gated providers (standard template has auth, pwa, i18n)
  testAuthProvider = assertHasFile "providers/auth" "crates/completeness-test-app/src/providers/auth.rs";
  testPwaProvider = assertHasFile "providers/pwa" "crates/completeness-test-app/src/providers/pwa.rs";
  testI18nProvider = assertHasFile "providers/i18n" "crates/completeness-test-app/src/providers/i18n.rs";

  # Stub modules (empty but required by lib.rs)
  testPagesMod = assertHasFile "pages/mod" "crates/completeness-test-app/src/pages/mod.rs";
  testSharedMod = assertHasFile "shared/mod" "crates/completeness-test-app/src/shared/mod.rs";
  testInfraMod = assertHasFile "infra/mod" "crates/completeness-test-app/src/infra/mod.rs";

  # Feature-gated modules (auth enables features/)
  testFeaturesMod = assertHasFile "features/mod" "crates/completeness-test-app/src/features/mod.rs";

  # Minimal template: always-present files exist
  testMinimalRouter = assertMinimalHasFile "minimal router" "crates/minimal-test-app/src/router.rs";
  testMinimalProvidersMod = assertMinimalHasFile "minimal providers/mod" "crates/minimal-test-app/src/providers/mod.rs";
  testMinimalTheme = assertMinimalHasFile "minimal providers/theme" "crates/minimal-test-app/src/providers/theme.rs";
  testMinimalPages = assertMinimalHasFile "minimal pages/mod" "crates/minimal-test-app/src/pages/mod.rs";
  testMinimalShared = assertMinimalHasFile "minimal shared/mod" "crates/minimal-test-app/src/shared/mod.rs";
  testMinimalInfra = assertMinimalHasFile "minimal infra/mod" "crates/minimal-test-app/src/infra/mod.rs";

  # Minimal template: feature-gated files absent
  testMinimalNoAuth = assertMinimalLacksFile "minimal no auth" "crates/minimal-test-app/src/providers/auth.rs";
  testMinimalNoPwa = assertMinimalLacksFile "minimal no pwa" "crates/minimal-test-app/src/providers/pwa.rs";
  testMinimalNoI18n = assertMinimalLacksFile "minimal no i18n" "crates/minimal-test-app/src/providers/i18n.rs";
  testMinimalNoFeatures = assertMinimalLacksFile "minimal no features" "crates/minimal-test-app/src/features/mod.rs";

in {
  inherit testCargoToml testFlakeNix testIndexHtml testManifest testVersion;
  inherit testGitignore testLicense testTrunk;
  inherit testCrateCargo testMainRs testLibRs testAppRs testRouterRs;
  inherit testProvidersMod testThemeProvider;
  inherit testAuthProvider testPwaProvider testI18nProvider;
  inherit testPagesMod testSharedMod testInfraMod testFeaturesMod;
  inherit testMinimalRouter testMinimalProvidersMod testMinimalTheme;
  inherit testMinimalPages testMinimalShared testMinimalInfra;
  inherit testMinimalNoAuth testMinimalNoPwa testMinimalNoI18n testMinimalNoFeatures;

  allPassed = builtins.all (x: x == true) [
    testCargoToml testFlakeNix testIndexHtml testManifest testVersion
    testGitignore testLicense testTrunk
    testCrateCargo testMainRs testLibRs testAppRs testRouterRs
    testProvidersMod testThemeProvider
    testAuthProvider testPwaProvider testI18nProvider
    testPagesMod testSharedMod testInfraMod testFeaturesMod
    testMinimalRouter testMinimalProvidersMod testMinimalTheme
    testMinimalPages testMinimalShared testMinimalInfra
    testMinimalNoAuth testMinimalNoPwa testMinimalNoI18n testMinimalNoFeatures
  ];
}
