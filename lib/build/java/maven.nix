# Java Maven Package Builder
#
# Reusable pattern for building Java packages from Maven-based source.
# Wraps maven.buildMavenPackage with common conventions for external SDKs
# and plugins.
#
# Usage (standalone):
#   javaMavenBuilder = import "${substrate}/lib/java-maven.nix";
#   my-sdk = javaMavenBuilder.mkJavaMavenPackage pkgs {
#     pname = "akeyless-java";
#     version = "4.3.0";
#     src = fetchFromGitHub { ... };
#     mvnHash = "sha256-...";
#   };
#
# Usage (via substrate lib):
#   my-sdk = substrateLib.mkJavaMavenPackage { ... };
{
  # Build a Java package from Maven-based source.
  #
  # Required attrs:
  #   pname       — package name
  #   version     — version string
  #   src         — source derivation
  #   mvnHash     — hash of Maven dependency closure
  #
  # Optional attrs:
  #   jdk             — JDK package (default: pkgs.jdk17)
  #   mvnParameters   — extra Maven CLI parameters (default: "-DskipTests")
  #   mvnFetchExtraArgs — extra args for dependency fetch phase
  #   buildOffline    — build in offline mode after fetching deps (default: true)
  #   installPhase    — custom install phase script
  #   outputJar       — relative path to output JAR (auto-detected if null)
  #   doCheck         — run tests (default: false for external packages)
  #   extraAttrs      — additional attrs passed to buildMavenPackage
  #   description     — package description
  #   homepage        — package homepage URL
  #   license         — license (default: lib.licenses.asl20)
  mkJavaMavenPackage = pkgs: {
    pname,
    version,
    src,
    mvnHash,
    jdk ? pkgs.jdk17,
    mvnParameters ? "-DskipTests",
    mvnFetchExtraArgs ? {},
    buildOffline ? true,
    installPhase ? null,
    outputJar ? null,
    doCheck ? false,
    extraAttrs ? {},
    description ? "${pname} - Java package",
    homepage ? null,
    license ? pkgs.lib.licenses.asl20,
    platforms ? pkgs.lib.platforms.all,
  }: let
    check = import ../../types/assertions.nix;
    _ = check.all [
      (check.nonEmptyStr "pname" pname)
      (check.nonEmptyStr "version" version)
      (check.str "mvnParameters" mvnParameters)
      (check.bool "buildOffline" buildOffline)
      (check.bool "doCheck" doCheck)
    ];
    lib = pkgs.lib;

    defaultInstallPhase = ''
      runHook preInstall
      jarPath="${if outputJar != null then outputJar else "target/${pname}-${version}.jar"}"
      if [ -f "$jarPath" ]; then
        install -Dm644 "$jarPath" "$out/share/java/${pname}.jar"
      else
        # Fallback: install all JARs from target/
        echo "Primary JAR not found at $jarPath, falling back to target/*.jar"
        find target -maxdepth 1 -name "*.jar" -not -name "*-sources.jar" -not -name "*-javadoc.jar" \
          -exec install -Dm644 {} "$out/share/java/" \;
      fi
      runHook postInstall
    '';
  in pkgs.maven.buildMavenPackage ({
    inherit pname version src mvnHash;
    inherit buildOffline doCheck;
    inherit mvnParameters;

    nativeBuildInputs = [ jdk ];

    installPhase = if installPhase != null then installPhase else defaultInstallPhase;

    meta = {
      inherit description license platforms;
    } // lib.optionalAttrs (homepage != null) { inherit homepage; };
  }
  // lib.optionalAttrs (mvnFetchExtraArgs != {}) { inherit mvnFetchExtraArgs; }
  // extraAttrs);

  # Create an overlay of Java Maven packages from a definitions attrset.
  mkJavaMavenPackageOverlay = pkgDefs: final: prev: let
    mkJavaMavenPackage' = (import ./maven.nix).mkJavaMavenPackage;
  in builtins.mapAttrs
    (name: def: mkJavaMavenPackage' final def)
    pkgDefs;
}
