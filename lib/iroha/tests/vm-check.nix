# Tests — iroha.vm-check (spec pass-through, extraConfig merge, typed throws).
#
# Pure-eval by construction: pkgs is a STUB whose testers.runNixOSTest
# returns an inspectable attrset instead of building a derivation, so the
# suite proves the invocation shape without ever touching QEMU.
{ lib, iroha }:
let
  inherit (iroha) mkVmCheck;

  linuxStub = {
    stdenv.hostPlatform.isLinux = true;
    testers.runNixOSTest = spec: {
      stub = "vm-test";
      inherit spec;
    };
  };
  darwinStub = {
    stdenv.hostPlatform.isLinux = false;
  };

  serverModule = {
    services.nginx.enable = true;
  };
  clientModule = {
    networking.firewall.enable = false;
  };

  okSpec = {
    name = "boot-serves";
    nodes.machine = serverModule;
    testScript = "machine.wait_for_unit('nginx.service')";
  };

  okResult = mkVmCheck okSpec linuxStub;

  multiResult = mkVmCheck {
    name = "multi";
    nodes = {
      server = serverModule;
      client = clientModule;
    };
    testScript = "server.start(); client.start()";
  } linuxStub;

  mergedResult = mkVmCheck (okSpec // { extraConfig.skipTypeCheck = true; }) linuxStub;

  overrideResult = mkVmCheck (okSpec // { extraConfig.name = "renamed"; }) linuxStub;
in
{
  # ── spec pass-through ───────────────────────────────────────────────
  invokes-run-nixos-test = {
    expr = okResult.stub;
    expected = "vm-test";
  };
  name-passes-through-verbatim = {
    expr = okResult.spec.name;
    expected = "boot-serves";
  };
  nodes-pass-through-verbatim = {
    expr = okResult.spec.nodes.machine;
    expected = serverModule;
  };
  test-script-passes-through-verbatim = {
    expr = okResult.spec.testScript;
    expected = "machine.wait_for_unit('nginx.service')";
  };
  multi-node-names-preserved = {
    expr = builtins.sort builtins.lessThan (builtins.attrNames multiResult.spec.nodes);
    expected = [
      "client"
      "server"
    ];
  };
  spec-stage-returns-pkgs-function = {
    expr = builtins.isFunction (mkVmCheck okSpec);
    expected = true;
  };

  # ── extraConfig merge ───────────────────────────────────────────────
  extra-config-defaults-to-empty = {
    expr = builtins.sort builtins.lessThan (builtins.attrNames okResult.spec);
    expected = [
      "name"
      "nodes"
      "testScript"
    ];
  };
  extra-config-merges-into-invocation = {
    expr = mergedResult.spec.skipTypeCheck;
    expected = true;
  };
  extra-config-merge-keeps-base-keys = {
    expr = mergedResult.spec.name == "boot-serves" && mergedResult.spec ? nodes && mergedResult.spec ? testScript;
    expected = true;
  };
  extra-config-wins-on-collision = {
    expr = overrideResult.spec.name;
    expected = "renamed";
  };

  # ── platform gate ───────────────────────────────────────────────────
  darwin-pkgs-throws = {
    expr = (builtins.tryEval (mkVmCheck okSpec darwinStub)).success;
    expected = false;
  };
  stdenv-less-pkgs-throws = {
    # `isLinux or false` treats a missing stdenv path as non-Linux.
    expr = (builtins.tryEval (mkVmCheck okSpec { })).success;
    expected = false;
  };

  # ── typed spec throws (eager — fire before pkgs binds) ──────────────
  missing-name-throws = {
    expr = (builtins.tryEval (mkVmCheck (builtins.removeAttrs okSpec [ "name" ]))).success;
    expected = false;
  };
  missing-nodes-throws = {
    expr = (builtins.tryEval (mkVmCheck (builtins.removeAttrs okSpec [ "nodes" ]))).success;
    expected = false;
  };
  missing-test-script-throws = {
    expr = (builtins.tryEval (mkVmCheck (builtins.removeAttrs okSpec [ "testScript" ]))).success;
    expected = false;
  };
  empty-nodes-throws = {
    expr = (builtins.tryEval (mkVmCheck (okSpec // { nodes = { }; }))).success;
    expected = false;
  };
  non-string-name-throws = {
    expr = (builtins.tryEval (mkVmCheck (okSpec // { name = 42; }))).success;
    expected = false;
  };
  non-attrs-nodes-throws = {
    expr = (builtins.tryEval (mkVmCheck (okSpec // { nodes = [ serverModule ]; }))).success;
    expected = false;
  };
  non-string-test-script-throws = {
    expr = (builtins.tryEval (mkVmCheck (okSpec // { testScript = [ "machine.start()" ]; }))).success;
    expected = false;
  };
  non-attrs-extra-config-throws = {
    expr = (builtins.tryEval (mkVmCheck (okSpec // { extraConfig = "skipTypeCheck"; }))).success;
    expected = false;
  };
}
