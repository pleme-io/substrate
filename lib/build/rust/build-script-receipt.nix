# The postInstall fragment that makes a crate's build-script receipt
# deterministic. See the "build-script receipt determinism" note in
# lockfile-builder.nix for the measurement and why dropping is safe.
#
# `rerun-if-changed` carries an absolute path into the build dir; nothing in
# buildRustCrate reads it. Every other line (the `rustc-*` directives,
# `rerun-if-env-changed`, warnings) is kept byte-for-byte.
{
  # grep exits 1 when every line is filtered out; the empty file is the right
  # result there, so that status is not a failure.
  postInstall = ''
    for opt in "''${lib:-/nonexistent}"/lib/*.opt; do
      [ -f "$opt" ] || continue
      grep -Ev '^cargo::?rerun-if-changed=' "$opt" > "$opt.norm" || [ $? -eq 1 ]
      mv "$opt.norm" "$opt"
    done
  '';

  pattern = "^cargo::?rerun-if-changed=";
}
