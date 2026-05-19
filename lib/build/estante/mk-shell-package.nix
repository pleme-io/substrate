# mk-shell-package.nix — build one estante shell package.
#
# A "shell package" is a directory containing one or more frost-lisp
# `.lisp` files (canonically `rc.lisp` at the root). It exports
# behaviors via standard def-forms (defalias, defhook, defcompletion,
# defprompt, defbind, …). frost-lisp's `defload` consumes the
# materialized directory by joining `<materialized-path>/<entrypoint>`
# and applying its forms in the outer rc's apply pass.
#
# This builder doesn't compile anything — it's a check-and-stage step.
# The output derivation is just the cleaned source tree, suitable for
# `mk-shell-env` to symlinkJoin into a runtime env.
#
# The check step is intentional and small for v0.1: confirm the
# entrypoint exists. Future hardening could include:
#   - syntax validation via frost-lisp::compile_typed
#   - export-declaration coherence (every (defalias …) :name lands in
#     `exports` if exports is non-empty)
#   - lockfile-shape coherence (deps in shellpkg.lisp match what was
#     pinned in the consumer's lockfile)
{ pkgs }:
let
  lib = pkgs.lib;
in
{
  # Build one shell package as a Nix derivation.
  #
  # Required:
  #   name      — slug, matches `defshellpkg :name`
  #   version   — semver-shape (not enforced for v0.1)
  #   src       — source tree containing the package's rc.lisp
  #
  # Optional:
  #   description  — human-readable; appears in meta
  #   exports      — list of behavior kinds (informational)
  #   entrypoint   — relative path to the rc.lisp inside src (default: "rc.lisp")
  #   license      — defaults to "MIT" matching pleme-io public-repo convention
  mkShellPackage = {
    name,
    version,
    src,
    description ? "estante shell package: ${name}",
    exports ? [],
    entrypoint ? "rc.lisp",
    license ? lib.licenses.mit,
    ...
  }:
    let
      sanitized = lib.removePrefix "estante-pkg-"
        (lib.replaceStrings [ "/" ] [ "-" ] name);
    in pkgs.stdenv.mkDerivation {
      pname = "estante-pkg-${sanitized}";
      inherit version src;
      strictDeps = true;

      dontConfigure = true;
      dontBuild = true;

      installPhase = ''
        runHook preInstall

        if [ ! -e "${entrypoint}" ]; then
          echo "estante mkShellPackage: entrypoint '${entrypoint}' not found in source tree" >&2
          exit 1
        fi

        mkdir -p $out
        cp -R . $out/

        # Drop a manifest stub Nix consumers can introspect without
        # parsing Lisp.
        cat > $out/.estante-manifest.json <<EOF
        {
          "name": "${name}",
          "version": "${version}",
          "entrypoint": "${entrypoint}",
          "exports": [${
            lib.concatMapStringsSep ", " (e: "\"${e}\"") exports
          }]
        }
        EOF

        runHook postInstall
      '';

      meta = {
        inherit description license;
        # Expose the typed-attrs at meta.estante for downstream tools
        # (build inventories, drift detectors) without re-parsing the
        # manifest JSON.
        estante = {
          shellPackage = {
            inherit name version exports entrypoint;
          };
        };
      };

      passthru = {
        estanteName = name;
        estanteVersion = version;
        estanteEntrypoint = entrypoint;
        estanteExports = exports;
      };
    };
}
