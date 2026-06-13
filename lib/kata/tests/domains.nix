# Tests — kata.domains.
{
  lib,
  iroha,
  kata,
}:
let
  d = kata.mkDomains {
    tld = "example.org";
    locations = {
      rio = "bristol";
      cid = "mobile";
      plo = "natal";
      zek = "natal";
    };
    transports = [ "tailscale" ];
    tailnetIps.rio = "100.96.225.66";
    sshUsers.rio = "ops";
    defaultSshUser = "admin";
  };
in
{
  fqdn-primary = {
    expr = d.fqdn "rio";
    expected = "rio.bristol.example.org";
  };
  fqdn-unknown-host-throws = {
    expr = (builtins.tryEval (d.fqdn "ghost")).success;
    expected = false;
  };
  fqdn-on-transport = {
    expr = d.fqdnOn "rio" "tailscale";
    expected = "rio.tailscale.example.org";
  };
  all-fqdns-primary-then-transports = {
    expr = d.allFqdns "rio";
    expected = [
      "rio.bristol.example.org"
      "rio.tailscale.example.org"
    ];
  };
  zone-fqdn = {
    expr = d.zoneFqdn "natal";
    expected = "natal.example.org";
  };
  hosts-sorted = {
    expr = d.hosts;
    expected = [
      "cid"
      "plo"
      "rio"
      "zek"
    ];
  };
  sites-unique = {
    expr = builtins.sort builtins.lessThan d.sites;
    expected = [
      "bristol"
      "mobile"
      "natal"
    ];
  };
  by-location-groups = {
    expr = d.byLocation.natal;
    expected = [
      "plo"
      "zek"
    ];
  };
  hosts-in-unknown-location-empty = {
    expr = d.hostsIn "atlantis";
    expected = [ ];
  };
  ssh-user-explicit-and-default = {
    expr = {
      rio = d.sshUserFor "rio";
      plo = d.sshUserFor "plo";
    };
    expected = {
      rio = "ops";
      plo = "admin";
    };
  };
  missing-tld-throws = {
    expr = (builtins.tryEval (kata.mkDomains { locations.a = "x"; }).tld).success;
    expected = false;
  };
  invariants-pass-for-good-config = {
    expr = (iroha.mkEvalChecks { name = "d"; tests = d.invariants; }).passed;
    expected = true;
  };
  invariants-fail-on-unknown-tailnet-host = {
    expr =
      (iroha.mkEvalChecks {
        name = "bad";
        tests =
          (kata.mkDomains {
            tld = "t.io";
            locations.a = "x";
            tailnetIps.ghost = "100.1.2.3";
          }).invariants;
      }).passed;
    expected = false;
  };
  invariants-fail-on-transport-location-collision = {
    expr =
      (iroha.mkEvalChecks {
        name = "bad";
        tests =
          (kata.mkDomains {
            tld = "t.io";
            locations.a = "vpn";
            transports = [ "vpn" ];
          }).invariants;
      }).passed;
    expected = false;
  };
  registry-counts = {
    expr = d.registry;
    expected = {
      hostCount = 4;
      siteCount = 3;
      transports = [ "tailscale" ];
    };
  };
}
