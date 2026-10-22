{ lib, root, exports, system }:

let
  testHelpers = import ../test-helpers.nix { inherit lib; };

  rel = p: lib.removePrefix "${toString root}/" (toString p);

  isHarness = p: builtins.match ".*/tests/.*|.*-tests?\\.nix|.*/tests\\.nix|.*/eval-suites\\.nix" p != null;

  codeLines = text:
    lib.imap1 (n: line: { inherit n line; })
      (lib.splitString "\n" text);

  offending = pattern: path:
    map (l: "${rel path}:${toString l.n}: ${lib.trim l.line}")
      (builtins.filter
        (l: builtins.match "[[:space:]]*#.*" l.line == null && builtins.match pattern l.line != null)
        (codeLines (builtins.readFile path)));

  libPattern = ".*(import <|<nixpkgs|(builtins\\.|__)(getEnv|currentSystem|currentTime|nixPath|findFile)).*";
  workflowPattern = ".*(import <|<nixpkgs).*";

  libFiles = builtins.filter (p: lib.hasSuffix ".nix" (toString p) && !isHarness (rel p))
    (lib.filesystem.listFilesRecursive (root + "/lib"));

  workflowFiles = builtins.filter (p: lib.hasSuffix ".yml" (toString p))
    (lib.filesystem.listFilesRecursive (root + "/.github/workflows"));

  scan = pattern: path:
    let hits = offending pattern path;
    in testHelpers.mkTest "no-ambient-read ${rel path}" (hits == [ ])
      "reads the ambient environment; the caller passes the pinned value instead:\n    ${lib.concatStringsSep "\n    " hits}";

  pool = { inherit lib system; devshell = "default"; };
  inert = { strict = false; };

  force = r: if builtins.isAttrs r then lib.all (v: builtins.seq v true) (builtins.attrValues r) else builtins.deepSeq r true;

  evaluate = name: path:
    let
      f = import path;
      declared = builtins.functionArgs f;
      required = lib.attrNames (lib.filterAttrs (_: optional: !optional) declared);
      missing = builtins.filter (a: !(pool ? ${a})) required;
      args = lib.genAttrs required (a: pool.${a}) // builtins.intersectAttrs declared inert;
    in testHelpers.mkTest "export ${name} evaluates with only its required arguments"
      (missing == [ ] && force (f args))
      "required argument(s) with no fixture: ${lib.concatStringsSep ", " missing}";

  pathExports = lib.filterAttrs (n: v: lib.hasSuffix "Path" n && builtins.isPath v) exports;

  tests =
    lib.mapAttrsToList evaluate pathExports
    ++ map (scan libPattern) libFiles
    ++ map (scan workflowPattern) workflowFiles
    ++ [
      (testHelpers.mkTest "exports-are-found" (builtins.length (lib.attrNames pathExports) >= 5)
        "fewer than 5 *Path exports were found; the export probe is blind")
      (testHelpers.mkTest "library-files-are-found" (builtins.length libFiles >= 300)
        "fewer than 300 library files were scanned; the file probe is blind")
      (testHelpers.mkTest "workflow-files-are-found" (builtins.length workflowFiles >= 10)
        "fewer than 10 workflows were scanned; the file probe is blind")
    ];

  result = testHelpers.runTests tests;
in
{
  inherit (result) total passCount failCount allPassed failures summary;
  inherit tests result;
  asCheck = testHelpers.mkAsCheck { name = "no-ambient-nixpkgs-test"; label = "no-ambient-nixpkgs"; } result;
}
