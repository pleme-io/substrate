# iroha.manifest — the typed fleet app manifest (nix repo lib/ecosystem.nix
# schema adopted VERBATIM, its three header claims completed).
#
# One entry per app drives all three integration surfaces that previously
# required hand-edits in three separate files (a drift opportunity each):
# (1) module imports (HM/NixOS/Darwin), (2) overlay registration, and
# (3) profile enables. A missing entry means the app is not in the fleet,
# period — drift impossible by construction.
#
# Exports (pure { lib }, zero pkgs; flake inputs are DATA the caller
# passes — ./overlay.nix is imported lazily inside the `overlays`
# projection only, never at import time of this file):
#
#   mkManifest :: {
#     inputs  :: attrs              — flake inputs (module/overlay sources);
#     apps    :: attrsOf appSpec;
#     classes :: attrsOf classSpec;
#     mkInputOverlay ? null         — late-binding seam for the overlay
#                                     letter (tests may inject a stub);
#                                     null -> (import ./overlay.nix
#                                     { inherit lib; }).mkInputOverlay,
#                                     resolved lazily inside `overlays`.
#   } -> manifest
#
# appSpec = {
#   class         (REQUIRED)        one of the `classes` keys — typed throw
#                                   (lazy, on field force) when missing or
#                                   unknown;
#   input         ? <key>           flake input name;
#   platforms     ? ["darwin" "linux"]  each "darwin"|"linux" — typed throw
#                                   (lazy, on element force) otherwise;
#   hmModule      ? true            ships a home-manager module;
#   hmModulePath  ? null            dotted path under inputs.<input>; null
#                                   means "homeManagerModules.default";
#   nixosModule   ? false           module at inputs.<input>.nixosModules.default;
#   darwinModule  ? false           module at inputs.<input>.darwinModules.default;
#   overlay       ? false           registers an overlay (see `overlays`);
#   packageAttr   ? <key>           package attr the overlay defines in pkgs;
#   namespace     ? "programs"      HM option namespace (dotted);
#   optionName    ? <key>           leaf under <namespace>;
#   enablePath    ? [<optionName> "enable"]  path under <namespace> to the
#                                   bool that turns the app on;
# }
#
# classSpec = { profiles ? [ ]; enabled ? true; auditOnly ? false; }
#
# manifest = {
#   apps    :: attrsOf resolvedApp  — defaults applied, name/input/
#                                     packageAttr/optionName/enablePath
#                                     computed;
#   classes :: attrsOf resolvedClass;
#
#   hmModulesFor :: "darwin"|"linux" -> [module]
#       apps where hmModule && platform ∈ platforms && class.enabled.
#       inputs.<input> resolved with a typed throw NAMING THE APP when the
#       input is missing from `inputs` or the module path is absent; each
#       module appears exactly once (keyed by app). Unknown platform
#       argument is a typed throw.
#
#   nixosModules  :: [module]       — apps with nixosModule  = true;
#   darwinModules :: [module]       — apps with darwinModule = true;
#
#   overlays :: [ { name, overlay, provenance :: { app, kind } } ]
#       apps with overlay = true. inputs.<input>.overlays.default when
#       present (kind = "upstream-overlay"); otherwise mkInputOverlay
#       { input, name, packageAttr } (kind = "input-package").
#
#   enablesForProfile :: profileName -> config attrset
#       PLAIN attrset (recursiveUpdate fold — usable directly as a bare
#       module body, the convention profiles/*/home/ecosystem.nix use) of
#       <namespace>.<enablePath> = (core.at "role" true) for every app
#       whose class lists the profile AND class.enabled AND not
#       class.auditOnly — role-band so node config wins by altitude. The
#       fold is sound because enable paths are disjoint by the
#       enable-paths-unique invariant;
#
#   appsForProfile :: profileName -> sorted [appName]  (same membership);
#
#   invariants :: attrsOf { expr, expected }
#       throw-free ready-made suite (feed to checks.mkEvalChecks): every
#       app class exists; auditOnly classes have profiles == []; every
#       class with profiles == [] is auditOnly (the "broken class" rule);
#       every app's platforms list is non-empty + valid; no two enabled
#       apps share the same namespace+enablePath;
#
#   catalog :: { appCount, byClass :: attrsOf [appName],
#                profiles :: attrsOf [appName] };
# }
{ lib }:
let
  core = import ./core.nix { inherit lib; };

  platformNames = [
    "darwin"
    "linux"
  ];

  classDefaults = {
    profiles = [ ];
    enabled = true;
    auditOnly = false;
  };

  appDefaults = {
    platforms = platformNames;
    hmModule = true;
    hmModulePath = null;
    nixosModule = false;
    darwinModule = false;
    overlay = false;
    namespace = "programs";
  };

  mkManifest =
    {
      inputs,
      apps,
      classes,
      mkInputOverlay ? null,
    }:
    let
      classList = lib.concatStringsSep ", " (builtins.attrNames classes);

      resolvedClasses = lib.mapAttrs (_: c: classDefaults // c) classes;

      # Defaults-only resolution — never throws. The invariants suite (and
      # anything that must REPORT rather than abort) reads this view.
      resolveBase =
        name: spec:
        let
          optionName = spec.optionName or name;
        in
        appDefaults
        // spec
        // {
          inherit name optionName;
          input = spec.input or name;
          packageAttr = spec.packageAttr or name;
          enablePath = spec.enablePath or [
            optionName
            "enable"
          ];
          platforms = spec.platforms or appDefaults.platforms;
        };

      # Public resolution — class + platform validity enforced by typed
      # throws. Lazy: forcing the offending FIELD surfaces the throw.
      resolveApp =
        name: spec:
        resolveBase name spec
        // {
          class =
            if !(spec ? class) then
              throw "iroha.manifest.mkManifest: app '${name}' is missing required `class` — expected one of ${classList}."
            else if !(classes ? ${spec.class}) then
              throw "iroha.manifest.mkManifest: app '${name}' names unknown class '${toString spec.class}' — expected one of ${classList}."
            else
              spec.class;
          platforms = map (
            p:
            if builtins.elem p platformNames then
              p
            else
              throw "iroha.manifest.mkManifest: app '${name}' lists invalid platform '${toString p}' — expected \"darwin\" or \"linux\"."
          ) (spec.platforms or appDefaults.platforms);
        };

      resolved = lib.mapAttrs resolveApp apps;
      rawResolved = lib.mapAttrs resolveBase apps;

      inputFor =
        fn: app:
        inputs.${app.input}
          or (throw "iroha.manifest.${fn}: app '${app.name}' references flake input '${app.input}' — expected it to exist in `inputs`.");

      moduleAt =
        fn: app: path:
        lib.attrByPath (lib.splitString "." path) (throw "iroha.manifest.${fn}: app '${app.name}' — expected a module at inputs.${app.input}.${path}, but that path does not exist.") (inputFor fn app);

      classEnabled = app: (resolvedClasses.${app.class}).enabled;

      hmModulesFor =
        platform:
        if !(builtins.elem platform platformNames) then
          throw "iroha.manifest.hmModulesFor: unknown platform '${toString platform}' — expected \"darwin\" or \"linux\"."
        else
          lib.mapAttrsToList
            (
              _: app:
              moduleAt "hmModulesFor" app (
                if app.hmModulePath != null then app.hmModulePath else "homeManagerModules.default"
              )
            )
            (
              lib.filterAttrs (
                _: app: app.hmModule && builtins.elem platform app.platforms && classEnabled app
              ) resolved
            );

      nixosModules = lib.mapAttrsToList (_: app: moduleAt "nixosModules" app "nixosModules.default") (
        lib.filterAttrs (_: app: app.nixosModule) resolved
      );

      darwinModules = lib.mapAttrsToList (_: app: moduleAt "darwinModules" app "darwinModules.default") (
        lib.filterAttrs (_: app: app.darwinModule) resolved
      );

      overlays = lib.mapAttrsToList (
        name: app:
        let
          input = inputFor "overlays" app;
          # Late-bound: the overlay letter is only imported when an app
          # actually takes the input-package route (and no seam was given).
          mkIO =
            if mkInputOverlay != null then
              mkInputOverlay
            else
              (import ./overlay.nix { inherit lib; }).mkInputOverlay;
        in
        if input ? overlays && input.overlays ? default then
          {
            inherit name;
            overlay = input.overlays.default;
            provenance = {
              app = name;
              kind = "upstream-overlay";
            };
          }
        else
          {
            inherit name;
            overlay = mkIO {
              inherit input name;
              packageAttr = app.packageAttr;
            };
            provenance = {
              app = name;
              kind = "input-package";
            };
          }
      ) (lib.filterAttrs (_: app: app.overlay) resolved);

      inProfile =
        profile: app:
        let
          cls = resolvedClasses.${app.class};
        in
        cls.enabled && !cls.auditOnly && builtins.elem profile cls.profiles;

      memberApps = profile: lib.filterAttrs (_: app: inProfile profile app) resolved;

      # attrNames is sorted by construction — the list is stable + sorted.
      appsForProfile = profile: builtins.attrNames (memberApps profile);

      # Plain attrset fold (NOT mkMerge): usable directly as a bare module
      # body — parity with ecosystem.nix enableConfigForProfile. Sound
      # because enable paths are disjoint by the enable-paths-unique
      # invariant; each leaf carries its own role-band priority.
      enablesForProfile =
        profile:
        builtins.foldl' lib.recursiveUpdate { } (
          lib.mapAttrsToList (
            _: app:
            lib.setAttrByPath (lib.splitString "." app.namespace ++ app.enablePath) (core.at "role" true)
          ) (memberApps profile)
        );

      profileNames = lib.unique (
        lib.concatMap (c: c.profiles) (builtins.attrValues resolvedClasses)
      );

      invariants = {
        every-app-class-exists = {
          expr = builtins.attrNames (
            lib.filterAttrs (_: s: !(s ? class) || !(classes ? ${s.class})) apps
          );
          expected = [ ];
        };
        audit-only-classes-have-no-profiles = {
          expr = builtins.attrNames (
            lib.filterAttrs (_: c: c.auditOnly && c.profiles != [ ]) resolvedClasses
          );
          expected = [ ];
        };
        profileless-classes-are-audit-only = {
          expr = builtins.attrNames (
            lib.filterAttrs (_: c: c.profiles == [ ] && !c.auditOnly) resolvedClasses
          );
          expected = [ ];
        };
        app-platforms-non-empty-and-valid = {
          expr = builtins.attrNames (
            lib.filterAttrs (
              _: a: a.platforms == [ ] || !(lib.all (p: builtins.elem p platformNames) a.platforms)
            ) rawResolved
          );
          expected = [ ];
        };
        enable-paths-unique-among-enabled-apps = {
          expr =
            let
              enabledApps = lib.filterAttrs (
                _: a: a ? class && resolvedClasses ? ${a.class} && (resolvedClasses.${a.class}).enabled
              ) rawResolved;
              keys = lib.mapAttrsToList (
                _: a: lib.concatStringsSep "." (lib.splitString "." a.namespace ++ a.enablePath)
              ) enabledApps;
            in
            lib.filter (k: builtins.length (lib.filter (x: x == k) keys) > 1) (lib.unique keys);
          expected = [ ];
        };
      };

      catalog = {
        appCount = builtins.length (builtins.attrNames apps);
        byClass = lib.mapAttrs (
          className: _: builtins.attrNames (lib.filterAttrs (_: a: a.class == className) resolved)
        ) resolvedClasses;
        profiles = lib.genAttrs profileNames appsForProfile;
      };
    in
    {
      apps = resolved;
      classes = resolvedClasses;
      inherit
        hmModulesFor
        nixosModules
        darwinModules
        overlays
        enablesForProfile
        appsForProfile
        invariants
        catalog
        ;
    };
in
{
  inherit mkManifest;
}
