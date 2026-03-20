# Go toolchain — built from upstream source
#
# Downloads Go source from go.dev and compiles with the bootstrap binary.
# Applies NixOS-compatibility patches for finding system databases
# (timezone, MIME types, network databases) from the Nix store.
#
# This is the single source of truth for Go versions in the pleme-io stack.
{
  lib,
  stdenv,
  fetchurl,
  replaceVars,
  buildPackages,
  pkgsBuildTarget,
  targetPackages,
  iana-etc,
  mailcap,
  tzdata,
}:

let
  goBootstrap = buildPackages.callPackage ./bootstrap.nix {};

  targetCC = pkgsBuildTarget.targetPackages.stdenv.cc;
  isCross = stdenv.buildPlatform != stdenv.targetPlatform;
in
stdenv.mkDerivation (finalAttrs: {
  pname = "go";
  version = "1.25.6";

  src = fetchurl {
    url = "https://go.dev/dl/go${finalAttrs.version}.src.tar.gz";
    hash = "sha256-WMv3ceRNdt5vVtGeM7d9dFoeSJNAkih15GWFuXXCsFk=";
  };

  strictDeps = true;
  buildInputs =
    []
    ++ lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.libc.out ]
    ++ lib.optionals (stdenv.hostPlatform.libc == "glibc") [ stdenv.cc.libc.static ];

  depsBuildTarget = lib.optional isCross targetCC;
  depsTargetTarget = lib.optional stdenv.targetPlatform.isMinGW targetPackages.threads.package;

  postPatch = ''
    patchShebangs .
  '';

  patches = [
    (replaceVars ./patches/iana-etc-1.25.patch { iana = iana-etc; })
    (replaceVars ./patches/mailcap-1.17.patch { inherit mailcap; })
    (replaceVars ./patches/tzdata-1.19.patch { inherit tzdata; })
    ./patches/remove-tools-1.11.patch
    ./patches/go_no_vendor_checks-1.23.patch
    ./patches/go-env-go_ldso.patch
  ];

  env = {
    inherit (stdenv.targetPlatform.go) GOOS GOARCH GOARM;
    GOHOSTOS = stdenv.buildPlatform.go.GOOS;
    GOHOSTARCH = stdenv.buildPlatform.go.GOARCH;
    GO386 = "softfloat";
    CGO_ENABLED =
      if (stdenv.targetPlatform.isWasi
          || (stdenv.targetPlatform.isPower64 && stdenv.targetPlatform.isBigEndian))
      then 0
      else 1;
    GOROOT_BOOTSTRAP = "${goBootstrap}/share/go";
  }
  // lib.optionalAttrs isCross {
    CC_FOR_TARGET = "${targetCC}/bin/${targetCC.targetPrefix}cc";
    CXX_FOR_TARGET = "${targetCC}/bin/${targetCC.targetPrefix}c++";
  };

  buildPhase = ''
    runHook preBuild
    export GOCACHE=$TMPDIR/go-cache
    if [ -f "$NIX_CC/nix-support/dynamic-linker" ]; then
      export GO_LDSO=$(cat $NIX_CC/nix-support/dynamic-linker)
    fi

    export PATH=$(pwd)/bin:$PATH

    ${lib.optionalString isCross ''
      export CC=${buildPackages.stdenv.cc}/bin/cc
      export GO_EXTLINK_ENABLED=${toString finalAttrs.env.CGO_ENABLED}
    ''}
    ulimit -a

    pushd src
    ./make.bash
    popd
    runHook postBuild
  '';

  preInstall = ''
    rm src/regexp/syntax/make_perl_groups.pl
  ''
  + (
    if (stdenv.buildPlatform.system != stdenv.hostPlatform.system) then
      ''
        mv bin/*_*/* bin
        rmdir bin/*_*
        ${lib.optionalString
          (!(finalAttrs.env.GOHOSTARCH == finalAttrs.env.GOARCH
             && finalAttrs.env.GOOS == finalAttrs.env.GOHOSTOS))
          ''
            rm -rf pkg/${finalAttrs.env.GOHOSTOS}_${finalAttrs.env.GOHOSTARCH} pkg/tool/${finalAttrs.env.GOHOSTOS}_${finalAttrs.env.GOHOSTARCH}
          ''
        }
      ''
    else
      lib.optionalString (stdenv.hostPlatform.system != stdenv.targetPlatform.system) ''
        rm -rf bin/*_*
        ${lib.optionalString
          (!(finalAttrs.env.GOHOSTARCH == finalAttrs.env.GOARCH
             && finalAttrs.env.GOOS == finalAttrs.env.GOHOSTOS))
          ''
            rm -rf pkg/${finalAttrs.env.GOOS}_${finalAttrs.env.GOARCH} pkg/tool/${finalAttrs.env.GOOS}_${finalAttrs.env.GOARCH}
          ''
        }
      ''
  );

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/go
    cp -a bin pkg src lib misc api doc go.env VERSION $out/share/go
    mkdir -p $out/bin
    ln -s $out/share/go/bin/* $out/bin
    runHook postInstall
  '';

  disallowedReferences = [ goBootstrap ];

  passthru = {
    inherit goBootstrap;
  };

  __structuredAttrs = true;

  meta = {
    changelog = "https://go.dev/doc/devel/release#go${lib.versions.majorMinor finalAttrs.version}";
    description = "Go programming language (built from source)";
    homepage = "https://go.dev/";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
    mainProgram = "go";
  };
})
