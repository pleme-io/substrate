# Tests — iroha.mcp (mkMcpRegistration: the single anvil MCP registration).
{ lib, iroha }:
let
  inherit (iroha) mkMcpRegistration;

  # Fake derivation — string interpolation needs only outPath, so the
  # suite stays pure-eval with zero pkgs.
  fakeDrv = {
    outPath = "/store/p";
  };

  # Minimal command form: every optional at its default.
  cmdForm = mkMcpRegistration {
    name = "foo";
    command = "/usr/local/bin/foo-mcp";
  };

  # Minimal package form: binaryName defaults to name.
  pkgForm = mkMcpRegistration {
    name = "bar";
    package = fakeDrv;
  };

  # Package form with an explicit binaryName.
  pkgFormNamed = mkMcpRegistration {
    name = "bar";
    package = fakeDrv;
    binaryName = "bar-mcp";
  };

  # Fully-populated command form.
  full = mkMcpRegistration {
    name = "zoekt";
    command = "/store/z/bin/zoekt-mcp";
    args = [ "mcp" "--listen" ];
    env.ZOEKT_URL = "http://localhost:6070";
    envFiles.ZOEKT_TOKEN = "/run/secrets/zoekt-token";
    scopes = [ "pleme" ];
    agents = [ "claude" ];
    hosts = [ "cid" ];
    description = "Zoekt trigram search";
    enable = false;
  };

  anvilPath = [ "blackmatter" "components" "anvil" "mcp" "servers" ];
in
{
  # ── command form ────────────────────────────────────────────────────
  command-form-entry-command-is-given-path = {
    expr = cmdForm.serverEntry.command;
    expected = "/usr/local/bin/foo-mcp";
  };
  command-form-omits-package-key = {
    expr = cmdForm.serverEntry ? package;
    expected = false;
  };
  command-form-meta-command-resolved = {
    expr = cmdForm.meta.command;
    expected = "/usr/local/bin/foo-mcp";
  };

  # ── package form ────────────────────────────────────────────────────
  package-form-entry-command-is-bare-binary = {
    # anvil's _mkCommandPath composes "${package}/bin/${command}" —
    # the entry must carry the BARE name, never a pre-resolved path.
    expr = pkgForm.serverEntry.command;
    expected = "bar";
  };
  package-form-entry-carries-package = {
    expr = pkgForm.serverEntry.package.outPath;
    expected = "/store/p";
  };
  package-form-meta-command-resolved = {
    expr = pkgForm.meta.command;
    expected = "/store/p/bin/bar";
  };
  package-form-binary-name-override = {
    expr = pkgFormNamed.meta.command == "/store/p/bin/bar-mcp" && pkgFormNamed.serverEntry.command == "bar-mcp";
    expected = true;
  };

  # ── exactly-one-of command/package ──────────────────────────────────
  both-command-and-package-throws = {
    expr =
      (builtins.tryEval (mkMcpRegistration {
        name = "x";
        command = "/bin/x";
        package = fakeDrv;
      })).success;
    expected = false;
  };
  neither-command-nor-package-throws = {
    expr = (builtins.tryEval (mkMcpRegistration { name = "x"; })).success;
    expected = false;
  };
  envfiles-list-throws = {
    expr =
      (builtins.tryEval (mkMcpRegistration {
        name = "x";
        command = "/bin/x";
        envFiles = [ "X=/run/x" ];
      })).success;
    expected = false;
  };

  # ── canonical anvil entry shape (mkAnvilRegistration key set) ───────
  default-entry-key-set-matches-anvil-helper = {
    # Always-present keys per hm/service-helpers.nix mkAnvilRegistration;
    # package + hosts absent at their defaults. attrNames sorts.
    expr = builtins.attrNames cmdForm.serverEntry;
    expected = [
      "agents"
      "args"
      "command"
      "description"
      "enable"
      "env"
      "envFiles"
      "scopes"
    ];
  };
  package-form-entry-key-set-includes-package = {
    expr = builtins.attrNames pkgForm.serverEntry;
    expected = [
      "agents"
      "args"
      "command"
      "description"
      "enable"
      "env"
      "envFiles"
      "package"
      "scopes"
    ];
  };
  default-collections-are-empty = {
    expr =
      cmdForm.serverEntry.args == [ ]
      && cmdForm.serverEntry.env == { }
      && cmdForm.serverEntry.envFiles == { }
      && cmdForm.serverEntry.scopes == [ ]
      && cmdForm.serverEntry.agents == [ ];
    expected = true;
  };
  default-description-is-name = {
    expr = cmdForm.serverEntry.description;
    expected = "foo";
  };
  default-enable-true = {
    expr = cmdForm.serverEntry.enable;
    expected = true;
  };
  hosts-omitted-when-empty = {
    expr = cmdForm.serverEntry ? hosts;
    expected = false;
  };
  hosts-included-when-set = {
    expr = full.serverEntry.hosts;
    expected = [ "cid" ];
  };

  # ── populated fields flow through ───────────────────────────────────
  populated-fields-flow-into-entry = {
    expr = {
      inherit (full.serverEntry)
        args
        env
        envFiles
        scopes
        agents
        description
        ;
    };
    expected = {
      args = [ "mcp" "--listen" ];
      env.ZOEKT_URL = "http://localhost:6070";
      envFiles.ZOEKT_TOKEN = "/run/secrets/zoekt-token";
      scopes = [ "pleme" ];
      agents = [ "claude" ];
      description = "Zoekt trigram search";
    };
  };
  enable-false-flows-into-entry = {
    expr = full.serverEntry.enable;
    expected = false;
  };

  # ── hmFragment ──────────────────────────────────────────────────────
  hm-fragment-path-reaches-server-entry = {
    expr = lib.attrByPath (anvilPath ++ [ "foo" ]) null cmdForm.hmFragment == cmdForm.serverEntry;
    expected = true;
  };
  hm-fragment-keyed-by-name = {
    expr = builtins.attrNames (lib.attrByPath anvilPath { } full.hmFragment);
    expected = [ "zoekt" ];
  };

  # ── meta ────────────────────────────────────────────────────────────
  meta-shape = {
    expr = cmdForm.meta;
    expected = {
      name = "foo";
      command = "/usr/local/bin/foo-mcp";
      kind = "anvil-mcp";
    };
  };
}
