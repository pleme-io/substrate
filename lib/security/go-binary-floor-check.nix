{ pkgs }:
let
  pin = builtins.fromJSON (builtins.readFile ../build/go/go-toolchain-pin.json);
in
{
  floor = pin.cveFloor;

  mkGoBinaryFloorCheck =
    {
      name,
      tree,
      expectBinaries,
      floor ? pin.cveFloor,
    }:
    pkgs.runCommand "go-binary-floor-${name}"
      {
        nativeBuildInputs = [ pkgs.go pkgs.jq pkgs.findutils ];
      }
      ''
        find -L ${tree} -type f -exec go version {} + > versions
        jq -Rrn --arg floor ${floor} '[inputs | capture("^(?<f>.+): go(?<v>[0-9.]+)") | select((.v | split(".") | map(tonumber)) < ($floor | split(".") | map(tonumber)))] | .[] | "BELOW FLOOR go\(.v) < ${floor}: \(.f)"' versions > offenders
        cat offenders
        test ! -s offenders
        test "$(jq -Rn '[inputs] | length' versions)" -ge ${toString expectBinaries}
        cp versions $out
      '';
}
