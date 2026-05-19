# lockfile-loader.nix — parse `shellpkg.lock.nix` into a typed Nix attrset.
#
# The lockfile is emitted by `estante export --format nix` as a pure-data
# Nix expression. This loader normalizes the shape so consumers can rely
# on the same attrset structure regardless of the lockfile's schema
# version.
#
# Canonical lockfile shape (schemaVersion = 1):
#
#   {
#     schemaVersion = 1;
#     packages = [
#       {
#         name = "you-should-use";
#         source = "github:MichaelAquilina/zsh-you-should-use";
#         rev = "aa489f1d0bef818c4ec7d09b87a44d5cabaa9b6f";
#         narHash = "sha256-…";
#         blake3  = "blake3-…";
#         exports = [ "alias" "hook" ];
#         # Optional fields:
#         entrypoint = "rc.lisp";   # consumer override
#         lazy = false;
#       }
#       # …
#     ];
#   }
#
# Returns the same attrset with defaults filled in. Validates that
# every package has the required fields; bad input fails Nix evaluation
# with a clear error.
{ lib }:
let
  requiredFields = [ "name" "source" "rev" ];

  validate = pkg:
    let
      missing = builtins.filter (f: !(pkg ? ${f})) requiredFields;
    in
      if missing == []
      then pkg
      else throw "estante lockfile entry for `${pkg.name or "?"}` missing required fields: ${
        builtins.concatStringsSep ", " missing
      }";

  fillDefaults = pkg: {
    name = pkg.name;
    source = pkg.source;
    rev = pkg.rev;
    narHash = pkg.narHash or "";
    blake3 = pkg.blake3 or "";
    exports = pkg.exports or [];
    entrypoint = pkg.entrypoint or "rc.lisp";
    lazy = pkg.lazy or false;
  };
in
{
  # Read a lockfile from disk (path) or accept an already-imported
  # attrset. Validates eagerly via `builtins.deepSeq` so per-entry
  # errors surface at loadLockfile time, not lazily when a downstream
  # field is touched. Mirrors the receipt-loader's pattern — both
  # estante artifacts (lockfile, receipt) fail-fast on bad input.
  loadLockfile = pathOrAttrs:
    let
      raw =
        if builtins.isPath pathOrAttrs then import pathOrAttrs
        else if builtins.isAttrs pathOrAttrs then pathOrAttrs
        else throw "loadLockfile: argument must be a path or attrset";

      schemaVersion = raw.schemaVersion or 0;
      checkedSchema =
        if schemaVersion == 1 then true
        else throw "estante lockfile schemaVersion must be 1, got ${toString schemaVersion}";

      packages = map (p: fillDefaults (validate p)) (raw.packages or []);

      result = { inherit schemaVersion packages; };
    in
      builtins.seq checkedSchema (builtins.deepSeq result result);

  # Convenience: load a lockfile and return its packages list directly.
  loadPackages = pathOrAttrs:
    let loaded = (import ./lockfile-loader.nix { inherit lib; }).loadLockfile pathOrAttrs;
    in loaded.packages;
}
