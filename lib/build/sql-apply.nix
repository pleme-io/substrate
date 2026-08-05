# sql-apply — typed SQL migration runner, exposed as a substrate flake package so
# consumers call `nix run github:pleme-io/substrate#sql-apply` (or drop the binary
# into an image) instead of shipping a shell runner plus a database CLI.
#
# buildRustPackage + committed Cargo.lock, same shape as relver.nix. Every crate
# is from crates.io and the build graph carries NO C dependency: sqlx is
# configured with rustls rather than OpenSSL, and the sqlite driver is not
# enabled. `libsqlite3-sys` does appear in Cargo.lock as an unenabled optional of
# sqlx -- verified absent from the real graph with
# `cargo tree -i libsqlite3-sys` ("nothing to print").
#
# No wrapProgram: unlike relver (which shells to `git`), this binary talks to the
# database over TCP and needs nothing on PATH. That is the whole point -- it is
# what lets a consuming image be distroless.
{ pkgs }:
let
  lib = pkgs.lib;
  src = lib.cleanSourceWith {
    src = ../../tools/sql-apply;
    filter = path: _type:
      let base = baseNameOf path;
      in base != "target";
  };
in
pkgs.rustPlatform.buildRustPackage {
  pname = "sql-apply";
  version = "0.1.0";
  inherit src;
  cargoLock.lockFile = ../../tools/sql-apply/Cargo.lock;
  # The unit tests are pure (statement splitting, error-code classification,
  # sentinel + filename parsing) and run in the sandbox without a database.
  doCheck = true;
  meta = {
    description = "Typed SQL migration runner (wait / wait-tables / apply) — no shell, no database CLI";
    mainProgram = "sql-apply";
  };
}

