# substrate/lib/build/helm/repo.nix
#
# mkHelmRepo — a Helm chart repository as ONE store path: ONE OCI image layout
# holding every chart (each manifest named `<chart>:<tag>`), plus a canonical
# charts.json naming every chart, version, tag, ref.name and digest.
#
#   mkHelmRepo = import "${substrate}/lib/build/helm/repo.nix" { inherit pkgs doca; };
#   mkHelmRepo {
#     charts = [ (mkHelmChart { … }) … ];   # or an attrset (mkHelmChartPackages output)
#     repository = "pleme-io/charts";        # default
#   }
#   # => $out/layout/{oci-layout,index.json,blobs/sha256/…}   ref.name = "<chart>:<tag>"
#   #    $out/charts.json  {"charts":[{chart,version,tag,refName,digest,chartDigest,layout}],"repository":…}
#
# THE INTERNAL DISTRIBUTION PATH. porto (the node-local OCI registry, sui)
# mounts `{ repository = "pleme-io/charts"; layout = "${repo}/layout"; }` and
# routes each ref.name `<chart>:<tag>` to `<repository>/<chart>:<tag>`, i.e.
# oci://charts.pleme.internal/pleme-io/charts/<chart> --version <version>, so
# Flux (OCIRepository / HelmRepository type: oci), engenho and
# `helm dependency` consume the chart exactly as they would from ghcr. No
# registry host is ever written into a ref.name (porto rejects one). ghcr is the
# PUBLIC EXPORT of the same digests —
# `oci-push push --layout ${repo}/layout --registry ghcr.io --image pleme-io/charts`
# applies the same routing — never the source the fleet pulls from.
#
# Built by doca (`oci-push layout --ref-name chart-version`), the fleet's one OCI tool: config
# blob = Chart.yaml as canonical JSON (application/vnd.cncf.helm.config.v1+json),
# one layer = the mkHelmChart archive byte for byte
# (application/vnd.cncf.helm.chart.content.v1.tar+gzip), tag = version with `+`
# spelled `_` (Helm's rule). Every JSON document is canonical, so the output is
# a function of the chart archives alone: mkHelmChart is bit-reproducible,
# therefore so is every digest here. Before $out is accepted, the layout is
# re-read and verified by `oci-push layout-verify --helm` (each blob hashed and
# sized against its descriptor; a Helm config and exactly one chart layer).
{ pkgs, doca }:
{
  charts,
  repository ? "pleme-io/charts",
  name ? "helm-repo",
}:
let
  lib = pkgs.lib;
  chartList = if builtins.isAttrs charts && !(lib.isDerivation charts) then lib.attrValues charts else charts;
  _ =
    if doca == null then
      throw "mkHelmRepo: needs doca (substrate's oci-push package); this substrate lib was built without fenix"
    else if chartList == [ ] then
      throw "mkHelmRepo: `charts` is empty"
    else if builtins.match "[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*" repository == null then
      throw "mkHelmRepo: repository `${repository}` is not an OCI repository path"
    else
      null;
in
builtins.seq _ (
  pkgs.runCommand name
    {
      nativeBuildInputs = [ doca ];
      passthru = { inherit repository; charts = chartList; };
    }
    ''
      args=()
      for c in ${lib.escapeShellArgs (map toString chartList)}; do
        set -- "$c"/*.tgz
        [ "$#" -eq 1 ] && [ -f "$1" ] || { echo "mkHelmRepo: $c must hold exactly one .tgz (a mkHelmChart output)" >&2; exit 1; }
        args+=(--helm-chart "$1")
      done
      mkdir -p "$out/layout"
      oci-push layout "''${args[@]}" \
        --out "$out/layout" --ref-name chart-version \
        --repository ${lib.escapeShellArg repository} \
        --summary "$out/charts.json"
      oci-push layout-verify --helm --layout "$out/layout" > /dev/null
    ''
)
