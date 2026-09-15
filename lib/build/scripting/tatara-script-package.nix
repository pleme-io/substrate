# substrate/lib/build/scripting/tatara-script-package.nix
#
# mkTataraScriptPackage — wire a `.tlisp` file into an INSTALLABLE package:
# a derivation with `bin/<name>` that runs `tatara-script <src>/<path> "$@"`.
#
# The sibling of `tatara-script.nix` (mkTataraScript), which returns a flake
# APP. mkTataraScript builds its runner through this function, so an app and
# a package made from the same arguments run the same wrapper derivation.
#
# ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
# mkTataraScript always built this derivation, but returned only
# `{ type = "app"; program = …; }`, so a `.tlisp` tool could be `nix run` but
# never put on PATH by `environment.systemPackages` / `home.packages`. The
# first consumer to need both (pleme-io/nix's `mekakushi`, 2026-09-15) would
# otherwise have re-typed the wrapper. Adding a `package` key to the app
# attrset instead was rejected: every consumer's `apps.<name>` would carry an
# attribute the flake apps schema does not define.
#
# Usage:
#
#   let
#     mkTataraScriptPackage = import "${substrate}/lib/build/scripting/tatara-script-package.nix" {
#       inherit pkgs system;
#       tataraLisp = inputs.tatara-lisp;
#     };
#   in {
#     packages.discover-imports = mkTataraScriptPackage {
#       name = "discover-imports";
#       src = ./.;
#       path = "bin/discover-imports.tlisp";
#     };
#   }
#
# Arguments: `name`, `src`, `path`, `extraPath`, `env` — identical in meaning
# to mkTataraScript's (see tatara-script.nix). `description` is an app-only
# field and is not accepted here.

{ pkgs, tataraLisp, system }:

{
  name,
  src,
  path,
  extraPath ? [],
  env ? {},
}:

let
  tataraScript = tataraLisp.packages.${system}.tatara-script;
  envExports = pkgs.lib.concatStringsSep "\n"
    (pkgs.lib.mapAttrsToList (k: v: "export ${k}=${pkgs.lib.escapeShellArg v}") env);
  pathPrefix = pkgs.lib.makeBinPath (extraPath ++ [ tataraScript ]);
in
pkgs.writeShellApplication {
  name = name;
  text = ''
    export PATH=${pathPrefix}:$PATH
    ${envExports}
    exec ${tataraScript}/bin/tatara-script ${src}/${path} "$@"
  '';
}
