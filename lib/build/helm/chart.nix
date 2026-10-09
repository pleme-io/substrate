# substrate/lib/build/helm/chart.nix
#
# mkHelmChart — one Helm chart as one deterministic, hermetic `.tgz` in the
# store. The unit the fleet's internal chart distribution is built from:
# mkHelmRepo (repo.nix) turns a set of these into OCI image layouts that a
# node-local registry serves as oci://charts.pleme.internal/pleme-io/charts/<c>;
# ghcr is the public export of the same bytes, never the source of truth.
#
#   mkHelmChart = import "${substrate}/lib/build/helm/chart.nix" { inherit pkgs; };
#   mkHelmChart {
#     name = "lareira-ntfy";
#     chart = ./charts/lareira-ntfy;
#     libraries = { pleme-lib = ./charts/pleme-lib; };          # unpacked dirs
#     vendoredDeps = {
#       pleme-lareira = mkHelmChart { … };                      # a sibling chart
#       redis = pkgs.fetchurl { url = "https://…/redis-19.0.0.tgz"; hash = "…"; };
#     };
#   }
#   # => $out/<chart-name>-<chart-version>.tgz   (the `helm package` filename)
#
# HERMETIC. Dependencies are vendored by vendor.nix, exactly as mkHelmRender
# does: the source's `charts/` and `Chart.lock` are discarded and every
# dependency comes from an explicit store input. `helm dependency update` is
# never run, so nothing reaches a registry. Before packaging, every dependency
# Chart.yaml declares must read `ok`/`unpacked` in `helm dependency list` — a
# missing one, and also a vendored one whose version does not satisfy the
# constraint, fails the build naming it. (`helm package` alone checks presence
# only: measured with helm 3.19, a `wrong version` subchart packages fine.)
#
# Chart.lock is DROPPED, not pinned: its `generated:` timestamp is wall-clock
# and its digests describe a resolution this build never performs. The vendored
# subcharts inside the archive are the lock.
#
# DETERMINISTIC. `helm package` stamps wall-clock mtimes into every tar header
# and the gzip header. The archive is re-packed from helm's own output: the
# same file set helm wrote (files only, as helm writes them), sorted by byte
# order, mtime = SOURCE_DATE_EPOCH, uid/gid 0, mode 0644, GNU tar format, and
# `gzip -n` (no name, no timestamp). Proven by checks.<system>.helm-chart-repo:
# two builds seconds apart are bit-identical, while the raw `helm package`
# output of the same two builds differs (the control that keeps it non-vacuous).
{ pkgs }:
{
  name,
  chart,
  libraries ? { },
  vendoredDeps ? { },
}:
let
  lib = pkgs.lib;
  vendor = (import ./vendor.nix { inherit lib; }).commands {
    dest = "chart/charts";
    inherit libraries vendoredDeps;
  };
in
pkgs.runCommand "helm-chart-${name}"
  {
    nativeBuildInputs = [
      pkgs.kubernetes-helm
      pkgs.gnutar
      pkgs.gzip
      pkgs.findutils
    ];
    passthru = {
      chartName = name;
      inherit chart libraries vendoredDeps;
    };
  }
  ''
    export HOME="$TMPDIR" HELM_CACHE_HOME="$TMPDIR/cache" HELM_CONFIG_HOME="$TMPDIR/config" HELM_DATA_HOME="$TMPDIR/data"
    cp -r ${chart} chart && chmod -R u+w chart
    rm -rf chart/charts chart/Chart.lock && mkdir -p chart/charts
    ${vendor}

    # Every declared dependency must be satisfied by what was vendored.
    helm dependency list chart > deps.txt
    if grep -vE '^NAME[[:space:]]|^[[:space:]]*$|^WARNING: no dependencies|[[:space:]](ok|unpacked)[[:space:]]*$' deps.txt > unmet.txt; then
      echo "mkHelmChart ${name}: dependencies not satisfied by libraries/vendoredDeps:" >&2
      cat unmet.txt >&2
      echo "Vendor each one: libraries.<n> = <chart dir>, or vendoredDeps.<n> = <.tgz | mkHelmChart output>." >&2
      exit 1
    fi

    helm package chart --destination packaged >/dev/null
    set -- packaged/*.tgz
    archive="$(basename "$1")"
    mkdir unpacked && tar -xzf "$1" -C unpacked
    (cd unpacked && find . -type f -printf '%P\n' | LC_ALL=C sort) > files.txt
    mkdir -p "$out"
    tar --create --format=gnu --no-recursion \
      --owner=0 --group=0 --numeric-owner \
      --mtime="@$SOURCE_DATE_EPOCH" --mode=0644 \
      -C unpacked -T files.txt \
      | gzip -9 -n > "$out/$archive"
  ''
