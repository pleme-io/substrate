# source-policy.nix — which files of a consumer's tree a build reads.
#
# Two typed parameters: `memberSource` (`memberSrc`, below) and `prose`:
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
# The policy applies to what a build DEPLOYS, not to test checks. A test check
# restarts nothing, and a test may read prose (engenho's
# retracted_safety_claims reads docs/*.md), so under "excluded" the Rust
# shapes hand their cargo test check the unfiltered tree (`testSrc`, set in
# flake.nix's callShape). Measured 2026-09-29: before that, engenho's test
# check failed because the filtered tree had no docs/.
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

  memberSourceValues = [ "workspace" "own" ];

  declareHint = crateName: relativePath:
    "declare it in ${relativePath}/Cargo.toml as [package.metadata.substrate] sources = [ \"<path relative to ${relativePath}>\" ], or build with memberSource = \"workspace\"";

  rootRelative = crateName: relativePath: path:
    let
      step = acc: segment:
        if segment == "" || segment == "." then acc
        else if segment == ".." then
          (if acc == [ ] then throw ''
            substrate source-policy: crate `${crateName}` declares source `${path}`, which leaves the workspace root.
            A member build reads only the workspace tree; ${declareHint crateName relativePath} with a path inside it.
          '' else lib.init acc)
        else acc ++ [ segment ];
    in
    lib.concatStringsSep "/" (lib.foldl' step [ ] (lib.splitString "/" path));

  declaredSources = { src, crateName, relativePath }:
    let
      manifest = src + "/${relativePath}/Cargo.toml";
      sources =
        if builtins.pathExists manifest
        then ((builtins.fromTOML (builtins.readFile manifest)).package.metadata.substrate.sources or [ ])
        else [ ];
    in
    if builtins.isList sources && lib.all builtins.isString sources then sources
    else throw ''
      substrate source-policy: ${relativePath}/Cargo.toml [package.metadata.substrate] sources must be a list of strings.
    '';

  memberSrc = { src, crateName, relativePath, memberSource ? "workspace" }:
    assert lib.assertOneOf "substrate source-policy: memberSource" memberSource memberSourceValues;
    let
      member = rootRelative crateName relativePath relativePath;
    in
    if memberSource == "workspace" || member == "" then src
    else
      let
        declared = map
          (p: rootRelative crateName relativePath "${relativePath}/${p}")
          (declaredSources { inherit src crateName relativePath; });
        missing = lib.filter (p: !(builtins.pathExists (src + "/${p}"))) declared;
        kept = [ "Cargo.toml" "Cargo.lock" member ] ++ declared;
        buildOnly = map (d: "${member}/${d}") [ "tests" "benches" "examples" ];
        under = rel: k: rel == k || lib.hasPrefix "${k}/" rel;
        ancestorOf = rel: k: lib.hasPrefix "${rel}/" k;
        reaches = rel: ks: lib.any (k: under rel k || ancestorOf rel k) ks;
        root = toString (src.origSrc or src);
      in
      if missing != [ ] then throw ''
        substrate source-policy: crate `${crateName}` declares sources that do not exist: ${lib.concatStringsSep ", " missing}.
        Fix the path in ${relativePath}/Cargo.toml [package.metadata.substrate] sources (paths are relative to ${relativePath}).
      ''
      else lib.cleanSourceWith {
        inherit src;
        name = "${crateName}-source";
        filter = path: type:
          let rel = lib.removePrefix (root + "/") (toString path);
          in
          (lib.any (under rel) kept || (type == "directory" && lib.any (ancestorOf rel) kept))
          && !(lib.any (under rel) buildOnly && !(reaches rel declared));
      };

  memberFailureHint = { crateName, relativePath, memberSource ? "workspace" }:
    if memberSource == "workspace" then { }
    else {
      failureHook = "echo ${lib.escapeShellArg "substrate: ${crateName} builds from ${relativePath} plus its declared sources (memberSource = \"own\"). If the error above names a missing file outside ${relativePath}, ${declareHint crateName relativePath}."} >&2";
    };
in
{
  inherit proseValues memberSourceValues memberSrc memberFailureHint;

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
