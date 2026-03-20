# Versioned overlay generator
#
# Generates versioned overlay entries for N tracks × M components, plus
# default and latest aliases. Eliminates the cartesian-product string
# manipulation boilerplate in flake.nix overlay definitions.
#
# Usage:
#   mkVersionedOverlay = (import "${substrate}/lib/versioned-overlay.nix").mkVersionedOverlay;
#   entries = mkVersionedOverlay {
#     lib = nixpkgs.lib;
#     tracks = [ "1.30" "1.31" "1.32" "1.33" "1.34" "1.35" ];
#     prefix = "blackmatter-";
#     defaultTrack = "1.34";
#     latestTrack = "1.35";
#     components = {
#       kubelet = { src = k8sPkgs; };
#       etcd    = { src = k8sPkgs; overlayName = "etcd-server"; };
#       k3s     = { src = k3sPkgs; srcAttr = track: "k3s_${track}"; };
#     };
#   };
#
# Returns an attrset with:
#   blackmatter-kubelet-1-30   = ...   (versioned entries)
#   blackmatter-kubelet        = ...   (default alias → defaultTrack)
#   blackmatter-kubelet-latest = ...   (latest alias → latestTrack)
{
  # Generate versioned overlay entries.
  #
  # Required attrs:
  #   lib          — nixpkgs lib
  #   tracks       — list of track strings (e.g., [ "1.30" "1.34" "1.35" ])
  #   defaultTrack — track for unversioned alias (e.g., "1.34")
  #   latestTrack  — track for -latest alias (e.g., "1.35")
  #   components   — attrset of component definitions (see below)
  #
  # Optional attrs:
  #   prefix       — overlay name prefix (default: "blackmatter-")
  #
  # Component definition:
  #   {
  #     src          — package set (e.g., k8sPkgs, k3sPkgs)
  #     overlayName  — optional: overlay name if different from component key
  #                    (e.g., "etcd-server" for the "etcd" component)
  #     srcAttr      — optional: function (trackSuffix → attr name in src)
  #                    Default: trackSuffix → "${componentKey}_${trackSuffix}"
  #   }
  mkVersionedOverlay = {
    lib,
    tracks,
    prefix ? "blackmatter-",
    defaultTrack,
    latestTrack,
    components,
  }: let
    # Generate versioned entries for all tracks × all components
    versioned = lib.listToAttrs (lib.concatMap (track: let
      dashSuffix = builtins.replaceStrings ["."] ["-"] track;
      underSuffix = builtins.replaceStrings ["."] ["_"] track;
    in lib.mapAttrsToList (compKey: compDef: let
      overlayName = compDef.overlayName or compKey;
      srcAttr = if compDef ? srcAttr
        then compDef.srcAttr underSuffix
        else "${compKey}_${underSuffix}";
    in {
      name = "${prefix}${overlayName}-${dashSuffix}";
      value = compDef.src.${srcAttr};
    }) components) tracks);

    # Generate default aliases (unversioned → defaultTrack)
    defaultUnderSuffix = builtins.replaceStrings ["."] ["_"] defaultTrack;
    defaults = lib.mapAttrs' (compKey: compDef: let
      overlayName = compDef.overlayName or compKey;
      srcAttr = if compDef ? srcAttr
        then compDef.srcAttr defaultUnderSuffix
        else "${compKey}_${defaultUnderSuffix}";
    in {
      name = "${prefix}${overlayName}";
      value = compDef.src.${srcAttr};
    }) components;

    # Generate latest aliases (${name}-latest → latestTrack)
    latestUnderSuffix = builtins.replaceStrings ["."] ["_"] latestTrack;
    latest = lib.mapAttrs' (compKey: compDef: let
      overlayName = compDef.overlayName or compKey;
      srcAttr = if compDef ? srcAttr
        then compDef.srcAttr latestUnderSuffix
        else "${compKey}_${latestUnderSuffix}";
    in {
      name = "${prefix}${overlayName}-latest";
      value = compDef.src.${srcAttr};
    }) components;

  in versioned // defaults // latest;
}
