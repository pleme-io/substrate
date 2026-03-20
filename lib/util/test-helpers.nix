# Pure Nix evaluation test helpers
#
# Reusable test infrastructure for NixOS and home-manager modules.
# Tests run as pure Nix evaluation — no VMs, no builds, instant results.
#
# Usage (standalone, in test file):
#   let testHelpers = import "${substrate}/lib/test-helpers.nix" { lib = nixpkgs.lib; };
#   in testHelpers.runTests [
#     (testHelpers.mkTest "my-test"
#       (1 + 1 == 2)
#       "basic math should work")
#   ]
#
# Usage (NixOS module evaluation):
#   let
#     testHelpers = import "${substrate}/lib/test-helpers.nix" { lib = nixpkgs.lib; };
#     result = testHelpers.evalNixOSModule {
#       module = import ./module/nixos/my-service { inherit nixosHelpers; };
#       config = { enable = true; port = 8080; };
#       configPath = ["services" "blackmatter" "my-service"];
#     };
#   in testHelpers.mkTest "option-exists"
#     (result.options ? services)
#     "services option should exist"
{ lib }:

with lib;

rec {
  # ─── Test case builder ──────────────────────────────────────────────
  # Creates a test case with a name, boolean assertion, and failure message.
  #
  # Example:
  #   mkTest "addition-works" (1 + 1 == 2) "1 + 1 should equal 2"
  mkTest = name: assertion: message: {
    inherit name message;
    passed = assertion;
  };

  # ─── Test runner ────────────────────────────────────────────────────
  # Takes a list of test cases (from mkTest) and produces a summary.
  #
  # Returns:
  #   { total, passCount, failCount, allPassed, failures, summary }
  #
  # Use in flake.nix:
  #   tests.unit = testHelpers.runTests [ ... ];
  #   # nix eval .#tests.x86_64-linux.unit
  runTests = tests: let
    passed = filter (t: t.passed) tests;
    failed = filter (t: !t.passed) tests;
  in {
    total = length tests;
    passCount = length passed;
    failCount = length failed;
    allPassed = failed == [];
    failures = map (t: "${t.name}: ${t.message}") failed;
    summary = "${toString (length passed)}/${toString (length tests)} passed";
  };

  # ─── NixOS module stubs ────────────────────────────────────────────
  # Generates a stub module with all common NixOS system options.
  # Use with lib.evalModules to test NixOS modules in isolation without
  # a full NixOS evaluation.
  #
  # Covers: systemd, networking, boot, environment, users, assertions,
  # and system activation scripts.
  #
  # Example:
  #   lib.evalModules {
  #     modules = [
  #       myModule
  #       (testHelpers.mkNixOSModuleStubs {})
  #     ];
  #   }
  mkNixOSModuleStubs = {
    extraOptions ? {},
  }: {
    options = {
      # Systemd
      systemd.services = mkOption { type = types.attrs; default = {}; };
      systemd.tmpfiles.rules = mkOption { type = types.listOf types.str; default = []; };

      # Networking
      networking.firewall = mkOption { type = types.attrs; default = {}; };

      # Boot
      boot.kernelModules = mkOption { type = types.listOf types.str; default = []; };
      boot.kernel.sysctl = mkOption { type = types.attrs; default = {}; };

      # Environment
      environment.systemPackages = mkOption { type = types.listOf types.package; default = []; };
      environment.etc = mkOption { type = types.attrs; default = {}; };
      environment.shellAliases = mkOption { type = types.attrs; default = {}; };

      # System
      system.activationScripts = mkOption { type = types.attrs; default = {}; };
      assertions = mkOption { type = types.listOf types.attrs; default = []; };

      # Users
      users.users = mkOption { type = types.attrs; default = {}; };
      users.groups = mkOption { type = types.attrs; default = {}; };
    } // extraOptions;
  };

  # ─── NixOS module evaluator ────────────────────────────────────────
  # Evaluates a NixOS module in isolation with stubs. Returns the full
  # evaluation result (access .config for config, .options for options).
  #
  # Use lazy evaluation: don't force config paths that reference actual
  # packages (guarded by mkIf cfg.enable). Only check option existence
  # and default values.
  #
  # Example:
  #   let result = testHelpers.evalNixOSModule {
  #     module = import ./module/nixos/k3s { inherit nixosHelpers; };
  #     config = { distribution = "1.35"; };
  #     configPath = ["services" "blackmatter" "k3s"];
  #   };
  #   in result.config.services.blackmatter.k3s.distribution == "1.35"
  evalNixOSModule = {
    module,
    config ? {},
    configPath ? [],
    extraStubs ? {},
  }: evalModules {
    modules = [
      module
      (if configPath != []
       then { config = setAttrByPath configPath config; }
       else { inherit config; })
      (mkNixOSModuleStubs { extraOptions = extraStubs; })
    ];
  };

  # ─── Profile evaluation check ──────────────────────────────────────
  # Verifies that every profile in a set evaluates successfully with
  # a given NixOS module. Returns a derivation suitable for
  # checks.<system>.<name>.
  #
  # Example:
  #   checks.x86_64-linux.profile-eval = testHelpers.mkProfileEvalCheck {
  #     pkgs = pkgs;
  #     name = "k3s-profile-eval";
  #     module = k3sModule;
  #     profiles = profileDefs.profiles;
  #     configPath = ["services" "blackmatter" "k3s"];
  #     mkConfig = profileName: { enable = false; profile = profileName; };
  #   };
  mkProfileEvalCheck = {
    pkgs,
    name,
    module,
    profiles,
    configPath,
    mkConfig,
    extraStubs ? {},
  }: let
    evalProfile = profileName: let
      result = evalNixOSModule {
        inherit module configPath extraStubs;
        config = mkConfig profileName;
      };
    in (getAttrFromPath configPath result.config).profile == profileName;
    profileNames = attrNames profiles;
    allPass = all (name: evalProfile name) profileNames;
  in pkgs.runCommand name {} (
    if allPass
    then "echo 'All ${toString (length profileNames)} profiles evaluate successfully' > $out"
    else builtins.throw "${name}: profile evaluation failed"
  );
}
