# substrate/lib/build/helm/render.nix
#
# mkHelmRender — a pinned Helm chart plus typed values, rendered to one store
# path of manifests at build time, with no network and no import-from-derivation.
#
# The shape both fleet chart consumers arrived at independently (plo's router
# templates, nix/nodes/plo/roteador-templates.nix, and the local-LLM workload,
# nix/modules/shared/llm): copy the chart from a git pin, vendor its library
# charts from the SAME pin (any bundled tgz is discarded first, and
# `helm dependency update` is never run, since it would reach a registry), then
# `helm template` with values given as Nix data. The result is a store path, so
# it can be dropped where engenho's node-manifests driver applies it
# (/etc/engenho/manifests.d) or handed to kata.mkSeedUnit; a change of values is
# a change of path, which is what restarts the applier.
#
#   mkHelmRender = import "${substrate}/lib/build/helm/render.nix" { inherit pkgs; };
#   mkHelmRender {
#     name = "llm";
#     chart = "${helmworks-src}/charts/pleme-llama-server";
#     libraries = { pleme-lib = "${helmworks-src}/charts/pleme-lib"; };
#     values = { image.repository = "nix:${llama-cpp}"; model.path = "${gguf}"; };
#     namespace = "llm";
#   }
#
# `createNamespace = true` puts the Namespace object first, for appliers that
# create nothing themselves (engenho's node-manifests driver, a plain SSA seed):
# `helm template --namespace` only STAMPS the name onto every object.
#
# Refuses an empty render: a chart whose gates are unmet emits nothing and helm
# still exits 0, which would otherwise apply an empty manifest and report success.
{ pkgs }:
{
  name,
  chart,
  libraries ? { },
  values ? { },
  namespace ? "default",
  release ? name,
  createNamespace ? false,
}:
let
  lib = pkgs.lib;
  namespaceDoc = pkgs.writeText "${name}-namespace.yaml" ''
    apiVersion: v1
    kind: Namespace
    metadata:
      name: ${namespace}
    ---
  '';
  vendor = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (n: p: "cp -r ${p} chart/charts/${n}") libraries
  );
in
pkgs.runCommand "${name}.yaml"
  {
    nativeBuildInputs = [ pkgs.kubernetes-helm ];
    valuesJson = builtins.toJSON values;
    passAsFile = [ "valuesJson" ];
    passthru = { inherit values chart; };
  }
  ''
    export HOME="$TMPDIR" HELM_CACHE_HOME="$TMPDIR/cache" HELM_CONFIG_HOME="$TMPDIR/config" HELM_DATA_HOME="$TMPDIR/data"
    cp -r ${chart} chart && chmod -R u+w chart
    rm -rf chart/charts chart/Chart.lock && mkdir -p chart/charts
    ${vendor}
    helm template ${release} chart --namespace ${namespace} -f "$valuesJsonPath" > rendered.yaml
    grep -q '^kind:' rendered.yaml || { echo "mkHelmRender ${name}: the chart rendered no objects" >&2; exit 1; }
    cat ${lib.optionalString createNamespace "${namespaceDoc} "}rendered.yaml > "$out"
  ''
