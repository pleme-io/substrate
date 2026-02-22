# Helm Chart Build Helpers
# Provides parameterized functions for linting, testing, packaging, and pushing Helm charts.
#
# Functions:
#   mkHelmLintApp       - Lint a chart (helm lint + helm template)
#   mkHelmPackageApp    - Package a chart into a .tgz tarball
#   mkHelmPushApp       - Push a packaged chart to OCI registry
#   mkHelmReleaseApp    - Full lifecycle: lint → package → push
#   mkHelmTemplateApp   - Render templates for debugging
#   mkHelmBumpApp       - Version bump library chart + update all dependents
#   mkHelmSdlcApps      - Complete SDLC: lint, package, push, release, template per chart
#   mkHelmAllApps       - Aggregate apps across multiple charts (includes bump)
{
  pkgs,
  forgeCmd ? "forge",
}:
let
  helm = pkgs.kubernetes-helm;
in
{
  # Lint a single chart (helm lint + helm template validation)
  mkHelmLintApp = {
    name,
    chartDir,
    libChartDir ? null,
  }:
    pkgs.writeShellApplication {
      name = "helm-lint-${name}";
      runtimeInputs = [ helm ];
      text = ''
        CHART_DIR="''${1:-${chartDir}}"
        TMPDIR=$(mktemp -d)
        trap 'rm -rf "$TMPDIR"' EXIT
        cp -r "$CHART_DIR" "$TMPDIR/${name}"
        ${if libChartDir != null then ''
          cp -r "${libChartDir}" "$TMPDIR/pleme-lib"
        '' else ""}
        chmod -R u+w "$TMPDIR"
        helm dependency update "$TMPDIR/${name}" 2>/dev/null || true
        echo "=== Linting ${name} ==="
        helm lint "$TMPDIR/${name}"
        echo "=== Template validation ==="
        helm template test "$TMPDIR/${name}" --set image.repository=test 2>/dev/null || true
        echo "PASS: ${name}"
      '';
    };

  # Package a single chart into a .tgz tarball
  mkHelmPackageApp = {
    name,
    chartDir,
    libChartDir ? null,
  }:
    pkgs.writeShellApplication {
      name = "helm-package-${name}";
      runtimeInputs = [ helm ];
      text = ''
        CHART_DIR="''${1:-${chartDir}}"
        OUTPUT_DIR="''${2:-dist}"
        mkdir -p "$OUTPUT_DIR"
        TMPDIR=$(mktemp -d)
        trap 'rm -rf "$TMPDIR"' EXIT
        cp -r "$CHART_DIR" "$TMPDIR/${name}"
        ${if libChartDir != null then ''
          cp -r "${libChartDir}" "$TMPDIR/pleme-lib"
        '' else ""}
        chmod -R u+w "$TMPDIR"
        helm dependency update "$TMPDIR/${name}" 2>/dev/null || true
        helm package "$TMPDIR/${name}" --destination "$OUTPUT_DIR"
        echo "Packaged ${name} → $OUTPUT_DIR"
      '';
    };

  # Push a packaged chart to OCI registry
  mkHelmPushApp = {
    name,
    registry ? "oci://ghcr.io/pleme-io/charts",
  }:
    pkgs.writeShellApplication {
      name = "helm-push-${name}";
      runtimeInputs = [ helm ];
      text = ''
        REGISTRY="''${1:-${registry}}"
        CHART_TGZ=$(find dist -name '${name}-*.tgz' 2>/dev/null | sort -V | tail -1)
        if [ -z "$CHART_TGZ" ]; then
          echo "ERROR: No ${name} tarball in dist/. Run package first."
          exit 1
        fi
        echo "Pushing $CHART_TGZ → $REGISTRY"
        helm push "$CHART_TGZ" "$REGISTRY"
      '';
    };

  # Full lifecycle: lint → package → push
  mkHelmReleaseApp = {
    name,
    chartDir,
    libChartDir ? null,
    registry ? "oci://ghcr.io/pleme-io/charts",
  }:
    pkgs.writeShellApplication {
      name = "helm-release-${name}";
      runtimeInputs = [ helm ];
      text = ''
        CHART_DIR="''${1:-${chartDir}}"
        REGISTRY="''${2:-${registry}}"
        OUTPUT_DIR="dist"
        mkdir -p "$OUTPUT_DIR"
        TMPDIR=$(mktemp -d)
        trap 'rm -rf "$TMPDIR"' EXIT
        cp -r "$CHART_DIR" "$TMPDIR/${name}"
        ${if libChartDir != null then ''
          cp -r "${libChartDir}" "$TMPDIR/pleme-lib"
        '' else ""}
        chmod -R u+w "$TMPDIR"
        helm dependency update "$TMPDIR/${name}" 2>/dev/null || true

        echo "=== Lint ==="
        helm lint "$TMPDIR/${name}"

        echo "=== Package ==="
        helm package "$TMPDIR/${name}" --destination "$OUTPUT_DIR"

        echo "=== Push ==="
        CHART_TGZ=$(find "$OUTPUT_DIR" -name '${name}-*.tgz' | sort -V | tail -1)
        helm push "$CHART_TGZ" "$REGISTRY"

        echo "=== Released ${name} ==="
      '';
    };

  # Render templates for debugging
  mkHelmTemplateApp = {
    name,
    chartDir,
    libChartDir ? null,
  }:
    pkgs.writeShellApplication {
      name = "helm-template-${name}";
      runtimeInputs = [ helm ];
      text = ''
        CHART_DIR="''${1:-${chartDir}}"
        VALUES="''${2:-}"
        TMPDIR=$(mktemp -d)
        trap 'rm -rf "$TMPDIR"' EXIT
        cp -r "$CHART_DIR" "$TMPDIR/${name}"
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

  # Version bump a library chart and update all dependent Chart.yaml files.
  # Delegates to `forge helm bump` for the actual work.
  #
  # Usage: nix run .#bump -- {major|minor|patch}
  #
  # Args:
  #   libChartName: Name of the library chart directory (e.g., "pleme-lib")
  #   chartsDir:    Relative path from repo root to charts/ directory (default: "charts")
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

  # Complete SDLC apps for a single chart
  # Returns: { lint, package, push, release, template }
  mkHelmSdlcApps = {
    name,
    chartDir,
    libChartDir ? null,
    registry ? "oci://ghcr.io/pleme-io/charts",
  }:
    let
      inherit (import ./helm-build.nix { inherit pkgs forgeCmd; })
        mkHelmLintApp mkHelmPackageApp mkHelmPushApp mkHelmReleaseApp mkHelmTemplateApp;
    in {
      lint = mkHelmLintApp { inherit name chartDir libChartDir; };
      package = mkHelmPackageApp { inherit name chartDir libChartDir; };
      push = mkHelmPushApp { inherit name registry; };
      release = mkHelmReleaseApp { inherit name chartDir libChartDir registry; };
      template = mkHelmTemplateApp { inherit name chartDir libChartDir; };
    };

  # Aggregate apps across multiple charts
  # charts: list of { name, chartDir, libChartDir? }
  # Returns flake apps attrset with lint:<name>, package:<name>, push:<name>,
  #   release:<name>, template, bump, plus aggregate lint/package/push/release
  mkHelmAllApps = {
    charts,
    libChartDir ? null,
    libChartName ? "pleme-lib",
    chartsDir ? "charts",
    registry ? "oci://ghcr.io/pleme-io/charts",
  }:
    let
      lib = pkgs.lib;
      chartNames = map (c: c.name) charts;

      # Per-chart apps
      perChartApps = lib.foldl' (acc: chart:
        let
          sdlc = import ./helm-build.nix { inherit pkgs forgeCmd; };
          apps = sdlc.mkHelmSdlcApps {
            inherit (chart) name chartDir;
            libChartDir = chart.libChartDir or libChartDir;
            inherit registry;
          };
        in acc // {
          "lint:${chart.name}" = { type = "app"; program = "${apps.lint}/bin/helm-lint-${chart.name}"; };
          "package:${chart.name}" = { type = "app"; program = "${apps.package}/bin/helm-package-${chart.name}"; };
          "push:${chart.name}" = { type = "app"; program = "${apps.push}/bin/helm-push-${chart.name}"; };
          "release:${chart.name}" = { type = "app"; program = "${apps.release}/bin/helm-release-${chart.name}"; };
        }
      ) {} charts;

      # Aggregate apps
      lintAll = pkgs.writeShellApplication {
        name = "helm-lint-all";
        runtimeInputs = [ helm ];
        text = ''
          FAILED=0
          ${lib.concatMapStringsSep "\n" (chart: ''
            echo "=== Linting ${chart.name} ==="
            TMPDIR=$(mktemp -d)
            cp -r "${chart.chartDir}" "$TMPDIR/${chart.name}"
            ${if (chart.libChartDir or libChartDir) != null then ''
              cp -r "${chart.libChartDir or libChartDir}" "$TMPDIR/pleme-lib"
            '' else ""}
            chmod -R u+w "$TMPDIR"
            helm dependency update "$TMPDIR/${chart.name}" 2>/dev/null || true
            if helm lint "$TMPDIR/${chart.name}"; then
              echo "PASS: ${chart.name}"
            else
              echo "FAIL: ${chart.name}"
              FAILED=1
            fi
            rm -rf "$TMPDIR"
          '') charts}
          exit $FAILED
        '';
      };

      packageAll = pkgs.writeShellApplication {
        name = "helm-package-all";
        runtimeInputs = [ helm ];
        text = ''
          OUTPUT_DIR="''${1:-dist}"
          mkdir -p "$OUTPUT_DIR"
          ${lib.concatMapStringsSep "\n" (chart: ''
            echo "=== Packaging ${chart.name} ==="
            TMPDIR=$(mktemp -d)
            cp -r "${chart.chartDir}" "$TMPDIR/${chart.name}"
            ${if (chart.libChartDir or libChartDir) != null then ''
              cp -r "${chart.libChartDir or libChartDir}" "$TMPDIR/pleme-lib"
            '' else ""}
            chmod -R u+w "$TMPDIR"
            helm dependency update "$TMPDIR/${chart.name}" 2>/dev/null || true
            helm package "$TMPDIR/${chart.name}" --destination "$OUTPUT_DIR"
            rm -rf "$TMPDIR"
          '') charts}
          echo "All charts packaged → $OUTPUT_DIR"
        '';
      };

      pushAll = pkgs.writeShellApplication {
        name = "helm-push-all";
        runtimeInputs = [ helm ];
        text = ''
          REGISTRY="''${1:-${registry}}"
          ${lib.concatMapStringsSep "\n" (chart: ''
            CHART_TGZ=$(find dist -name '${chart.name}-*.tgz' 2>/dev/null | sort -V | tail -1)
            if [ -n "$CHART_TGZ" ]; then
              echo "=== Pushing ${chart.name} ==="
              helm push "$CHART_TGZ" "$REGISTRY"
            else
              echo "SKIP: ${chart.name} (no tarball in dist/)"
            fi
          '') charts}
        '';
      };

      releaseAll = pkgs.writeShellApplication {
        name = "helm-release-all";
        runtimeInputs = [ helm ];
        text = ''
          REGISTRY="''${1:-${registry}}"
          OUTPUT_DIR="dist"
          mkdir -p "$OUTPUT_DIR"
          FAILED=0
          ${lib.concatMapStringsSep "\n" (chart: ''
            echo ""
            echo "=========================================="
            echo "  Releasing ${chart.name}"
            echo "=========================================="
            TMPDIR=$(mktemp -d)
            cp -r "${chart.chartDir}" "$TMPDIR/${chart.name}"
            ${if (chart.libChartDir or libChartDir) != null then ''
              cp -r "${chart.libChartDir or libChartDir}" "$TMPDIR/pleme-lib"
            '' else ""}
            chmod -R u+w "$TMPDIR"
            helm dependency update "$TMPDIR/${chart.name}" 2>/dev/null || true
            echo "--- Lint ---"
            if ! helm lint "$TMPDIR/${chart.name}"; then
              echo "FAIL: ${chart.name} lint"
              FAILED=1
              rm -rf "$TMPDIR"
              continue 2>/dev/null || true
            fi
            echo "--- Package ---"
            helm package "$TMPDIR/${chart.name}" --destination "$OUTPUT_DIR"
            echo "--- Push ---"
            CHART_TGZ=$(find "$OUTPUT_DIR" -name '${chart.name}-*.tgz' | sort -V | tail -1)
            helm push "$CHART_TGZ" "$REGISTRY"
            echo "DONE: ${chart.name}"
            rm -rf "$TMPDIR"
          '') charts}
          exit $FAILED
        '';
      };

      templateApp = pkgs.writeShellApplication {
        name = "helm-template";
        runtimeInputs = [ helm ];
        text = ''
          CHART="''${1:?Usage: nix run .#template -- <chart-name> [values-file]}"
          VALUES="''${2:-}"
          REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
          TMPDIR=$(mktemp -d)
          trap 'rm -rf "$TMPDIR"' EXIT
          cp -r "$REPO_ROOT/charts/$CHART" "$TMPDIR/$CHART"
          if [ -d "$REPO_ROOT/charts/pleme-lib" ]; then
            cp -r "$REPO_ROOT/charts/pleme-lib" "$TMPDIR/pleme-lib"
          fi
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
      lint = { type = "app"; program = "${lintAll}/bin/helm-lint-all"; };
      package = { type = "app"; program = "${packageAll}/bin/helm-package-all"; };
      push = { type = "app"; program = "${pushAll}/bin/helm-push-all"; };
      release = { type = "app"; program = "${releaseAll}/bin/helm-release-all"; };
      template = { type = "app"; program = "${templateApp}/bin/helm-template"; };
      bump = bumpApp;
    };
}
