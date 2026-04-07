# Utility Module Tests
#
# Pure Nix evaluation tests for util/ helpers and test-helpers self-tests.
# No builds, no pkgs, instant feedback.
#
# Usage:
#   nix eval --impure --raw --file lib/util/tests.nix --apply 'r: r.summary'
#   nix eval --impure --raw --file lib/util/tests.nix --apply 'r: builtins.toJSON r.allPassed'
let
  lib = (import <nixpkgs> { system = "x86_64-linux"; }).lib;
  testHelpers = import ./test-helpers.nix { inherit lib; };
  versionedOverlay = import ./versioned-overlay.nix;
  dockerHelpers = import ./docker-helpers.nix;

  inherit (testHelpers) mkTest runTests;
in runTests [

  # ════════════════════════════════════════════════════════════════════
  # test-helpers.nix — self-tests (mkTest / runTests)
  # ════════════════════════════════════════════════════════════════════

  (mkTest "self-test-passing"
    (let r = runTests [ (mkTest "pass" true "should pass") ];
    in r.total == 1 && r.passCount == 1 && r.failCount == 0 && r.allPassed)
    "runTests on a passing test should report allPassed=true")

  (mkTest "self-test-failing"
    (let r = runTests [ (mkTest "fail" false "oops") ];
    in r.total == 1 && r.passCount == 0 && r.failCount == 1 && !r.allPassed)
    "runTests on a failing test should report allPassed=false")

  (mkTest "self-test-empty"
    (let r = runTests [];
    in r.total == 0 && r.allPassed && r.failCount == 0)
    "runTests on empty list should pass with zero total")

  (mkTest "self-test-mixed"
    (let r = runTests [
      (mkTest "a" true "a")
      (mkTest "b" false "b")
      (mkTest "c" true "c")
    ];
    in r.total == 3 && r.passCount == 2 && r.failCount == 1 && !r.allPassed)
    "runTests on mixed results should count correctly")

  (mkTest "self-test-summary-format"
    (let r = runTests [ (mkTest "a" true "a") (mkTest "b" true "b") ];
    in r.summary == "2/2 passed")
    "runTests summary should be '{pass}/{total} passed' format")

  (mkTest "self-test-failures-list"
    (let r = runTests [
      (mkTest "good" true "ok")
      (mkTest "bad1" false "first fail")
      (mkTest "bad2" false "second fail")
    ];
    in builtins.length r.failures == 2
      && builtins.head r.failures == "bad1: first fail")
    "runTests failures should list 'name: message' for each failed test")

  (mkTest "mkTest-structure"
    (let t = mkTest "my-test" true "my msg";
    in t.name == "my-test" && t.passed && t.message == "my msg")
    "mkTest should produce { name, passed, message } attrset")

  # ════════════════════════════════════════════════════════════════════
  # test-helpers.nix — mkNixOSModuleStubs
  # ════════════════════════════════════════════════════════════════════

  (let stubs = testHelpers.mkNixOSModuleStubs {};
  in mkTest "stubs-systemd"
    (stubs.options ? systemd && stubs.options.systemd ? services)
    "stubs should declare systemd.services option")

  (let stubs = testHelpers.mkNixOSModuleStubs {};
  in mkTest "stubs-networking"
    (stubs.options ? networking && stubs.options.networking ? firewall)
    "stubs should declare networking.firewall option")

  (let stubs = testHelpers.mkNixOSModuleStubs {};
  in mkTest "stubs-users"
    (stubs.options ? users && stubs.options.users ? users && stubs.options.users ? groups)
    "stubs should declare users.users and users.groups options")

  (let stubs = testHelpers.mkNixOSModuleStubs {};
  in mkTest "stubs-assertions"
    (stubs.options ? assertions)
    "stubs should declare assertions option")

  (let stubs = testHelpers.mkNixOSModuleStubs {};
  in mkTest "stubs-environment"
    (stubs.options ? environment
      && stubs.options.environment ? systemPackages
      && stubs.options.environment ? etc
      && stubs.options.environment ? shellAliases)
    "stubs should declare environment.systemPackages, etc, shellAliases")

  (let stubs = testHelpers.mkNixOSModuleStubs {
    extraOptions = { custom.option = lib.mkOption { type = lib.types.str; default = "x"; }; };
  };
  in mkTest "stubs-extra-options"
    (stubs.options ? custom && stubs.options.custom ? option)
    "stubs should merge extraOptions into options")

  # ════════════════════════════════════════════════════════════════════
  # versioned-overlay.nix — mkVersionedOverlay
  # ════════════════════════════════════════════════════════════════════

  (let
    fakeSrc = {
      kubelet_1_34 = "kubelet-1.34-bin";
      kubelet_1_35 = "kubelet-1.35-bin";
      etcd_1_34 = "etcd-1.34-bin";
      etcd_1_35 = "etcd-1.35-bin";
    };
    entries = versionedOverlay.mkVersionedOverlay {
      inherit lib;
      tracks = [ "1.34" "1.35" ];
      defaultTrack = "1.34";
      latestTrack = "1.35";
      components = {
        kubelet = { src = fakeSrc; };
        etcd = { src = fakeSrc; };
      };
    };
  in mkTest "versioned-overlay-versioned-entries"
    (entries."blackmatter-kubelet-1-34" == "kubelet-1.34-bin"
      && entries."blackmatter-kubelet-1-35" == "kubelet-1.35-bin"
      && entries."blackmatter-etcd-1-34" == "etcd-1.34-bin"
      && entries."blackmatter-etcd-1-35" == "etcd-1.35-bin")
    "versioned entries should use dash-separated track in key and underscore in source attr")

  (let
    fakeSrc = { kubelet_1_34 = "k-1.34"; kubelet_1_35 = "k-1.35"; };
    entries = versionedOverlay.mkVersionedOverlay {
      inherit lib;
      tracks = [ "1.34" "1.35" ];
      defaultTrack = "1.34";
      latestTrack = "1.35";
      components = { kubelet = { src = fakeSrc; }; };
    };
  in mkTest "versioned-overlay-default-alias"
    (entries."blackmatter-kubelet" == "k-1.34")
    "default alias should point to defaultTrack")

  (let
    fakeSrc = { kubelet_1_34 = "k-1.34"; kubelet_1_35 = "k-1.35"; };
    entries = versionedOverlay.mkVersionedOverlay {
      inherit lib;
      tracks = [ "1.34" "1.35" ];
      defaultTrack = "1.34";
      latestTrack = "1.35";
      components = { kubelet = { src = fakeSrc; }; };
    };
  in mkTest "versioned-overlay-latest-alias"
    (entries."blackmatter-kubelet-latest" == "k-1.35")
    "latest alias should point to latestTrack")

  (let
    fakeSrc = { "etcd-server_1_34" = "etcd-bin"; };
    entries = versionedOverlay.mkVersionedOverlay {
      inherit lib;
      tracks = [ "1.34" ];
      defaultTrack = "1.34";
      latestTrack = "1.34";
      components = { etcd = { src = fakeSrc; overlayName = "etcd-server"; srcAttr = suffix: "etcd-server_${suffix}"; }; };
    };
  in mkTest "versioned-overlay-custom-names"
    (entries ? "blackmatter-etcd-server-1-34"
      && entries."blackmatter-etcd-server-1-34" == "etcd-bin"
      && entries ? "blackmatter-etcd-server"
      && entries ? "blackmatter-etcd-server-latest")
    "overlayName and srcAttr should override default naming conventions")

  (let
    fakeSrc = { k_1_30 = "a"; k_1_31 = "b"; k_1_32 = "c"; };
    entries = versionedOverlay.mkVersionedOverlay {
      inherit lib;
      tracks = [ "1.30" "1.31" "1.32" ];
      prefix = "my-";
      defaultTrack = "1.31";
      latestTrack = "1.32";
      components = { k = { src = fakeSrc; }; };
    };
  in mkTest "versioned-overlay-custom-prefix"
    (entries ? "my-k-1-30" && entries ? "my-k-1-31" && entries ? "my-k-1-32"
      && entries ? "my-k" && entries ? "my-k-latest"
      && !(entries ? "blackmatter-k-1-30"))
    "custom prefix should replace default blackmatter- prefix")

  (let
    fakeSrc = { a_1_0 = "x"; };
    entries = versionedOverlay.mkVersionedOverlay {
      inherit lib;
      tracks = [ "1.0" ];
      defaultTrack = "1.0";
      latestTrack = "1.0";
      components = { a = { src = fakeSrc; }; };
    };
  in mkTest "versioned-overlay-single-track"
    (entries."blackmatter-a-1-0" == "x"
      && entries."blackmatter-a" == "x"
      && entries."blackmatter-a-latest" == "x")
    "single track should produce versioned + default + latest all pointing to same value")

  # ════════════════════════════════════════════════════════════════════
  # docker-helpers.nix — pure string builders
  # ════════════════════════════════════════════════════════════════════

  (mkTest "docker-web-user-setup"
    (builtins.match ".*web:x:101:101.*" dockerHelpers.mkWebUserSetup != null
      && builtins.match ".*root:x:0:0.*" dockerHelpers.mkWebUserSetup != null)
    "mkWebUserSetup should create web (101:101) and root users")

  (mkTest "docker-app-user-setup"
    (builtins.match ".*app:x:1000:1000.*" dockerHelpers.mkAppUserSetup != null)
    "mkAppUserSetup should create app (1000:1000) user")

  (mkTest "docker-tmp-dirs"
    (builtins.match ".*mkdir -p var/log run tmp.*" dockerHelpers.mkTmpDirs != null
      && builtins.match ".*chmod -R 777.*" dockerHelpers.mkTmpDirs != null)
    "mkTmpDirs should create and chmod temp directories")

]
