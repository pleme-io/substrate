# Home-manager typed configuration helpers
#
# Reusable patterns for generating config files (JSON/YAML) from typed
# Nix options. Provides conditional attribute builders and config file
# deployment helpers used across blackmatter agent modules.
#
# Usage (in flake.nix):
#   configHelpers = import "${substrate}/lib/hm-typed-config-helpers.nix" { lib = nixpkgs.lib; };
#
# Usage (in module/default.nix):
#   { configHelpers }: { lib, config, pkgs, ... }:
#   let inherit (configHelpers) optAttr optList optNested mkJsonConfig; in { ... }
{ lib }:
with lib;
{
  # ── Conditional Attribute Helpers ─────────────────────────────────────
  # Include a key in an attrset only when the value is meaningful.
  # Useful for building JSON/YAML config where absent keys have semantics.

  # Only include key if value is non-null.
  # Example: optAttr "model" cfg.model → {} or { model = "opus"; }
  optAttr = key: val: if val != null then { ${key} = val; } else {};

  # Only include key if list is non-empty.
  # Example: optList "tags" cfg.tags → {} or { tags = ["a" "b"]; }
  optList = key: val: if val != [] then { ${key} = val; } else {};

  # Only include key if attrset is non-empty.
  # Example: optNested "env" cfg.env → {} or { env = { FOO = "bar"; }; }
  optNested = key: val: if val != {} then { ${key} = val; } else {};

  # ── JSON Config File ──────────────────────────────────────────────────
  # Build a home.file entry that writes a JSON config file.
  # Merges typed config with an escape-hatch attrset.
  #
  # Returns: { "path" = { text = "<json>"; }; }
  #
  # Example:
  #   home.file = mkMerge [
  #     (configHelpers.mkJsonConfig {
  #       path = ".config/app/config.json";
  #       config = { theme = "nord"; model = "opus"; };
  #       extraConfig = cfg.extraSettings;
  #     })
  #   ];
  mkJsonConfig = {
    path,
    config,
    extraConfig ? {},
  }: {
    ${path}.text = builtins.toJSON (config // extraConfig);
  };

  # ── YAML Config File ──────────────────────────────────────────────────
  # Build a home.file entry that writes a YAML config file.
  # Uses lib.generators.toYAML for proper YAML serialization.
  # Note: null values are serialized as YAML null. Use filterAttrs to
  # exclude nulls before passing if your target app doesn't accept them.
  #
  # Returns: { "path" = { text = "<yaml>"; }; }
  #
  # Example:
  #   home.file = mkMerge [
  #     (configHelpers.mkYamlConfig {
  #       path = ".config/app/config.yml";
  #       config = { agent.model = "opus"; streaming = true; };
  #     })
  #   ];
  mkYamlConfig = {
    path,
    config,
    extraConfig ? {},
  }: {
    ${path}.text = generators.toYAML {} (config // extraConfig);
  };

  # ── Versioned Config ──────────────────────────────────────────────────
  # Wrap a config attrset with a version field (common CLI config pattern).
  # Note: if config already contains a "version" key, it will override
  # the provided version (right-hand side of // wins).
  #
  # Example:
  #   configHelpers.mkVersionedConfig { version = 1; config = { permissions = {...}; }; }
  #   → { version = 1; permissions = {...}; }
  mkVersionedConfig = {
    version ? 1,
    config,
  }: { inherit version; } // config;

  # ── Typed JSON File (convenience) ─────────────────────────────────────
  # Combine typed settings with an escape hatch and write to a JSON file.
  # Shorthand for mkJsonConfig when you have a typedSettings + extraSettings pattern.
  #
  # Example:
  #   home.file = configHelpers.mkTypedJsonFile {
  #     path = "Library/Application Support/Cursor/User/settings.json";
  #     typedSettings = { "cursor.ai.model" = "opus"; };
  #     extraSettings = cfg.settings;
  #   };
  mkTypedJsonFile = {
    path,
    typedSettings,
    extraSettings ? {},
  }: {
    ${path}.text = builtins.toJSON (typedSettings // extraSettings);
  };
}
