# quirk-apply.nix — mechanical dispatch from typed `BundlerQuirk`
# variants. Source of truth:
# `pleme-io/gen/crates/gen-bundler/src/quirks.rs::BundlerQuirk`.
# Dispatch + fold combinator shared via
# `../shared/mk-quirk-applier.nix`.
{ lib }:
let
  pinRubyApply = version: _: { ruby = "ruby_${lib.replaceStrings ["."] ["_"] version}"; };

  skipNativeBuildApply = _: attrs: {
    nativeBuildInputs = lib.filter
      (x: !(builtins.elem x ["gcc" "clang" "make" "autoconf"]))
      (attrs.nativeBuildInputs or []);
  };

  extraCflagsApply = flags: attrs: {
    NIX_CFLAGS_COMPILE = lib.concatStringsSep " " (
      (lib.splitString " " (attrs.NIX_CFLAGS_COMPILE or "")) ++ [ flags ]
    );
  };

  substituteSourceApply = { file, from, to }: attrs: {
    postPatch = (attrs.postPatch or "") + ''
      if [ -f ${file} ]; then
        substituteInPlace ${file} \
          --replace-fail ${builtins.toJSON from} ${builtins.toJSON to}
      fi
    '';
  };

  # Substrate consumer maps `override-source` onto gemset.nix's
  # per-gem source override. The fold yields an extension table the
  # consumer merges into its gemset.
  overrideSourceApply = { url }: attrs: {
    gemSourceOverride = (attrs.gemSourceOverride or {}) // { inherit url; };
  };
in
import ../shared/mk-quirk-applier.nix {
  inherit lib;
  helpers = {
    "pin-ruby" = quirk: pinRubyApply quirk.version;
    "skip-native-build" = quirk: skipNativeBuildApply quirk;
    "extra-cflags" = quirk: extraCflagsApply quirk.flags;
    "substitute-source" = quirk: substituteSourceApply {
      inherit (quirk) file from to;
    };
    "override-source" = quirk: overrideSourceApply { inherit (quirk) url; };
  };
}
