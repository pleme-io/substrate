# Home-Manager aws-auth helper.
#
# Materialises `~/.aws/credentials` and `~/.aws/config` from
# sops-nix-decrypted secrets so any dev node can `aws <cmd>` against
# long-lived break-glass identities (or workload-specific IAM users)
# without the access key / secret ever landing plaintext on disk.
# sops-nix writes the final files with mode 0600; the
# placeholder→ciphertext round-trip keeps every commit encrypted.
#
# Pairs 1-1 with docker-auth.nix (same pattern, different target file
# set): one encrypted source, N dev nodes render the same credentials.
#
# Why this module exists:
#   - SSO sessions expire (12-hour default). Long operator workflows
#     (AMI bakes, long Terraform applies, fleet orchestration) break
#     when SSO kicks you out mid-run. A SOPS-backed IAM user gives a
#     durable AWS_PROFILE=<name> escape hatch.
#   - Generic across dev nodes: laptop, VM, kasou, buildhost. Each node
#     gets the same ~/.aws/credentials via home-manager + sops-nix.
#
# Usage (home-manager module):
#
#   { config, lib, pkgs, substrate, ... }:
#   let
#     awsAuth = import "${substrate}/lib/hm/aws-auth.nix" { inherit lib; };
#   in {
#     sops.secrets."aws/ci-user/pleme-io-ci/access_key_id" = {
#       sopsFile = ../nix/secrets.yaml;
#     };
#     sops.secrets."aws/ci-user/pleme-io-ci/secret_access_key" = {
#       sopsFile = ../nix/secrets.yaml;
#     };
#     home.packages = with pkgs; [ awscli2 ];
#     sops.templates = awsAuth.mkTemplates {
#       home = config.home.homeDirectory;
#       placeholders = config.sops.placeholder;
#       profiles = {
#         pleme-io-ci = {
#           accessKeyIdSecret     = "aws/ci-user/pleme-io-ci/access_key_id";
#           secretAccessKeySecret = "aws/ci-user/pleme-io-ci/secret_access_key";
#           region = "us-east-1";
#           output = "json";
#         };
#       };
#     };
#   }
#
# Use: AWS_PROFILE=pleme-io-ci aws <cmd>
{ lib }:

