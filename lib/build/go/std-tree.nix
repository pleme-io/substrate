# std-tree.nix (Go) — ONE shared standard-library derivation per target tuple.
#
# Modern Go (≥ ~1.20) dropped the prebuilt `$GOROOT/pkg` archives; std is
# compiled per-package into GOCACHE on demand. The clean per-package answer for
# the gen-gomod M1 incremental interpreter is a single derivation per
# `(goVersion, goos, goarch, tags)` that runs the REAL toolchain once to
# materialize every std package's `.a` + a base `importcfg`, so all N workload
# nodes import std archives from this one store path instead of recompiling std
# in every package sandbox (buildGoModule's whole-module recompile is exactly
# what M1 removes).
#
# Mechanism: `go list -export std` builds every std package and reports, per
# package, the on-disk path of its freshly-compiled archive (`.Export`, a GOCACHE
# path that does NOT survive the sandbox). We copy each archive into
# `$out/pkg/<importPath>.a` and emit `$out/importcfg.base` pointing at the copies
# — a stable, reproducible (`-trimpath`) per-tuple std snapshot. The interpreter
# appends `$out/importcfg.base` to each node's importcfg at BUILD time (a store
# reference, never an eval-time readFile → no IFD).
#
# std packages carry assembly (`.s`); that asm lives INSIDE this derivation,
# compiled by the real toolchain, opaque to the per-node graph — which is why
# own/dep asm packages are deferred to M-asm but std asm is a non-problem.
#
# ── Risk (M1, from the build plan §7 #3) ─────────────────────────────────────
# One std derivation per tuple is clean but its cold build is a monolith. If it
# dominates Gate A wall-clock, split std into per-package nodes too. Measure
# before deciding — do not pre-optimize.
{ pkgs, lib ? pkgs.lib }:

# Returns a builder keyed by tuple: { goVersion; goos; goarch; tags; } -> stdTree.
{ goVersion
, goos
, goarch
, tags ? [ ]
}:
let
  tagArg =
    lib.optionalString (tags != [ ])
      "-tags ${lib.escapeShellArg (lib.concatStringsSep "," tags)}";

  drv = pkgs.stdenv.mkDerivation {
    name = "go-std-${goVersion}-${goos}-${goarch}";
    dontUnpack = true;
    dontConfigure = true;
    dontInstall = true;
    nativeBuildInputs = [ pkgs.go ];

    # Reproducibility: -trimpath + a fixed from-source toolchain (pkgs.go is the
    # fleet single-source, see build/go/toolchain.nix) ⇒ content-addressable
    # std archives across hosts.
    buildPhase = ''
      runHook preBuild

      export HOME="$TMPDIR"
      export GOCACHE="$TMPDIR/gocache"
      export GOPATH="$TMPDIR/gopath"
      export GOOS="${goos}"
      export GOARCH="${goarch}"
      export CGO_ENABLED=0
      export GOFLAGS=-trimpath

      mkdir -p "$out/pkg"
      : > "$out/importcfg.base"

      # `-export` builds each std package and prints its archive path.
      go list -export ${tagArg} -f '{{.ImportPath}} {{.Export}}' std > std-exports.txt

      while read -r ip export; do
        [ -z "$export" ] && continue
        dest="$out/pkg/$ip.a"
        mkdir -p "$(dirname "$dest")"
        cp "$export" "$dest"
        echo "packagefile $ip=$dest" >> "$out/importcfg.base"
      done < std-exports.txt

      runHook postBuild
    '';

    passthru.package = importPath: "${drv}/pkg/${importPath}.a";
  };
in
{
  inherit drv;
  # importPath -> the std archive path inside this tree.
  package = drv.passthru.package;
  # A store reference (NOT a readFile) — appended to node importcfgs at build.
  importcfgBaseRef = "${drv}/importcfg.base";
}
