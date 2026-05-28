# quirk-apply.nix — typed `GomodQuirk` dispatch. Source of truth:
# `gen-gomod/src/quirks.rs::GomodQuirk`. Threads into nixpkgs'
# `buildGoModule` mkArgs.
{ lib }:
let
  forceVendorHashApply = hash: _: { vendorHash = hash; };

  buildTagApply = tag: attrs: { tags = (attrs.tags or []) ++ [ tag ]; };

  ldflagApply = flag: attrs: { ldflags = (attrs.ldflags or []) ++ [ flag ]; };

  cgoOffApply = _: attrs: {
    env = (attrs.env or {}) // { CGO_ENABLED = "0"; };
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
    "force-vendor-hash" = quirk: forceVendorHashApply quirk.hash;
    "build-tag" = quirk: buildTagApply quirk.tag;
    "ldflag" = quirk: ldflagApply quirk.flag;
    "cgo-off" = quirk: cgoOffApply quirk;
    "substitute-source" = quirk: substituteSourceApply {
      inherit (quirk) file from to;
    };
  };
}
