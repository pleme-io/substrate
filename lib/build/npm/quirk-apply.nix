# quirk-apply.nix — mechanical dispatch from typed `NpmQuirk`
# variants (emitted by gen-npm at `spec.packages.<pkg>.quirks`) to
# their class-helper apply functions.
#
# Source of truth for variants:
# `pleme-io/gen/crates/gen-npm/src/quirks.rs::NpmQuirk`. The
# dispatch + fold combinator is shared via
# `../shared/mk-quirk-applier.nix`.
#
# Returns: `{ applyQuirks }`. Consumes typed args matching
# nixpkgs' `buildNpmPackage`.
{ lib }:
let
  # Append an `npm install` flag.
  npmInstallFlagApply = flag: attrs: {
    npmFlags = (attrs.npmFlags or []) ++ [ flag ];
  };

  # Skip the postinstall lifecycle script — typically a native build
  # consumers don't need.
  skipPostinstallApply = _: attrs: {
    npmFlags = (attrs.npmFlags or []) ++ [ "--ignore-scripts" ];
  };

  # Pin a specific nodejs interpreter.
  pinNodejsApply = nodejs: _: { inherit nodejs; };

  # Override the npm registry — for private mirrors.
  overrideRegistryApply = url: attrs: {
    npmFlags = (attrs.npmFlags or []) ++ [ "--registry=${url}" ];
  };

  # One-line source patch (package.json or lockfile).
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
    "npm-install-flag" = quirk: npmInstallFlagApply quirk.flag;
    "skip-postinstall" = quirk: skipPostinstallApply quirk;
    "pin-nodejs" = quirk: pinNodejsApply quirk.nodejs;
    "override-registry" = quirk: overrideRegistryApply quirk.url;
    "substitute-source" = quirk: substituteSourceApply {
      inherit (quirk) file from to;
    };
  };
}
