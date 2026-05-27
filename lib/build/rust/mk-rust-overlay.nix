# mkRustOverlay — typed `(final: prev: { ... })` factory for consumer
# flakes that need to expose `pkgs.<name>` for a Rust workspace built
# via substrate's lockfile-builder.
#
# Compound abstraction on top of mkRustTool. Eliminates the 5-line
# `final: prev: let lockfileBuilder = ...; project = ...; in { ... }`
# boilerplate that's appeared in every consumer overlay
# (shinryu-mcp, engenho, escriba, etc.).
#
# Usage in a consumer flake (e.g. nix/parts/overlays.nix):
#
#   (import "${inputs.substrate}/lib/build/rust/mk-rust-overlay.nix" {
#     name = "shinryu-mcp";
#     src = inputs.shinryu-mcp;
#   })
#
# Or directly in a flake's `outputs.overlays.default`:
#
#   overlays.default = import (substrate + "/lib/build/rust/mk-rust-overlay.nix") {
#     name = "engenho";
#     src = self;
#     # Optional — pick a specific workspace member binary.
#     member = "engenho-mcp";
#     crateOverrides = { rmcp = old: { CARGO_CRATE_NAME = "rmcp"; }; };
#   };
#
# Prerequisites: <src>/Cargo.build-spec.json exists (run `gen build .`).
{
  name,
  src,
  # Optional: workspace member key. null → uses rootCrate.
  member ? null,
  # Optional defaultCrateOverrides additions.
  crateOverrides ? {},
  # Optional pkgs override for cross-platform builds.
  buildRustCrateForPkgs ? null,
  # Optional meta attrs to overlay onto the derivation.
  meta ? {},
}:
final: prev:
let
  mkRustTool = import ./mk-rust-tool.nix;
  tool = mkRustTool ({
    inherit name src member crateOverrides meta;
  } // (if buildRustCrateForPkgs != null
        then { inherit buildRustCrateForPkgs; }
        else {}));
in {
  ${name} = tool { pkgs = prev; };
}
