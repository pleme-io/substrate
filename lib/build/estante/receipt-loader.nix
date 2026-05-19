# receipt-loader.nix — parse `shellpkg.receipt.json` into a typed Nix
# attrset.
#
# The receipt is the tameshi-chain anchor emitted by
# `estante attest [--out shellpkg.receipt.json]`. It is canonical
# JSON (deterministic across processes) containing:
#
#   - schemaVersion (must be 1)
#   - estante: { version }
#   - manifest: { path, blake3 }
#   - lockfile: { path, blake3 }
#   - entries:  [ { name, blake3, placement, materializedExists } ]
#
# A flake that imports a receipt gets a transferable proof that the
# upstream manifest + lockfile + every locked entry agree on bytes.
# Anyone with `estante attest --verify` can re-derive the chain.
#
# This loader does NOT verify any digest itself — Nix's builtin
# `builtins.hashFile` covers sha256/sha512 but not BLAKE3, so digest
# verification belongs to `estante attest --verify` invoked from CI
# or a build phase. The loader's job is to parse, validate the
# schema, and surface a typed attrset.
#
# Canonical author-side usage:
#
#   let
#     receipt = (import "${substrate}/lib/build/estante/receipt-loader.nix" {
#       inherit lib;
#     }).loadReceipt ./shellpkg.receipt.json;
#   in {
#     inherit (receipt) entries;
#     manifestBlake3 = receipt.manifest.blake3;
#   }
#
# Mirrors the shape of `lockfile-loader.nix`. Together they form the
# substrate's view of estante's two attestation artifacts:
# lockfile (resolver output) + receipt (attestation anchor).
{ lib }:
let
  requiredTopLevel = [ "schemaVersion" "manifest" "lockfile" "entries" ];
  requiredFileDigest = [ "path" "blake3" ];
  requiredEntry = [ "name" "blake3" "placement" ];

  # Throw with a clear message if a field is absent.
  missingFields = obj: fields:
    builtins.filter (f: !(obj ? ${f})) fields;

  validateFileDigest = label: fd:
    let
      missing = missingFields fd requiredFileDigest;
    in
      if missing == []
      then fd
      else throw "estante receipt ${label} digest missing fields: ${
        builtins.concatStringsSep ", " missing
      }";

  validateEntry = entry:
    let
      missing = missingFields entry requiredEntry;
    in
      if missing == []
      then {
        name = entry.name;
        blake3 = entry.blake3;
        placement = entry.placement;
        materializedExists = entry.materializedExists or false;
      }
      else throw "estante receipt entry `${entry.name or "?"}` missing fields: ${
        builtins.concatStringsSep ", " missing
      }";
in
{
  # Read a receipt from disk (path) or accept an already-imported
  # attrset. Validates the schema eagerly (via builtins.seq on the
  # validation expressions) so structural errors surface as soon as
  # `loadReceipt` is invoked — not lazily when a particular field is
  # touched downstream.
  loadReceipt = pathOrAttrs:
    let
      raw =
        if builtins.isPath pathOrAttrs then builtins.fromJSON (builtins.readFile pathOrAttrs)
        else if builtins.isAttrs pathOrAttrs then pathOrAttrs
        else throw "loadReceipt: argument must be a path or attrset";

      missingTop = missingFields raw requiredTopLevel;
      checkedTop =
        if missingTop == [] then true
        else throw "estante receipt missing top-level fields: ${
          builtins.concatStringsSep ", " missingTop
        }";

      schemaVersion = raw.schemaVersion;
      checkedSchema =
        if schemaVersion == 1 then true
        else throw "estante receipt schemaVersion must be 1, got ${
          toString schemaVersion
        }";

      manifest = validateFileDigest "manifest" raw.manifest;
      lockfile = validateFileDigest "lockfile" raw.lockfile;
      entries = map validateEntry raw.entries;
      estante = raw.estante or { version = "unknown"; };

      result = {
        inherit schemaVersion estante manifest lockfile entries;
      };
    in
      # Eagerly force the entire validated shape — `builtins.deepSeq`
      # walks every attribute and list element so missing-field,
      # bad-schema, and per-entry errors all surface at loadReceipt
      # time rather than lazily on field access.
      builtins.seq checkedTop (
        builtins.seq checkedSchema (
          builtins.deepSeq result result
        )
      );

  # Convenience: load receipt + return ONLY its BLAKE3 digests, for
  # quick consumer-side cross-checks. Order matches the receipt's
  # internal entry order — deterministic.
  loadDigests = pathOrAttrs:
    let
      loaded =
        (import ./receipt-loader.nix { inherit lib; }).loadReceipt pathOrAttrs;
    in {
      manifest = loaded.manifest.blake3;
      lockfile = loaded.lockfile.blake3;
      entries = map (e: { inherit (e) name blake3; }) loaded.entries;
    };
}
