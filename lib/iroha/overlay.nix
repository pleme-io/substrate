# iroha.overlay — overlay algebra: typed input re-exports, provenance-
# mandatory fix catalogs, unstable pins, and layer/composite composition
# with a queryable registry.
#
# Subsumes the fleet's four overlay idioms: the ~30 one-file-per-input
# re-export overlays (nix repo overlays/tend.nix shape), the preferAttrs
# variant (overlays/gen.nix host-tool-over-default), the boolean-flag
# fix-soup PATTERN (overlays/default.nix — the flag mechanism plus every
# single-package overrideAttrs fix; fixes that mutate package-set LISTS
# like pythonPackagesExtensions or nested trees like haskell.* use the
# `raw` fixSpec arm, keeping their provenance in the catalog), and
# parts/overlays.nix's hand-rolled mkComposed role layers. Provenance is
# mandatory: every fix carries a `reason`, every composition layer carries
# a registry — "why is this overlay here?" becomes a data query, never
# archaeology.
#
# COMPOSITION SEMANTICS (migration hazard — read before porting
# mkComposed-style folds): composeLayers uses lib.composeManyExtensions —
# a later overlay sees an earlier overlay's output through ITS prev, and
# two fixes touching one attr STACK (second overrideAttrs applies on top
# of the first). The nix repo's legacy mkComposed (foldl' // over a shared
# original prev) gives neither: entries never see siblings' additions and
# the last same-attr writer CLOBBERS earlier ones. composeLayers is the
# correct overlay algebra (nixpkgs.overlays semantics); when migrating a
# mkComposed list, audit entries that read prev.<attr-from-a-sibling> or
# write the same attr — their behavior CHANGES (deliberately) here.
#
# Exports (pure { lib }, zero pkgs — pkgs appears only as the late-bound
# final/prev arguments of the emitted overlays):
#
#   mkInputOverlay :: {
#     input,                       — flake input with .packages.<system>
#     name :: str,                 — input name (for error messages)
#     packageAttr ? name,          — pkgs attr the overlay defines
#     preferAttrs ? [ "default" ], — first attr present in
#                                    input.packages.<system> wins
#     fallback ? null,             — value when none present; when null,
#                                    forcing the attr is a typed throw
#                                    naming input, system, and tried attrs
#   } -> overlay
#
#   mkFixOverlay :: {
#     package :: str,              — pkgs attr to overrideAttrs
#     reason :: str,               — REQUIRED provenance; typed throw when
#                                    missing — say WHY this override exists
#     skipTests ? false,           — layer in { doCheck = false; }
#     darwinOnly ? false,          — identity overlay ({ }) on non-Darwin prev
#     override ? null,             — old: attrs; applied first, skipTests'
#                                    doCheck = false layered last (the named
#                                    flag is authoritative on conflict)
#   } -> overlay
#     At least one of skipTests/override must be set (typed throw).
#     Package missing from prev -> typed throw when the attr is forced —
#     a fix never degrades to a silent identity.
#
#   mkFixCatalog :: {
#     fixes :: attrsOf fixSpec,
#     flags ? { },                 — attrsOf bool; per-name enable override,
#                                    wins over fixSpec.enabled
#   } -> {
#     overlays :: attrsOf overlay  — ENABLED fixes only;
#     composed :: overlay          — enabled fixes composed in attr-name-
#                                    sorted order;
#     catalog  :: attrsOf { package, reason, enabled, skipTests,
#                           darwinOnly, kind }
#                                  — ALL fixes incl. disabled: the
#                                    provenance registry; kind =
#                                    "overrideAttrs" | "raw";
#   }
#   fixSpec — two arms:
#     overrideAttrs arm (the common case — single-package fix):
#       { package ? <attrName>; reason (required, typed throw);
#         skipTests ? false; darwinOnly ? false; override ? null;
#         enabled ? true; }
#     raw arm (list-append / nested-tree fixes a single overrideAttrs
#     cannot express — pythonPackagesExtensions, haskell.*):
#       { reason (required); overlay :: final: prev: attrs;
#         darwinOnly ? false; enabled ? true; }
#       darwinOnly gates the raw overlay to identity on non-Darwin prev.
#
#   mkUnstablePin :: {
#     unstable,                    — nixpkgs-like flake input
#     packages :: [str],           — non-empty, else typed throw
#     reason :: str,               — REQUIRED provenance; typed throw
#     config ? { },                — nixpkgs config when importing fresh
#   } -> overlay
#     Pins each name from unstable.legacyPackages.<system> when present,
#     else `import unstable { inherit system config; }`. A name absent
#     from the unstable set is a typed throw when its attr is forced.
#
#   composeLayers :: {
#     layers :: attrsOf (listOf entry),
#       entry = overlay-fn | { overlay :: overlay-fn; provenance ? attrs };
#       bare functions get provenance { kind = "opaque"; };
#     composites ? { },            — attrsOf (listOf layerName); an unknown
#                                    layer name is a typed throw, surfacing
#                                    when the composite value is forced
#   } -> {
#     layers     :: attrsOf overlay  — each layer's entries composed in list
#                                      order (a later entry sees an earlier
#                                      entry's output through ITS prev);
#     composites :: attrsOf overlay  — the named layers composed in list
#                                      order;
#     registry   :: { layers :: attrsOf (listOf provenance);
#                     composites :: attrsOf (listOf str); }
#                                    — pure data: "why is this overlay
#                                      here" is a query;
#   }
{ lib }:
let
  inherit (lib) concatStringsSep;

  mkInputOverlay =
    {
      input,
      name,
      packageAttr ? name,
      preferAttrs ? [ "default" ],
      fallback ? null,
    }:
    final: prev:
    let
      system = prev.stdenv.hostPlatform.system;
      provided = (input.packages or { }).${system} or { };
      found = lib.findFirst (a: provided ? ${a}) null preferAttrs;
    in
    {
      ${packageAttr} =
        if found != null then
          provided.${found}
        else if fallback != null then
          fallback
        else
          throw "iroha.overlay.mkInputOverlay: input '${name}' provides none of [ ${concatStringsSep " " preferAttrs} ] in packages.${system} — expected one of the preferred attrs to exist for this system (or pass `fallback`).";
    };

  mkFixOverlay =
    {
      package,
      reason ? null,
      skipTests ? false,
      darwinOnly ? false,
      override ? null,
    }:
    if reason == null then
      throw "iroha.overlay.mkFixOverlay: fix for '${package}' is missing `reason` — provenance is mandatory; expected a string saying WHY this override exists."
    else if !skipTests && override == null then
      throw "iroha.overlay.mkFixOverlay: fix for '${package}' sets neither `skipTests` nor `override` — expected at least one (a fix that changes nothing is drift)."
    else
      final: prev:
      if darwinOnly && !(prev.stdenv.hostPlatform.isDarwin or false) then
        { }
      else
        {
          ${package} =
            if !(prev ? ${package}) then
              throw "iroha.overlay.mkFixOverlay: package '${package}' is not in the package set this overlay extends (reason: ${reason}) — expected prev.${package} to exist; a fix never degrades to a silent identity."
            else
              prev.${package}.overrideAttrs (
                old:
                (if override != null then override old else { })
                // lib.optionalAttrs skipTests { doCheck = false; }
              );
        };

  mkFixCatalog =
    {
      fixes,
      flags ? { },
    }:
    let
      normalized = lib.mapAttrs (
        attrName: spec: {
          package = spec.package or attrName;
          reason =
            if (spec.reason or null) != null then
              spec.reason
            else
              throw "iroha.overlay.mkFixCatalog: fix '${attrName}' is missing `reason` — provenance is mandatory; expected a string saying WHY this override exists.";
          skipTests = spec.skipTests or false;
          darwinOnly = spec.darwinOnly or false;
          override = spec.override or null;
          rawOverlay = spec.overlay or null;
          enabled = flags.${attrName} or (spec.enabled or true);
        }
      ) fixes;
      # builtins.attrNames is sorted — composition order is deterministic.
      enabledNames = builtins.filter (n: normalized.${n}.enabled) (builtins.attrNames normalized);
      mkOne =
        n:
        let
          f = normalized.${n};
        in
        if f.rawOverlay != null then
          # raw arm: the fix IS an overlay (list-append / nested-tree
          # mutations); darwinOnly still gates it. seq the reason so the
          # provenance throw fires even on the raw path.
          (
            final: prev:
            builtins.seq f.reason (
              if f.darwinOnly && !(prev.stdenv.hostPlatform.isDarwin or false) then
                { }
              else
                f.rawOverlay final prev
            )
          )
        else
          mkFixOverlay {
            inherit (f)
              package
              reason
              skipTests
              darwinOnly
              override
              ;
          };
    in
    {
      overlays = lib.genAttrs enabledNames mkOne;
      composed = lib.composeManyExtensions (map mkOne enabledNames);
      catalog = lib.mapAttrs (
        _: f: {
          inherit (f)
            package
            reason
            enabled
            skipTests
            darwinOnly
            ;
          kind = if f.rawOverlay != null then "raw" else "overrideAttrs";
        }
      ) normalized;
    };

  mkUnstablePin =
    {
      unstable,
      packages,
      reason ? null,
      config ? { },
    }:
    if reason == null then
      throw "iroha.overlay.mkUnstablePin: missing `reason` — provenance is mandatory; expected a string saying WHY these packages are pinned from unstable."
    else if packages == [ ] then
      throw "iroha.overlay.mkUnstablePin: `packages` is empty — expected a non-empty list of package names to pin (reason: ${reason})."
    else
      final: prev:
      let
        system = prev.stdenv.hostPlatform.system;
        unstablePkgs =
          if (unstable.legacyPackages or { }) ? ${system} then
            unstable.legacyPackages.${system}
          else
            import unstable { inherit system config; };
      in
      lib.genAttrs packages (
        n:
        unstablePkgs.${n}
          or (throw "iroha.overlay.mkUnstablePin: package '${n}' is not in unstable for ${system} (reason: ${reason}) — expected the pinned name to exist in the unstable package set.")
      );

  defaultProvenance = {
    kind = "opaque";
  };

  composeLayers =
    {
      layers,
      composites ? { },
    }:
    let
      normalizeEntry =
        layerName: entry:
        if builtins.isFunction entry then
          {
            overlay = entry;
            provenance = defaultProvenance;
          }
        else if builtins.isAttrs entry && entry ? overlay then
          {
            overlay = entry.overlay;
            provenance = entry.provenance or defaultProvenance;
          }
        else
          throw "iroha.overlay.composeLayers: layer '${layerName}' contains a ${builtins.typeOf entry} — expected an overlay function or { overlay, provenance ? }.";
      normalized = lib.mapAttrs (layerName: map (normalizeEntry layerName)) layers;
      # Force-then-compose: a bad entry / unknown layer name surfaces as
      # soon as the composed overlay VALUE is forced (e.g. when wired into
      # flake.overlays), not later when it is applied to a package set.
      strictCompose =
        ovs: builtins.seq (builtins.all builtins.isFunction ovs) (lib.composeManyExtensions ovs);
      layerOverlays = lib.mapAttrs (_: entries: strictCompose (map (e: e.overlay) entries)) normalized;
      knownLayers = concatStringsSep ", " (builtins.attrNames layers);
      resolveComposite =
        compositeName: layerNames:
        strictCompose (
          map (
            ln:
            layerOverlays.${ln}
              or (throw "iroha.overlay.composeLayers: composite '${compositeName}' references unknown layer '${ln}' — expected one of: ${knownLayers}.")
          ) layerNames
        );
    in
    {
      layers = layerOverlays;
      composites = lib.mapAttrs resolveComposite composites;
      registry = {
        layers = lib.mapAttrs (_: map (e: e.provenance)) normalized;
        inherit composites;
      };
    };
in
{
  inherit
    mkInputOverlay
    mkFixOverlay
    mkFixCatalog
    mkUnstablePin
    composeLayers
    ;
}
