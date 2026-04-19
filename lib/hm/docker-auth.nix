# Home-Manager docker-auth helper.
#
# Materialises `~/.docker/config.json` from sops-nix-decrypted secrets
# so laptops can `skopeo login` / `docker push` to per-cluster zot
# registries without the token ever landing plaintext on disk (sops-nix
# writes the final JSON with mode 0600, and the placeholder→ciphertext
# round-trip keeps every commit encrypted).
#
# One encrypted source, two render targets — this is the client-side
# counterpart to the K8s Secret that arch-synthesizer's
# `ZotCredentialDecl` materialises inside the cluster. Both resolve
# through the same SOPS key path so rotation is a single sops-edit.
#
# Usage (home-manager module):
#
#   { config, lib, pkgs, substrate, ... }:
#   let
#     dockerAuth = import "${substrate}/lib/hm/docker-auth.nix" { inherit lib; };
#   in {
#     sops.secrets."zot/alpha-1/laptop-push-auth" = {
#       sopsFile = ./secrets.yaml;
#     };
#     home.packages = with pkgs; [ skopeo regctl crane jq ];
#     sops.templates = dockerAuth.mkTemplates {
#       home = config.home.homeDirectory;
#       placeholders = config.sops.placeholder;
#       registries = {
#         "zot.alpha.1.k8s.quero.lol" = {
#           authSecret = "zot/alpha-1/laptop-push-auth";
#         };
#         # Optional: ghcr.io so `skopeo copy` from the workstation
#         # straight into zot uses our GHCR token too.
#         "ghcr.io" = {
#           authSecret = "github/ghcr-token";
#         };
#       };
#     };
#   }
#
# Each referenced `authSecret` value must contain the raw
# `base64(user:pw)` string — that's what docker's auths[].auth expects.
# `skopeo login --get-login-password` + `base64` is the usual mint path.
{ lib }:

let
  inherit (lib) mkOption types concatStringsSep mapAttrsToList;

  # ── Option types ─────────────────────────────────────────────────

  registryEntrySubmodule = types.submodule {
    options = {
      authSecret = mkOption {
        type = types.str;
        description = ''
          SOPS secret name carrying the raw `base64(user:pw)` string
          docker's `auths[].auth` field expects. The name must match a
          key you've declared in `config.sops.secrets`.
        '';
        example = "zot/alpha-1/laptop-push-auth";
      };
      email = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Optional email to include in the auth entry.";
      };
    };
  };

  # ── Helpers ──────────────────────────────────────────────────────

  # Validate the shape of the input — required arguments present,
  # placeholders attrset contains every referenced secret.
  validate = { home, placeholders, registries }:
    assert (home != null && home != "");
    assert (builtins.isAttrs placeholders);
    assert (builtins.isAttrs registries);
    let
      missing = lib.filter
        (spec: ! (placeholders ? ${spec.authSecret}))
        (lib.attrValues registries);
    in
      if missing != [] then
        throw ''
          docker-auth: the following authSecret entries reference SOPS
          secrets that aren't declared in config.sops.secrets: ${
            lib.concatMapStringsSep ", " (s: s.authSecret) missing
          }
          Add them to your sops.secrets attrset before invoking
          mkTemplates. Example:
            sops.secrets."zot/alpha-1/laptop-push-auth" = {
              sopsFile = ./secrets.yaml;
            };
        ''
      else true;

  # Render the docker config.json content using sops-nix placeholders.
  # sops-nix replaces ${placeholders.<secret>} with the decrypted value
  # at activation time.
  mkDockerConfigContent = { placeholders, registries }:
    let
      authsEntries = mapAttrsToList (host: entry:
        let
          emailField = lib.optionalString (entry.email != null)
            ''"email": "${entry.email}","'';
        in ''
          "${host}": {
            ${emailField}
            "auth": "${placeholders.${entry.authSecret}}"
          }''
      ) registries;
    in ''
      {
        "auths": {
      ${concatStringsSep ",\n" authsEntries}
        }
      }
    '';