let
  inherit (lib) mkOption types concatStringsSep mapAttrsToList optionalString;

  # ── Option types ─────────────────────────────────────────────────

  profileEntrySubmodule = types.submodule {
    options = {
      accessKeyIdSecret = mkOption {
        type = types.str;
        description = ''
          SOPS secret name carrying the AWS access key ID
          (e.g. AKIAXXXXXXX). Must match a key declared in
          `config.sops.secrets`.
        '';
        example = "aws/ci-user/pleme-io-ci/access_key_id";
      };
      secretAccessKeySecret = mkOption {
        type = types.str;
        description = ''
          SOPS secret name carrying the AWS secret access key. Must
          match a key declared in `config.sops.secrets`.
        '';
        example = "aws/ci-user/pleme-io-ci/secret_access_key";
      };
      sessionTokenSecret = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Optional SOPS secret name for an STS session token
          (populated when the profile represents temporary creds from
          `sts assume-role` or an Akeyless dynamic producer). null for
          long-lived IAM user keys.
        '';
        example = null;
      };
      region = mkOption {
        type = types.str;
        default = "us-east-1";
        description = "Default region written into ~/.aws/config for this profile.";
      };
      output = mkOption {
        type = types.enum [ "json" "text" "table" "yaml" "yaml-stream" ];
        default = "json";
        description = "Default --output format written into ~/.aws/config.";
      };
    };
  };

  # ── Helpers ──────────────────────────────────────────────────────

  validate = { home, placeholders, profiles }:
    assert (home != null && home != "");
    assert (builtins.isAttrs placeholders);
    assert (builtins.isAttrs profiles);
    let
      referenced = lib.flatten (mapAttrsToList (_: p:
        [ p.accessKeyIdSecret p.secretAccessKeySecret ]
        ++ lib.optional (p.sessionTokenSecret != null) p.sessionTokenSecret
      ) profiles);
      missing = lib.filter (n: ! (placeholders ? ${n})) referenced;
    in
      if missing != [] then
        throw ''
          aws-auth: the following secrets are referenced by profiles
          but aren't declared in config.sops.secrets: ${
            concatStringsSep ", " missing
          }
          Add them to your sops.secrets attrset before invoking
          mkTemplates. Example:
            sops.secrets."${builtins.head missing}" = {
              sopsFile = ./secrets.yaml;
            };
        ''
      else true;

  # Render `~/.aws/credentials` content. INI-style:
  #   [profile-name]
  #   aws_access_key_id = ${AWS_ACCESS_KEY_ID_PLACEHOLDER}
  #   aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY_PLACEHOLDER}
  #   aws_session_token = ${OPTIONAL_STS_TOKEN}
  mkCredentialsContent = { placeholders, profiles }:
    let
      sectionFor = name: p: ''
        [${name}]
        aws_access_key_id = ${placeholders.${p.accessKeyIdSecret}}
        aws_secret_access_key = ${placeholders.${p.secretAccessKeySecret}}${
          optionalString (p.sessionTokenSecret != null)
            "\naws_session_token = ${placeholders.${p.sessionTokenSecret}}"
        }
      '';
      sections = mapAttrsToList sectionFor profiles;
    in concatStringsSep "\n" sections;

  # Render `~/.aws/config` content. Note: aws CLI spells the section
  # header `[profile <name>]` in ~/.aws/config (with the "profile "
  # prefix), UNLIKE ~/.aws/credentials which uses just `[<name>]`. The
  # exception is the `default` profile which is `[default]` in both.
  mkConfigContent = { profiles }:
    let
      headerFor = name:
        if name == "default" then "[default]" else "[profile ${name}]";
      sectionFor = name: p: ''
        ${headerFor name}
        region = ${p.region}
        output = ${p.output}
      '';
      sections = mapAttrsToList sectionFor profiles;
    in concatStringsSep "\n" sections;

