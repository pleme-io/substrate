# Substrate flake builder for a maestro stack — a YAML or
# .lisp file declaring a `StackSpec` that maestro-runtime
# executes (launch + invariant monitor + drift handlers).
#
# Wraps the canonical Rust library flake builder with:
#
#  * `apps.${system}.stack-${name}` — `nix run .#stack-<name>` launches
#    the declared stack via maestro-runtime.
#  * `apps.${system}.stack-${name}-verify` — re-runs the engate
#    attestation chain (M4) for the stack's attaches.
#  * `passthru.stacks` — every declared StackSpec surfaced as a flake
#    attr so fleet-wide audit jobs (`maestro fleet-audit`) can
#    enumerate every stack across the org.
#
# Long-term (M2.1+): when tatara-lisp's `(defstack ...)` form is
# auto-registered via `#[derive(TataraDomain)]`, the consumer
# repo's `.engate.lisp` / `.stack.lisp` files become a derived
# attribute the renderer reads directly. For now the consumer
# passes `stackSpecs = [ { name = ...; path = ...; } ]` explicitly.
#
# Usage:
#
#   outputs = { self, nixpkgs, crate2nix, fenix, substrate, maestro, ... }:
#     (import "${substrate}/lib/build/rust/maestro-flake.nix" {
#       inherit nixpkgs crate2nix fenix substrate;
#     }) {
#       libraryName = "my-consumer";
#       src = self;
#       stackSpecs = [
#         { name = "mado-default"; path = "stacks/mado-default.yaml"; }
#         { name = "mado-shared";  path = "stacks/mado-shared.yaml"; }
#       ];
#     };

{ nixpkgs, crate2nix, fenix, substrate }:
{ libraryName
, src
, stackSpecs ? []
, extraOverlay ? (final: prev: {})
, module ? null
, ...
}@args:

let
  base = import "${substrate}/lib/build/rust/library-flake.nix" {
    inherit nixpkgs crate2nix fenix;
  };

  baseOutputs = base ({
    inherit libraryName src extraOverlay;
  } // (if module != null then { inherit module; } else {}));

  systems = [
    "x86_64-linux"
    "aarch64-linux"
    "x86_64-darwin"
    "aarch64-darwin"
  ];
  eachSystem = nixpkgs.lib.genAttrs systems;

  stackApps = eachSystem (system:
    let
      pkgs = import nixpkgs { inherit system; };
      mkLauncher = spec:
        let
          script = pkgs.writeShellScript "maestro-stack-${spec.name}" ''
            set -euo pipefail
            # Maestro CLI is the consumer's `bin/maestro` from the
            # library output. Path resolution is by convention: the
            # consuming library exposes a binary or we shell out to
            # the workspace-local one in development.
            exec maestro launch ${spec.path}
          '';
        in
        {
          type = "app";
          program = "${script}";
        };
      mkVerifier = spec:
        let
          script = pkgs.writeShellScript "maestro-stack-${spec.name}-verify" ''
            set -euo pipefail
            echo "maestro-stack-${spec.name}-verify: re-running engate attestation"
            exec maestro verify ${spec.path}
          '';
        in
        {
          type = "app";
          program = "${script}";
        };
    in
    nixpkgs.lib.foldl' (acc: spec:
      acc // {
        "stack-${spec.name}" = mkLauncher spec;
        "stack-${spec.name}-verify" = mkVerifier spec;
      }) {} stackSpecs);
in
baseOutputs // {
  apps = nixpkgs.lib.recursiveUpdate (baseOutputs.apps or {}) stackApps;

  # Surface the spec set so fleet-wide audit can enumerate every
  # declared stack across the org.
  passthru = (baseOutputs.passthru or {}) // {
    inherit stackSpecs;
  };
}
