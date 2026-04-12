# Substrate Assertion Library Tests
#
# Pure Nix evaluation tests verifying that every assertion function in
# assertions.nix correctly accepts valid input and rejects invalid input.
# This makes the assertion layer itself testably predictable.
#
# Run: nix eval --impure --expr '(import ./lib/types/assertion-tests.nix).summary'
let
  check = import ./assertions.nix;
  testHelpers = import ../util/test-helpers.nix { lib = (import <nixpkgs> {}).lib; };
  inherit (testHelpers) mkTest runTests;

  # Helper: returns true if evaluating `expr` throws
  throws = expr: !(builtins.tryEval (builtins.seq expr true)).success;

in runTests [
  # ═══════════════════════════════════════════════════════════════════
  # nonEmptyStr
  # ═══════════════════════════════════════════════════════════════════
  (mkTest "nonEmptyStr-accepts-valid"
    ((check.nonEmptyStr "test" "hello") == "hello")
    "nonEmptyStr should accept non-empty string")

  (mkTest "nonEmptyStr-rejects-empty"
    (throws (check.nonEmptyStr "test" ""))
    "nonEmptyStr should reject empty string")

  (mkTest "nonEmptyStr-rejects-int"
    (throws (check.nonEmptyStr "test" 42))
    "nonEmptyStr should reject integer")

  (mkTest "nonEmptyStr-rejects-null"
    (throws (check.nonEmptyStr "test" null))
    "nonEmptyStr should reject null")

  # ═══════════════════════════════════════════════════════════════════
  # str
  # ═══════════════════════════════════════════════════════════════════
  (mkTest "str-accepts-empty"
    ((check.str "test" "") == "")
    "str should accept empty string")

  (mkTest "str-accepts-nonempty"
    ((check.str "test" "hello") == "hello")
    "str should accept non-empty string")

  (mkTest "str-rejects-int"
    (throws (check.str "test" 42))
    "str should reject integer")

  # ═══════════════════════════════════════════════════════════════════
  # strOrNull
  # ═══════════════════════════════════════════════════════════════════
  (mkTest "strOrNull-accepts-string"
    ((check.strOrNull "test" "hello") == "hello")
    "strOrNull should accept string")

  (mkTest "strOrNull-accepts-null"
    ((check.strOrNull "test" null) == null)
    "strOrNull should accept null")

  (mkTest "strOrNull-rejects-int"
    (throws (check.strOrNull "test" 42))
    "strOrNull should reject integer")

  # ═══════════════════════════════════════════════════════════════════
  # int / positiveInt / port
  # ═══════════════════════════════════════════════════════════════════
  (mkTest "int-accepts-zero"
    ((check.int "test" 0) == 0)
    "int should accept zero")

  (mkTest "int-rejects-string"
    (throws (check.int "test" "not-int"))
    "int should reject string")

  (mkTest "positiveInt-accepts-one"
    ((check.positiveInt "test" 1) == 1)
    "positiveInt should accept 1")

  (mkTest "positiveInt-rejects-zero"
    (throws (check.positiveInt "test" 0))
    "positiveInt should reject 0")

  (mkTest "positiveInt-rejects-negative"
    (throws (check.positiveInt "test" (-1)))
    "positiveInt should reject -1")

  (mkTest "port-accepts-8080"
    ((check.port "test" 8080) == 8080)
    "port should accept 8080")

  (mkTest "port-accepts-zero"
    ((check.port "test" 0) == 0)
    "port should accept 0")

  (mkTest "port-rejects-negative"
    (throws (check.port "test" (-1)))
    "port should reject -1")

  (mkTest "port-rejects-too-high"
    (throws (check.port "test" 70000))
    "port should reject 70000")

  # ═══════════════════════════════════════════════════════════════════
  # bool
  # ═══════════════════════════════════════════════════════════════════
  (mkTest "bool-accepts-true"
    ((check.bool "test" true) == true)
    "bool should accept true")

  (mkTest "bool-accepts-false"
    ((check.bool "test" false) == false)
    "bool should accept false")

  (mkTest "bool-rejects-string"
    (throws (check.bool "test" "true"))
    "bool should reject string 'true'")

  # ═══════════════════════════════════════════════════════════════════
  # list / attrs / listOfStr
  # ═══════════════════════════════════════════════════════════════════
  (mkTest "list-accepts-empty"
    ((check.list "test" []) == [])
    "list should accept empty list")

  (mkTest "list-rejects-string"
    (throws (check.list "test" "not-list"))
    "list should reject string")

  (mkTest "attrs-accepts-empty"
    ((check.attrs "test" {}) == {})
    "attrs should accept empty attrset")

  (mkTest "attrs-rejects-list"
    (throws (check.attrs "test" []))
    "attrs should reject list")

  (mkTest "listOfStr-accepts-strings"
    ((check.listOfStr "test" ["a" "b"]) == ["a" "b"])
    "listOfStr should accept list of strings")

  (mkTest "listOfStr-rejects-mixed"
    (throws (check.listOfStr "test" ["a" 1]))
    "listOfStr should reject mixed list")

  # ═══════════════════════════════════════════════════════════════════
  # enum
  # ═══════════════════════════════════════════════════════════════════
  (mkTest "enum-accepts-valid"
    ((check.enum "test" ["a" "b" "c"] "b") == "b")
    "enum should accept valid member")

  (mkTest "enum-rejects-invalid"
    (throws (check.enum "test" ["a" "b" "c"] "d"))
    "enum should reject non-member")

  # ═══════════════════════════════════════════════════════════════════
  # architecture
  # ═══════════════════════════════════════════════════════════════════
  (mkTest "architecture-accepts-amd64"
    ((check.architecture "test" "amd64") == "amd64")
    "architecture should accept amd64")

  (mkTest "architecture-accepts-arm64"
    ((check.architecture "test" "arm64") == "arm64")
    "architecture should accept arm64")

  (mkTest "architecture-rejects-x86"
    (throws (check.architecture "test" "x86"))
    "architecture should reject x86")

  # ═══════════════════════════════════════════════════════════════════
  # architectures (list)
  # ═══════════════════════════════════════════════════════════════════
  (mkTest "architectures-accepts-valid"
    ((check.architectures "test" ["amd64" "arm64"]) == ["amd64" "arm64"])
    "architectures should accept valid list")

  (mkTest "architectures-rejects-invalid-member"
    (throws (check.architectures "test" ["amd64" "sparc"]))
    "architectures should reject invalid member")

  # ═══════════════════════════════════════════════════════════════════
  # namedPorts
  # ═══════════════════════════════════════════════════════════════════
  (mkTest "namedPorts-accepts-valid"
    ((check.namedPorts "test" { http = 8080; health = 8081; }) == { http = 8080; health = 8081; })
    "namedPorts should accept valid port map")

  (mkTest "namedPorts-rejects-non-attrset"
    (throws (check.namedPorts "test" "not-attrs"))
    "namedPorts should reject non-attrset")

  # ═══════════════════════════════════════════════════════════════════
  # cpuQuantity / memoryQuantity
  # ═══════════════════════════════════════════════════════════════════
  (mkTest "cpuQuantity-accepts-milli"
    ((check.cpuQuantity "test" "100m") == "100m")
    "cpuQuantity should accept 100m")

  (mkTest "cpuQuantity-accepts-whole"
    ((check.cpuQuantity "test" "2") == "2")
    "cpuQuantity should accept 2")

  (mkTest "cpuQuantity-rejects-invalid"
    (throws (check.cpuQuantity "test" "fast"))
    "cpuQuantity should reject 'fast'")

  (mkTest "memoryQuantity-accepts-mi"
    ((check.memoryQuantity "test" "128Mi") == "128Mi")
    "memoryQuantity should accept 128Mi")

  (mkTest "memoryQuantity-accepts-gi"
    ((check.memoryQuantity "test" "4Gi") == "4Gi")
    "memoryQuantity should accept 4Gi")

  (mkTest "memoryQuantity-rejects-bare-number"
    (throws (check.memoryQuantity "test" "128"))
    "memoryQuantity should reject bare number")

  # ═══════════════════════════════════════════════════════════════════
  # all (batch helper)
  # ═══════════════════════════════════════════════════════════════════
  (mkTest "all-accepts-valid-checks"
    (check.all [ (check.nonEmptyStr "a" "hello") (check.int "b" 42) ])
    "all should accept when all checks pass")

  # ═══════════════════════════════════════════════════════════════════
  # attrsOrNull / derivationOrNull / pathOrNull
  # ═══════════════════════════════════════════════════════════════════
  (mkTest "attrsOrNull-accepts-null"
    ((check.attrsOrNull "test" null) == null)
    "attrsOrNull should accept null")

  (mkTest "attrsOrNull-accepts-attrs"
    ((check.attrsOrNull "test" { a = 1; }) == { a = 1; })
    "attrsOrNull should accept attrset")

  (mkTest "attrsOrNull-rejects-string"
    (throws (check.attrsOrNull "test" "not-attrs"))
    "attrsOrNull should reject string")
]
