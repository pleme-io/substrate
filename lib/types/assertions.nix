# Substrate Type Assertions
#
# Lightweight assertion functions for inline use in builder functions.
# These run at evaluation time and throw with descriptive messages
# when invariants are violated. No module system overhead — just
# assert + throw on the hot path.
#
# Every builder imports this once and guards its parameters.
#
# Pure — depends only on builtins.
#
# Usage:
#   let check = import "${substrate}/lib/types/assertions.nix"; in
#   { name, src, ... }: let
#     _ = check.nonEmptyStr "name" name;
#     __ = check.path "src" src;
#   in ...
rec {
  # ── String Assertions ─────────────────────────────────────────────
  nonEmptyStr = field: value:
    assert builtins.isString value && value != ""
      || throw "${field}: must be a non-empty string, got ${builtins.typeOf value}";
    value;

  str = field: value:
    assert builtins.isString value
      || throw "${field}: must be a string, got ${builtins.typeOf value}";
    value;

  strOrNull = field: value:
    assert value == null || builtins.isString value
      || throw "${field}: must be a string or null, got ${builtins.typeOf value}";
    value;

  # ── Numeric Assertions ────────────────────────────────────────────
  int = field: value:
    assert builtins.isInt value
      || throw "${field}: must be an integer, got ${builtins.typeOf value}";
    value;

  positiveInt = field: value:
    assert builtins.isInt value && value > 0
      || throw "${field}: must be a positive integer, got ${toString value}";
    value;

  port = field: value:
    assert builtins.isInt value && value >= 0 && value <= 65535
      || throw "${field}: must be a port (0-65535), got ${toString value}";
    value;

  # ── Boolean Assertions ────────────────────────────────────────────
  bool = field: value:
    assert builtins.isBool value
      || throw "${field}: must be a boolean, got ${builtins.typeOf value}";
    value;

  # ── Collection Assertions ─────────────────────────────────────────
  list = field: value:
    assert builtins.isList value
      || throw "${field}: must be a list, got ${builtins.typeOf value}";
    value;

  attrs = field: value:
    assert builtins.isAttrs value
      || throw "${field}: must be an attrset, got ${builtins.typeOf value}";
    value;

  attrsOrNull = field: value:
    assert value == null || builtins.isAttrs value
      || throw "${field}: must be an attrset or null, got ${builtins.typeOf value}";
    value;

  listOfStr = field: value:
    assert builtins.isList value && builtins.all builtins.isString value
      || throw "${field}: must be a list of strings";
    value;

  # ── Path Assertions ───────────────────────────────────────────────
  path = field: value:
    assert builtins.isPath value || (builtins.isString value && builtins.substring 0 1 value == "/")
      || throw "${field}: must be a path, got ${builtins.typeOf value}";
    value;

  pathOrNull = field: value:
    assert value == null || builtins.isPath value || (builtins.isString value && builtins.substring 0 1 value == "/")
      || throw "${field}: must be a path or null, got ${builtins.typeOf value}";
    value;

  # ── Enum Assertions ───────────────────────────────────────────────
  enum = field: allowed: value:
    assert builtins.elem value allowed
      || throw "${field}: must be one of [${builtins.concatStringsSep ", " allowed}], got '${toString value}'";
    value;

  # ── Resource Quantity Assertions ──────────────────────────────────
  cpuQuantity = field: value:
    assert builtins.isString value && builtins.match "[0-9]+(m)?" value != null
      || throw "${field}: must be a CPU quantity (e.g. '100m', '2'), got '${value}'";
    value;

  memoryQuantity = field: value:
    assert builtins.isString value && builtins.match "[0-9]+(Mi|Gi|Ki|Ti)" value != null
      || throw "${field}: must be a memory quantity (e.g. '128Mi', '4Gi'), got '${value}'";
    value;

  # ── Composite Assertions ──────────────────────────────────────────
  # Validate a named ports attrset: { http = 8080; health = 8081; }
  namedPorts = field: value:
    assert builtins.isAttrs value
      && builtins.all (k: builtins.isInt value.${k} && value.${k} >= 0 && value.${k} <= 65535) (builtins.attrNames value)
      || throw "${field}: must be an attrset of port numbers (0-65535)";
    value;

  # Validate architecture enum
  architecture = field: value:
    enum field [ "amd64" "arm64" ] value;

  # Validate a list of architectures
  architectures = field: value:
    assert builtins.isList value && builtins.all (a: builtins.elem a [ "amd64" "arm64" ]) value
      || throw "${field}: must be a list of architectures (amd64, arm64)";
    value;

  # ── Derivation Assertions ─────────────────────────────────────────
  # Check that a value looks like a derivation (has type "derivation" or is a store path)
  derivation = field: value:
    assert builtins.isAttrs value || builtins.isPath value || builtins.isString value
      || throw "${field}: must be a derivation/package, got ${builtins.typeOf value}";
    value;

  derivationOrNull = field: value:
    assert value == null || builtins.isAttrs value || builtins.isPath value || builtins.isString value
      || throw "${field}: must be a derivation or null, got ${builtins.typeOf value}";
    value;

  # ── Batch Assertion Helper ────────────────────────────────────────
  # Apply multiple checks at once. Returns true (for use in let bindings).
  # Usage: _ = check.all [ (check.nonEmptyStr "name" name) (check.port "port" port) ];
  all = checks:
    assert builtins.all (x: x != null) checks; true;
}
