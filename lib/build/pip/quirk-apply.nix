# quirk-apply.nix — typed `PipQuirk` dispatch. Source of truth:
# `gen-pip/src/quirks.rs::PipQuirk`.
{ lib }:
let
  pinInterpreterApply = python: _: { inherit python; };

  skipCheckApply = _: _: { doCheck = false; };

  dropRequiresApply = package: attrs: {
    propagatedBuildInputs = lib.filter
      (p: p != package)
      (attrs.propagatedBuildInputs or []);
  };

  substituteSourceApply = { file, from, to }: attrs: {
    postPatch = (attrs.postPatch or "") + ''
      if [ -f ${file} ]; then
        substituteInPlace ${file} \
          --replace-fail ${builtins.toJSON from} ${builtins.toJSON to}
      fi
    '';
  };
in
import ../shared/mk-quirk-applier.nix {
  inherit lib;
  helpers = {
    "pin-interpreter" = quirk: pinInterpreterApply quirk.python;
    "skip-check" = quirk: skipCheckApply quirk;
    "drop-requires" = quirk: dropRequiresApply quirk.package;
    "substitute-source" = quirk: substituteSourceApply {
      inherit (quirk) file from to;
    };
  };
}
