{ pkgs }:
let
  govulncheckNixpkgs = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/61b7c44c4073f0b827768aff0049561b5110ea5a.tar.gz";
    sha256 = "1knbr9j7szzlppbp0r9rby06nml7b45vqhmskgycfbcnr1nanqnp";
  };
  govulncheck = (import govulncheckNixpkgs { inherit (pkgs.stdenv.hostPlatform) system; }).govulncheck;
  script = ./go-reachability.tlisp;
  path = pkgs.lib.makeBinPath [ pkgs.jq pkgs.gnutar pkgs.gzip pkgs.coreutils ];
in
{
  inherit govulncheck script path;

  bundle = pkgs.linkFarm "go-reachability" [
    { name = "go-reachability.tlisp"; path = script; }
    { name = "bin/govulncheck"; path = "${govulncheck}/bin/govulncheck"; }
  ];

  invoke = { tataraScript, format, report, source, work }:
    ''GOVULNCHECK="${govulncheck}/bin/govulncheck" PATH="${path}:$PATH" ${tataraScript}/bin/tatara-script ${script} ${format} ${report} ${source} ${work}'';
}
