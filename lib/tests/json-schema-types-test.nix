# Regression tests for lib/types/json-schema.nix (JSON Schema → option types).
#
# The fixtures are REAL schemars 1.2.2 output, not hand-written guesses at it:
# fixtures/json-schema/schemars-source.rs is the Rust that produced them (the
# GithubAuth / SecretSource / GithubApp target shape, plus a DaemonConfig that
# covers unit enums with and without doc comments, an internally-tagged enum,
# maps, sets, floats, bounded ints and an Option<recursive enum>). Regenerate
# with the command in that file's header; a change in schemars' output shape
# then shows up here as a diff, not as a silent mismatch.
#
# ── Not vacuous ─────────────────────────────────────────────────────────────
# Every rejection test is a NEAR-MISS PAIR: `rejects base broken` passes only
# if `base` evaluates AND `broken` (one value changed) does not. A rejection
# that fires for an unrelated reason — a broken fixture, a typo in the test
# module — fails the pair through its `base` half instead of reading green.
# The refusals of unsupported SCHEMA constructs are paired the same way: the
# identical schema minus the offending keyword must convert.
#
# Run: nix build .#checks.<system>.json-schema-types
{ lib }:

let
  js = import ../types/json-schema.nix { inherit lib; };
  testHelpers = import ../util/test-helpers.nix { inherit lib; };
  inherit (testHelpers) mkTest;

  fx = ./fixtures/json-schema;
  authSchema = lib.importJSON (fx + "/github-auth.schema.json");
  daemonSchema = lib.importJSON (fx + "/daemon-config.schema.json");

  ok = e: (builtins.tryEval (builtins.deepSeq e true)).success;

  evalType =
    type: v:
    (lib.evalModules {
      modules = [
        {
          options.v = lib.mkOption { inherit type; };
          config.v = v;
        }
      ];
    }).config.v;

  accepts = type: v: ok (evalType type v);
  rejects = type: base: broken: accepts type base && !(accepts type broken);

  authNative = js.fromJsonSchema {
    inherit lib;
    schema = authSchema;
  };
  authFallback = js.fromJsonSchema {
    inherit lib;
    schema = authSchema;
    attrTagImpl = "fallback";
  };

  daemonEval =
    v:
    lib.evalModules {
      modules = [
        {
          options.s = js.optionsFromJsonSchema {
            inherit lib;
            schema = fx + "/daemon-config.schema.json";
          };
          config.s = v;
        }
      ];
    };
  daemonOk = v: ok (daemonEval v).config.s;
  daemonRejects = base: broken: daemonOk base && !(daemonOk broken);

  # ── GithubAuth values ──────────────────────────────────────────────────
  app = {
    app_id = 12345;
    private_key = {
      file = "/run/secrets/app.pem";
    };
  };
  appFull = app // {
    installation_id = 99;
    owner = "pleme-io";
    api_url = "https://ghe.example/api/v3";
    refresh_before_secs = 600;
  };
  chain = {
    chain = [
      { token = { env = "GITHUB_TOKEN"; }; }
      { gh_cli = { }; }
      { inherit app; }
      { chain = [ { token = "ghp_literal"; } ]; }
    ];
  };

  authCases =
    impl: t:
    [
      (mkTest "${impl}/token-literal" (accepts t { token = "ghp_x"; }) "token as an inline string (untagged literal arm)")
      (mkTest "${impl}/token-file" (accepts t { token.file = "/p"; }) "token from {file}")
      (mkTest "${impl}/token-env" (accepts t { token.env = "GH_TOKEN"; }) "token from {env}")
      (mkTest "${impl}/token-sops" (accepts t {
        token.sops = {
          file = "secrets.yaml";
          key = "github/token";
        };
      }) "token from {sops}")
      (mkTest "${impl}/token-command" (accepts t {
        token.command = [
          "pass"
          "gh"
        ];
      }) "token from {command}")
      (mkTest "${impl}/gh-cli-default-host" (evalType t { gh_cli = { }; } == { gh_cli.host = "github.com"; })
        "gh_cli = {} gets host's schemars default"
      )
      (mkTest "${impl}/gh-cli-host" (evalType t { gh_cli.host = "ghe.example"; } == { gh_cli.host = "ghe.example"; })
        "gh_cli host overrides the default"
      )
      (mkTest "${impl}/app-defaults"
        (
          evalType t { inherit app; } == {
            app = app // {
              installation_id = null;
              owner = null;
              api_url = "https://api.github.com";
              refresh_before_secs = 300;
            };
          }
        )
        "app gets api_url / refresh_before_secs defaults, Option fields null"
      )
      (mkTest "${impl}/app-full" (accepts t { app = appFull; }) "app with every field")
      (mkTest "${impl}/chain-nested" (accepts t chain) "chain of every variant, including a nested chain")

      # ── rejections: each a near-miss of a value accepted above ──────────
      (mkTest "${impl}/rejects-two-variants" (rejects t { token = "x"; } {
        token = "x";
        gh_cli = { };
      }) "two keys in an externally-tagged enum")
      (mkTest "${impl}/rejects-unknown-variant" (rejects t { token = "x"; } { password = "x"; }) "a variant that does not exist")
      (mkTest "${impl}/rejects-empty-tag" (rejects t { token = "x"; } { }) "no variant at all")
      (mkTest "${impl}/rejects-two-secret-refs" (rejects t { token.file = "/p"; } {
        token = {
          file = "/p";
          env = "X";
        };
      }) "two keys in the nested SecretRef enum")
      (mkTest "${impl}/rejects-string-app-id" (rejects t { inherit app; } { app = app // { app_id = "12345"; }; })
        "app_id is a uint64, not a string"
      )
      (mkTest "${impl}/rejects-negative-app-id" (rejects t { inherit app; } { app = app // { app_id = -1; }; })
        "app_id is unsigned"
      )
      (mkTest "${impl}/rejects-float-refresh" (rejects t { inherit app; } { app = app // { refresh_before_secs = 1.5; }; })
        "refresh_before_secs is an integer"
      )
      (mkTest "${impl}/rejects-unknown-app-key" (rejects t { inherit app; } { app = app // { bogus = 1; }; })
        "unknown key inside a struct variant"
      )
      (mkTest "${impl}/rejects-unknown-gh-cli-key" (rejects t { gh_cli.host = "h"; } {
        gh_cli = {
          host = "h";
          hots = "typo";
        };
      }) "unknown key in gh_cli (struct without deny_unknown_fields is still closed)")
      (mkTest "${impl}/rejects-missing-private-key" (rejects t { inherit app; } { app = removeAttrs app [ "private_key" ]; })
        "private_key is required"
      )
      (mkTest "${impl}/rejects-int-token" (rejects t { token = "x"; } { token = 5; }) "token is a string or a SecretRef")
      (mkTest "${impl}/rejects-command-string" (rejects t { token.command = [ "ls" ]; } { token.command = "ls"; })
        "command is a list"
      )
      (mkTest "${impl}/rejects-bad-chain-member"
        (rejects t chain {
          chain = chain.chain ++ [
            {
              token = "x";
              gh_cli = { };
            }
          ];
        })
        "an invalid member deep in a chain"
      )
      (mkTest "${impl}/rejects-bad-nested-chain-member"
        (rejects t chain {
          chain = [ { chain = [ { app = app // { app_id = "x"; }; } ]; } ];
        })
        "an invalid member in a nested chain"
      )
      (mkTest "${impl}/rejects-chain-not-list" (rejects t chain { chain = { token = "x"; }; }) "chain is a list")
    ];

  daemonBase = {
    github.gh_cli = { };
    mode = "fast";
    sinks = [
      { kind = "stdout"; }
      {
        kind = "file";
        path = "/var/log/d";
      }
      {
        kind = "http";
        url = "https://sink";
        port = 8443;
      }
    ];
    labels.team = "infra";
    ratio = 0.25;
    enabled = true;
    port = 22;
    offset = -3;
    tags = [
      "a"
      "b"
    ];
  };
  setSink = i: v: daemonBase // { sinks = lib.imap0 (j: s: if j == i then v else s) daemonBase.sinks; };
  daemonOpts = (daemonEval daemonBase).options.s;

  # ── Ad-hoc schemas for the shapes the fixtures do not carry ────────────
  conv = schema: js.fromJsonSchema { inherit lib schema; };
  converts = schema: ok (conv schema).check;
  refusesSchema = good: bad: converts good && !(converts bad);

  strSchema = {
    type = "object";
    properties.name = {
      type = "string";
    };
    required = [ "name" ];
  };
  withProp = p: strSchema // { properties.name = { type = "string"; } // p; };

  untaggedRec = {
    "$ref" = "#/$defs/V";
    "$defs".V.anyOf = [
      { type = "string"; }
      {
        type = "array";
        items."$ref" = "#/$defs/V";
      }
    ];
  };
  legacyDefs = {
    "$ref" = "#/definitions/Port";
    definitions.Port = {
      type = "integer";
      format = "uint16";
      minimum = 0;
      maximum = 65535;
    };
  };
  mixedEnum = {
    oneOf = [
      {
        type = "string";
        enum = [ "off" ];
      }
      {
        type = "object";
        properties.on = {
          type = "object";
          properties.level = {
            type = "integer";
            format = "uint8";
            minimum = 0;
            maximum = 255;
          };
          required = [ "level" ];
        };
        required = [ "on" ];
        additionalProperties = false;
      }
    ];
  };
  freeform = {
    type = "object";
    properties.name.type = "string";
    required = [ "name" ];
    additionalProperties.type = "integer";
  };
  bounded = {
    type = "integer";
    minimum = 1;
    maximum = 10;
  };

  tests =
    authCases "native" authNative
    ++ authCases "fallback" authFallback
    ++ [
      (mkTest "native-is-attrTag" (
        authNative ? nestedTypes.token
        && (lib.types ? attrTag) == !(authNative ? jsonSchemaFallback)
        && authFallback ? jsonSchemaFallback
      ) "auto picks types.attrTag where nixpkgs has it (>= 24.05), the fallback elsewhere")
      (mkTest "description-terminates" (ok authNative.description && ok (lib.types.listOf authNative).description)
        "a recursive type's description is finite"
      )

      # ── DaemonConfig through optionsFromJsonSchema ─────────────────────
      (mkTest "daemon-valid" (daemonOk daemonBase) "a full DaemonConfig evaluates")
      (mkTest "daemon-defaults"
        (
          let
            c = (daemonEval daemonBase).config.s;
          in
          c.log_level == null && c.fallback == null && c.github == { gh_cli.host = "github.com"; }
        )
        "Option fields default to null; nested defaults applied"
      )
      (mkTest "daemon-descriptions" (
        daemonOpts.github.description == "GitHub credentials." && daemonOpts.log_level.description == "Log verbosity."
      ) "descriptions carried from doc comments")
      (mkTest "ref-description-fallback"
        (
          (js.optionsFromJsonSchema {
            inherit lib;
            schema = {
              type = "object";
              properties.x."$ref" = "#/$defs/D";
              "$defs".D = {
                type = "string";
                description = "from the def";
              };
            };
          }).x.description == "from the def"
        )
        "a $ref'd property without its own doc gets the target's"
      )
      (mkTest "daemon-log-level-ok" (daemonOk (daemonBase // { log_level = "info"; })) "a plain unit enum value")
      (mkTest "daemon-rejects-log-level" (daemonRejects (daemonBase // { log_level = "info"; }) (
        daemonBase // { log_level = "verbose"; }
      )) "an unknown unit-enum value")
      (mkTest "daemon-rejects-mode" (daemonRejects daemonBase (daemonBase // { mode = "medium"; }))
        "documented unit variants (oneOf of const) are an enum"
      )
      (mkTest "daemon-rejects-http-sink-missing-port" (daemonRejects daemonBase (
        setSink 2 {
          kind = "http";
          url = "u";
        }
      )) "internally-tagged variant missing a required field")
      (mkTest "daemon-rejects-file-sink-extra-key" (daemonRejects daemonBase (
        setSink 1 {
          kind = "file";
          path = "/p";
          port = 1;
        }
      )) "internally-tagged variant carrying another variant's field")
      (mkTest "daemon-rejects-unknown-sink-kind" (daemonRejects daemonBase (setSink 0 { kind = "ftp"; }))
        "internally-tagged discriminator outside the set"
      )
      (mkTest "daemon-rejects-sink-port-range" (daemonRejects daemonBase (
        setSink 2 {
          kind = "http";
          url = "u";
          port = 70000;
        }
      )) "u16 inside a union alternative")
      (mkTest "daemon-rejects-port" (daemonRejects daemonBase (daemonBase // { port = 65536; })) "u16 range")
      (mkTest "daemon-rejects-offset" (daemonRejects daemonBase (daemonBase // { offset = 3000000000; })) "i32 range")
      (mkTest "daemon-int-ratio" (daemonOk (daemonBase // { ratio = 1; })) "a JSON number accepts an int")
      (mkTest "daemon-rejects-string-ratio" (daemonRejects daemonBase (daemonBase // { ratio = "0.5"; })) "number")
      (mkTest "daemon-rejects-dup-tags" (daemonRejects daemonBase (
        daemonBase
        // {
          tags = [
            "a"
            "a"
          ];
        }
      )) "BTreeSet → uniqueItems")
      (mkTest "daemon-rejects-label-int" (daemonRejects daemonBase (daemonBase // { labels.team = 1; })) "map values")
      (mkTest "daemon-rejects-unknown-top-key" (daemonRejects daemonBase (daemonBase // { colour = "red"; }))
        "deny_unknown_fields root"
      )
      (mkTest "daemon-rejects-missing-required" (daemonRejects daemonBase (removeAttrs daemonBase [ "mode" ])) "required")
      (mkTest "daemon-fallback-chain" (daemonOk (daemonBase // { fallback = chain; })) "Option<GithubAuth> set")
      (mkTest "daemon-rejects-fallback" (daemonRejects (daemonBase // { fallback = chain; }) (
        daemonBase // { fallback.token = 1; }
      )) "Option<GithubAuth> still checks the inner type")
      (mkTest "daemon-docs-terminate"
        (ok (map (o: o.name) (lib.optionAttrSetToDocList (daemonEval daemonBase).options)))
        "option docs over a recursive schema terminate"
      )
      (mkTest "daemon-docs-expand-nonrecursive"
        (lib.any (o: o.name == "s.fallback.app.api_url" || lib.hasSuffix "app.api_url" o.name) (
          lib.optionAttrSetToDocList (daemonEval daemonBase).options
        ))
        "docs still unfold the non-recursive GithubApp"
      )
      (mkTest "prune-nulls"
        (
          js.pruneNulls {
            a = null;
            b = {
              c = null;
              d = 1;
            };
            l = [
              null
              { e = null; }
            ];
          } == {
            b.d = 1;
            l = [
              null
              { }
            ];
          }
        )
        "attr nulls pruned recursively; list nulls kept"
      )

      # ── ad-hoc shapes ──────────────────────────────────────────────────
      (mkTest "untagged-recursive-through-list" (
        accepts (conv untaggedRec) [
          "a"
          [ "b" ]
        ]
        && rejects (conv untaggedRec) [ "a" ] [ 1 ]
        && ok (conv untaggedRec).description
      ) "a recursive UNTAGGED enum through Vec<Self>")
      (mkTest "legacy-definitions" (rejects (conv legacyDefs) 80 70000) "`definitions` (schemars 0.8) refs")
      (mkTest "nullable-type-list" (
        accepts (conv { type = [ "string" "null" ]; }) null && rejects (conv { type = [ "string" "null" ]; }) "x" 1
      ) "type [X, null] → nullOr X")
      (mkTest "openapi-nullable" (
        accepts (conv {
          type = "string";
          nullable = true;
        }) null
      ) "nullable: true → nullOr")
      (mkTest "mixed-unit-and-data-enum" (
        accepts (conv mixedEnum) "off" && rejects (conv mixedEnum) { on.level = 3; } "on"
        && rejects (conv mixedEnum) { on.level = 3; } { on.level = 300; }
      ) "externally-tagged enum mixing unit and data variants")
      (mkTest "freeform-object" (
        rejects (conv freeform) {
          name = "x";
          extra = 1;
        } {
          name = "x";
          extra = "1";
        }
      ) "properties + additionalProperties schema → submodule with freeformType")
      (mkTest "optional-without-default-is-null"
        (
          let
            t = conv {
              type = "object";
              properties.n.type = "integer";
            };
          in
          accepts t { } && evalType t { } == { n = null; } && accepts t { n = null; } && rejects t { n = 1; } { n = "1"; }
        )
        "a non-required field with no default is nullOr T, default null (serde: missing)"
      )
      (mkTest "bounds" (rejects (conv bounded) 10 11 && !(accepts (conv bounded) 0)) "minimum/maximum")

      # ── refusals of unsupported schema constructs (paired) ─────────────
      (mkTest "refuses-pattern" (refusesSchema strSchema (withProp { pattern = "^a"; })) "pattern")
      (mkTest "refuses-minLength" (refusesSchema strSchema (withProp { minLength = 1; })) "minLength")
      (mkTest "refuses-unknown-keyword" (refusesSchema strSchema (withProp { frobnicate = true; })) "an unknown keyword")
      (mkTest "refuses-unused-def" (refusesSchema strSchema (
        strSchema
        // {
          "$defs".Unused = {
            type = "string";
            pattern = "x";
          };
        }
      )) "an unsupported keyword in a $def nothing references (eager audit, not lazy)")
      (mkTest "refuses-tuple" (refusesSchema strSchema (
        strSchema
        // {
          properties.name = {
            type = "array";
            prefixItems = [ { type = "string"; } ];
            items = false;
          };
        }
      )) "prefixItems tuples")
      (mkTest "refuses-dangling-ref" (refusesSchema legacyDefs (legacyDefs // { "$ref" = "#/definitions/Nope"; }))
        "a $ref that resolves nowhere"
      )
      (mkTest "refuses-remote-ref" (refusesSchema legacyDefs (legacyDefs // { "$ref" = "https://x/s.json"; }))
        "a non-local $ref"
      )
      (mkTest "refuses-pure-ref-cycle" (refusesSchema untaggedRec {
        "$ref" = "#/$defs/A";
        "$defs" = {
          A.anyOf = [
            { "$ref" = "#/$defs/B"; }
            { type = "string"; }
          ];
          B.anyOf = [
            { "$ref" = "#/$defs/A"; }
            { type = "integer"; }
          ];
        };
      }) "a ref cycle with no object/array/map in between")
      (mkTest "refuses-unknown-type" (refusesSchema strSchema (withProp { type = "decimal"; })) "unknown type")
      (mkTest "refuses-unknown-int-format" (refusesSchema bounded (bounded // { format = "uint128"; }))
        "unknown integer format"
      )
      (mkTest "refuses-two-drivers" (refusesSchema legacyDefs (legacyDefs // { properties = { }; }))
        "$ref beside properties"
      )
      (mkTest "refuses-false-schema" (refusesSchema strSchema (strSchema // { properties.name = false; }))
        "the false schema"
      )
      (mkTest "refuses-allOf-two" (refusesSchema { allOf = [ strSchema ]; } { allOf = [ strSchema strSchema ]; })
        "allOf with two members (one is unwrapped)"
      )
      (mkTest "options-need-object-root" (
        ok (js.optionsFromJsonSchema { inherit lib; schema = strSchema; })
        && !ok (js.optionsFromJsonSchema { inherit lib; schema = authSchema; })
      ) "optionsFromJsonSchema refuses a non-object root")
    ];

  result = testHelpers.runTests tests;
in
{
  inherit (result)
    total
    passCount
    failCount
    allPassed
    failures
    summary
    ;
  inherit tests result;

  asCheck = testHelpers.mkAsCheck {
    name = "json-schema-types-test";
    label = "json-schema-types";
  } result;
}
