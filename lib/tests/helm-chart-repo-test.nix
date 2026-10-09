# Internal Helm chart distribution: mkHelmChart -> mkHelmRepo -> registry.
#
# Run: nix build .#checks.<system>.helm-chart-repo
#
# A helmworks-shaped fixture (a fake library chart, an app depending on it via
# file://../fixture-lib, an umbrella depending on the app via file://../) is
# built through the REAL mkHelmChartPackages and mkHelmRepo, and this check
# proves, each against a control so none of it is green by construction:
#
#   hermetic       — the fixture builds in the sandbox with no network (the
#                    app's committed Chart.lock is dropped, its library and the
#                    umbrella's nested sibling are vendored from store inputs);
#                    an unvendored dependency and a vendored one of the WRONG
#                    version both fail the build, naming the dependency.
#   reproducible   — the app built twice, seconds apart in two derivations, is
#                    bit-identical, and the two repos built from those builds
#                    publish the same charts.json (same manifest digests).
#                    CONTROL: raw `helm package` of the same chart twice,
#                    seconds apart, DIFFERS — so the comparison can see a
#                    difference when there is one.
#   layout         — every chart is an OCI image layout under
#                    <repository>/<chart>, verified blob by blob by doca,
#                    tagged with the version (`+` spelled `_`), with Helm's
#                    config and chart-layer media types.
#   consumable     — the layout pushed (doca push --layout) to a real
#                    registry (CNCF distribution, loopback, in the sandbox) is
#                    pulled by `helm pull oci://` byte-identical to the archive
#                    and resolved by `helm dependency update` from an
#                    oci:// repository, unchanged — the Flux/engenho/helm path.
{ pkgs, doca, lib ? pkgs.lib }:

let
  helmBuild = import ../service/helm-build.nix { inherit pkgs; ociPush = doca; };
  inherit (helmBuild) mkHelmChart mkHelmChartPackages mkHelmRepo;

  fx = ./fixtures/helm;
  packages = mkHelmChartPackages {
    charts = [
      { name = "fixture-app"; chartDir = fx + "/fixture-app"; }
      { name = "fixture-umbrella"; chartDir = fx + "/fixture-umbrella"; }
    ];
    libChartDir = fx + "/fixture-lib";
    libChartName = "fixture-lib";
  };
  app = packages.fixture-app;
  umbrella = packages.fixture-umbrella;

  # The same derivation recipe, built in a second derivation two seconds later.
  later = drv: drv.overrideAttrs (o: { buildCommand = "sleep 2\n" + o.buildCommand; });
  appLater = later app;

  # CONTROL: what `helm package` alone produces (the pre-mkHelmChart builder).
  rawPackage = extra: pkgs.runCommand "raw-helm-package${extra}" { nativeBuildInputs = [ pkgs.kubernetes-helm ]; } ''
    ${lib.optionalString (extra != "") "sleep 2"}
    export HOME="$TMPDIR"
    cp -r ${fx + "/fixture-lib"} lib && chmod -R u+w lib
    helm package lib --destination "$out" >/dev/null
  '';

  repo = mkHelmRepo { charts = packages; };
  repoLater = mkHelmRepo { charts = [ appLater umbrella ]; };

  # Wrong-version library: fixture-app wants ~0.2.
  libV3 = pkgs.runCommand "fixture-lib-0.3.0" { } ''
    cp -r ${fx + "/fixture-lib"} $out && chmod -R u+w $out
    printf 'apiVersion: v2\nname: fixture-lib\ntype: library\nversion: 0.3.0\n' > $out/Chart.yaml
  '';
  unvendored = pkgs.testers.testBuildFailure (mkHelmChart {
    name = "fixture-app";
    chart = fx + "/fixture-app";
  });
  wrongVersion = pkgs.testers.testBuildFailure (mkHelmChart {
    name = "fixture-app";
    chart = fx + "/fixture-app";
    libraries.fixture-lib = libV3;
  });

  registryConfig = pkgs.writeText "registry.yml" ''
    version: 0.1
    log:
      level: error
    storage:
      filesystem:
        rootdirectory: /registry-data-overridden-by-env
      delete:
        enabled: true
    http:
      addr: 127.0.0.1:5000
  '';

  consumer = pkgs.writeTextDir "consumer/Chart.yaml" ''
    apiVersion: v2
    name: consumer
    version: 0.0.1
    dependencies:
      - name: fixture-umbrella
        version: "0.3.0"
        repository: oci://127.0.0.1:5000/pleme-io/charts
  '';
