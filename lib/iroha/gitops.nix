# iroha.gitops — L2: a pull-based GitOps RECONCILE MODULE emitter.
#
# The pull-GitOps pattern is a per-platform pair behind ONE option surface:
# on NixOS the node reconciles itself to a flake repo via `services.comin`
# (the comin pull-deploy daemon — watches a git remote, builds + switches the
# host's nixosConfiguration on every new commit); on macOS there is no comin,
# so the equivalent is a `launchd.daemons.<name>-reconcile` periodic job that
# runs `darwin-rebuild switch --flake <repo>#<attr>` on an interval. Both are
# "the node continuously pulls its desired state from a git repo and applies
# it" — this letter is the single typed declaration the ~per-node hand-rolled
# comin block (NixOS) and the hand-rolled launchd darwin-rebuild timer (macOS)
# collapse into. It does NOT emit a package option (comin / darwin-rebuild are
# resolved by the platform) and it does NOT emit a home-manager projection
# (pull-GitOps reconciles a SYSTEM, not a user).
#
# The flake attribute the node reconciles to (the nixosConfigurations /
# darwinConfigurations key) is `flakeAttr` when given, else the host's own
# name resolved at module-eval time from `config.networking.hostName` (NixOS)
# / `config.networking.hostName` (nix-darwin both expose it) — so the default
# is "reconcile to the configuration named after this host", the near-universal
# convention. The launchd ProgramArguments are a verbatim argv (no escaping):
# [ darwinCommand "switch" "--flake" "<repo>#<attr>" ].
#
# COMPOSES iroha.mkOptionSurface for the enable + extraOptions skeleton
# (package = false, settings = null) and iroha.core.tag for class tagging.
#
# Exports (pure { lib }, zero pkgs — pkgs binds late as a module arg):
#
#   mkGitopsModule :: {
#     name        ? "gitops"        — unit name + last option-path segment;
#     description ? "pull-based GitOps reconcile" — enable option text;
#     namespace   ? "services"      — dotted option root; lands at
#                                     <namespace>.<name>;
#     enable      ? true            — emit the `enable` option (mkEnableOption);
#     extraOptions ? { } | (lib -> attrs) — extra typed option declarations
#                                     merged under the option root (function
#                                     form receives lib);
#     repository  :: str (required) — the flake repo URL/ref the node
#                                     reconciles to (comin remote url / the
#                                     `--flake <repo>#…` repo half);
#     branch      ? "main"          — the git branch comin tracks / the darwin
#                                     timer pins (documented; the launchd
#                                     `--flake <repo>#<attr>` ref does not carry
#                                     a branch, so branch is comin-load-bearing
#                                     and darwin-informational);
#     interval    ? 300             — seconds between reconciles (comin
#                                     poller period / launchd StartInterval);
#     flakeAttr   ? null (str)      — the nixosConfigurations /
#                                     darwinConfigurations attr; null resolves
#                                     to the host name at module-eval time;
#     nixosBackend ? "comin"        — pull-deploy backend on NixOS; only
#                                     "comin" is supported (a typed throw on
#                                     any other value — the seam future
#                                     backends extend);
#     darwinCommand ? "darwin-rebuild" — the rebuild command the launchd
#                                     reconcile runs (`<cmd> switch --flake …`);
#   } -> {
#     nixos :: class-tagged module (_class "nixos") —
#       options.<ns>.<name>.{ enable, …extraOptions };
#       config = mkIf cfg.enable {
#         services.comin = {
#           enable = true;
#           remotes = [ {
#             name = "origin";
#             url = repository;
#             branches.main.name = branch;
#             poller.period = interval;   # seconds
#           } ];
#         };
#       };
#       (the documented comin remote shape — url + the single tracked branch +
#        the poller period; comin's own option surface owns every other knob.)
#     darwin :: class-tagged module (_class "darwin") —
#       config = mkIf cfg.enable {
#         launchd.daemons.<name>-reconcile.serviceConfig = {
#           ProgramArguments = [ darwinCommand "switch" "--flake"
#                                "<repository>#<attr>" ];
#           StartInterval = interval;
#           RunAtLoad = true;
#           KeepAlive = false;
#         };
#       };
#       where <attr> = flakeAttr or config.networking.hostName.
#       Tier-honest: macOS has no comin; this is the periodic-pull equivalent —
#       a launchd job that re-runs the host's rebuild against the flake repo.
#     meta :: { name, optionPath, enablePath, repository, kind = "gitops" };
#   }
#
# Throws (every message prefixed "iroha.gitops.mkGitopsModule: "):
#   - `repository` missing;
#   - `interval` not an int;
#   - `nixosBackend` not "comin".
{ lib }:
let
  core = import ./core.nix { inherit lib; };
  optionSurface = import ./option-surface.nix { inherit lib; };
  inherit (lib) optionalAttrs;

  validNixosBackends = [ "comin" ];

  mkGitopsModule =
    args:
    let
      name = args.name or "gitops";
      description = args.description or "pull-based GitOps reconcile";
      namespace = args.namespace or "services";
      enable = args.enable or true;
      extraOptions = args.extraOptions or { };

      repository =
        args.repository
          or (throw "iroha.gitops.mkGitopsModule: `repository` (str — the flake repo URL/ref the node reconciles to) is required.");

      branch = args.branch or "main";

      rawInterval = args.interval or 300;
      interval =
        if builtins.isInt rawInterval then
          rawInterval
        else
          throw "iroha.gitops.mkGitopsModule: `interval` must be an int (seconds between reconciles) — got ${builtins.typeOf rawInterval}.";

      flakeAttr = args.flakeAttr or null;

      nixosBackend = args.nixosBackend or "comin";
      _backendChecked =
        if builtins.elem nixosBackend validNixosBackends then
          nixosBackend
        else
          throw "iroha.gitops.mkGitopsModule: `nixosBackend` must be one of ${lib.concatStringsSep ", " validNixosBackends} — got '${toString nixosBackend}'.";

      darwinCommand = args.darwinCommand or "darwin-rebuild";

      # ── option surface (enable + extras; no package, no settings) ───────
      surface = optionSurface.mkOptionSurface {
        inherit
          name
          description
          namespace
          enable
          ;
        package = false;
        settings = null;
        extra = extraOptions;
      };

      optionPath = surface.optionPath;
      enablePath = surface.enablePath;

      # ── NixOS: services.comin (the comin pull-deploy daemon) ────────────
      # `_backendChecked` is referenced via `builtins.seq` so an invalid
      # `nixosBackend` throws when the comin config is realized (it is the
      # backend selector for this NixOS projection; only "comin" is wired).
      cominConfig = builtins.seq _backendChecked {
        enable = true;
        remotes = [
          {
            name = "origin";
            url = repository;
            branches.main.name = branch;
            poller.period = interval;
          }
        ];
      };

      nixosFragment =
        {
          config,
          ...
        }:
        let
          cfg = lib.getAttrFromPath optionPath config;
        in
        {
          config = lib.mkIf cfg.enable {
            services.comin = cominConfig;
          };
        };

      # ── macOS: launchd periodic darwin-rebuild reconcile ────────────────
      # <attr> = flakeAttr (verbatim) or the host name resolved at eval time.
      reconcileName = "${name}-reconcile";

      mkFlakeRef = attr: "${repository}#${attr}";

      darwinFragment =
        {
          config,
          ...
        }:
        let
          cfg = lib.getAttrFromPath optionPath config;
          attr = if flakeAttr != null then flakeAttr else config.networking.hostName;
        in
        {
          config = lib.mkIf cfg.enable {
            launchd.daemons.${reconcileName}.serviceConfig = {
              ProgramArguments = [
                darwinCommand
                "switch"
                "--flake"
                (mkFlakeRef attr)
              ];
              StartInterval = interval;
              RunAtLoad = true;
              KeepAlive = false;
            };
          };
        };

      mkClassModule =
        class: fragment:
        core.tag class {
          imports = [
            surface.module
            fragment
          ];
        };
    in
    {
      nixos = mkClassModule core.classes.nixos nixosFragment;
      darwin = mkClassModule core.classes.darwin darwinFragment;
      meta = {
        inherit name optionPath enablePath repository;
        kind = "gitops";
      };
    };
in
{
  inherit mkGitopsModule;
}
