# mk-receipt-verifier.nix — produces a Nix derivation that runs
# `estante attest --check` against a source tree at build time.
#
# Build succeeds iff the manifest, lockfile, and committed receipt
# all agree on bytes. Build fails (with the JSON drift report in
# stderr) iff anything has drifted. Suitable for wiring into a
# flake's `checks.<system>.receipt-attested` so `nix flake check`
# enforces the attestation gate.
#
# Usage from a consumer flake:
#
#   checks.${system}.receipt-attested =
#     (import "${substrate}/lib/build/estante/mk-receipt-verifier.nix" {
#       inherit pkgs;
#     }).mkReceiptVerifier {
#       name = "my-shellpkg";
#       src = self;
#       estante = inputs.estante.packages.${system}.default;
#     };
#
# The derivation outputs a tiny sentinel file at $out; build success
# is the actual proof. The `--json` flag means drift surfaces as a
# structured report in the build log.
{ pkgs }:
{
  mkReceiptVerifier =
    { name
    , src
    , estante
    , manifestPath ? "shellpkg.lisp"
    , lockfilePath ? "shellpkg.lock.lisp"
    , receiptPath ? "shellpkg.receipt.json"
    }:
    pkgs.runCommand "${name}-receipt-verified"
      {
        buildInputs = [ estante ];
        meta = {
          description = "Build-time `estante attest --check` gate for ${name}";
        };
      }
      ''
        mkdir -p work
        cp -R ${src}/. work/
        cd work
        if [ ! -f ${manifestPath} ]; then
          echo "mkReceiptVerifier: missing ${manifestPath} in src" >&2
          exit 2
        fi
        if [ ! -f ${lockfilePath} ]; then
          echo "mkReceiptVerifier: missing ${lockfilePath} in src" >&2
          exit 2
        fi
        if [ ! -f ${receiptPath} ]; then
          echo "mkReceiptVerifier: missing ${receiptPath} in src — run `estante lock --emit-receipt`" >&2
          exit 2
        fi
        estante \
          --manifest ${manifestPath} \
          --lockfile ${lockfilePath} \
          attest --check --json
        printf 'receipt-attested\n' > $out
      '';
}
