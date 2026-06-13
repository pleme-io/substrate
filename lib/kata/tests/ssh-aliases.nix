# Tests — kata.ssh-aliases (fleet domains -> ssh_config Host entries).
{
  lib,
  iroha,
  kata,
}:
let
  fleet = kata.mkDomains {
    tld = "example.org";
    locations = {
      rio = "bristol";
      cid = "mobile";
    };
    transports = [ "tailscale" ];
    sshUsers.rio = "ops";
    defaultSshUser = "admin";
  };

  aliases = kata.mkSshAliases { inherit fleet; };
  skipped = kata.mkSshAliases {
    inherit fleet;
    skipHosts = [ "cid" ];
  };
in
{
  emits-four-identities-per-host = {
    # bare, .local, primary FQDN, one transport FQDN = 4 per host, 2 hosts.
    expr = builtins.length (builtins.attrNames aliases);
    expected = 8;
  };
  bare-name-entry = {
    expr = aliases.rio;
    expected = {
      hostname = "rio";
      user = "ops";
      disableHostKeyChecking = true;
    };
  };
  local-mdns-entry = {
    expr = aliases."rio.local".hostname;
    expected = "rio.local";
  };
  primary-fqdn-entry = {
    expr = aliases."rio.bristol.example.org".hostname;
    expected = "rio.bristol.example.org";
  };
  transport-fqdn-entry = {
    expr = aliases."rio.tailscale.example.org".hostname;
    expected = "rio.tailscale.example.org";
  };
  user-defaults-applied = {
    expr = {
      rio = aliases.rio.user;
      cid = aliases.cid.user;
    };
    expected = {
      rio = "ops";
      cid = "admin";
    };
  };
  tofu-free-policy = {
    expr = builtins.all (e: e.disableHostKeyChecking) (builtins.attrValues aliases);
    expected = true;
  };
  skip-hosts-omits-all-identities = {
    expr = {
      total = builtins.length (builtins.attrNames skipped);
      noCidBare = !(skipped ? cid);
      noCidFqdn = !(skipped ? "cid.mobile.example.org");
    };
    expected = {
      total = 4;
      noCidBare = true;
      noCidFqdn = true;
    };
  };
  shape-matches-extraHosts = {
    # every value carries exactly { hostname, user, disableHostKeyChecking }.
    expr = builtins.all (
      e: builtins.sort builtins.lessThan (builtins.attrNames e) == [ "disableHostKeyChecking" "hostname" "user" ]
    ) (builtins.attrValues aliases);
    expected = true;
  };
}
