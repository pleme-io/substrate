# substrate/lib/build/helm/vendor.nix
#
# The one place a chart's dependencies are placed under its `charts/` directory
# inside a Nix build, with no network and no `helm dependency update`.
#
# Shared by mkHelmRender (render.nix) and mkHelmChart (chart.nix): both copy a
# chart from a pin, discard whatever `charts/` and `Chart.lock` it carried, and
# vendor every dependency from an explicit store input. Two input kinds:
#
#   libraries    = { <n> = <chart directory>; }   copied as an unpacked chart
#                  (mkHelmRender's original shape: library charts from a pin)
#   vendoredDeps = { <n> = <chart archive>;   }   a `.tgz` file (a fixed-output
#                  fetchurl of a third-party chart) OR a directory holding exactly
#                  one `.tgz` (a mkHelmChart output — a sibling chart built
#                  hermetically by the same builder)
#
# With `vendoredDeps = { }` the emitted text is byte-identical to what
# render.nix emitted before this file existed, so every mkHelmRender consumer
# keeps its derivation.
{ lib }:
{
  commands =
    {
      dest,
      libraries ? { },
      vendoredDeps ? { },
    }:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (n: p: "cp -r ${p} ${dest}/${n}") libraries
      ++ lib.mapAttrsToList (n: p: ''
        if [ -d ${p} ]; then
          set -- ${p}/*.tgz
          [ "$#" -eq 1 ] && [ -f "$1" ] || { echo "vendoredDeps.${n}: ${p} must hold exactly one .tgz chart archive" >&2; exit 1; }
          cp "$1" ${dest}/${n}.tgz
        else
          cp ${p} ${dest}/${n}.tgz
        fi'') vendoredDeps
    );
}