in rec {
  inherit registryEntrySubmodule;

  # ── Public API ───────────────────────────────────────────────────

  # `mkTemplates { home, placeholders, registries }` returns an
  # attrset suitable for `sops.templates`. Each entry paths to
  # `<home>/.docker/config.json` with mode 0600 and owns content
  # derived from the `registries` declaration.
  mkTemplates = args @ { home, placeholders, registries }:
    # `assert` forces evaluation of `validate args` eagerly so the
    # "missing placeholder" throw fires at mkTemplates call site rather
    # than later when a consumer dereferences `.content`.
    assert validate args;
    {
      "docker-config.json" = {
        path = "${home}/.docker/config.json";
        mode = "0600";
        content = mkDockerConfigContent {
          inherit placeholders registries;
        };
      };
    };

  # Convenience for callers that want to define their own templates
  # attrset but reuse the content rendering. Exposed for composition.
  inherit mkDockerConfigContent;

  # Standard OCI tooling recommended for workstations that wield zot
  # credentials. Consumers add these to `home.packages` directly —
  # kept as a list helper rather than a Nix closure so the module stays
  # importable without `pkgs`.
  recommendedToolNames = [ "skopeo" "regctl" "crane" "jq" ];

  # ── Tests (pure lib eval) ────────────────────────────────────────
  #
  # Exposed as an attrset so consumers can `lib.runTests` over them.
  tests = {
    testSingleRegistryBuildsAuths = {
      expr =
        let
          out = mkDockerConfigContent {
            placeholders = { "zot/a" = "ZOT_PLACEHOLDER"; };
            registries = {
              "zot.alpha.1.k8s.quero.lol" = {
                authSecret = "zot/a";
                email = null;
              };
            };
          };
        in
          (lib.hasInfix "zot.alpha.1.k8s.quero.lol" out) &&
          (lib.hasInfix "ZOT_PLACEHOLDER" out);
      expected = true;
    };

    testMultiRegistryCoexists = {
      expr =
        let
          out = mkDockerConfigContent {
            placeholders = {
              "zot/a" = "ZOT_PH";
              "github/ghcr" = "GHCR_PH";
            };
            registries = {
              "zot.alpha.1.k8s.quero.lol" = {
                authSecret = "zot/a"; email = null;
              };
              "ghcr.io" = {
                authSecret = "github/ghcr"; email = null;
              };
            };
          };
        in
          (lib.hasInfix "ZOT_PH" out) &&
          (lib.hasInfix "GHCR_PH" out) &&
          (lib.hasInfix "zot.alpha.1.k8s.quero.lol" out) &&
          (lib.hasInfix "ghcr.io" out);
      expected = true;
    };

    testEmailIsEmittedWhenPresent = {
      expr =
        let
          out = mkDockerConfigContent {
            placeholders = { "r" = "PH"; };
            registries = {
              "r.example" = { authSecret = "r"; email = "ops@pleme-io.dev"; };
            };
          };
        in lib.hasInfix "ops@pleme-io.dev" out;
      expected = true;
    };

    testEmailOmittedWhenNull = {
      expr =
        let
          out = mkDockerConfigContent {
            placeholders = { "r" = "PH"; };
            registries = {
              "r.example" = { authSecret = "r"; email = null; };
            };
          };
        in ! (lib.hasInfix "email" out);
      expected = true;
    };

    testMissingPlaceholderThrows = {
      expr = builtins.tryEval (mkTemplates {
        home = "/home/x";
        placeholders = { };  # empty — doesn't include "zot/missing"
        registries = {
          "zot.x" = { authSecret = "zot/missing"; email = null; };
        };
      });
      expected = { success = false; value = false; };
    };

    testMkTemplatesProducesDockerPath = {
      expr =
        let
          t = mkTemplates {
            home = "/home/luis";
            placeholders = { "r" = "PH"; };
            registries = {
              "r.example" = { authSecret = "r"; email = null; };
            };
          };
        in t."docker-config.json".path;
      expected = "/home/luis/.docker/config.json";
    };

    testMkTemplatesSetsMode0600 = {
      expr =
        let
          t = mkTemplates {
            home = "/h";
            placeholders = { "r" = "PH"; };
            registries = {
              "r.example" = { authSecret = "r"; email = null; };
            };
          };
        in t."docker-config.json".mode;
      expected = "0600";
    };

    testRecommendedToolsPresent = {
      expr = builtins.length recommendedToolNames;
      expected = 4;
    };
  };
}
