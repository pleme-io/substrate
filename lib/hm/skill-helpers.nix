# Home-manager skill deployment helpers
#
# Reusable pattern for any agent that bundles skills (Claude Code, OpenCode, etc.).
# Provides auto-discovery from a skills/ directory, option declarations,
# and home.file deployment config. The `basePath` parameter controls where
# skills are deployed (default: `.claude/skills` for backward compat).
#
# Usage (in flake.nix):
#   homeManagerModules.default = import ./module {
#     skillHelpers = import "${substrate}/lib/hm-skill-helpers.nix" { lib = nixpkgs.lib; };
#   };
#
# Usage (in module/default.nix):
#   { skillHelpers }: { lib, config, pkgs, ... }:
#   let
#     skills = skillHelpers.mkSkills {
#       skillsDir = ../skills;
#       extraSkills = cfg.skills.extraSkills;
#       basePath = ".config/opencode/skills";  # agent-specific deployment path
#     };
#   in {
#     options.myModule.skills = skillHelpers.mkSkillOptions;
#     config = lib.mkIf cfg.skills.enable {
#       home.file = skills.homeFiles;
#     };
#   };
#
# Standalone usage (no substrate lib, just import the file):
#   skillHelpers = import "${substrate}/lib/hm-skill-helpers.nix" { lib = nixpkgs.lib; };
{ lib }:
with lib;
let
  # A skill directory may ship assets beside SKILL.md (a driver.js, an assets/
  # or docs/ subtree). These are junk to never deploy.
  isSkillJunk = n:
    hasSuffix "~" n || hasSuffix ".backup" n || hasSuffix ".swp" n
    || n == ".DS_Store" || n == ".git";

  # Build home.file entries for a set of skills, shipping SKILL.md AND every
  # asset in each skill directory. `sourceFor name entry` returns the byte
  # source for one top-level entry — a PATH for the source dir, or a store-path
  # STRING for a gated derivation. Directory entries (assets/, docs/) are linked
  # recursively. SKILL.md is emitted as an explicit per-file key so a federation
  # regex matching `<name>/SKILL.md` on config.home.file still resolves, and its
  # source is byte-identical to the pre-asset mapping (no re-link for the ~all
  # skills that carry only a SKILL.md).
  mkSkillHomeFiles = {
    skillsDir,
    names,
    sourceFor,
    basePath ? ".claude/skills",
  }:
    let
      entriesFor = name:
        filter (x: ! isSkillJunk x.name)
          (mapAttrsToList (n: t: { name = n; isDir = t == "directory"; })
            (builtins.readDir (skillsDir + "/${name}")));
    in
    foldl' (acc: name:
      acc // listToAttrs (map (x:
        nameValuePair "${basePath}/${name}/${x.name}" (
          { source = sourceFor name x.name; }
          // optionalAttrs x.isDir { recursive = true; }
        )
      ) (entriesFor name))
    ) {} names;
in
{
  # exposed for gate-based consumers (blackmatter-pleme serves skill bytes from a
  # derivation, so it maps names → gate paths itself but reuses this enumerator).
  inherit mkSkillHomeFiles isSkillJunk;

  # Discover skills from a directory and merge with extra skills.
  #
  # Returns:
  #   {
  #     names      — list of all skill names
  #     files      — attrset { name = /path/to/SKILL.md; }
  #     homeFiles  — attrset ready to merge into home.file (SKILL.md + assets)
  #   }
  #
  # skillsDir:   path to the skills/ directory (e.g., ../skills)
  # extraSkills: attrset of additional skill files { name = /path; } (default: {})
  mkSkills = {
    skillsDir,
    extraSkills ? {},
    basePath ? ".claude/skills",
  }: let
    bundledSkillNames =
      if builtins.pathExists skillsDir
      then builtins.attrNames (filterAttrs (_: t: t == "directory") (builtins.readDir skillsDir))
      else [];

    bundledSkillFiles = listToAttrs (map (name:
      nameValuePair name (skillsDir + "/${name}/SKILL.md")
    ) bundledSkillNames);

    allSkillFiles = bundledSkillFiles // extraSkills;

    # bundled skills ship their whole directory (assets included); extraSkills
    # are SKILL.md file paths outside any repo dir, so they stay single-file.
    bundledHomeFiles = mkSkillHomeFiles {
      inherit skillsDir basePath;
      names = bundledSkillNames;
      sourceFor = name: entry: skillsDir + "/${name}/${entry}";
    };
    extraHomeFiles = mapAttrs' (name: path:
      nameValuePair "${basePath}/${name}/SKILL.md" { source = path; }
    ) extraSkills;

    homeFiles = bundledHomeFiles // extraHomeFiles;
  in {
    names = attrNames allSkillFiles;
    files = allSkillFiles;
    inherit homeFiles;
  };

  # Standard option declarations for skill deployment.
  # Merge into your module's options.
  #
  # Returns an attrset with:
  #   enable      — bool (default: true)
  #   extraSkills — attrset of additional skill files
  mkSkillOptions = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Deploy bundled skills to the agent's skills directory.";
    };

    extraSkills = mkOption {
      type = types.attrsOf types.path;
      default = {};
      description = "Additional skill files. Keys are skill names, values are SKILL.md paths.";
    };
  };

  # All-in-one: create the skill deployment config block.
  # Use inside mkIf cfg.enable (mkMerge [ ... ]) alongside other config.
  #
  # Returns an attrset with home.file entries, ready to merge.
  #
  # Example:
  #   config = mkIf cfg.enable (mkMerge [
  #     (mkIf cfg.skills.enable (skillHelpers.mkSkillConfig {
  #       skillsDir = ../skills;
  #       extraSkills = cfg.skills.extraSkills;
  #     }))
  #     # ... other config ...
  #   ]);
  mkSkillConfig = {
    skillsDir,
    extraSkills ? {},
    basePath ? ".claude/skills",
  }: let
    skills = (import ./skill-helpers.nix { inherit lib; }).mkSkills {
      inherit skillsDir extraSkills basePath;
    };
  in {
    home.file = skills.homeFiles;
  };
}
