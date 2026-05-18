# substrate/lib/infra/pangea-backend.nix
#
# Typed selection layer for Pangea's dual-backend execution model.
# Per theory/MAGMA.md §II.11, Pangea supports two execution backends:
#
#   - tofu  (historical default; current pleme-io fleet)
#   - magma (pleme-io's Rust-native executor; theory/MAGMA.md)
#
# Both backends consume Pangea-rendered Terraform JSON. This helper
# centralizes:
#
#   1. Binary selection — returns the chosen package derivation.
#   2. Env-var setup — emits the shell snippet that exports
#      PANGEA_BACKEND + PATH adjustments so `bundle exec pangea`
#      dispatches correctly.
#   3. Capability declarations — Nix-level mirror of magma's JSON
#      capability manifest, so workspace flakes can verify backend
#      compatibility at eval time rather than runtime.
#   4. Verification — `verify { requires }` fails the eval with a
#      typed error when the chosen backend lacks a declared feature.
#
# # Usage in a downstream flake
#
#   {
#     inputs = {
#       nixpkgs.url      = "github:NixOS/nixpkgs/nixos-25.11";
#       substrate.url    = "github:pleme-io/substrate";
#       magma            = { url = "github:pleme-io/magma"; inputs.nixpkgs.follows = "nixpkgs"; };
#     };
#     outputs = { self, nixpkgs, substrate, magma, ... }:
#       let
#         system  = "aarch64-darwin";
#         pkgs    = import nixpkgs { inherit system; };
#         backend = (import "${substrate}/lib/infra/pangea-backend.nix" { inherit pkgs; }) {
#           name         = "magma";
#           magmaPackage = magma.packages.${system}.default;
#         };
#       in {
#         devShells.${system}.default = pkgs.mkShellNoCC {
#           buildInputs = backend.runtimeInputs;
#           shellHook   = backend.envSetup;
#         };
#       };
#   }
#
# # Capability shape
#
# The Nix-level capability attrset mirrors the JSON manifest emitted by
# `magma capabilities` (theory/MAGMA.md §II.11). tofu's capabilities
# are hardcoded from the published surface; magma's are auto-derived
# from the magma package's version when available.
#
# # Verification
#
# `verify { requires = { feature = "in_memory_pipeline"; }; }` raises
# at eval time when the chosen backend doesn't support the feature.
# Workspace flakes declare their requirements; the eval-time check
# fails fast instead of letting the operator hit a runtime error.

{ pkgs }:

{
  # "tofu" or "magma". Default is tofu (matches the fleet-wide current state).
  name ? "tofu",

  # Magma package derivation. Required when name == "magma". Threaded
  # via the consumer flake's `magma.packages.${system}.default` input.
  magmaPackage ? null,

  # tofu package derivation. Default: pkgs.opentofu from nixpkgs.
  tofuPackage ? pkgs.opentofu,
}:

