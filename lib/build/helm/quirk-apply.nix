# quirk-apply.nix — typed `HelmQuirk` dispatch. Source of truth:
# `gen-helm/src/quirks.rs::HelmQuirk`. Dispatch + fold combinator
# shared via `../shared/mk-quirk-applier.nix`.
#
# Substrate consumer threads the produced overrides into the
# Helm-rendered values + manifest stream — either at
# `helm template --set <path>=<value>` time (`override-value` +
# `force-image-tag`), at post-render time (`patch-manifest` +
# `skip-hook`), or by passing the override table into the
# Helm-build-spec consumer's `helmTemplate` wrapper.
{ lib }:
let
  overrideValueApply = { path, value }: attrs: {
    valueOverrides = (attrs.valueOverrides or {}) // { "${path}" = value; };
  };

  skipHookApply = hook: attrs: {
    skipHooks = (attrs.skipHooks or []) ++ [ hook ];
  };

  patchManifestApply = { resource_kind, name, jsonpath, value }: attrs: {
    manifestPatches = (attrs.manifestPatches or []) ++ [
      { kind = resource_kind; inherit name jsonpath value; }
    ];
  };

  forceImageTagApply = { container, tag }: attrs: {
    valueOverrides = (attrs.valueOverrides or {}) // {
      "${container}.image.tag" = tag;
    };
  };
in
import ../shared/mk-quirk-applier.nix {
  inherit lib;
  helpers = {
    "override-value" = quirk: overrideValueApply {
      inherit (quirk) path value;
    };
    "skip-hook" = quirk: skipHookApply quirk.hook;
    "patch-manifest" = quirk: patchManifestApply {
      inherit (quirk) resource_kind name jsonpath value;
    };
    "force-image-tag" = quirk: forceImageTagApply {
      inherit (quirk) container tag;
    };
  };
}
