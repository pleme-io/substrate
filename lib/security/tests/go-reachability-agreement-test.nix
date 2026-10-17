{ pkgs, tataraScript }:
let
  reach = import ../go-reachability.nix { inherit pkgs; };

  mkFixture = { pname, ldflags }: pkgs.buildGoModule {
    inherit pname ldflags;
    version = "0";
    src = ./go-reachability/fixture;
    vendorHash = "sha256-APfTngWgXEPs8ldsn/euypGMimD7iqI6EniCHj8HeHQ=";
    env.CGO_ENABLED = "0";
  };

  linked = mkFixture { pname = "go-reachability-linked"; ldflags = [ ]; };
  stripped = mkFixture { pname = "go-reachability-stripped"; ldflags = [ "-s" "-w" ]; };

  image = pkgs.dockerTools.buildImage {
    name = "go-reachability-fixture";
    tag = "0";
    copyToRoot = [
      (pkgs.linkFarm "go-reachability-fixtures" [
        { name = "linked"; path = linked; }
        { name = "stripped"; path = stripped; }
      ])
    ];
  };

  inImage = drv: pkgs.lib.removePrefix "/" "${drv}/bin/go-reachability-fixture";
in
pkgs.runCommand "go-reachability-agreement"
{
  nativeBuildInputs = [ tataraScript pkgs.jq pkgs.gnutar pkgs.gzip pkgs.coreutils ];
  GOVULNCHECK = "${reach.govulncheck}/bin/govulncheck";
  GO_REACHABILITY_DB = "file://${./go-reachability/vulndb}";
} ''
  export HOME=$TMPDIR
  tatara-script ${./go-reachability/agreement.tlisp} ${reach.script} ${image} ${inImage linked} ${inImage stripped} $out
''
