{ lib, trio }:
let
  enumOrNull = values: lib.types.nullOr (lib.types.enum values);
  coherent =
    e:
    (e.runtime == "rust" -> (e.backend == null && e.seed == null))
    && (e.runtime == "native" -> e.door == null)
    && ((e.seed == "binary" || e.seed == "full-source") -> e.backend == "x64");
  entryType = lib.types.addCheck (lib.types.submodule {
    options = {
      runtime = lib.mkOption { type = lib.types.enum [ "rust" "native" ]; };
      door = lib.mkOption { type = enumOrNull [ "walker" "vm" "auto" ]; default = null; };
      front = lib.mkOption { type = lib.types.enum [ "rust" "blue" ]; };
      backend = lib.mkOption { type = enumOrNull [ "rustc" "x64" ]; default = null; };
      seed = lib.mkOption { type = enumOrNull [ "stage0" "binary" "full-source" ]; default = null; };
      memory = lib.mkOption { type = lib.types.enum [ "counted" "inferred" "inferred-local" ]; };
      rung = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The plan step that makes this entry buildable; null when it builds today.";
      };
    };
  }) coherent;
  entries = {
    rust = { runtime = "rust"; door = "auto"; front = "rust"; memory = "counted"; };
    rust-owned = { runtime = "rust"; door = "auto"; front = "rust"; memory = "inferred"; rung = "M3"; };
    native-rustc = { runtime = "native"; front = "rust"; backend = "rustc"; seed = "stage0"; memory = "inferred"; rung = "R6"; };
    pure = { runtime = "native"; front = "blue"; backend = "x64"; seed = "binary"; memory = "inferred-local"; rung = "S2"; };
    pure-source = { runtime = "native"; front = "blue"; backend = "x64"; seed = "full-source"; memory = "inferred-local"; rung = "S4"; };
  };
in
{
  inherit entryType entries coherent;
  concept = trio.mkModuleTrio {
    kind = "registry";
    namespace = "pleme";
    name = "blueToolchain";
    description = "how blue is built and run: runtime, front end, backend, seed, memory";
    entries = {
      option = "entries";
      type = entryType;
      default = entries;
      description = "Every toolchain permutation, buildable or refused by the rung that unblocks it.";
    };
    selector = {
      over = "entries";
      default = "rust";
      description = "The toolchain this machine's blue is built with.";
    };
    settings =
      _:
      {
        packages = lib.mkOption {
          type = lib.types.attrsOf lib.types.package;
          default = { };
          description = "The blue derivation of each buildable entry, by entry name, from the flake that builds blue.";
        };
      };
    projections =
      { cfg, ... }:
      let
        entry = cfg.entries.${cfg.selected};
      in
      {
        refusal = {
          type = lib.types.nullOr lib.types.str;
          value =
            if entry.rung != null then
              "blueToolchain: entry `${cfg.selected}` is not buildable yet: needs ${entry.rung}"
            else if !(cfg.packages ? ${cfg.selected}) then
              "blueToolchain: entry `${cfg.selected}` has no derivation in packages"
            else
              null;
          description = "Why the selected entry cannot be rendered, or null when it can.";
        };
        door = {
          type = lib.types.nullOr lib.types.str;
          value = entry.door;
          description = "BLUE_DOOR for the rust runtime; null under native.";
        };
      };
    render = {
      nixos = ./toolchain/system.nix;
      darwin = ./toolchain/darwin.nix;
      homeManager = ./toolchain/home.nix;
    };
  };
}
