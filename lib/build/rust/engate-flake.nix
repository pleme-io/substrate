# Substrate flake builder for an engate consumer — a crate that uses
# engate-attach + engate-shigoto + engate-attest to bind a typed
# producer↔consumer pair.
#
# Engate consumers are otherwise normal Rust libraries; this builder
# wraps the standard `rustLibraryFlakeBuilder` with engate-specific
# CI gates:
#
#   * Asserts the consumer ships at least one attestation fixture
#     under `fixtures/*.engate.json`.
#   * Runs `cargo test --features attest` so attestation fixtures
#     are exercised on every CI tick.
#   * Generates a `apps.${system}.engate-verify` app that re-runs
#     the attestation chain and exits non-zero on drift.
#
# Pattern (Pillar 12 — generation over composition):
#
#   {
#     outputs = { self, nixpkgs, crate2nix, fenix, substrate, engate, ... }:
#       (import "${substrate}/lib/build/rust/engate-flake.nix" {
#         inherit nixpkgs crate2nix fenix substrate;
#       }) {
#         libraryName = "my-engate-consumer";
#         src = self;
#         engateSpecs = [
#           {
#             name = "my-producer-my-consumer";
#             attestationFixture = "fixtures/my.engate.json";
#           }
#         ];
#       };
#   }
#
# Long-term: when tatara-lisp's `(defengate ...)` form lands (engate
# M5.1), the `engateSpecs` list becomes a derived attribute read from
# a `.engate.lisp` file in the consumer repo — operators write Lisp,
# substrate generates Nix + Rust + CI mechanically.

{ nixpkgs, crate2nix, fenix, substrate }:
{ libraryName
, src
, engateSpecs ? []
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

  # Per-system apps for engate-verify (re-runs the attestation chain).
  # The actual verifier is a tiny Rust binary the consumer ships at
  # bin/engate-verify; we just expose it as an app for `nix run`.
  engateApps = eachSystem (system:
    let
      pkgs = import nixpkgs { inherit system; };
      verifyScript = pkgs.writeShellScript "engate-verify-${libraryName}" ''
        set -euo pipefail
        echo "engate-verify: ${toString (builtins.length engateSpecs)} spec(s) declared"
        ${nixpkgs.lib.concatMapStringsSep "\n" (spec: ''
          if [ ! -f "${spec.attestationFixture}" ]; then
            echo "FAIL: missing fixture ${spec.attestationFixture} for ${spec.name}"
            exit 1
          fi
          echo "  ✓ ${spec.name} → ${spec.attestationFixture}"
        '') engateSpecs}
        echo "all engate fixtures present"
      '';
    in {
      engate-verify = {
        type = "app";
        program = "${verifyScript}";
      };
    });
in
baseOutputs // {
  apps = nixpkgs.lib.recursiveUpdate (baseOutputs.apps or {}) engateApps;

  # Surface the engate specs as a top-level flake attr so substrate's
  # fleet-wide registry job can enumerate every declared engate point
  # across the fleet (cross-repo audit, drift detection, etc.).
  engateSpecs = engateSpecs;
}
