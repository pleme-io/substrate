{ lib ? (import <nixpkgs> {}).lib }:
let
  leptos = (import ../../build/rust/leptos-app-scaffold.nix { inherit lib; }).generate
    ({ name = "test-leptos"; } // (import ../../build/rust/leptos-app-scaffold.nix { inherit lib; }).templates.standard);
  service = (import ../../build/rust/rust-service-scaffold.nix { inherit lib; }).generate
    ({ name = "test-service"; } // (import ../../build/rust/rust-service-scaffold.nix { inherit lib; }).templates.graphql);
  tool = (import ../../build/rust/rust-tool-scaffold.nix { inherit lib; }).generate
    ({ name = "test-tool"; } // (import ../../build/rust/rust-tool-scaffold.nix { inherit lib; }).templates.standard);
  dioxus = (import ../../build/rust/dioxus-app-scaffold.nix { inherit lib; }).generate
    ({ name = "test-dioxus"; } // (import ../../build/rust/dioxus-app-scaffold.nix { inherit lib; }).templates.desktop);
  gpu = (import ../../build/rust/gpu-app-scaffold.nix { inherit lib; }).generate
    ({ name = "test-gpu"; } // (import ../../build/rust/gpu-app-scaffold.nix { inherit lib; }).templates.minimal);
  ruby = (import ../../build/ruby/ruby-gem-scaffold.nix { inherit lib; }).generate
    ({ name = "test-gem"; } // (import ../../build/ruby/ruby-gem-scaffold.nix { inherit lib; }).templates.library);

  assertHas = name: set: key:
    if set ? ${key} then true
    else builtins.throw "${name}: missing ${key}";

  assertContains = name: str: substr:
    if builtins.isString str && builtins.match ".*${substr}.*" str != null then true
    else builtins.throw "${name}: '${substr}' not found";

  # Every scaffold generates files + meta + deployment
  testLeptosHasFiles = assertHas "leptos" leptos "files";
  testLeptosHasMeta = assertHas "leptos" leptos "meta";
  testLeptosHasDeploy = assertHas "leptos" leptos "deployment";

  testServiceHasFiles = assertHas "service" service "files";
  testServiceHasMeta = assertHas "service" service "meta";
  testServiceHasDeploy = assertHas "service" service "deployment";

  testToolHasFiles = assertHas "tool" tool "files";
  testToolHasMeta = assertHas "tool" tool "meta";

  testDioxusHasFiles = assertHas "dioxus" dioxus "files";
  testDioxusHasMeta = assertHas "dioxus" dioxus "meta";

  testGpuHasFiles = assertHas "gpu" gpu "files";
  testGpuHasMeta = assertHas "gpu" gpu "meta";

  testRubyHasFiles = assertHas "ruby" ruby "files";
  testRubyHasMeta = assertHas "ruby" ruby "meta";

  # Each has a Cargo.toml or Gemfile
  testLeptosCargo = assertHas "leptos cargo" leptos.files "Cargo.toml";
  testServiceCargo = assertHas "service cargo" service.files "Cargo.toml";
  testToolCargo = assertHas "tool cargo" tool.files "Cargo.toml";
  testDioxusCargo = assertHas "dioxus cargo" dioxus.files "Cargo.toml";
  testGpuCargo = assertHas "gpu cargo" gpu.files "Cargo.toml";
  testRubyGemfile = assertHas "ruby gemfile" ruby.files "Gemfile";

  # Service has axum, tool has clap, gpu has garasu
  testServiceHasAxum = assertContains "service axum" service.files."Cargo.toml" "axum";
  testToolHasClap = assertContains "tool clap" tool.files."Cargo.toml" "clap";
  testGpuHasGarasu = assertContains "gpu garasu" gpu.files."Cargo.toml" "garasu";
  testDioxusHasDioxus = assertContains "dioxus" dioxus.files."Cargo.toml" "dioxus";

  # Deployment specs
  testServicePort = service.deployment.port == 8080;
  testLeptosPort = leptos.deployment.port == 3000;

  allPassed = builtins.all (x: x == true) [
    testLeptosHasFiles testLeptosHasMeta testLeptosHasDeploy
    testServiceHasFiles testServiceHasMeta testServiceHasDeploy
    testToolHasFiles testToolHasMeta
    testDioxusHasFiles testDioxusHasMeta
    testGpuHasFiles testGpuHasMeta
    testRubyHasFiles testRubyHasMeta
    testLeptosCargo testServiceCargo testToolCargo testDioxusCargo testGpuCargo testRubyGemfile
    testServiceHasAxum testToolHasClap testGpuHasGarasu testDioxusHasDioxus
    testServicePort testLeptosPort
  ];
in {
  inherit
    testLeptosHasFiles testLeptosHasMeta testLeptosHasDeploy
    testServiceHasFiles testServiceHasMeta testServiceHasDeploy
    testToolHasFiles testToolHasMeta
    testDioxusHasFiles testDioxusHasMeta
    testGpuHasFiles testGpuHasMeta
    testRubyHasFiles testRubyHasMeta
    testLeptosCargo testServiceCargo testToolCargo testDioxusCargo testGpuCargo testRubyGemfile
    testServiceHasAxum testToolHasClap testGpuHasGarasu testDioxusHasDioxus
    testServicePort testLeptosPort
    allPassed;
}
