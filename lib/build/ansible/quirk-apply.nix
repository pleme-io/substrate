# quirk-apply.nix — typed `AnsibleQuirk` dispatch. Source of truth:
# `gen-ansible/src/quirks.rs::AnsibleQuirk`. Produces override
# attrset the substrate consumer threads into the rendered
# `galaxy.yml` pre-build phase.
{ lib }:
let
  dropDependencyApply = collection: attrs: {
    dependenciesDropped = (attrs.dependenciesDropped or []) ++ [ collection ];
  };

  pinDependencyApply = { collection, version }: attrs: {
    dependencyOverrides = (attrs.dependencyOverrides or {}) // {
      "${collection}" = version;
    };
  };

  buildIgnoreApply = path: attrs: {
    buildIgnore = (attrs.buildIgnore or []) ++ [ path ];
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
    "drop-dependency" = quirk: dropDependencyApply quirk.collection;
    "pin-dependency" = quirk: pinDependencyApply {
      inherit (quirk) collection version;
    };
    "build-ignore" = quirk: buildIgnoreApply quirk.path;
    "substitute-source" = quirk: substituteSourceApply {
      inherit (quirk) file from to;
    };
  };
}
