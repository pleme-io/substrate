# Home-manager helpers for CLAUDE.md deployment at every directory level
#
# Parallel to flake-fragment-helpers.nix — provides a composable registry
# for CLAUDE.md files with dynamic section injection.
#
# Usage (in aggregator):
#   claudeMdHelpers = import "${substrate}/lib/hm/claude-md-helpers.nix" { lib = nixpkgs.lib; };
#   imports = [ (claudeMdHelpers.mkClaudeMdModule {}) ];
#
# Usage (in component modules):
#   blackmatter.claudeMdFiles."code/github/pleme-io" = [
#     (claudeMdLib.mkStaticDoc { id = "pleme-org"; source = ../docs/pleme-io-CLAUDE.md; })
#   ];
{ lib }:
with lib;
let
  # ── Option Types ──────────────────────────────────────────────────────

  claudeMdEntryType = types.submodule {
    options = {
      id = mkOption {
        type = types.str;
        description = "Unique identifier for this content contribution";
      };
      priority = mkOption {
        type = types.int;
        default = 50;
        description = "Priority (higher wins when multiple sources contribute to the same path)";
      };
      source = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to the base CLAUDE.md file";
      };
      text = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Inline CLAUDE.md content (alternative to source)";
      };
      dynamicSections = mkOption {
        type = types.attrsOf types.str;
        default = {};
        description = ''
          Dynamic sections to inject. Keys are heading markers (e.g. "## Adding a New Org"),
          values are content to insert BEFORE that heading.
        '';
      };
    };
  };

  # ── Content Assembly ──────────────────────────────────────────────────

  # Inject dynamic sections into a base document.
  # For each heading in dynamicSections, splits the doc at that heading
  # and inserts the content before it.
  injectSections = baseText: dynamicSections:
    foldl' (doc: heading:
      let
        content = dynamicSections.${heading};
        parts = splitString heading doc;
      in
        if length parts == 2
        then (elemAt parts 0) + content + "\n" + heading + (elemAt parts 1)
        else doc  # heading not found, leave unchanged
    ) baseText (attrNames dynamicSections);

  # Resolve a single entry to its final text content
  resolveEntry = entry:
    let
      baseText =
        if entry.source != null then builtins.readFile entry.source
        else if entry.text != null then entry.text
        else "";
    in
      if entry.dynamicSections == {} then baseText
      else injectSections baseText entry.dynamicSections;

  # Merge entries for a single path — highest priority wins as base,
  # dynamic sections from all entries are merged
  mergeEntries = entries: let
    sorted = sort (a: b: a.priority > b.priority) entries;
    base = head sorted;
    allSections = foldl' (acc: e: acc // e.dynamicSections) {} (reverseList sorted);
  in
    resolveEntry (base // { dynamicSections = allSections; });

  # ── Builders ──────────────────────────────────────────────────────────

  mkStaticDoc = { id, source, priority ? 50 }: {
    inherit id priority source;
    text = null;
    dynamicSections = {};
  };

  mkDynamicDoc = { id, source, dynamicSections, priority ? 50 }: {
    inherit id priority source dynamicSections;
    text = null;
  };

  mkInlineDoc = { id, text, priority ? 50 }: {
    inherit id priority text;
    source = null;
    dynamicSections = {};
  };

in {
  inherit claudeMdEntryType;
  inherit mkStaticDoc mkDynamicDoc mkInlineDoc;

  # ── Module Factory ───────────────────────────────────────────────────
  mkClaudeMdModule = {}: args @ { config, ... }: let
    cfg = config.blackmatter.claudeMdFiles;
  in {
    options.blackmatter.claudeMdFiles = mkOption {
      type = types.attrsOf (types.listOf claudeMdEntryType);
      default = {};
      description = ''
        Registry of CLAUDE.md files, keyed by path relative to $HOME.
        Any blackmatter module can contribute content to any directory.
        Multiple contributions are merged by priority (highest wins as base doc).

        Example:
          blackmatter.claudeMdFiles."code/github/pleme-io" = [
            (claudeMdLib.mkStaticDoc { id = "pleme-org"; source = ./docs/pleme-io-CLAUDE.md; })
          ];
      '';
    };

    config._module.args.claudeMdLib = {
      inherit mkStaticDoc mkDynamicDoc mkInlineDoc;
    };

    config.home.file = mkIf (cfg != {}) (
      mapAttrs' (path: entries:
        let
          filePath = if path == "" then "CLAUDE.md" else "${path}/CLAUDE.md";
          content = mergeEntries entries;
        in nameValuePair filePath { text = content; }
      ) cfg
    );
  };
}
