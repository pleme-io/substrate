# quirk-apply.nix — typed `SwiftQuirk` dispatch. Source of truth:
# `gen-swift/src/quirks.rs::SwiftQuirk`.
{ lib }:
let
  pinToolchainApply = version: _: { swiftToolchain = version; };

  forceConfigurationApply = configuration: _: { inherit configuration; };

  ldflagApply = flag: attrs: { ldflags = (attrs.ldflags or []) ++ [ flag ]; };

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
    "pin-toolchain" = quirk: pinToolchainApply quirk.version;
    "force-configuration" = quirk: forceConfigurationApply quirk.configuration;
    "ldflag" = quirk: ldflagApply quirk.flag;
    "substitute-source" = quirk: substituteSourceApply {
      inherit (quirk) file from to;
    };
  };
}
