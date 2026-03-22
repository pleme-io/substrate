# Devenv module for Android development.
#
# Provides: Android SDK (via androidenv), ADB, Gradle, Kotlin,
# ANDROID_HOME/ANDROID_SDK_ROOT env vars, optional NDK/emulator/Flutter.
#
# Usage (in a devenv shell definition):
#   imports = [ "${substrate}/lib/devenv/android.nix" ];
#
# With customization:
#   imports = [ "${substrate}/lib/devenv/android.nix" ];
#   android.platformVersions = [ "34" "35" ];
#   android.includeNDK = true;
#   android.flutter.enable = true;
{ pkgs, lib, config, ... }:
let
  cfg = config.android;
  androidComposition = pkgs.androidenv.composeAndroidPackages {
    platformVersions = cfg.platformVersions;
    buildToolsVersions = cfg.buildToolsVersions;
    includeNDK = cfg.includeNDK;
    ndkVersions = cfg.ndkVersions;
    includeCmake = cfg.includeCmake;
    cmakeVersions = cfg.cmakeVersions;
    includeEmulator = cfg.includeEmulator;
    includeSystemImages = cfg.includeSystemImages;
    systemImageTypes = cfg.systemImageTypes;
    abiVersions = cfg.abiVersions;
    useGoogleAPIs = cfg.useGoogleAPIs;
    includeSources = cfg.includeSources;
    extraLicenses = cfg.extraLicenses;
  };
  sdkPath = "${androidComposition.androidsdk}/libexec/android-sdk";
in {
  options.android = {
    platformVersions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "34" "35" ];
      description = "Android platform API versions";
    };
    buildToolsVersions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "34.0.0" ];
      description = "Build tools versions";
    };
    includeNDK = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Include Android NDK";
    };
    ndkVersions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "26.1.10909125" ];
    };
    includeCmake = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    cmakeVersions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "3.22.1" ];
    };
    includeEmulator = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    includeSystemImages = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    systemImageTypes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "google_apis" ];
    };
    abiVersions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "arm64-v8a" "x86_64" ];
    };
    useGoogleAPIs = lib.mkOption {
      type = lib.types.bool;
      default = true;
    };
    includeSources = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    extraLicenses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "android-sdk-license"
        "android-sdk-preview-license"
        "android-googletv-license"
        "android-sdk-arm-dbt-license"
        "google-gdk-license"
        "intel-android-extra-license"
        "intel-android-sysimage-license"
        "mips-android-sysimage-license"
      ];
    };
    flutter = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Include Flutter SDK";
      };
    };
  };

  config = {
    packages = with pkgs; [
      androidComposition.androidsdk
      android-tools
      gradle
      kotlin
    ] ++ lib.optional cfg.flutter.enable pkgs.flutter;

    env = {
      ANDROID_HOME = sdkPath;
      ANDROID_SDK_ROOT = sdkPath;
      GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${sdkPath}/build-tools/${builtins.head cfg.buildToolsVersions}/aapt2";
    };
  };
}