in rec {
  inherit profileEntrySubmodule;

  # ── Public API ───────────────────────────────────────────────────

  # `mkTemplates { home, placeholders, profiles }` returns an
  # attrset suitable for `sops.templates`. Produces two entries:
  #   - aws-credentials  → <home>/.aws/credentials (mode 0600)
  #   - aws-config       → <home>/.aws/config      (mode 0600)
  mkTemplates = args @ { home, placeholders, profiles }:
    assert validate args;
    {
      "aws-credentials" = {
        path = "${home}/.aws/credentials";
        mode = "0600";
        content = mkCredentialsContent {
          inherit placeholders profiles;
        };
      };
      "aws-config" = {
        path = "${home}/.aws/config";
        mode = "0600";
        content = mkConfigContent { inherit profiles; };
      };
    };

  inherit mkCredentialsContent mkConfigContent;

  # Standard AWS tooling a dev node with credentials ought to have.
  recommendedToolNames = [ "awscli2" "aws-vault" "session-manager-plugin" ];

  # ── Tests (pure lib eval) ────────────────────────────────────────

  tests = {
    testSingleProfileCredentialsHasKeys = {
      expr =
        let
          out = mkCredentialsContent {
            placeholders = {
              "aws/ci/ak" = "AKIA_PH";
              "aws/ci/sk" = "SK_PH";
            };
            profiles = {
              pleme-io-ci = {
                accessKeyIdSecret = "aws/ci/ak";
                secretAccessKeySecret = "aws/ci/sk";
                sessionTokenSecret = null;
                region = "us-east-1";
                output = "json";
              };
            };
          };
        in
          (lib.hasInfix "[pleme-io-ci]" out) &&
          (lib.hasInfix "AKIA_PH" out) &&
          (lib.hasInfix "SK_PH" out) &&
          (! lib.hasInfix "aws_session_token" out);
      expected = true;
    };

    testSessionTokenEmittedWhenPresent = {
      expr =
        let
          out = mkCredentialsContent {
            placeholders = {
              "ak" = "AK_PH";
              "sk" = "SK_PH";
              "tok" = "TOK_PH";
            };
            profiles = {
              temp = {
                accessKeyIdSecret = "ak";
                secretAccessKeySecret = "sk";
                sessionTokenSecret = "tok";
                region = "us-east-1";
                output = "json";
              };
            };
          };
        in
          (lib.hasInfix "aws_session_token = TOK_PH" out);
      expected = true;
    };

    testMultipleProfilesCoexist = {
      expr =
        let
          out = mkCredentialsContent {
            placeholders = {
              "a1" = "AK1"; "s1" = "SK1";
              "a2" = "AK2"; "s2" = "SK2";
            };
            profiles = {
              alpha = {
                accessKeyIdSecret = "a1"; secretAccessKeySecret = "s1";
                sessionTokenSecret = null; region = "us-east-1"; output = "json";
              };
              beta = {
                accessKeyIdSecret = "a2"; secretAccessKeySecret = "s2";
                sessionTokenSecret = null; region = "eu-west-1"; output = "json";
              };
            };
          };
        in
          (lib.hasInfix "[alpha]" out) &&
          (lib.hasInfix "[beta]" out) &&
          (lib.hasInfix "AK1" out) && (lib.hasInfix "AK2" out);
      expected = true;
    };

    testDefaultProfileUsesBareBracket = {
      expr =
        let
          out = mkConfigContent {
            profiles = {
              default = {
                accessKeyIdSecret = "x"; secretAccessKeySecret = "y";
                sessionTokenSecret = null; region = "us-east-2"; output = "json";
              };
            };
          };
        in
          (lib.hasInfix "[default]" out) &&
          (! lib.hasInfix "[profile default]" out);
      expected = true;
    };

    testNamedProfileUsesProfilePrefix = {
      expr =
        let
          out = mkConfigContent {
            profiles = {
              pleme-io-ci = {
                accessKeyIdSecret = "x"; secretAccessKeySecret = "y";
                sessionTokenSecret = null; region = "us-east-1"; output = "json";
              };
            };
          };
        in
          lib.hasInfix "[profile pleme-io-ci]" out;
      expected = true;
    };

    testMissingPlaceholderThrows = {
      expr = builtins.tryEval (mkTemplates {
        home = "/home/x";
        placeholders = { };  # empty — doesn't include "ak"
        profiles = {
          p = {
            accessKeyIdSecret = "ak"; secretAccessKeySecret = "sk";
            sessionTokenSecret = null; region = "us-east-1"; output = "json";
          };
        };
      });
      expected = { success = false; value = false; };
    };

    testMkTemplatesProducesBothFiles = {
      expr =
        let
          t = mkTemplates {
            home = "/home/luis";
            placeholders = { "ak" = "AK"; "sk" = "SK"; };
            profiles = {
              default = {
                accessKeyIdSecret = "ak"; secretAccessKeySecret = "sk";
                sessionTokenSecret = null; region = "us-east-1"; output = "json";
              };
            };
          };
        in
          [ t."aws-credentials".path t."aws-config".path ];
      expected = [ "/home/luis/.aws/credentials" "/home/luis/.aws/config" ];
    };

    testMkTemplatesSetsMode0600 = {
      expr =
        let
          t = mkTemplates {
            home = "/h";
            placeholders = { "ak" = "AK"; "sk" = "SK"; };
            profiles = {
              default = {
                accessKeyIdSecret = "ak"; secretAccessKeySecret = "sk";
                sessionTokenSecret = null; region = "us-east-1"; output = "json";
              };
            };
          };
        in
          (t."aws-credentials".mode == "0600") &&
          (t."aws-config".mode == "0600");
      expected = true;
    };

    testRecommendedToolsPresent = {
      expr = builtins.length recommendedToolNames;
      expected = 3;
    };
  };
}
