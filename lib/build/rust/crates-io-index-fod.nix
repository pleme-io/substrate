# crates-io-index-fod.nix — hermetic FOD of the FULL crates.io registry
# index, packaged so `cargo generate-lockfile --offline` resolves ANY
# registry dependency in a clean CARGO_HOME with NO network, NO --impure,
# NO __noChroot.
#
# APPROACH: git-registry source-replacement (NOT a sparse-cache snapshot).
#
#   - Cargo offline resolution against a SPARSE registry reads ONLY from a
#     pre-populated binary `.cache/` (the host ~/.cargo sparse index resolves
#     offline for exactly this reason — its `.cache/` is warm). Building a
#     full `.cache/` for ~160k crates requires running cargo per crate or a
#     bespoke SummariesCache encoder — large, slow, format-version-coupled to
#     cargo. Empirically confirmed: `registry = "sparse+file://<plaindir>"`
#     does NOT resolve offline (no warm `.cache/`).
#
#   - Cargo offline resolution against a GIT registry reads index entries
#     straight out of the git tree of an ALREADY-FETCHED clone. The canonical
#     full index `github.com/rust-lang/crates.io-index` IS that git tree
#     byte-for-byte, so it needs no transformation — only correct placement.
#     Empirically confirmed: a clone placed at
#     `$CARGO_HOME/registry/index/<source-hash>/` carrying
#     `refs/remotes/origin/HEAD` + `refs/remotes/origin/master`, plus a
#     `replace-with` file:// git registry in config.toml, makes
#     `cargo generate-lockfile --offline` resolve fully offline. (Cargo never
#     runs the initial `git fetch`, which --offline blocks even for a local
#     file:// remote — so the clone MUST be pre-placed.)
#
# The FOD is a DETERMINISTIC plain-directory snapshot of the index at a pinned
# rev (fetchgit default `leaveDotGit = false` strips .git -> reproducible
# content-addressed snapshot). The git repo cargo consumes is materialized
# once, cheaply, at provision time by the typed Rust provisioner
# (`cargo-index-provision`, NO SHELL) whose algorithm is documented below.
#
# PROVISION ALGORITHM (what the typed provisioner does, offline-only):
#   1. Materialize a file:// git "remote" from this FOD once:
#        cp -R <fullIndex>/. <registryRemote>/ ; git init -b master ;
#        git add -A ; git commit -m "crates.io-index @ <rev>"
#      <registryRemote> MUST be a stable absolute path — its URL string
#      deterministically selects cargo's on-disk index dir name (source hash).
#   2. Write <cargoHome>/config.toml (see `configToml` below).
#   3. Pre-place the clone where cargo expects an already-fetched git index:
#        git clone <registryRemote> <cargoHome>/registry/index/<source-hash>
#      `git clone` reproduces exactly the refs cargo's online path creates
#      (refs/remotes/origin/HEAD + refs/remotes/origin/master). The
#      <source-hash> is a pure function of the file:// URL; the provisioner
#      discovers it by listing the empty dir an offline `cargo` probe always
#      creates, or computes it directly.
{ pkgs }:
let
  inherit (pkgs) lib;

  # Pinned default-branch HEAD of rust-lang/crates.io-index.
  # Refresh with: git ls-remote https://github.com/rust-lang/crates.io-index HEAD
  rev = "5997c97232e4bc0cf2b3a61748934d286ad83ecd";

  # Real content hash of the plain-directory snapshot at `rev`.
  # Re-derive by setting `hash = lib.fakeHash;` and reading the "got:" line.
  hash = "@CRATES_IO_INDEX_HASH@";

  # The hermetic FOD: a plain directory of the full index (config.json at root
  # + per-crate JSON-lines files in cargo's name-shard layout).
  fullIndex = pkgs.fetchgit {
    url = "https://github.com/rust-lang/crates.io-index.git";
    inherit rev hash;
  };

  # The source-replacement config the provisioner writes to
  # <cargoHome>/config.toml. `registryRemote` is the stable file:// path from
  # provision step 1.
  configToml = registryRemote: ''
    [source.crates-io]
    replace-with = "local-crates-index"

    [source.local-crates-index]
    registry = "file://${registryRemote}"
  '';
in
{
  inherit rev hash fullIndex configToml;
}
