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
    subsumes = "The DESTINATION for mkModuleTrio, fleet-app-module.nix, and blackmatter-component-flake module emission. Covered today: enable/package/settings surface, user+system daemons, platform gates, per-class extension modules. NOT yet covered (mkModuleTrio remains canonical for these): withMcp/withAnvilMcp shims, withHttp service, extraPackages-by-overlay-attr quirks, shikumiGateOnEnable. Promotion per surface as consumers migrate.";
    dependsOn = [ "core" "option-surface" "daemon" ];
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
