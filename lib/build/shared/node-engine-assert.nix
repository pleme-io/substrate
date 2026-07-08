# node-engine-assert.nix — eval-time assertion that a pinned `nodejs`
# satisfies a package.json's `engines.node` constraint. Shared by
# ../npm/tool.nix (mkNpmTool) and ../npm/pnpm-tool.nix (mkPnpmTool) so
# the same coarse-major-version check isn't duplicated per builder.
#
# Mirrors mkGoTool's goVersionAssert (build/go/tool.nix): fail at EVAL
# time with a clear message, instead of deep inside a package-manager
# install step with a cryptic EBADENGINE.
{ lib }:
{
  # Returns null on pass, throws on fail. `caller` names the builder in
  # the thrown message so the operator knows which one to fix. A range
  # syntax the naive leading-integer parse can't handle skips the
  # assertion rather than false-failing on it.
  assertNodeEngine =
    {
      caller,
      pname,
      src,
      nodejs,
      packageJsonPath ? "package.json",
    }:
    let
      pkgJsonPath = "${src}/${packageJsonPath}";
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
    then throw ("substrate.${caller}: ${pname}'s package.json requires node "
      + "${req} but the pinned nodejs is ${nodejs.version}. Pass a newer "
      + "`nodejs` (e.g. pkgs.nodejs_22).")
    else null;
}
