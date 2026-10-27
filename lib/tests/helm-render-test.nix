# mkHelmRender + mkHelmRelease: what a chart consumer needs, offline.
#
# Run: nix build .#checks.<system>.helm-render
#
# The fixture chart depends on its library through an oci:// repository that
# does not resolve (registry.invalid), ships a values.schema.json and a CRD:
#
#   offline   — the library vendored from a directory (as from a flake input)
#               renders; no registry is reached.
#   schema    — a value outside values.schema.json fails the render.
#               CONTROL: the same chart with the schema removed accepts it.
#   crds      — includeCrds = true renders crds/, false does not.
#   extra     — extraObjects append as YAML documents; the default appends
#               nothing and leaves the derivation unchanged.
#   release   — mkHelmRelease.renderDecl checks the declaration and renders
#               the Namespace, the chart and the extra object.
{ pkgs, lib ? pkgs.lib }:

let
  mkHelmRender = import ../build/helm/render.nix { inherit pkgs; };
  release = import ../build/helm/release.nix { inherit pkgs; };

  fx = ./fixtures/helm;
  base = {
    name = "fixture-render";
    chart = fx + "/fixture-render";
    libraries.fixture-lib = fx + "/fixture-lib";
  };

  plain = mkHelmRender base;
  emptyExtra = mkHelmRender (base // { extraObjects = [ ]; });
  withCrds = mkHelmRender (base // { includeCrds = true; });
  withExtra = mkHelmRender (base // {
    extraObjects = [ { apiVersion = "v1"; kind = "Secret"; metadata.name = "extra-one"; } ];
  });
  outsideSchema = pkgs.testers.testBuildFailure (mkHelmRender (base // {
    values.not_declared = 1;
  }));
  noSchemaChart = pkgs.runCommand "fixture-render-no-schema" { } ''
    cp -r ${fx + "/fixture-render"} $out && chmod -R u+w $out
    rm $out/values.schema.json
  '';
  outsideNoSchema = mkHelmRender (base // {
    chart = noSchemaChart;
    values.not_declared = 1;
  });
  unvendored = pkgs.testers.testBuildFailure (mkHelmRender (removeAttrs base [ "libraries" ]));
  typed = release.renderDecl "fixture" {
    chart = fx + "/fixture-render";
    libraries.fixture-lib = fx + "/fixture-lib";
    values.greeting = "typed";
    includeCrds = true;
    extraObjects = [ { apiVersion = "v1"; kind = "ConfigMap"; metadata.name = "extra-two"; } ];
  };
in
assert plain.drvPath == emptyExtra.drvPath;
pkgs.runCommand "helm-render-test" { } ''
  set -euo pipefail
  pass() { echo "ok - $*"; }
  fail() { echo "FAIL - $*" >&2; exit 1; }

  grep -q 'greeting: "hello"' ${plain} || fail "the chart did not render through its vendored library"
  pass "offline: library vendored from a directory, oci:// repository never reached"
  grep -qi 'fixture-lib' ${unvendored}/testBuildFailure.log || fail "a missing library did not fail the render by name"
  pass "offline: a missing library fails the render"

  grep -q 'not_declared' ${outsideSchema}/testBuildFailure.log || fail "a value outside values.schema.json rendered"
  pass "schema: a value outside values.schema.json fails the render"
  [ -s ${outsideNoSchema} ] || fail "CONTROL: without a schema the same value should render"
  pass "control: the same value renders when the chart ships no schema"

  grep -q '^kind: CustomResourceDefinition' ${withCrds} || fail "includeCrds = true did not render crds/"
  ! grep -q 'CustomResourceDefinition' ${plain} || fail "includeCrds = false rendered crds/"
  pass "crds: rendered only with includeCrds"

  grep -q '"name":"extra-one"' ${withExtra} || fail "extraObjects not appended"
  ! grep -q 'extra-one' ${plain} || fail "an object appeared with no extraObjects"
  pass "extra: appended as a YAML document; default identity (same drvPath)"

  grep -q '^kind: Namespace' ${typed} || fail "mkHelmRelease did not render the Namespace"
  grep -A3 '^kind: Namespace' ${typed} | grep -q '^  name: fixture$' || fail "mkHelmRelease did not default namespace to the release key"
  grep -q 'greeting: "typed"' ${typed} || fail "mkHelmRelease values"
  grep -q 'CustomResourceDefinition' ${typed} || fail "mkHelmRelease includeCrds"
  grep -q '"name":"extra-two"' ${typed} || fail "mkHelmRelease extraObjects"
  pass "release: typed declaration renders Namespace, chart, CRDs and extra objects"

  mkdir -p $out && echo "helm-render: all checks passed" > $out/result
''
