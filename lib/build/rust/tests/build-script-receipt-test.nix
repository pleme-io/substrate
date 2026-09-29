# Runs lib/build/rust/build-script-receipt.nix's postInstall fragment against a
# fixture `$lib/lib/*.opt` and compares the result byte-for-byte.
#
# NOT VACUOUS: the fixture carries both spellings of rerun-if-changed (`cargo:`
# and `cargo::`) with build-dir paths, and every line that must survive. A
# fragment that stopped filtering leaves a path behind; one that filtered too
# much drops a `rustc-*` directive; one that let grep's "no lines" status fail
# the build breaks the all-filtered file.
{ }:
let
  receipt = import ../build-script-receipt.nix;
in
{
  asCheck = pkgs: pkgs.runCommand "rust-build-script-receipt" { } ''
    lib=$PWD/fake-lib
    mkdir -p "$lib/lib"
    printf '%s\n' \
      'cargo:rerun-if-changed=/nix/var/nix/builds/nix-1-2/src/proto' \
      'cargo:rustc-cfg=has_foo' \
      'cargo::rerun-if-changed=/nix/var/nix/builds/nix-3-4/build.rs' \
      'cargo:rerun-if-env-changed=PROTOC' \
      'cargo:rustc-link-lib=z' \
      'cargo:warning=kept' > "$lib/lib/mixed.opt"
    printf '%s\n' 'cargo:rerun-if-changed=/nix/var/nix/builds/nix-5-6/x' > "$lib/lib/only.opt"

    ${receipt.postInstall}

    printf '%s\n' \
      'cargo:rustc-cfg=has_foo' \
      'cargo:rerun-if-env-changed=PROTOC' \
      'cargo:rustc-link-lib=z' \
      'cargo:warning=kept' > expected
    cmp expected "$lib/lib/mixed.opt"
    [ ! -s "$lib/lib/only.opt" ]
    [ ! -e "$lib/lib/mixed.opt.norm" ]
    touch $out
  '';
}