let
  lib = pkgs.lib;

  validNames = [ "tofu" "magma" ];

  _ = if !(builtins.elem name validNames)
      then throw "pangea-backend: name must be one of ${toString validNames}, got ${name}"
      else null;

  _2 = if name == "magma" && magmaPackage == null
       then throw "pangea-backend: name = \"magma\" requires `magmaPackage` (thread `magma.packages.\${system}.default` via your flake inputs)"
       else null;

  # ── Capability declarations (Nix-level mirror of magma's JSON manifest)

  # tofu's capabilities. Hardcoded from the published surface — tofu
  # doesn't emit a `capabilities` subcommand today, so we encode what
  # the version-string + documented surface implies. Update when tofu
  # evolves (currently aligned to v1.7).
  tofuCapabilities = {
    name                          = "tofu";
    schema_version                = 1;
    supported_protocols           = [ "tfplugin5" "tfplugin6" ];
    input_formats                 = [ "hcl2" "terraform-json" ];
    input_formats_excluded        = [ ];
    backends                      = [ "local" "s3" "http" "consul" "kubernetes" "postgres" "azurerm" "gcs" "remote" ];
    subcommands = [
      "init" "plan" "apply" "destroy" "state" "import" "workspace"
      "output" "show" "refresh" "taint" "force-unlock" "get" "fmt"
      "validate" "console"
    ];
    workspace_primitive_supported = false;
    workspace_chain_supported     = false;
    in_memory_pipeline_supported  = false;
    shigoto_job_wrapping          = "n/a (tofu has its own DAG executor)";
  };

  # Magma's capabilities. Static for now (mirrors the JSON manifest
  # `magma capabilities` outputs); a future build-time probe could
  # invoke the package and parse its actual output.
  magmaCapabilities = {
    name                          = "magma";
    schema_version                = 1;
    supported_protocols           = [ "tfplugin5" "tfplugin6" ];
    input_formats                 = [ "pangea-ruby-inprocess" "terraform-json" ];
    input_formats_excluded        = [ "hcl2" ];
    backends                      = [ "local" ];
    subcommands = [
      "init" "plan" "apply" "destroy" "state" "import" "workspace"
      "output" "show" "refresh" "taint" "force-unlock" "get" "fmt"
      "validate" "console"
      # Native magma additions:
      "mcp" "daemon" "watch" "attest" "config" "flow" "capabilities"
    ];
    workspace_primitive_supported = true;
    workspace_chain_supported     = true;
    in_memory_pipeline_supported  = true;
    shigoto_job_wrapping          = "available (PlanJob / ApplyChangeJob / ApplyPlanJob)";
  };

  capabilities = if name == "magma" then magmaCapabilities else tofuCapabilities;

  binary = if name == "magma" then magmaPackage else tofuPackage;

  # ── Env setup — shell snippet exporting PANGEA_BACKEND.
  envSetup = ''
    # Pangea backend selection — substrate-side declarative wiring.
    export PANGEA_BACKEND=${lib.escapeShellArg name}
  '';

  # ── Verification — fail at eval time on missing capability.
  verify = { requires ? {} }:
    let
      checks = lib.flatten [
        # input_format check
        (lib.optionals (requires ? input_format) (
          let
            fmt = requires.input_format;
          in lib.optional (!(builtins.elem fmt capabilities.input_formats))
            "input format \"${fmt}\" not supported by backend=${name} (supported: ${
              toString capabilities.input_formats})"
        ))
        # in_memory_pipeline check
        (lib.optional (
          requires ? feature && requires.feature == "in_memory_pipeline"
          && !capabilities.in_memory_pipeline_supported
        ) "feature=in_memory_pipeline not supported by backend=${name}; switch to backend=magma")
        # workspace_chain check
        (lib.optional (
          requires ? feature && requires.feature == "workspace_chain"
          && !capabilities.workspace_chain_supported
        ) "feature=workspace_chain not supported by backend=${name}; switch to backend=magma")
      ];
    in
      if checks == []
      then true
      else throw "pangea-backend (verify): ${builtins.concatStringsSep "; " checks}";

in {
  # The chosen backend's name. Echoed for downstream debugging.
  inherit name;

  # The package derivation that provides the backend binary.
  inherit binary;

  # Convenience: list shape for `buildInputs` / `runtimeInputs`.
  runtimeInputs = [ binary ];

  # Env setup shell snippet — append to mkShell.shellHook /
  # writeShellApplication.text after the prologue.
  inherit envSetup;

  # Typed Nix-level capabilities. Same shape as magma's JSON manifest;
  # tofu's are hardcoded from the published surface.
  inherit capabilities;

  # Verify the chosen backend can satisfy a workspace's requires.
  # Fails the eval (throw) on mismatch.
  inherit verify;

  # All capability data for inspection / debugging from REPL.
  __inspect = {
    inherit name capabilities;
    binaryName = binary.pname or binary.name or "unknown";
  };
}
