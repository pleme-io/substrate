# mk-shell-env.nix — materialize a full estante lockfile into one
# derivation suitable for `frost-lisp::defload` consumption.
#
# Returns a `symlinkJoin`-shaped derivation whose `$out` contains:
#
#   $out/store/<name>/rc.lisp              ← one tree per package
#   $out/store/<name>/...
#   $out/shellpkg.lock.nix                 ← the lockfile, for tooling
#   $out/shellpkg.lock.lisp                ← (if provided) the original
#                                            Lisp lockfile authors authored
#
# Consumer frostrc.lisp shape:
#
#   (defsource :path "/nix/store/.../shellpkg.lock.lisp")
#   (defload   :pkg "you-should-use")
#
# The `materialized-path` for each entry in shellpkg.lock.lisp points
# at `$out/store/<name>/`, so the chain hangs together: estante install
# pre-computes everything, frost-lisp reads the lockfile, defload
# resolves the materialized path inside this derivation.
{ pkgs }:
let
  lib = pkgs.lib;
  loader = import ./lockfile-loader.nix { inherit lib; };

  # Split `github:owner/repo` (or `github:owner/repo@ref`) into the
  # parts fetchFromGitHub wants.
  parseGithubSource = source:
    let
      stripped = lib.removePrefix "github:" source;
      withoutRef = lib.head (lib.splitString "@" stripped);
      parts = lib.splitString "/" withoutRef;
    in
      if lib.length parts < 2
      then throw "mk-shell-env: malformed github source `${source}` — expected `github:owner/repo[@ref]`"
      else { owner = lib.elemAt parts 0; repo = lib.elemAt parts 1; };

  # Synthesize a fetch derivation for one locked package entry.
  fetchPkg = entry:
    if lib.hasPrefix "github:" entry.source then
      let
        gh = parseGithubSource entry.source;
        hash = if entry.narHash != "" then entry.narHash else lib.fakeHash;
      in
        pkgs.fetchFromGitHub {
          inherit (gh) owner repo;
          rev = entry.rev;
          inherit hash;
        }
    else if lib.hasPrefix "local:" entry.source then
      # local: sources expand to the absolute path on disk. The Nix
      # store can pick this up via `lib.path.cleanedNixSource` but for
      # now we just fetchTarball the directory.
      let
        path = lib.removePrefix "local:" entry.source;
      in lib.cleanSource (/. + path)
    else
      throw "mk-shell-env: source scheme not yet supported by the Nix bridge: ${entry.source}";

  # Build one mkShellPackage derivation per entry.
  mkPkg = entry: ((import ./mk-shell-package.nix { inherit pkgs; }).mkShellPackage {
    inherit (entry) name exports entrypoint;
    version = if entry.rev == "" then "0.0.0" else entry.rev;
    src = fetchPkg entry;
  });
in
{
  inherit fetchPkg;

  mkPackageDerivation = mkPkg;

  # Materialize every package in `lockfile` into one symlinked tree.
  #
  # Required:
  #   lockfile  — path to shellpkg.lock.nix OR an already-imported attrset.
  #
  # Optional:
  #   name      — derivation name (default: "estante-shell-env").
  #   extraIncludes — list of `{ name, src }` pairs to additionally include
  #                   (e.g. project-local rc.lisp files outside the lockfile).
  mkShellEnv = {
    lockfile,
    name ? "estante-shell-env",
    extraIncludes ? [],
    ...
  }:
    let
      loaded = loader.loadLockfile lockfile;
      pkgsList = map (e: { inherit (e) name; drv = mkPkg e; }) loaded.packages;
      extraDrvs = map (e: e // { drv = e.src; }) extraIncludes;

      allEntries = pkgsList ++ extraDrvs;
    in pkgs.symlinkJoin {
      inherit name;
      paths = map (e: e.drv) allEntries;
      postBuild = ''
        # Re-layout: each package gets its own subdir under $out/store/
        # so frost-lisp's defload can address them by name.
        rm -f $out/.estante-manifest.json
        mkdir -p $out/store
        ${lib.concatMapStringsSep "\n" (e: ''
          mkdir -p $out/store/${e.name}
          cp -RL ${e.drv}/. $out/store/${e.name}/
        '') allEntries}

        # Drop a Nix-side manifest so consumers can introspect.
        cat > $out/.estante-env.json <<EOF
        {
          "schemaVersion": 1,
          "packages": [${
            lib.concatMapStringsSep ", " (e:
              "{\"name\": \"${e.name}\", \"path\": \"$out/store/${e.name}\"}"
            ) allEntries
          }]
        }
        EOF
      '';

      meta = {
        description = "estante materialized shell environment (${toString (lib.length allEntries)} packages)";
        # The estante metadata is a top-level concern — surface it so
        # higher-level tools (HM modules, fleet inventories) can pull
        # the package list without parsing JSON.
        estante = {
          envContents = map (e: e.name) allEntries;
        };
      };
    };
}
