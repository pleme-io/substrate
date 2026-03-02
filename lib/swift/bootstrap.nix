# Swift prebuilt toolchain — fetched from swift.org
#
# Extracts the universal .pkg with xar + cpio (no Apple installer needed).
# Installs the Xcode toolchain layout: usr/bin/swift, usr/lib/swift, etc.
{ lib, stdenvNoCC, fetchurl, xar, cpio, makeWrapper }:

let
  version = "6.2.4";

  # Swift distributes a single universal .pkg for macOS (arm64 + x86_64)
  src = fetchurl {
    url = "https://download.swift.org/swift-${version}-release/xcode/swift-${version}-RELEASE/swift-${version}-RELEASE-osx.pkg";
    hash = "sha256-nJRjf9qDEpAaCOVyplHDoYpnJomthn+WySV7Q3dRWek=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "swift-toolchain";
  inherit version src;

  nativeBuildInputs = [ xar cpio makeWrapper ];

  dontUnpack = true;
  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    # Extract the .pkg (xar archive)
    mkdir -p pkg-extract
    xar -xf $src -C pkg-extract

    # Find and extract the payload (CPIO archive, may be gzipped)
    mkdir -p payload-extract
    for payload in pkg-extract/*/Payload; do
      if [ -f "$payload" ]; then
        # Payload may be gzip-compressed CPIO or plain CPIO
        if file "$payload" | grep -q gzip; then
          gunzip -c "$payload" | (cd payload-extract && cpio -id 2>/dev/null)
        else
          (cd payload-extract && cpio -id < "$payload" 2>/dev/null)
        fi
      fi
    done

    # The .pkg payload extracts the toolchain directly:
    #   payload-extract/usr/bin/swift, payload-extract/usr/lib/swift, etc.
    # Some .pkg variants use an .xctoolchain wrapper; handle both layouts.
    toolchain=$(find payload-extract -type d -name "*.xctoolchain" -print -quit)
    if [ -n "$toolchain" ] && [ -d "$toolchain/usr" ]; then
      cp -r "$toolchain/usr" "$out"
    elif [ -d "payload-extract/usr" ]; then
      cp -r payload-extract/usr "$out"
    else
      echo "ERROR: Could not find usr/ tree in extracted payload" >&2
      find payload-extract -maxdepth 3 -type d | head -20
      exit 1
    fi

    # Wrap swift/swiftc with TOOLCHAINS env so they find their own resources
    for bin in swift swiftc; do
      if [ -x "$out/bin/$bin" ]; then
        wrapProgram "$out/bin/$bin" \
          --set SWIFT_TOOLCHAIN_DIR "$out"
      fi
    done

    runHook postInstall
  '';

  meta = {
    description = "Swift compiler toolchain ${version} (prebuilt from swift.org)";
    homepage = "https://www.swift.org/";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-darwin" "aarch64-darwin" ];
    mainProgram = "swift";
  };
}
