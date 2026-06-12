# iroha.mcp — binary-to-agent distribution: ONE typed registration shape
# for MCP servers consumed by AI coding agents through blackmatter-anvil.
#
# The letter that ends the mkMcpServerEntry / withMcp / withAnvilMcp drift.
# Today three surfaces emit `blackmatter.components.anvil.mcp.servers.<name>`
# values with three slightly different conventions (hm/service-helpers.nix
# mkAnvilRegistration, module-trio.nix withAnvilMcp, hm/mcp-helpers.nix
# mkMcpFleet). mkMcpRegistration is the single primitive: it produces the
# anvil serverOpts-shaped entry that hm/mcp-helpers.nix mcpServerOpts
# declares and mkResolvedServers/_mkCommandPath resolve — command stays the
# BARE binary name when a package is given (anvil resolves
# "${package}/bin/${command}" itself), and the pre-resolved absolute path
# when `command` is given directly. The double-resolution bug class
# ("${package}/bin//nix/store/...-pkg/bin/<bin>") has no expressible input.
#
# Exports (pure { lib }, zero pkgs — `package` is a consumer-supplied
# derivation bound late; nothing here builds):
#
#   mkMcpRegistration :: {
#     name        :: str (REQUIRED) — server name; becomes the attr under
#                    blackmatter.components.anvil.mcp.servers.<name>;
#     command     ? null :: nullOr str — pre-resolved executable (absolute
#                    path, or a PATH-resolvable name like "npx");
#     package     ? null :: nullOr drv — package providing the binary;
#                    anvil resolves "${package}/bin/<binaryName>";
#                    EXACTLY ONE of command/package must be set;
#     binaryName  ? name :: str — binary under ${package}/bin/ (package
#                    form only; ignored in command form);
#     args        ? [ ]  :: listOf str;
#     env         ? { }  :: attrsOf str — static env baked into the wrapper;
#     envFiles    ? { }  :: attrsOf str — VAR -> file path, resolved at
#                    runtime (the anvil mcpServerOpts shape — an attrset,
#                    NOT a list; a list is a typed throw);
#     scopes      ? [ ]  :: listOf str — empty = all profile scopes;
#     agents      ? [ ]  :: listOf str — empty = all agents;
#     hosts       ? [ ]  :: listOf str — empty = all hosts; emitted into
#                    the entry only when non-empty (mcpServerOpts defaults
#                    it, and the legacy helper never carried it);
#     description ? name :: str;
#     enable      ? true :: bool;
#   } -> {
#     serverEntry — the blackmatter.components.anvil.mcp.servers.<name>
#                   VALUE. Always carries command, args, env, envFiles,
#                   description, scopes, agents, enable (the
#                   mkAnvilRegistration key set); plus `package` only in
#                   package form and `hosts` only when non-empty.
#                   command = `command` (command form) | binaryName
#                   (package form — anvil's _mkCommandPath finishes it);
#     hmFragment  — { blackmatter.components.anvil.mcp.servers.<name> =
#                   serverEntry; } — merge straight into an HM config block;
#     meta        — { name; command (RESOLVED: command if given, else
#                   "${package}/bin/<binaryName>"); kind = "anvil-mcp"; };
#   }
#
#   Typed throws (all EAGER — forcing the returned attrset to WHNF
#   surfaces them, so `tryEval (mkMcpRegistration {...})` is sufficient):
#     iroha.mcp.mkMcpRegistration: exactly one of `command`/`package`
#       required — got both;
#     iroha.mcp.mkMcpRegistration: exactly one of `command`/`package`
#       required — got neither;
#     iroha.mcp.mkMcpRegistration: `envFiles` must be an attrset of
#       VAR -> file path, got a list.
{ lib }:
let
  mkMcpRegistration =
    {
      name,
      command ? null,
      package ? null,
      binaryName ? name,
      args ? [ ],
      env ? { },
      envFiles ? { },
      scopes ? [ ],
      agents ? [ ],
      hosts ? [ ],
      description ? name,
      enable ? true,
    }:
    let
      guard =
        if command != null && package != null then
          throw "iroha.mcp.mkMcpRegistration: exactly one of `command` or `package` must be set for '${name}' — got both. `command` is a pre-resolved executable; `package` is a derivation anvil resolves to <package>/bin/${binaryName}. Drop one."
        else if command == null && package == null then
          throw "iroha.mcp.mkMcpRegistration: exactly one of `command` or `package` must be set for '${name}' — got neither."
        else if builtins.isList envFiles then
          throw "iroha.mcp.mkMcpRegistration: `envFiles` for '${name}' must be an attrset of VAR -> file path (the anvil mcpServerOpts shape), got a list."
        else
          true;

      resolvedCommand = if command != null then command else "${package}/bin/${binaryName}";

      serverEntry =
        {
          # Bare binary name in package form — anvil's _mkCommandPath
          # composes "${package}/bin/${command}"; pre-resolving here would
          # reintroduce the double-resolution drift this letter ends.
          command = if command != null then command else binaryName;
          inherit
            args
            env
            envFiles
            description
            scopes
            agents
            enable
            ;
        }
        // lib.optionalAttrs (package != null) { inherit package; }
        // lib.optionalAttrs (hosts != [ ]) { inherit hosts; };
    in
    builtins.seq guard {
      inherit serverEntry;
      hmFragment = {
        blackmatter.components.anvil.mcp.servers.${name} = serverEntry;
      };
      meta = {
        inherit name;
        command = resolvedCommand;
        kind = "anvil-mcp";
      };
    };
in
{
  inherit mkMcpRegistration;
}
