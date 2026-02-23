# Zig prebuilt binary — fetched from ziglang.org
#
# Used as the compiler to build zls from source.
# This is the only prebuilt binary in the chain.
{ lib, stdenv, fetchurl }:

let
  version = "0.15.2";

  hashes = {
    x86_64-linux = "02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239";
    aarch64-linux = "958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f";
    x86_64-darwin = "375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f";
    aarch64-darwin = "3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b";
  };

  # Map Nix system to Zig platform naming
  zigPlatform = {
    x86_64-linux = "x86_64-linux";
    aarch64-linux = "aarch64-linux";
    x86_64-darwin = "x86_64-macos";
    aarch64-darwin = "aarch64-macos";
  }.${stdenv.hostPlatform.system} or (throw "Unsupported platform: ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "zig";
  inherit version;

  src = fetchurl {
    url = "https://ziglang.org/download/${version}/zig-${zigPlatform}-${version}.tar.xz";
    sha256 = hashes.${stdenv.hostPlatform.system}
      or (throw "Missing Zig hash for platform ${stdenv.hostPlatform.system}");
  };

  dontBuild = true;
  dontFixup = stdenv.hostPlatform.isDarwin;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/lib
    cp -r lib/* $out/lib/
    cp -r doc $out/doc || true
    install -Dm755 zig $out/bin/zig
    runHook postInstall
  '';

  meta = {
    description = "Zig compiler (prebuilt binary from ziglang.org)";
    homepage = "https://ziglang.org/";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    mainProgram = "zig";
  };
}
