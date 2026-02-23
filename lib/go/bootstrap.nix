# Go bootstrap binary — fetched from go.dev
#
# Used as the bootstrap compiler to build Go from source.
# This is the only prebuilt binary in the chain.
{ lib, stdenv, fetchurl }:

let
  version = "1.24.11";

  hashes = {
    darwin-amd64 = "c45566cf265e2083cd0324e88648a9c28d0edede7b5fd12f8dc6932155a344c5";
    darwin-arm64 = "a9c90c786e75d5d1da0547de2d1199034df6a4b163af2fa91b9168c65f229c12";
    linux-386 = "bb702d0b67759724dccee1825828e8bae0b5199e3295cac5a98a81f3098fa64a";
    linux-amd64 = "bceca00afaac856bc48b4cc33db7cd9eb383c81811379faed3bdbc80edb0af65";
    linux-arm64 = "beaf0f51cbe0bd71b8289b2b6fa96c0b11cd86aa58672691ef2f1de88eb621de";
    linux-armv6l = "24d712a7e8ea2f429c05bc67287249e0291f2fe0ea6d6ff268f11b7343ad0f47";
  };

  platform = with stdenv.hostPlatform.go;
    "${GOOS}-${if GOARCH == "arm" then "armv6l" else GOARCH}";
in
stdenv.mkDerivation {
  name = "go-${version}-${platform}-bootstrap";

  src = fetchurl {
    url = "https://go.dev/dl/go${version}.${platform}.tar.gz";
    sha256 = hashes.${platform} or (throw "Missing Go bootstrap hash for platform ${platform}");
  };

  dontStrip = stdenv.hostPlatform.isDarwin;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/go $out/bin
    cp -r . $out/share/go
    ln -s $out/share/go/bin/go $out/bin/go
    runHook postInstall
  '';

  meta = {
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    description = "Go bootstrap compiler (prebuilt binary from go.dev)";
    homepage = "https://go.dev/";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
  };
}
