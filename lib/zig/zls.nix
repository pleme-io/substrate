# zls — built from source with Zig
#
# Builds the Zig Language Server from the official source tarball
# using our prebuilt Zig compiler. Dependencies are pre-fetched
# via deps.nix (zon2nix pattern).
{ lib, stdenvNoCC, fetchzip, callPackage }:

let
  zig = callPackage ./bootstrap.nix {};
  deps = callPackage ./deps.nix {};

  # Map Nix system to Zig target triple
  zigTarget = {
    x86_64-linux = "x86_64-linux";
    aarch64-linux = "aarch64-linux";
    x86_64-darwin = "x86_64-macos";
    aarch64-darwin = "aarch64-macos";
  }.${stdenvNoCC.hostPlatform.system}
    or (throw "Unsupported platform: ${stdenvNoCC.hostPlatform.system}");
in
stdenvNoCC.mkDerivation {
  pname = "zls";
  version = "0.15.1";

  src = fetchzip {
    url = "https://github.com/zigtools/zls/archive/refs/tags/0.15.1.tar.gz";
    hash = "sha256-6IkRtQkn+qUHDz00QvCV/rb2yuF6xWEXug41CD8LLw8=";
  };

  nativeBuildInputs = [ zig ];

  dontInstall = true;

  configurePhase = ''
    export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/.zig-cache
  '';

  buildPhase = ''
    zig build install \
      --system ${deps} \
      -Dtarget=${zigTarget} \
      -Doptimize=ReleaseSafe \
      --color off \
      --prefix $out
  '';

  meta = {
    description = "Zig Language Server (built from source)";
    homepage = "https://github.com/zigtools/zls";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    mainProgram = "zls";
  };
}
