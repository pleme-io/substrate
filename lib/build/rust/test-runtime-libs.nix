# test-runtime-libs — the native libraries a cargo-built test binary can
# link inside a dev shell, with the loader path that lets the binary RUN,
# not only build.
#
# The class (measured 2026-11-26): sui's auto-release Test gate built its
# tests green and then could not execute them — `liblzma.so.5: cannot open
# shared object file` (run 45892858314) — because a nix dev shell puts a
# library where pkg-config and the LINKER find it, but never on the dynamic
# loader's path. cracha hit the build-time half of the same class (no
# `protoc` in the shell). A dev shell that can build a binary it cannot run
# is a trap: every workspace that links a native crate reds its gate the
# day a test touches it.
#
# Consumers compose, they do not restate:
#   rt = import ./test-runtime-libs.nix { inherit pkgs; };
#   pkgs.mkShell { buildInputs = rt.libs; env.LD_LIBRARY_PATH = rt.path; }
# or, where an inherited LD_LIBRARY_PATH must survive:
#   shellHook = rt.prependHook;
{ pkgs }:
let
  inherit (pkgs) lib;
  libs = with pkgs; [
    xz
    zstd
    openssl
    sqlite
    protobuf
  ];
  path = lib.makeLibraryPath libs;
in {
  inherit libs path;
  prependHook = ''
    export LD_LIBRARY_PATH="${path}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  '';
}
