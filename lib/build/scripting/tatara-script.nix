# substrate/lib/build/scripting/tatara-script.nix
#
# mkTataraScript — wire a `.tlisp` file into a flake's apps output as a
# first-class `nix run .#<name>` target. Replaces bash wrappers in
# nix-run app declarations.
#
# Usage (from a consumer flake):
#
#   let
#     tataraLisp = inputs.tatara-lisp;  # or fetchTarball/fetchFlake
#     mkTataraScript = import "${substrate}/lib/build/scripting/tatara-script.nix" {
#       inherit pkgs tataraLisp system;
#     };
#   in {
#     apps.discover-imports = mkTataraScript {
#       name = "discover-imports";
#       src = ./.;
#       path = "bin/discover-imports.tlisp";
#     };
#   }
#
# What you get:
#
#   - `nix run .#discover-imports` runs `tatara-script <src>/<path>`
#   - script inherits $PATH, $HOME, $PWD from the calling shell
#   - positional args land in `(argv)` inside the script
#   - CLOUDFLARE_* / AWS_PROFILE / etc are available via `(env-get "NAME")`
#
# Arguments:
#
#   name    — the flake app key (what goes after `#` in nix run)
#   src     — a directory (flake self or a subpath); the script resolves
#             relative to this
#   path    — relative path under `src` to the .tlisp file
#   extraPath — optional list of packages to prepend to PATH inside the
#               runner (e.g. [ pkgs.jq pkgs.curl ] if your script shells
#               out to them despite the tlisp stdlib covering most cases)
#   env     — optional attrset of env-var bindings set before exec
#             (alternative to `export FOO=bar; tatara-script ...`)
#
# Returns an `apps.<system>.<name>` flake output shape: `{ type = "app";
# program = "/nix/store/.../bin/<name>"; }`. The underlying wrapper is a
# tiny shell script that sets PATH + env then exec's tatara-script on
# the .tlisp path.

{ pkgs, tataraLisp, system }:

{
  name,
  src,
  path,
  extraPath ? [],
  env ? {},
  description ? "tatara-script runner for ${path}",
}:

let
  tataraScript = tataraLisp.packages.${system}.tatara-script;
  envExports = pkgs.lib.concatStringsSep "\n"
    (pkgs.lib.mapAttrsToList (k: v: "export ${k}=${pkgs.lib.escapeShellArg v}") env);
  pathPrefix = pkgs.lib.makeBinPath (extraPath ++ [ tataraScript ]);
  wrapper = pkgs.writeShellApplication {
    name = name;
    text = ''
      export PATH=${pathPrefix}:$PATH
      ${envExports}
      exec ${tataraScript}/bin/tatara-script ${src}/${path} "$@"
    '';
  };
in {
  type = "app";
  program = "${wrapper}/bin/${name}";
  meta.description = description;
}
