# relver — typed release-version primitive, exposed as a substrate flake
# package so auto-bump workflows call `nix run github:pleme-io/substrate#relver`
# instead of inline semver/tag bash.
#
# buildRustPackage + committed Cargo.lock (clap + thiserror, all crates.io —
# no git deps, no C deps). `git` is wrapped onto PATH so `nix run` works
# hermetically outside CI too (CI runners already have git).
{ pkgs }:
let
  lib = pkgs.lib;
  src = lib.cleanSourceWith {
    src = ../../tools/relver;
    filter = path: _type:
      let base = baseNameOf path;
      in base != "target";
  };
in
pkgs.rustPlatform.buildRustPackage {
  pname = "relver";
  version = "0.1.0";
  inherit src;
  cargoLock.lockFile = ../../tools/relver/Cargo.lock;
  nativeBuildInputs = [ pkgs.makeWrapper ];
  # The integration tests shell out to real git in a tempdir — proven via
  # `cargo test` + CI; skipped in the nix sandbox build (which has no git
  # identity / restricted env) to keep the package build hermetic + fast.
  doCheck = false;
  postInstall = ''
    wrapProgram $out/bin/relver \
      --prefix PATH : ${lib.makeBinPath [ pkgs.git ]}
  '';
  meta = {
    description = "Typed release-version primitive (semver / changed-since-tag / idempotent tag)";
    mainProgram = "relver";
  };
}
