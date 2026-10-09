# Helm Chart Build Helpers
# Provides parameterized functions for Helm chart lifecycle operations.
# All commands delegate to `forge` (Rust CLI) — no generated shell scripts.
#
# Functions:
#   mkHelmBumpApp        - Version bump library chart + update all dependents
#   mkHelmSdlcApps       - Per-chart SDLC apps: lint, package, push, release, template
#   mkHelmAllApps        - Aggregate apps across multiple charts + per-chart apps
#   mkHelmChartPackages  - Every chart of a repo as a hermetic mkHelmChart (sibling graph resolved)
#   mkHelmChart          - One chart -> one deterministic, hermetic .tgz
#   mkHelmRepo           - Charts -> OCI image layouts (internal registry) + charts.json
#   mkHelmRender         - Pinned chart + typed values -> rendered manifests
#   mkHelmRenderTestApps - Pure-helm render tests: unittest + render-check apps
{
  pkgs,
  forgeCmd ? "forge",
  # doca (substrate's oci-push package), for mkHelmRepo. null = mkHelmRepo
  # throws naming it; every other function here is unaffected.
  ociPush ? null,
}:
let
  helm = pkgs.kubernetes-helm;
  mkHelmChart = import ../build/helm/chart.nix { inherit pkgs; };
in
{
  # Version bump a library chart and update all dependent Chart.yaml files.
  # Delegates to `forge helm bump`.
  mkHelmBumpApp = {
    libChartName ? "pleme-lib",
    chartsDir ? "charts",
  }: {
    type = "app";
    program = toString (pkgs.writeShellScript "helm-bump" ''
      set -euo pipefail
      exec ${forgeCmd} helm bump \
        --charts-dir "${chartsDir}" \
        --lib-chart-name "${libChartName}" \
        --level "''${1:-patch}"
    '');
  };

  # Per-chart SDLC apps (lint, package, push, release, template)
  # Each delegates to forge with --lib-chart-dir for dependency resolution.
  mkHelmSdlcApps = {
    name,
    chartDir,
    libChartDir ? null,
    registry ? "oci://ghcr.io/pleme-io/charts",
  }: let
    check = import ../types/assertions.nix;
    _ = check.all [
      (check.nonEmptyStr "name" name)
      (check.str "registry" registry)
    ];
  in {
    lint = pkgs.writeShellScript "helm-lint-${name}" ''
      set -euo pipefail
      export PATH="${helm}/bin:$PATH"
      exec ${forgeCmd} helm lint \
        --chart-dir "${chartDir}" \
        ${if libChartDir != null then "--lib-chart-dir \"${libChartDir}\"" else ""}
    '';

    release = pkgs.writeShellScript "helm-release-${name}" ''
      set -euo pipefail
      export PATH="${helm}/bin:$PATH"
      exec ${forgeCmd} helm release \
        --chart-dir "${chartDir}" \
        --registry "${registry}" \
        ${if libChartDir != null then "--lib-chart-dir \"${libChartDir}\"" else ""}
    '';

    # Template still uses helm directly (interactive debugging tool)
    template = pkgs.writeShellApplication {
      name = "helm-template-${name}";
      runtimeInputs = [ helm ];
      text = ''
        VALUES="''${1:-}"
        TMPDIR=$(mktemp -d)
        trap 'rm -rf "$TMPDIR"' EXIT
        cp -r "${chartDir}" "$TMPDIR/${name}"
        ${if libChartDir != null then ''
          cp -r "${libChartDir}" "$TMPDIR/pleme-lib"
        '' else ""}
        chmod -R u+w "$TMPDIR"
        helm dependency update "$TMPDIR/${name}" 2>/dev/null || true
        if [ -n "$VALUES" ]; then
          helm template test "$TMPDIR/${name}" -f "$VALUES"
        else
          helm template test "$TMPDIR/${name}" --set image.repository=test
        fi
      '';
    };
  };

  # Aggregate apps across multiple charts
  # charts: list of { name, chartDir, libChartDir? }
  # Returns flake apps attrset with lint:<name>, release:<name>,
  #   plus aggregate lint/release/template, and bump
  mkHelmAllApps = {
    charts,
    libChartDir ? null,
    libChartName ? "pleme-lib",
    chartsDir ? "charts",
    registry ? "oci://ghcr.io/pleme-io/charts",
  }:
    let
      lib = pkgs.lib;

      # Per-chart apps (delegate to forge)
      perChartApps = lib.foldl' (acc: chart:
        let
          sdlc = (import ./helm-build.nix { inherit pkgs forgeCmd; }).mkHelmSdlcApps {
            inherit (chart) name chartDir;
            libChartDir = chart.libChartDir or libChartDir;
            inherit registry;
          };
        in acc // {
          "lint:${chart.name}" = { type = "app"; program = toString sdlc.lint; };
          "release:${chart.name}" = { type = "app"; program = toString sdlc.release; };
        }
      ) {} charts;

      # Aggregate lint-all (forge discovers charts in directory)
      lintAllScript = pkgs.writeShellScript "helm-lint-all" ''
        set -euo pipefail
        export PATH="${helm}/bin:$PATH"
        REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
        exec ${forgeCmd} helm lint-all \
          --charts-dir "$REPO_ROOT/${chartsDir}" \
          ${if libChartDir != null then "--lib-chart-dir \"${libChartDir}\"" else ""} \
          --lib-chart-name "${libChartName}"
      '';

      # Aggregate release-all (forge discovers + lint + package + push)
      releaseAllScript = pkgs.writeShellScript "helm-release-all" ''
        set -euo pipefail
        export PATH="${helm}/bin:$PATH"
        REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
        exec ${forgeCmd} helm release-all \
          --charts-dir "$REPO_ROOT/${chartsDir}" \
          ${if libChartDir != null then "--lib-chart-dir \"${libChartDir}\"" else ""} \
          --lib-chart-name "${libChartName}" \
          --registry "''${1:-${registry}}"
      '';

      # Mirror upstream third-party subcharts into the pleme-io OCI registry so
      # `release` never fetches from a third-party repo. Everything is derived
      # from the wrapper charts' own Chart.yaml deps — no catalog. Idempotent:
      # only a NEW upstream version touches the upstream; a clean no-op for a repo
      # with no third-party subchart deps.
      mirrorScript = pkgs.writeShellScript "helm-mirror" ''
        set -euo pipefail
        export PATH="${helm}/bin:$PATH"
        REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
        exec ${forgeCmd} helm mirror \
          --charts-dir "$REPO_ROOT/${chartsDir}" \
          --registry "''${1:-${registry}}"
      '';

      # Template app (interactive, uses helm directly)
      templateApp = pkgs.writeShellApplication {
        name = "helm-template";
        runtimeInputs = [ helm ];
        text = ''
          CHART="''${1:?Usage: nix run .#template -- <chart-name> [values-file]}"
          VALUES="''${2:-}"
          REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
          TMPDIR=$(mktemp -d)
          trap 'rm -rf "$TMPDIR"' EXIT
          cp -r "$REPO_ROOT/${chartsDir}/$CHART" "$TMPDIR/$CHART"
          ${if libChartDir != null then ''
            cp -r "${libChartDir}" "$TMPDIR/${libChartName}"
          '' else ''
            if [ -d "$REPO_ROOT/${chartsDir}/${libChartName}" ]; then
              cp -r "$REPO_ROOT/${chartsDir}/${libChartName}" "$TMPDIR/${libChartName}"
            fi
          ''}
          chmod -R u+w "$TMPDIR"
          helm dependency update "$TMPDIR/$CHART" 2>/dev/null || true
          if [ -n "$VALUES" ]; then
            helm template test "$TMPDIR/$CHART" -f "$VALUES"
          else
            helm template test "$TMPDIR/$CHART" --set image.repository=test
          fi
        '';
      };

      bumpApp = (import ./helm-build.nix { inherit pkgs forgeCmd; }).mkHelmBumpApp {
        inherit libChartName chartsDir;
      };

    in perChartApps // {
      lint = { type = "app"; program = toString lintAllScript; };
      release = { type = "app"; program = toString releaseAllScript; };
      mirror = { type = "app"; program = toString mirrorScript; };
      template = { type = "app"; program = "${templateApp}/bin/helm-template"; };
      bump = bumpApp;
    };

  # Build chart tarballs as Nix packages: one hermetic, bit-reproducible
  # mkHelmChart (lib/build/helm/chart.nix) per chart. Returns an attrset of
  # { <chart-name> = derivation; ... }, each holding `<name>-<version>.tgz`.
  #
  # charts:       list of { name, chartDir }
  # libChartDir:  the library chart (e.g. pleme-lib), vendored unpacked into
  #               every chart whose Chart.yaml depends on file://../<libChartName>
  # libChartName: that dependency's directory name (default: "pleme-lib")
  # vendoredDeps: third-party subcharts, per chart, as fixed-output archives —
  #               { <chart> = { <dep> = pkgs.fetchurl { url; hash; }; }; }.
  #               Nothing is ever fetched in the sandbox; a dependency with no
  #               vendored archive fails the build naming it.
  #
  # Every OTHER `file://../<dir>` dependency is a sibling chart: it is built by
  # this same function (listed in `charts` or not — pleme-lareira,
  # pleme-microservice) and vendored as its archive, so nested umbrellas
  # (lareira-openclaw-stack -> lareira-cartorio -> pleme-microservice) resolve
  # to the end. The sibling edges are read from Chart.yaml at eval time by a
  # line scan, which is NOT a YAML parser: an edge it missed cannot ship a
  # wrong chart, because mkHelmChart's `helm dependency list` gate fails the
  # build on any declared dependency that was not vendored (CI-caught).
  #
  # Usage:
  #   packages = substrateLib.mkHelmChartPackages {
  #     charts = chartDefs;
  #     libChartDir = ./charts/pleme-lib;
  #   };
  #   helmRepo = substrateLib.mkHelmRepo { charts = packages; };
  mkHelmChartPackages = {
    charts,
    libChartDir,
    libChartName ? "pleme-lib",
    vendoredDeps ? { },
  }:
    let
      lib = pkgs.lib;
      listedName = lib.listToAttrs (map (c: lib.nameValuePair (toString c.chartDir) c.name) charts);
      nodeName = dir: listedName.${toString dir} or (baseNameOf (toString dir));
      sibling = dir: d: (dirOf dir) + "/${d}";
      fileDepDirs = dir:
        let
          lines = lib.splitString "\n" (builtins.readFile (dir + "/Chart.yaml"));
          # Block style (`  repository: file://../x`) and flow style
          # (`- {name: x, repository: "file://../x"}`) — helmworks uses both.
          isFileRepo = l: builtins.match "[^#]*repository:[[:space:]]*[\"']?file://.*" l != null;
          siblingOf = l: builtins.match "[^#]*repository:[[:space:]]*[\"']?file://\\.\\./([A-Za-z0-9._-]+)/?[\"']?[[:space:]]*([,}].*|#.*)?" l;
        in
        lib.concatMap (l:
          if !(isFileRepo l) then [ ]
          else if siblingOf l != null then [ (builtins.head (siblingOf l)) ]
          else throw "mkHelmChartPackages: ${toString dir}/Chart.yaml: `${l}` is a file:// dependency that is not a sibling (file://../<dir>); build that chart with mkHelmChart and vendor it explicitly"
        ) lines;
      closure = builtins.genericClosure {
        startSet = map (c: { key = toString c.chartDir; dir = c.chartDir; }) charts;
        operator = n:
          map (d: { key = toString (sibling n.dir d); dir = sibling n.dir d; })
            (lib.filter (d: d != libChartName) (fileDepDirs n.dir));
      };
      nodes = lib.listToAttrs (map (n:
        let
          deps = fileDepDirs n.dir;
          name = nodeName n.dir;
        in
        lib.nameValuePair n.key (mkHelmChart {
          inherit name;
          chart = n.dir;
          libraries = lib.optionalAttrs (builtins.elem libChartName deps) { ${libChartName} = libChartDir; };
          vendoredDeps =
            lib.listToAttrs (map (d: lib.nameValuePair d nodes.${toString (sibling n.dir d)})
              (lib.filter (d: d != libChartName) deps))
            // (vendoredDeps.${name} or { });
        })) closure);
    in
    lib.listToAttrs (map (c: lib.nameValuePair c.name nodes.${toString c.chartDir}) charts);

  # One chart -> one deterministic, hermetic .tgz (lib/build/helm/chart.nix).
  inherit mkHelmChart;

  # Charts -> one store path of OCI image layouts + charts.json, served by the
  # node-local registry as oci://charts.pleme.internal/<repository>/<chart>
  # (lib/build/helm/repo.nix). Needs doca (`ociPush`).
  mkHelmRepo = import ../build/helm/repo.nix { inherit pkgs; doca = ociPush; };

  # A pinned chart + typed values -> rendered manifests (lib/build/helm/render.nix).
  mkHelmRender = import ../build/helm/render.nix { inherit pkgs; };

  # Render-test apps for a repo's charts, wrapping a typed render-test binary
  # (the akeyless `charttest` keyway tool, or any cmd exposing the same
  # `render`/`unittest`/`ci` subcommands). ALL logic lives in that binary —
  # this recipe is launch plumbing only (zero shell logic), the same shape as
  # mkHelmAllApps wrapping `forge helm …`. The binary is given a
  # helm-with-unittest plugin on PATH so it can shell out via os/exec.
  #
  # cmd        - the render-test binary on PATH (default "charttest")
  # configArg  - optional `--config <path>` the binary reads its chart list from
  #
  # Exposes three flake apps, each a thin `exec <cmd> <sub>`:
  #   nix run .#render-check   nix run .#unittest   nix run .#render-test-ci
  mkHelmRenderTestApps = {
    cmd ? "charttest",
    configArg ? "",
  }:
    let
      # helm-unittest plugin: its $out holds helm-unittest/plugin.yaml, so $out
      # is itself a valid HELM_PLUGINS dir — version-robust across nixpkgs revs
      # that lack kubernetes-helm.withPlugins.
      helmPlugins = pkgs.kubernetes-helmPlugins.helm-unittest;
      mkApp = sub: name:
        let
          app = pkgs.writeShellApplication {
            inherit name;
            runtimeInputs = [ pkgs.kubernetes-helm pkgs.cacert pkgs.git ];
            text = ''
              export SSL_CERT_FILE="''${SSL_CERT_FILE:-${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt}"
              export HELM_PLUGINS="${helmPlugins}''${HELM_PLUGINS:+:$HELM_PLUGINS}"
              exec ${cmd} ${sub} ${configArg} "$@"
            '';
          };
        in { type = "app"; program = "${app}/bin/${name}"; };
    in {
      render-check = mkApp "render" "helm-render-check";
      unittest = mkApp "unittest" "helm-unittest";
      render-test-ci = mkApp "ci" "helm-render-test-ci";
    };
}
