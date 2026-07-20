# kata.fleet-config — THE BLANKS: the typed configuration contract a
# private fleet repo fills in. This schema IS the template's fill-in
# surface; everything else is vocabulary.
#
# A fleet repo (the pleme-io/nix shape, or any new instantiation) supplies
# exactly one value of this schema (conventionally `fleet.nix`) plus
# per-node hardware files and a secrets file. Unknown keys are REJECTED
# (strict submodules — a typo fails loud at validation, never silently
# ignored).
#
# Exports (pure { lib }):
#
#   fleetConfigModule — the module declaring `kata.fleet.*` options
#                       (evalModules class "kata.fleet");
#   validateFleet :: attrs -> validated config (typed throw on schema
#                    violation; returns config.kata.fleet).
#
# Schema (every blank, typed):
#   name           :: str                       — fleet identifier;
#   domains        :: mkDomains argument set    — tld/locations/transports/
#                     tailnet/sshUsers (see kata.domains);
#   users          :: mkUsers argument set      — users/groups/uidMigration
#                     (see kata.users; `shell` is resolved node-side);
#   trust.fleetKeys      ? [ ]  — ssh public keys trusted fleet-wide;
#   trust.automationKeys ? [ ]  — keys for automation accounts;
#   nodes          :: attrsOf nodeSpec          — mkHostMatrix node shape:
#                     { class ("nixos"|"darwin"), system, hostname ?,
#                       sshUser ?, tags ? [], status ? "live" ("live"|
#                       "down"), statusReason ? "", profiles ? [str]
#                       (names — resolved by the consumer's profile
#                       table),
#                       users ? attrsOf (listOf str) (HM module names),
#                       deploy ? null | { method ? "deploy-rs" } };
#   apps           ? { }  — mkManifest apps (ecosystem schema verbatim);
#   appClasses     ? { }  — mkManifest classes;
#   caches         ? [ ]  — [{ url :: str; publicKey :: str }];
#   secrets        :: { backend ? "sops" ("sops"|"akeyless");
#                       defaultSopsFile ? null (nullOr path);
#                       ageKeyFile ? null (nullOr str); };
{ lib }:
let
  core = import ../iroha/core.nix { inherit lib; };
  inherit (lib) types mkOption;

  freeAttrs =
    desc:
    mkOption {
      type = types.attrsOf types.anything;
      default = { };
      description = desc;
    };

  nodeSpec = types.submodule {
    options = {
      class = mkOption {
        type = types.enum [
          "nixos"
          "darwin"
        ];
        description = "Module class realizing this node.";
      };
      system = mkOption {
        type = types.str;
        description = "Nix system string (e.g. aarch64-darwin).";
      };
      hostname = core.mkField {
        type = "nullOrStr";
        default = null;
        description = "Override hostname (default: node name; FQDN derives via kata.domains).";
      };
      sshUser = core.mkField {
        type = "nullOrStr";
        default = null;
        description = "Deploy ssh user (default: domains.sshUserFor).";
      };
      tags = core.mkField {
        type = "listOfStr";
        default = [ ];
        description = "Free-form tags (vm, k3s, ...) driving projections.";
      };
      # ── Liveness: the TYPED single source, never a magic tag ────────────
      # "down" = retired / offline / unreachable. MODULARIZE, DON'T DELETE:
      # a down node keeps its declaration (and its domain, vpn-link, users
      # and secret entries) verbatim — only the PROJECTIONS drop it, so a
      # retired node is never blindly deploy-targeted + retried, and comes
      # back by flipping one field. mkFleet's projectNode nulls a down
      # node's `deploy` block, which removes it from deployRs/colmena by
      # construction; nixosConfigurations/darwinConfigurations still build
      # it, and `report` still lists it (carrying status + statusReason).
      status = mkOption {
        type = types.enum [
          "live"
          "down"
        ];
        default = "live";
        description = "Node liveness. \"down\" = retired/offline/unreachable — the declaration stays, the deploy projections drop it.";
      };
      statusReason = core.mkField {
        type = "str";
        default = "";
        description = "Free text explaining a non-live status: why, and since when (e.g. \"retired 2026-07-02 — replaced by camelot\").";
      };
      profiles = core.mkField {
        type = "listOfStr";
        default = [ ];
        description = "Profile NAMES — resolved against the consumer's profile table at mkFleet time.";
      };
      users = mkOption {
        type = types.attrsOf (types.listOf types.str);
        default = { };
        description = "Per-user HM module names on this node.";
      };
      deploy = mkOption {
        type = types.nullOr (
          types.submodule {
            options.method = mkOption {
              type = types.enum [
                "deploy-rs"
                "colmena"
              ];
              default = "deploy-rs";
            };
          }
        );
        default = null;
        description = "Deployment wiring (null = local-only node).";
      };
    };
  };

  fleetConfigModule = {
    _class = "kata.fleet";
    options.kata.fleet = {
      name = mkOption {
        type = types.str;
        description = "Fleet identifier.";
      };
      domains = freeAttrs "kata.domains.mkDomains argument set (tld, locations, transports, ...).";
      users = freeAttrs "kata.users.mkUsers argument set (users, groups, uidMigration).";
      trust = {
        fleetKeys = core.mkField {
          type = "listOfStr";
          default = [ ];
          description = "SSH public keys trusted fleet-wide (interactive users).";
        };
        automationKeys = core.mkField {
          type = "listOfStr";
          default = [ ];
          description = "SSH public keys for automation accounts.";
        };
      };
      nodes = mkOption {
        type = types.attrsOf nodeSpec;
        default = { };
        description = "The fleet's machines (mkHostMatrix node shape, profile names unresolved).";
      };
      apps = freeAttrs "iroha.mkManifest `apps` (ecosystem schema verbatim).";
      appClasses = freeAttrs "iroha.mkManifest `classes`.";
      vpnLinks = freeAttrs "kata.mkWireguardLinks `registry` — attrsOf link (point-to-point or hub-and-spoke). When non-empty, mkFleet exposes `wireguard` (the per-node projection).";
      caches = mkOption {
        type = types.listOf (
          types.submodule {
            options = {
              url = mkOption { type = types.str; };
              publicKey = mkOption { type = types.str; };
            };
          }
        );
        default = [ ];
        description = "Binary caches (substituter + trusted key pairs).";
      };
      secrets = {
        backend = mkOption {
          type = types.enum [
            "sops"
            "akeyless"
          ];
          default = "sops";
          description = "Secret materialization backend.";
        };
        defaultSopsFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "The fleet's encrypted secrets file.";
        };
        ageKeyFile = core.mkField {
          type = "nullOrStr";
          default = null;
          description = "Path to the age key on each node.";
        };
      };
    };
  };

  validateFleet =
    cfg:
    (lib.evalModules {
      class = "kata.fleet";
      modules = [
        fleetConfigModule
        {
          _file = "<kata:fleet-config:instance>";
          kata.fleet = cfg;
        }
      ];
    }).config.kata.fleet;
in
{
  inherit fleetConfigModule validateFleet;
}
