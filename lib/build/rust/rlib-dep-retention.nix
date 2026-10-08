{ lib }:
{
  fileName = "propagated-rlib-deps";

  postInstallFor = depDrvs:
    let paths = lib.unique (map (d: "${d.lib}") depDrvs);
    in lib.optionalString (paths != [ ]) ''
      mkdir -p "$lib/nix-support"
      printf '%s\n' ${lib.concatMapStringsSep " " lib.escapeShellArg paths} > "$lib/nix-support/propagated-rlib-deps"
    '';
}
