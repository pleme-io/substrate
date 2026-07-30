# Go bootstrap binary — fetched from go.dev
#
# Used as the bootstrap compiler to build Go from source. This is the only
# prebuilt binary in the chain, and toolchain.nix `disallowedReferences` it out
# of the result, so it is a build-time input that cannot reach a shipped
# artifact. That is why its own CVE status gates nothing: nothing links it.
#
# The version + per-platform sha256 table is NOT here — it lives in
# go-toolchain-pin.json, alongside the from-source version, so one file is the
# whole answer to "which Go does the fleet build with". That shape is the
# literal structural mirror of fenix's data/stable.json + fetchurl: a committed
# transcription of upstream's own published hashes, never a resolution at eval.
{ lib, stdenv, fetchurl,
  # The pin, overridable for the same reason toolchain.nix's is: reproducing an
  # older artifact byte-for-byte. Defaults to the committed fleet pin.
  pin ? builtins.fromJSON (builtins.readFile ./go-toolchain-pin.json),
}:

let
  version = pin.bootstrap.version;
  hashes = pin.bootstrap.hashes;

  platform = with stdenv.hostPlatform.go;
    "${GOOS}-${if GOARCH == "arm" then "armv6l" else GOARCH}";
in
stdenv.mkDerivation {
  name = "go-${version}-${platform}-bootstrap";

  src = fetchurl {
    url = "https://go.dev/dl/go${version}.${platform}.tar.gz";
    sha256 = hashes.${platform} or (throw ''
      go-toolchain-pin.json carries no Go bootstrap hash for platform "${platform}".

      Add it under bootstrap.hashes, taking the sha256 from go.dev's own
      published manifest rather than from a local prefetch:

        curl -sS 'https://go.dev/dl/?mode=json&include=all'
    '');
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