in
pkgs.runCommand "helm-chart-repo-test"
  {
    nativeBuildInputs = [
      doca
      pkgs.kubernetes-helm
      pkgs.distribution
      pkgs.curl
      pkgs.gnutar
      pkgs.gzip
      pkgs.jq
    ];
  }
  ''
    set -euo pipefail
    export HOME="$TMPDIR" HELM_CACHE_HOME="$TMPDIR/cache" HELM_CONFIG_HOME="$TMPDIR/config" HELM_DATA_HOME="$TMPDIR/data"
    pass() { echo "ok - $*"; }
    fail() { echo "FAIL - $*" >&2; exit 1; }

    appTgz=${app}/fixture-app-0.1.0+nix.1.tgz
    [ -f "$appTgz" ] || fail "mkHelmChart output is not named <chart>-<version>.tgz"

    # ── hermetic ──────────────────────────────────────────────────────────
    tar -tzf "$appTgz" | grep -qx 'fixture-app/charts/fixture-lib/Chart.yaml' \
      || fail "library chart was not vendored into fixture-app"
    ! tar -tzf "$appTgz" | grep -q 'Chart.lock' || fail "Chart.lock (wall-clock generated:) shipped"
    tar -tzf ${umbrella}/fixture-umbrella-0.3.0.tgz \
      | grep -qx 'fixture-umbrella/charts/fixture-app/charts/fixture-lib/Chart.yaml' \
      || fail "nested sibling (umbrella -> app -> lib) not resolved"
    helm template t ${umbrella}/fixture-umbrella-0.3.0.tgz | grep -q 'greeting: "from-umbrella"' \
      || fail "umbrella does not render through its vendored subchart"
    pass "hermetic: library + nested sibling vendored, Chart.lock dropped, renders"
    grep -q 'dependencies not satisfied' ${unvendored}/testBuildFailure.log && grep -q 'fixture-lib.*missing' ${unvendored}/testBuildFailure.log \
      || fail "an unvendored dependency did not fail the build by name"
    grep -q 'fixture-lib.*wrong version' ${wrongVersion}/testBuildFailure.log \
      || fail "a wrong-version vendored dependency did not fail the build"
    pass "hermetic: missing and wrong-version dependencies fail the build"

    # ── reproducible ──────────────────────────────────────────────────────
    cmp -s ${rawPackage ""}/fixture-lib-0.2.0.tgz ${rawPackage "-later"}/fixture-lib-0.2.0.tgz \
      && fail "CONTROL: raw helm package was identical across builds; the comparison below could not see a difference"
    pass "control: raw helm package differs across two builds"
    a=$(sha256sum < "$appTgz" | cut -d' ' -f1)
    b=$(sha256sum < ${appLater}/fixture-app-0.1.0+nix.1.tgz | cut -d' ' -f1)
    [ "$a" = "$b" ] || fail "mkHelmChart not reproducible: $a vs $b"
    pass "reproducible: fixture-app sha256 $a in both builds"
    cmp -s ${repo}/charts.json ${repoLater}/charts.json || fail "charts.json differs between repos built from the two builds"
    digest=$(jq -r '.charts[] | select(.chart=="fixture-app") | .digest' ${repo}/charts.json)
    pass "reproducible: fixture-app manifest digest $digest in both repos"

    # ── layout ────────────────────────────────────────────────────────────
    layout=${repo}/pleme-io/charts/fixture-app
    oci-push layout-verify --helm --layout "$layout" > verify.txt
    expected="0.1.0_nix.1	$digest	application/vnd.cncf.helm.config.v1+json	application/vnd.cncf.helm.chart.content.v1.tar+gzip"
    [ "$(cat verify.txt)" = "$expected" ] || { cat verify.txt >&2; fail "layout tag/digest/media types"; }
    [ "$(jq -r .repository ${repo}/charts.json)" = pleme-io/charts ] || fail "charts.json repository"
    [ "$(jq -r '.charts | length' ${repo}/charts.json)" = 2 ] || fail "charts.json chart count"
    pass "layout: verified, tag 0.1.0_nix.1, Helm media types"

    # ── consumable ────────────────────────────────────────────────────────
    REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY="$TMPDIR/registry-data" \
      registry serve ${registryConfig} > registry.log 2>&1 &
    for _ in $(seq 1 100); do curl -sf http://127.0.0.1:5000/v2/ >/dev/null && break; sleep 0.1; done
    curl -sf http://127.0.0.1:5000/v2/ >/dev/null || { cat registry.log >&2; fail "registry did not start"; }
    for c in fixture-app fixture-umbrella; do
      oci-push push --layout ${repo}/pleme-io/charts/$c --registry 127.0.0.1:5000 \
        --image pleme-io/charts/$c --dest-user nix --dest-pass nix
    done
    served=$(curl -sfI -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
      http://127.0.0.1:5000/v2/pleme-io/charts/fixture-app/manifests/0.1.0_nix.1 \
      | tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: //p')
    [ "$served" = "$digest" ] || fail "registry serves $served, layout says $digest"
    pass "push --layout: registry digest == layout digest"
    mkdir pulled
    helm pull oci://127.0.0.1:5000/pleme-io/charts/fixture-app --version 0.1.0+nix.1 --plain-http -d pulled >/dev/null
    cmp pulled/fixture-app-0.1.0+nix.1.tgz "$appTgz" || fail "helm pull returned different bytes"
    pass "helm pull oci:// returns the mkHelmChart archive byte for byte"
    cp -r ${consumer}/consumer consumer && chmod -R u+w consumer
    helm dependency update consumer --plain-http >/dev/null
    tar -tzf consumer/charts/fixture-umbrella-0.3.0.tgz | grep -qx 'fixture-umbrella/Chart.yaml' \
      || fail "helm dependency update did not resolve the oci:// chart"
    pass "helm dependency update resolves oci://…/pleme-io/charts unchanged"

    kill %1 || true
    mkdir -p $out && echo "helm-chart-repo: all checks passed (fixture-app $a, manifest $digest)" > $out/result
  ''
