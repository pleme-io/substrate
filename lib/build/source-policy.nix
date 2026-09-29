# source-policy.nix — which files of a consumer's tree a build reads.
#
# One typed parameter today, `prose`:
#
#   "included"  (default) the tree exactly as given. Today's behaviour; no
#               consumer's derivation changes by adopting this file.
#   "excluded"  drop the top-level `docs/` directory and every top-level
#               `*.md` file, so a documentation edit never changes the
#               derivation, and so never rebuilds (or, on a node, restarts)
#               what the build deploys. Member-level files such as
#               `crates/x/README.md` stay, because `include_str!` on a crate's
#               own README is common; choosing "excluded" asserts that nothing
#               embeds the top-level files.
#
# A new source behaviour is a new value here, not a new filter in a consumer.
# Any unknown value is an eval error naming the accepted ones.
{ lib }:

let
  proseValues = [ "included" "excluded" ];

  topLevelProse = src:
    let
      entries = builtins.readDir src;
      names = builtins.attrNames entries;
      docsDir = lib.optional ((entries.docs or null) == "directory") (src + "/docs");
      markdown = map (n: src + "/${n}")
        (lib.filter (n: entries.${n} == "regular" && lib.hasSuffix ".md" n) names);
    in
    docsDir ++ markdown;
in
{
  inherit proseValues;

  # buildSrc { src, prose ? "included" } -> a source the builders consume.
  # A non-path `src` (already a store path string, a fetched tree) passes
  # through untouched: the policy only reshapes a local flake tree.
  buildSrc = { src, prose ? "included" }:
    assert lib.assertOneOf "substrate source-policy: prose" prose proseValues;
    if prose == "included" || !(builtins.isPath src) then src
    else
      let drop = topLevelProse src;
      in
      if drop == [ ] then src
      else lib.fileset.toSource {
        root = src;
        fileset = lib.fileset.difference src (lib.fileset.unions drop);
      };
}
