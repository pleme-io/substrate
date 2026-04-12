# Substrate Port Types
#
# Unifies the three incompatible port representations found across
# substrate builders:
#   1. Single integer (web: port = 8080)
#   2. Named attrset (go: { http = 8080; health = 8081; })
#   3. List of records (infra: [{ name = "http"; port = 8080; }])
#
# Uses attrTag for the sum type and coercedTo for backward-compatible
# automatic coercion from legacy formats.
#
# Pure — depends only on nixpkgs lib.
{ lib }:

let
  inherit (lib) types mkOption;
  foundation = import ./foundation.nix { inherit lib; };
in rec {
  # ── Port Entry (single named port) ───────────────────────────────
  portEntry = types.submodule {
    options = {
      name = mkOption {
        type = types.nonEmptyStr;
        description = "Port name (e.g. 'http', 'grpc', 'metrics').";
      };
      port = mkOption {
        type = types.port;
        description = "Port number (0-65535).";
      };
      protocol = mkOption {
        type = foundation.networkProtocol;
        default = "TCP";
        description = "Network protocol.";
      };
    };
  };

  # ── Named Ports Map ───────────────────────────────────────────────
  # The canonical internal representation: { http = 8080; health = 8081; }
  namedPorts = types.attrsOf types.port;

  # ── Port List ─────────────────────────────────────────────────────
  # For infra specs: [{ name = "http"; port = 8080; protocol = "TCP"; }]
  portList = types.listOf portEntry;

  # ── Coercion: single int → named ports ────────────────────────────
  # Accepts `8080` and produces `{ http = 8080; }`.
  portFromInt = types.coercedTo
    types.port
    (p: { http = p; })
    namedPorts;

  # ── Coercion: port list → named ports ─────────────────────────────
  # Accepts [{ name = "http"; port = 8080; }] and produces { http = 8080; }.
  portFromList = types.coercedTo
    portList
    (ps: builtins.listToAttrs (map (p: { name = p.name; value = p.port; }) ps))
    namedPorts;

  # ── Flexible Port Spec ────────────────────────────────────────────
  # Accepts any of: int, attrset, or list — normalizes to namedPorts.
  # This is the type builders should use for port parameters.
  #
  # Usage in a builder module:
  #   ports = mkOption { type = portTypes.flexiblePorts; default = {}; };
  #
  # Consumers can pass:
  #   ports = 8080;                              # → { http = 8080; }
  #   ports = { http = 8080; health = 8081; };   # → passthrough
  #   ports = [{ name = "grpc"; port = 50051; }] # → { grpc = 50051; }
  flexiblePorts = types.oneOf [ portFromInt portFromList namedPorts ];
}
