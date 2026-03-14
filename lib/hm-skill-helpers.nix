# Home-manager skill deployment helpers
#
# Reusable pattern for any repo that bundles Claude Code skills.
# Provides auto-discovery from a skills/ directory, option declarations,
# and home.file deployment config.
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
{
  # Discover skills from a directory and merge with extra skills.
  #
  # Returns:
  #   {
  #     names      — list of all skill names
  #     files      — attrset { name = /path/to/SKILL.md; }
  #     homeFiles  — attrset ready to merge into home.file
  #   }
  #
  # skillsDir:   path to the skills/ directory (e.g., ../skills)
  # extraSkills: attrset of additional skill files { name = /path; } (default: {})
  mkSkills = {
    skillsDir,
    extraSkills ? {},
  }: let
    bundledSkillNames =
      if builtins.pathExists skillsDir
      then builtins.attrNames (filterAttrs (_: t: t == "directory") (builtins.readDir skillsDir))
      else [];

    bundledSkillFiles = listToAttrs (map (name:
      nameValuePair name (skillsDir + "/${name}/SKILL.md")
    ) bundledSkillNames);

    allSkillFiles = bundledSkillFiles // extraSkills;

    homeFiles = mapAttrs' (name: path:
      nameValuePair ".claude/skills/${name}/SKILL.md" {
        source = path;
      }
    ) allSkillFiles;
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
      description = "Deploy bundled skills to ~/.claude/skills/";
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
  }: let
    skills = (import ./hm-skill-helpers.nix { inherit lib; }).mkSkills {
      inherit skillsDir extraSkills;
    };
  in {
    home.file = skills.homeFiles;
  };
}
