# Helm Chart Build Helpers
# Provides parameterized functions for Helm chart lifecycle operations.
# All commands delegate to `forge` (Rust CLI) — no generated shell scripts.
#
# Functions:
#   mkHelmBumpApp       - Version bump library chart + update all dependents
#   mkHelmSdlcApps      - Per-chart SDLC apps: lint, package, push, release, template
#   mkHelmAllApps       - Aggregate apps across multiple charts + per-chart apps
{
  pkgs,
  forgeCmd ? "forge",
}:
let
  helm = pkgs.kubernetes-helm;
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
  }: {
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
      template = { type = "app"; program = "${templateApp}/bin/helm-template"; };
      bump = bumpApp;
    };
}
