# iroha.catalog — CATALOG REFLECTION for the alphabet itself.
#
# Every letter declares itself here; tests/catalog.nix asserts a bijection
# between catalog entries and letter files on disk (a letter without a
# catalog entry — or vice versa — fails `nix flake check`), that the
# dependsOn graph is acyclic over existing letters, and that the maturity
# histogram partitions the catalog. Adding a letter is half-done until its
# entry lands; the catalog IS the doc.
#
# Entry schema (per the ★★ CATALOG REFLECTION directive):
#   file        — letter filename in this directory
#   tier        — "kernel" | "standard" | "extended" (ship order)
#   maturity    — "Working" | "M2Typed" | "M3Typed" | "M4Typed"
#                 | "Informational" (mechanical readiness gate)
#   since       — landing date (YYYY-MM-DD)
#   description — one-line purpose
#   subsumes    — what existing fleet idioms this letter replaces, scoped
#                 honestly (overclaiming is drift)
#   dependsOn   — other letters this one imports (the typed DAG)
#   exports     — names the letter contributes to the iroha attrset
{ lib }:
{
  core = {
    file = "core.nix";
    tier = "kernel";
    maturity = "Working";
    since = "2026-06-12";
    description = "L0 vocabulary: named priority bands, _class tagging, field-type dictionary.";
    subsumes = "module-trio.nix resolveFieldType; the unstated profiles-use-mkDefault convention (now the named role band).";
    dependsOn = [ ];
    exports = [ "prio" "at" "bandOf" "classes" "tag" "fieldType" "mkField" "mkFields" ];
  };

  checks = {
    file = "checks.nix";
    tier = "kernel";
    maturity = "Working";
    since = "2026-06-12";
    description = "Self-hosting proof harness: nix-unit-shaped eval suites, aggregate-before-assert check derivations, module-eval checks with class-rejection assertions. The mkModuleEvalCheck 'evaluates' probe is shallow (module graph + option names); deep value proof is the `asserts` entries' job.";
    subsumes = "nix repo parts/checks.nix hand-rolled mkTest/runTests; substrate util/test-helpers.nix runner; stale nix-test-runner input.";
    dependsOn = [ ];
    exports = [ "mkEvalChecks" "mkSuiteTree" "mkModuleEvalCheck" ];
  };

  option-surface = {
    file = "option-surface.nix";
    tier = "kernel";
    maturity = "Working";
    since = "2026-06-12";
    description = "Generated option skeletons: enable + lazily-resolved package + RFC42 freeform settings with typed field islands; hand-written option blocks above this layer are drift.";
    subsumes = "The hand-typed options.blackmatter.components.* skeleton pattern; module-trio shikumiTypedGroups/configPath/envVar; fleet-app-module tier/extraSettings surface (settings slot — tier env contract pending).";
    dependsOn = [ "core" ];
    exports = [ "mkOptionSurface" ];
  };

  package-module = {
    file = "package-module.nix";
    tier = "kernel";
    maturity = "Working";
    since = "2026-06-12";
    description = "THE package module: one spec emits three class-tagged modules (homeManager/nixos/darwin) + reflection meta — the standardized interface configuration composes over.";
    subsumes = "The DESTINATION for mkModuleTrio, fleet-app-module.nix, and blackmatter-component-flake module emission. Covered today: enable/package/settings surface, user+system daemons, mcp (anvil registration + PATH shim), http user service, platform gates, per-class extension modules. NOT yet covered (mkModuleTrio remains canonical for these): extraPackages-by-overlay-attr quirks, shikumiGateOnEnable, anvilGateOnEnable=false semantics. Promotion per surface as consumers migrate.";
    dependsOn = [ "core" "option-surface" "daemon" "mcp" ];
    exports = [ "mkPackageModule" ];
  };

  daemon = {
    file = "daemon.nix";
    tier = "kernel";
    maturity = "Working";
    since = "2026-06-12";
    description = "One daemon spec, four platform projections: systemd system/user units and launchd daemons/agents from a single typed shape. systemd Exec lines escaped per systemd semantics (toJSON + %%/$$), never shell-escaped.";
    subsumes = "The SIMPLE-DAEMON SUBSET of the four unit-helper dialects (hm/service-helpers, hm/nixos-service-helpers, hm/darwin-service-helpers) — user keep-alive daemons + periodic jobs, the dominant fleet pattern. Root/notify-class power fields (Type=notify, Delegate, KillMode, launchd UserName/ProcessType) flow through the systemdExtra/systemdUserExtra/launchdExtra escape hatches; mkNixOSService/mkLaunchdDaemon remain canonical for k3s-class daemons until those fields are promoted (trigger: third spec'd consumer).";
    dependsOn = [ ];
    exports = [ "mkDaemonUnit" ];
  };

  overlay = {
    file = "overlay.nix";
    tier = "kernel";
    maturity = "Working";
    since = "2026-06-12";
    description = "Overlay algebra: input re-export, fix catalog (typed reasons, no boolean soup; raw arm for list-append/nested-tree fixes), unstable pins, layer/composite composition with provenance registry. composeManyExtensions semantics — NOT parity with the nix repo's legacy mkComposed fold (see header).";
    subsumes = "~30 one-file-per-input overlays/*.nix in the nix repo; overlays/default.nix's boolean-flag pattern + single-package overrideAttrs fixes (raw arm carries the pythonPackagesExtensions/haskell.* class); unstablePinsOverlay; parts/overlays.nix mkComposed (with deliberate semantic upgrade — audit same-attr fixes on migration).";
    dependsOn = [ ];
    exports = [ "mkInputOverlay" "mkFixOverlay" "mkFixCatalog" "mkUnstablePin" "composeLayers" ];
  };

  manifest = {
    file = "manifest.nix";
    tier = "kernel";
    maturity = "Working";
    since = "2026-06-12";
    description = "Typed fleet app manifest (lib/ecosystem.nix schema, completed): one entry per app drives module imports, overlay registration, and profile enables — drift impossible by construction. enablesForProfile returns a plain attrset usable as a bare module body (ecosystem.nix parity).";
    subsumes = "lib/ecosystem.nix (completing its three header claims); the manifest-fed halves of lib/hm-modules.nix and the inline Darwin sharedModules list (their non-ecosystem foundation modules migrate separately).";
    dependsOn = [ "core" "overlay" ];
    exports = [ "mkManifest" ];
  };

  profile = {
    file = "profile.nix";
    tier = "kernel";
    maturity = "Working";
    since = "2026-06-12";
    description = "Axis-named profile layers (base/hardware/mixin/role, srvos shape): plain-data settings band-wrapped at the axis priority so stacking is commutative within an axis and any value is overridable at a predictable altitude. Default axis 'role' == mkDefault (migration parity). `whole` escapes the band boundary for non-recursing option types (types.attrs, nixpkgs.config).";
    subsumes = "nix repo profiles/* enable-flipping layers; blizzard/macos variant enums; the srvos taxonomy (shape adopted, dependency skipped).";
    dependsOn = [ "core" ];
    exports = [ "mkProfile" ];
  };

  shim = {
    file = "shim.nix";
    tier = "kernel";
    maturity = "Working";
    since = "2026-06-12";
    description = "The only sanctioned rename/removal path: deprecation shims (renamed/removed/alias) shipped in the same commit as any option-path change, so fleet configs warn instead of breaking mid-migration.";
    subsumes = "Hand-written legacy alias modules across blackmatter's profile generations; ad-hoc keep-the-old-option-working fragments.";
    dependsOn = [ "core" ];
    exports = [ "mkDeprecationShim" "mkEnableAlias" ];
  };

  wrapped-package = {
    file = "wrapped-package.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-12";
    description = "Typed wrapper chokepoint: { basePackage, flags, env, pathAdd, rename, multicall } compiled to symlinkJoin+wrapProgram; passthru.iroha.wrapSpec gives round-trip auditability (CLOSED-LOOP rule 3).";
    subsumes = "The six hand-rolled wrapper idioms (symlinkJoin+wrapProgram PATH-pin, multicall symlinks, binary rename, env-export, makeWrapper launcher, writeShellScriptBin glue); wrapper-manager's shape (adopted, dependency skipped).";
    dependsOn = [ ];
    exports = [ "mkWrappedPackage" ];
  };

  typed-app = {
    file = "typed-app.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-12";
    description = "Typed flake-app constructor (binary + argv + env): zero-wrapper fast path; otherwise a compiled export/exec wrapper — bash is emitted, never authored (NO SHELL law).";
    subsumes = "Ad-hoc writeShellScript app wrappers in parts/packages.nix and infra helpers (kubectl contexts, kikai lifecycle, push-image).";
    dependsOn = [ ];
    exports = [ "mkTypedApp" ];
  };

  mcp = {
    file = "mcp.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-12";
    description = "The single binary-to-agent-distribution primitive: anvil serverOpts-shaped registration (command|package form, scopes, agents) as data + HM fragment. Fixes module-trio's latent package+resolved-path double-resolution.";
    subsumes = "mkMcpServerEntry / mkAnvilRegistration / module-trio withAnvilMcp drift — one entry shape.";
    dependsOn = [ ];
    exports = [ "mkMcpRegistration" ];
  };

  vm-check = {
    file = "vm-check.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-12";
    description = "testers.runNixOSTest wrapper — the integration tier proving profile/host compositions boot and serve (SELinux-M3-style gates; Linux builders / pangea-jit-builders).";
    subsumes = "Ad-hoc VM test wiring; substrate's per-repo NixOS-test boilerplate.";
    dependsOn = [ ];
    exports = [ "mkVmCheck" ];
  };

  settings-shikumi = {
    file = "settings-shikumi.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-12";
    description = "shikumi schema -> option-surface settings.fields projection: one schema, two projections (Rust TieredConfig + Nix options) that cannot drift — the CONFIGURATION-MANAGEMENT missing link. Bounds on non-integer aliases carried but inert (documented ceiling).";
    subsumes = "Hand-duplicated shikumiTypedGroups blocks; the Rust-vs-Nix config surface drift class.";
    dependsOn = [ ];
    exports = [ "mkSettingsFromShikumi" "shikumiTypeToFieldType" ];
  };

  fleet-inventory = {
    file = "fleet-inventory.nix";
    tier = "extended";
    maturity = "Working";
    since = "2026-06-12";
    description = "Machines x services x instances x roles/tags placement (clan-core shape, dependency skipped): one declaration places a multi-machine service; modulesFor projects per-machine module sets; invariants are throw-free data.";
    subsumes = "The hand-rolled registry+projection pairs (lib/vpn-links.nix linksForNode, lib/clusters.nix) and every future multi-node service's bespoke registry.";
    dependsOn = [ ];
    exports = [ "mkFleetInventory" ];
  };

  host-matrix = {
    file = "host-matrix.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-12";
    description = "Typed node registry: one declaration -> nixosConfigurations + darwinConfigurations + deploy-rs node data + colmena hive + tag projections; ONE shared module-list builder makes config/deploy drift unrepresentable; manifest feeds HM sharedModules on BOTH platforms (dissolves the dual-list drift). deployRs is typed data — path realization stays consumer-side (never faked).";
    subsumes = "lib/nodes.nix hand-listed node entries; the mkDarwin + inline sharedModules stack; lib/deploy.nix; tag-driven image emission wiring.";
    dependsOn = [ "core" ];
    exports = [ "mkHostMatrix" ];
  };

  flake-unit = {
    file = "flake-unit.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-12";
    description = "The flake-parts faces: mkFlakeUnit projects a package-module unit into flake.modules.<class>.<name> (dendritic shape) + legacy-alias outputs + perSystem packages/checks/overlay; mkDendriticRoot = mkFlake + import-tree veneer; mkDevPartition isolates dev-only inputs from consumer locks (the 233-repo wedge amplifier).";
    subsumes = "Hand-rolled trio exports in consumer flakes; the inline overlays.default duplication; hand-curated parts imports lists (once the dead-parts purge lands).";
    dependsOn = [ ];
    exports = [ "mkFlakeUnit" "mkDendriticRoot" "mkDevPartition" ];
  };

  component-flake = {
    file = "component-flake.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-12";
    description = "THE BLACKMATTER SWALLOW SURFACE: blackmatter-component-flake.nix v2 — same consumer contract (parity suite asserts attr-name sets + deep metadata equality against the legacy implementation), re-emitted through iroha letters; typed throws replace silent key drops; the legacy eval-nixos-module check was broken by construction (stub prefix conflict) — v2's actually runs.";
    subsumes = "lib/blackmatter-component-flake.nix — SWALLOWED 2026-06-12: the legacy path is now a delegation shim over mkComponentFlake, so all ~20 blackmatter sub-repos run v2 with zero consumer edits; the frozen TRUE legacy implementation lives at tests/fixtures/legacy-component-flake.nix as the parity oracle; authored consumer modules pass through verbatim.";
    dependsOn = [ "core" "checks" ];
    exports = [ "mkComponentFlake" ];
  };

  service-module = {
    file = "service-module.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-13";
    description = "SYSTEM-class service MODULE emitter: a typed enable+config surface -> a full systemd.service (nixos) / launchd.daemon (darwin) with the root/system power fields iroha.daemon excludes (Type/EnvironmentFile/StateDirectory/RuntimeDirectory/User/Group/RemainAfterExit/ExecStartPre-Post/hardening). Composes mkOptionSurface + core.tag. mkServiceUnit is the PURE keep-alive systemd-service renderer (data -> { service, programArguments }) that bespoke modules — those whose ExecStart depends on their own typed options + a generated config file, AND which emit extra config (tmpfiles, HM bridges) alongside the unit (toride-system) — consume INSIDE their config block to farm the service shape while keeping their knobs; serviceExtra is the service-level path/restartIfChanged passthrough (siblings of serviceConfig).";
    subsumes = "The ~50 hand-rolled system-service modules in pleme-io/nix (attic-store-push, k3s-kubeconfig-export, toride-system, dns-split-horizon, vaultwarden, edge-router, power, ...).";
    dependsOn = [ "core" "option-surface" ];
    exports = [ "mkServiceModule" "mkServiceUnit" ];
  };

  service-bundle = {
    file = "service-bundle.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-13";
    description = "Curated-service bundle: a typed bundle-enable + per-feature mkIf -> services.<upstream> mkMerge module, each feature independently gateable, configs merge without clobbering.";
    subsumes = "The ~10 home-* family modules' hand-rolled enable-fan-out pattern (home-services/storage/automation/network-extras/data-services/media-automation, home-observability, darwin containers).";
    dependsOn = [ "core" ];
    exports = [ "mkServiceBundle" ];
  };

  registry-accumulator = {
    file = "registry-accumulator.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-13";
    description = "Typed attrsOf entries (each with enable) -> filtered + deterministically-sorted merge into one config sink. Composes core.mkFields + core.tag.";
    subsumes = "The recurring registry->sink pattern: binary-caches->substituters, kubeconfig-paths->KUBECONFIG, edge-router blocklists.";
    dependsOn = [ "core" ];
    exports = [ "mkRegistryAccumulator" ];
  };

  activation-hook = {
    file = "activation-hook.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-13";
    description = "Typed enable -> idempotent cross-platform OS activation-script step (NixOS system.activationScripts rich {text,deps}; nix-darwin flat .text). enable=false = always-on. The body is the one sanctioned (generated, idempotent) bash.";
    subsumes = "disable-determinate-nixd, admin-users, passwordless-sudo, pmset, mac-app-sync, attic-default-server, home-materialization activation steps.";
    dependsOn = [ "core" ];
    exports = [ "mkActivationHook" ];
  };

  scheduled-job = {
    file = "scheduled-job.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-13";
    description = "Periodic/scheduled work as a MODULE: a typed enable+command+schedule -> systemd oneshot service + timer (nixos) / launchd StartInterval|StartCalendarInterval (darwin). The oneshot+timer sibling of service-module's keep-alive shape. mkScheduledUnit is the PURE systemd-unit renderer (data -> { service, timer }) that bespoke modules — those whose ExecStart/schedule depend on their own typed options (attic-store-push) — consume INSIDE their config block to farm the unit shape while keeping their knobs; serviceConfigExtra (Type override) + serviceExtra (service-level path/restartIfChanged passthrough) make every load-bearing field expressible.";
    subsumes = "mkScheduledFleetMutation (nightly fetch/flake-update), the rio NIC-tune timers, attic-cache-warmer, attic-store-push, cron-like fleet jobs.";
    dependsOn = [ "core" "option-surface" ];
    exports = [ "mkScheduledJob" "mkScheduledUnit" ];
  };

  config-owner = {
    file = "config-owner.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-13";
    description = "Single typed OWNER of a contended config region: sets the owned fragment at a high priority band (default force) so it wins over plain competitors, with optional assertions. Reuses the profile.nix band-leaf descent.";
    subsumes = "The contended-knob disambiguation pattern: post-build-hook, nix-cache, sysctl-overrides mkOverride collisions, nix-provider.";
    dependsOn = [ "core" "option-surface" ];
    exports = [ "mkConfigOwner" ];
  };

  remote-builders = {
    file = "remote-builders.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-13";
    description = "Typed remote build machines -> nix.buildMachines + nix.distributedBuilds + programs.ssh Host blocks (ProxyCommand when set), deterministically sorted.";
    subsumes = "The pangea-builder consumer shape (~600 lines: buildMachines + ssh_config + known_hosts + wake-aware SSM ProxyCommand).";
    dependsOn = [ "core" "option-surface" ];
    exports = [ "mkRemoteBuilders" ];
  };

  conf-checks = {
    file = "conf-checks.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-13";
    description = "Assert OPTION VALUES on a BUILT config's .config (expected/satisfies/present), emitting mkEvalChecks-compatible cases; mkConfChecksFor runs per-config asserts across many configs. Missing paths fail cleanly (no eval abort).";
    subsumes = "The nix repo parts/checks.nix hand-rolled 557-line config-conformance harness.";
    dependsOn = [ "checks" ];
    exports = [ "mkConfChecks" "mkConfChecksFor" ];
  };

  udev-tune = {
    file = "udev-tune.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-13";
    description = "Device-appear / link-up driven tuning as a typed module: typed udev match attrs -> rule lines (RUN+= action or systemctl start <tuneService>@) + the triggered oneshot tuning services. NixOS-only (udev is Linux).";
    subsumes = "rio's hand-rolled services.udev.extraRules NVMe tuning + the i40e-tune@ NIC link-up oneshot template (rio + mar).";
    dependsOn = [ "core" "option-surface" ];
    exports = [ "mkUdevTune" ];
  };

  gitops = {
    file = "gitops.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-13";
    description = "Pull-based GitOps reconcile behind one option surface with per-platform backends: NixOS -> services.comin (remote url/branch/poll), macOS -> a launchd periodic darwin-rebuild --flake <repo>#<attr>.";
    subsumes = "The two hand-written pull-gitops backend modules (comin on NixOS, launchd darwin-rebuild on macOS) behind one pleme.gitops surface.";
    dependsOn = [ "core" "option-surface" ];
    exports = [ "mkGitopsModule" ];
  };

  resource-policy = {
    file = "resource-policy.nix";
    tier = "standard";
    maturity = "Working";
    since = "2026-06-13";
    description = "Typed CPU/memory/IO/task resource envelope rendered onto systemd units (CPUQuota/CPUWeight/MemoryMax/TasksMax/IOWeight/AllowedCPUs/OOMScoreAdjust) + best-effort sanity assertions. NixOS-only.";
    subsumes = "The node-budget (breathe L2) + sshd-survivability systemd resource-control projections.";
    dependsOn = [ "core" "option-surface" ];
    exports = [ "mkResourcePolicy" ];
  };

  catalog = {
    file = "catalog.nix";
    tier = "kernel";
    maturity = "Working";
    since = "2026-06-12";
    description = "This file: the alphabet's self-description. Bijection with letter files, acyclic dependsOn graph, and maturity partition are test-enforced.";
    subsumes = "Doc drift between code and description surfaces.";
    dependsOn = [ ];
    exports = [ "catalog" ];
  };
}
