# npm Tool Builder
#
# Reusable pattern for building npm-packaged CLI tools from upstream
# (third-party / vendor) source — the npm sibling of ../go/tool.nix's
# mkGoTool. pleme-io's OWN TypeScript is built via typescript/library.nix
# + typescript-tool.nix; this builder is for wrapping an EXTERNAL npm CLI
# unmodified (caller supplies `src`, typically `pkgs.fetchFromGitHub`).
#
# Usage (standalone):
#   npmToolBuilder = import "${substrate}/lib/build/npm/tool.nix";
#   openwiki = npmToolBuilder.mkNpmTool pkgs {
#     pname = "openwiki";
#     version = "0.0.2";
#     src = pkgs.fetchFromGitHub {
#       owner = "langchain-ai"; repo = "openwiki"; rev = "...";
#       hash = "sha256-...";
#     };
#     npmDepsHash = "sha256-...";
#   };
#
# Usage (via substrate lib):
#   substrateLib = substrate.libFor { inherit pkgs system; };
#   openwiki = substrateLib.mkNpmTool { ... };
{
  # Build an npm-packaged CLI tool from upstream source.
  #
  # Required attrs:
  #   pname       — package name
  #   version     — version string
  #   src         — source derivation (fetchFromGitHub, etc.)
  #   npmDepsHash — hash of npm dependencies (`prefetch-npm-deps
  #                 package-lock.json`, or the standard nixpkgs
  #                 hash-mismatch-on-first-build dance)
  #
  # Optional attrs:
  #   binName         — bin/<name> entry exposed as meta.mainProgram
  #                     (default: pname)
  #   nodejs          — Node interpreter (default: pkgs.nodejs_22)
  #   npmBuildScript  — npm script to run (default: null — most CLIs ship
  #                     pre-built `dist/`; set when the tool needs `npm run build`)
  #   npmFlags        — extra npm install flags (default: [])
  #   dontNpmBuild    — skip the npm build phase (default: npmBuildScript == null)
  #   quirks          — typed NpmQuirk values (see ./quirk-apply.nix) dispatched
  #                      to extra buildNpmPackage attrs — the same mechanical
  #                      quirk-dispatch shape gomod/rust/poetry/ansible/helm use.
  #   engineAssert    — enforce package.json's engines.node against `nodejs`
  #                     at eval time (default: true)
  #   doCheck         — run tests (default: false)
  #   extraBuildInputs — additional nativeBuildInputs
  #   extraAttrs      — any extra attrs passed to buildNpmPackage (wins over quirks)
  #   description     — package description for meta
  #   homepage        — package homepage URL for meta
  #   license         — license (default: lib.licenses.mit)
  #   platforms       — supported platforms (default: lib.platforms.all)
  mkNpmTool = pkgs: {
    pname,
    version,
    src,
    npmDepsHash,
    binName ? pname,
    nodejs ? pkgs.nodejs_22,
    npmBuildScript ? null,
    npmFlags ? [],
    dontNpmBuild ? npmBuildScript == null,
    quirks ? [],
    engineAssert ? true,
    doCheck ? false,
    extraBuildInputs ? [],
    extraAttrs ? {},
    description ? "${pname} - CLI tool",
    homepage ? null,
    license ? pkgs.lib.licenses.mit,
    platforms ? pkgs.lib.platforms.all,
  }: let
    lib = pkgs.lib;

    check = import ../../types/assertions.nix;
    _ = check.all [
      (check.nonEmptyStr "pname" pname)
      (check.nonEmptyStr "version" version)
      (check.nonEmptyStr "npmDepsHash" npmDepsHash)
      (check.list "npmFlags" npmFlags)
      (check.list "quirks" quirks)
      (check.bool "doCheck" doCheck)
      (check.list "extraBuildInputs" extraBuildInputs)
      (check.attrs "extraAttrs" extraAttrs)
    ];

    quirkApply = import ./quirk-apply.nix { inherit lib; };
    quirkAttrs = quirkApply.applyQuirks quirks {};

    # package.json's engines.node is the tool's own compatibility contract
    # (e.g. OpenWiki declares ">=20"). Assert the pinned `nodejs` satisfies it
    # at EVAL time instead of failing deep inside `npm install` with a cryptic
    # EBADENGINE, mirroring mkGoTool's goVersionAssert. A range syntax the
    # naive leading-integer parse can't handle skips the assertion rather
    # than false-failing on it.
    engineNodeAssert =
      if !engineAssert then null
      else
        let
          pkgJsonPath = "${src}/package.json";
          read = builtins.tryEval (builtins.fromJSON (builtins.readFile pkgJsonPath));
          req = if read.success then (read.value.engines.node or null) else null;
          nodeMajor = lib.versions.major nodejs.version;
          reqMajor =
            if req == null then null
            else
              let m = builtins.match "[^0-9]*([0-9]+).*" req;
              in if m == null then null else lib.head m;
        in
        if reqMajor != null && builtins.compareVersions reqMajor nodeMajor > 0
        then throw ("substrate.mkNpmTool: ${pname}'s package.json requires node "
          + "${req} but the pinned nodejs is ${nodejs.version}. Pass a newer "
          + "`nodejs` (e.g. pkgs.nodejs_22).")
        else null;

  in builtins.seq engineNodeAssert (pkgs.buildNpmPackage ({
    inherit pname version src npmDepsHash doCheck npmFlags dontNpmBuild nodejs;

    nativeBuildInputs = extraBuildInputs;

    meta = {
      inherit description license platforms;
      mainProgram = binName;
    } // lib.optionalAttrs (homepage != null) { inherit homepage; };
  }
  // lib.optionalAttrs (npmBuildScript != null) { inherit npmBuildScript; }
  // quirkAttrs
  // extraAttrs));

  # Create a Nix overlay that provides multiple npm tools.
  mkNpmToolOverlay = toolDefs: final: prev: let
    mkNpmTool' = import ./tool.nix;
  in builtins.mapAttrs
    (name: def: mkNpmTool'.mkNpmTool final def)
    toolDefs;
}
