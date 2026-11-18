# blue builders: the family evaluates with a stub toolchain and refuses the
# arguments it cannot work without. Eval-only: nothing here builds blue.
{ pkgs }:
let
  inherit (pkgs) lib;
  stubJoin = args: args;
  stubRun = _name: _attrs: _script: "built";
  builders = (import ../build/blue { }).bidamas {
    inherit lib;
    runCommand = stubRun;
    symlinkJoin = stubJoin;
    makeBinaryWrapper = "wrapper";
  };
  joined = builders.mkBluePath {
    bidamas = {
      a = "pa";
      b = "pb";
    };
  };
  noJoin = (import ../build/blue { }).bidamas {
    inherit lib;
    runCommand = stubRun;
  };
  refused = builtins.tryEval (noJoin.mkBluePath { bidamas = { }; }).paths;
  results = {
    joinsEveryBidamaIntoOnePath = joined.paths == [
      "pa"
      "pb"
    ];
    namesThePathBlueDash = joined.name == "blue-path";
    refusesWithoutSymlinkJoin = !refused.success;
  };
in
pkgs.runCommand "blue-builders-test" { } ''
  ${lib.concatStringsSep "\n" (
    lib.mapAttrsToList (n: ok: if ok then "echo ok ${n}" else "echo FAIL ${n}; exit 1") results
  )}
  touch $out
''
