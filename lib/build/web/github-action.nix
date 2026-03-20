# GitHub Action Builder
#
# Builds GitHub Actions that use @vercel/ncc to bundle into dist/.
# Handles the common pattern: npm install → ncc build → copy dist/ + action.yml.
#
# Usage (standalone):
#   actionBuilder = import "${substrate}/lib/github-action.nix";
#   action = actionBuilder.mkGitHubAction pkgs {
#     pname = "akeyless-github-action";
#     src = ./.;
#     npmDepsHash = "sha256-...";
#     entryPoint = "src/index.js";   # ncc compiles this
#   };
#
# Usage (via repo-flake.nix):
#   language = "npm";
#   builder = "action";
#   npmDepsHash = "sha256-...";
{
  # Build a GitHub Action from npm source.
  #
  # Required attrs:
  #   pname       — action name
  #   src         — source derivation
  #   npmDepsHash — hash of npm dependencies
  #
  # Optional attrs:
  #   version         — version string (default: "0.0.0-dev")
  #   entryPoint      — JS entry for ncc (default: "src/index.js")
  #   npmBuildScript   — npm script that runs ncc (default: "package", falls back to "build")
  #   actionYml       — name of the action manifest (default: "action.yml")
  #   extraFiles      — list of extra files/dirs to copy to output
  #   nodeOptions     — NODE_OPTIONS env var (default: null)
  #   npmFlags        — extra npm flags (default: [])
  #   doCheck         — run tests (default: false)
  #   extraAttrs      — additional attrs passed to buildNpmPackage
  #   description     — action description
  #   homepage        — action homepage URL
  #   license         — license (default: lib.licenses.isc)
  #   platforms       — platforms (default: lib.platforms.all)
  mkGitHubAction = pkgs: {
    pname,
    src,
    npmDepsHash,
    version ? "0.0.0-dev",
    entryPoint ? "src/index.js",
    npmBuildScript ? "package",
    actionYml ? "action.yml",
    extraFiles ? [],
    nodeOptions ? null,
    npmFlags ? [],
    doCheck ? false,
    extraAttrs ? {},
    description ? "${pname} - GitHub Action",
    homepage ? null,
    license ? pkgs.lib.licenses.isc,
    platforms ? pkgs.lib.platforms.all,
  }: let
    lib = pkgs.lib;
  in pkgs.buildNpmPackage ({
    inherit pname version src npmDepsHash doCheck;
    dontNpmBuild = false;
    inherit npmBuildScript;

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r dist $out/dist
      cp ${actionYml} $out/
      ${lib.concatMapStringsSep "\n" (f: "cp -r ${f} $out/ 2>/dev/null || true") extraFiles}
      runHook postInstall
    '';

    meta = {
      inherit description license platforms;
    } // lib.optionalAttrs (homepage != null) { inherit homepage; };
  }
  // lib.optionalAttrs (nodeOptions != null) { NODE_OPTIONS = nodeOptions; }
  // lib.optionalAttrs (npmFlags != []) { inherit npmFlags; }
  // extraAttrs);

  # Create an overlay of GitHub Actions from a definitions attrset.
  mkGitHubActionOverlay = actionDefs: final: prev: let
    mkGitHubAction' = (import ./github-action.nix).mkGitHubAction;
  in builtins.mapAttrs
    (name: def: mkGitHubAction' final def)
    actionDefs;
}
