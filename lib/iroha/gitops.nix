# iroha.gitops — L2: a pull-based GitOps RECONCILE MODULE emitter.
#
# ONE typed declaration renders all three platform arms of "this node
# continuously pulls its desired state from a git repo and applies it":
#
#   nixos       services.comin (the upstream pull-deploy daemon)
#   darwin      sentinela (default — the attested Rust daemon) or the
#               legacy periodic `darwin-rebuild switch` timer (`script`)
#   homeManager the OBSERVER — status binary on the user PATH, and
#               deliberately NO second reconcile loop (see below)
#
# ── ★ ONE TYPED SOURCE, EVERY URL SPELLING DERIVED ──────────────────────
# The backends need the same repository spelled incompatibly: comin clones
# with git and needs `https://github.com/o/r.git`; `darwin-rebuild --flake`
# needs `github:o/r`. A single `repository :: str` (this letter's original
# input) could only ever be right for one of them — and the fleet's
# hand-rolled modules shipped exactly that split, with the Darwin arm
# reverse-parsing its own value via `builtins.match "github:([^/]+)/(.+)"`
# to recover the fields it needed. Parsing a string back into the fields it
# should never have lost is the signal that the string was the wrong type.
#
# So the input is the FIELDS and each renderer derives its own spelling:
#
#   source = { kind = "github"; owner = "pleme-io"; repo = "nix";
#              branch = "main"; }
#     -> gitUrl   "https://github.com/pleme-io/nix.git"   (comin, ls-remote)
#     -> flakeRef "github:pleme-io/nix"                   (--flake)
#
#   source = { kind = "git"; url = "https://git.example.org/f.git"; }
#     -> gitUrl   as given;  flakeRef  "git+<url>"
#
# A caller cannot supply a mismatched pair because there is no pair to
# supply. `repository` is retired and THROWS with a migration message.
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
#     enable      ? true            — emit the `enable` option;
#     extraOptions ? { } | (lib -> attrs) — extra typed option declarations;
#     source      :: required       — { kind = "github"; owner; repo;
#                                     branch ? "main"; } or
#                                     { kind = "git"; url; branch ? "main"; }
#     interval    ? 300             — seconds between reconciles (comin
#                                     poller period / sentinela poll /
#                                     launchd StartInterval);
#     flakeAttr   ? null (str)      — the nixos/darwinConfigurations attr;
#                                     null resolves to the host name at
#                                     module-eval time. REQUIRED for the
#                                     sentinela backend, whose config
#                                     document is rendered at build time and
#                                     cannot read config.networking.hostName;
#     nixosBackend  ? "comin"       — closed sum; typed throw otherwise;
#     darwinBackend ? "sentinela"   — closed sum: "sentinela" | "script";
#     sentinelaBin  ? null          — store path; REQUIRED when
#                                     darwinBackend = "sentinela";
#     stateDir    ? "/var/log/pleme-gitops"    — receipts + heartbeat + logs;
#     configPath  ? "/etc/pleme-gitops/config.yaml";
#     tokenFile   ? null            — token for ls-remote against a private
#                                     repo (the daemon runs as root and has
#                                     no git credentials of its own);
#     cooldownAfterFailureSeconds ? 300;
#     extraRebuildArgs ? [ ];
#     darwinCommand ? "darwin-rebuild" — `script` backend only;
#   } -> { nixos; darwin; homeManager; meta }
#
# ── ★ WHY THE DARWIN DEFAULT IS THE DAEMON ──────────────────────────────
# A bare `darwin-rebuild switch --flake` on a StartInterval is structurally
# a rollback machine, measured twice on ryn (2026-07-02): nix's `github:`
# fetcher deploys a CACHED tarball on an API 403; a run that starts before
# a push finishes after it and re-registers the older system; and a
# multi-minute build under a 60s interval stacks overlapping switches. The
# `script` arm stays selectable (retirement is a typed flag, never a
# deletion) but a node must opt INTO it.
#
# ── ★ WHY home-manager OBSERVES AND DOES NOT RECONCILE ──────────────────
# Pull-GitOps converges a SYSTEM, and in this fleet home-manager is
# activated as part of that system switch. An HM arm running its own
# `home-manager switch` would be a second loop racing the first for the
# same generation. What the user scope legitimately owns is READING the
# verdict: the reconciler runs as root and writes root-owned state, so
# without this arm an operator has no user-scope way to ask "is my machine
# at HEAD?" — which is how a dead daemon went unnoticed on cid while every
# human-facing surface stayed silent. The arm ships the status binary and
# nothing else, and because it is an arm of the SAME declaration it can
# never drift from the daemon it reports on.
#
# meta :: { name, optionPath, enablePath, repository, source, gitUrl,
#           flakeRef, nixosBackend, darwinBackend, kind = "gitops" }
#   — gitUrl/flakeRef are exposed so a test can assert the two derived
#     spellings agree rather than trusting that they do.
#
# Throws (every message prefixed "iroha.gitops.mkGitopsModule: "):
#   - `repository` passed (retired — migrate to `source`);
#   - `source` missing / unknown `source.kind` / missing required field;
#   - `interval` not an int;
#   - `nixosBackend` not "comin"; `darwinBackend` not in the closed sum;
#   - `sentinelaBin` or `flakeAttr` missing under the sentinela backend.
{ lib }:
let
  core = import ./core.nix { inherit lib; };
  optionSurface = import ./option-surface.nix { inherit lib; };
  inherit (lib) optionalAttrs;

  validNixosBackends = [ "comin" ];
  # `sentinela` is the attested Rust daemon (one KeepAlive process, typed
  # BLAKE3 receipts, a per-tick heartbeat, fail-closed). `script` is the
  # legacy launchd `StartInterval` + bare `darwin-rebuild switch` timer,
  # kept selectable per ★★ MODULARIZE, DON'T DELETE — retirement is a typed
  # flag, never a deletion — but it is NOT the default, because it is a
  # rollback machine (see the `script` arm's own comment).
  validDarwinBackends = [
    "sentinela"
    "script"
  ];

  # ── ★ THE SOURCE IS ONE TYPED VALUE, AND BOTH URL FORMS DERIVE FROM IT ──
  # The two backends need the SAME repository spelled two incompatible ways:
  #
  #   comin `remotes[].url`      https://github.com/pleme-io/nix.git
  #   `darwin-rebuild --flake`   github:pleme-io/nix
  #
  # The previous `repository :: str` took one of them, so whichever you
  # passed, the other arm was wrong — the factory could not emit a working
  # pair at all. In the fleet's hand-rolled modules the same split shipped
  # for real: `pleme.gitops.flakeUrl` meant a flake ref on Darwin and a git
  # URL on NixOS, and the Darwin arm reverse-parsed its own value with
  # `builtins.match "github:([^/]+)/(.+)"` to recover the pieces it needed.
  #
  # Parsing a string back into the fields it should never have lost is the
  # signal that the string was the wrong type. So the input is the FIELDS,
  # and each renderer derives the spelling it needs. A caller cannot supply
  # a mismatched pair because there is no longer a pair to supply.
  parseSource =
    src:
    let
      kind =
        src.kind
          or (throw "iroha.gitops.mkGitopsModule: `source.kind` is required — one of \"github\", \"git\".");
      req =
        f:
        src.${f}
          or (throw "iroha.gitops.mkGitopsModule: `source.${f}` is required when source.kind = \"${kind}\".");
    in
    if kind == "github" then
      let
        owner = req "owner";
        repo = req "repo";
        branch = src.branch or "main";
      in
      {
        inherit kind owner repo branch;
        # The git-protocol URL: comin's remote, and sentinela's `ls-remote`.
        # Rate-limit-immune by construction — the GitHub API is never on the
        # resolution path, so an API 403 cannot substitute a stale cached
        # tree (the failure that rolled ryn back on 2026-07-02).
        gitUrl = "https://github.com/${owner}/${repo}.git";
        # The flake ref: `nix`/`darwin-rebuild --flake <ref>#<attr>`.
        flakeRef = "github:${owner}/${repo}";
      }
    else if kind == "git" then
      let
        url = req "url";
        branch = src.branch or "main";
      in
      {
        inherit kind url branch;
        gitUrl = url;
        # A bare git URL is already a valid flake ref (`git+https://…`);
        # only add the scheme prefix when it is not spelled that way.
        flakeRef = if lib.hasPrefix "git+" url then url else "git+${url}";
      }
    else
      throw "iroha.gitops.mkGitopsModule: `source.kind` must be one of \"github\", \"git\" — got \"${toString kind}\".";

  mkGitopsModule =
    args:
    let
      name = args.name or "gitops";
      description = args.description or "pull-based GitOps reconcile";
      namespace = args.namespace or "services";
      enable = args.enable or true;
      extraOptions = args.extraOptions or { };

      # The retired single-string input. A typed throw rather than a silent
      # coercion: a caller passing `repository` is passing exactly one of
      # the two spellings and would get a broken arm on the other platform.
      _repositoryRetired =
        if args ? repository then
          throw "iroha.gitops.mkGitopsModule: `repository` (str) is retired — it could only ever be spelled correctly for ONE of the two backends. Pass a typed `source` instead: { kind = \"github\"; owner = \"…\"; repo = \"…\"; branch = \"main\"; } (or { kind = \"git\"; url = \"…\"; }). Both the comin git URL and the darwin flake ref are derived from it."
        else
          null;

      source = builtins.seq _repositoryRetired (parseSource (
        args.source
          or (throw "iroha.gitops.mkGitopsModule: `source` is required — { kind = \"github\"; owner = \"…\"; repo = \"…\"; } or { kind = \"git\"; url = \"…\"; }.")
      ));

      repository = source.flakeRef;
      branch = source.branch;

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

      darwinBackend = args.darwinBackend or "sentinela";
      _darwinBackendChecked =
        if builtins.elem darwinBackend validDarwinBackends then
          darwinBackend
        else
          throw "iroha.gitops.mkGitopsModule: `darwinBackend` must be one of ${lib.concatStringsSep ", " validDarwinBackends} — got '${toString darwinBackend}'.";

      # Path to the sentinela binary. Required when the sentinela backend is
      # selected — a store path, not a bare name, so the daemon never
      # depends on PATH resolution inside launchd.
      sentinelaBin = args.sentinelaBin or null;
      stateDir = args.stateDir or "/var/log/pleme-gitops";
      configPath = args.configPath or "/etc/pleme-gitops/config.yaml";
      tokenFile = args.tokenFile or null;
      cooldownAfterFailureSeconds = args.cooldownAfterFailureSeconds or 300;

      # The sentinela config document, derived from the SAME typed source
      # every other arm reads. snake_case to match its serde surface.
      sentinelaSettings = {
        flake_url = source.flakeRef;
        hostname = flakeAttrOrHost;
        poll_seconds = interval;
        state_dir = stateDir;
        extra_rebuild_args = args.extraRebuildArgs or [ ];
        rev_probe = {
          git_url = source.gitUrl;
          branch = source.branch;
          token_file = tokenFile;
        };
        cooldown_after_failure_ms = cooldownAfterFailureSeconds * 1000;
      };
      # `flakeAttr` may be null (resolve to the host at module-eval time),
      # but the config document is built outside the module. Callers that
      # want the daemon backend therefore pass `flakeAttr` explicitly; the
      # throw names that requirement instead of silently writing "null".
      flakeAttrOrHost =
        if flakeAttr != null then
          flakeAttr
        else
          throw "iroha.gitops.mkGitopsModule: `flakeAttr` is required when darwinBackend = \"sentinela\" — the rendered config document needs the darwinConfigurations attribute at build time, and cannot read config.networking.hostName. Pass the host name.";

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
            # comin clones with git directly, so it needs the GIT URL —
            # never the flake ref. Handing it `github:owner/repo` produces a
            # remote it cannot fetch, and pull-mode then stalls silently
            # (comin logs a fetch error; nothing else reports it). This is
            # exactly the confusion the typed source removes: the field is
            # derived, so it cannot be given the other spelling.
            url = source.gitUrl;
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

      # ── macOS backend: `script` — the legacy periodic rebuild ───────────
      # ★ RETAINED, NOT RECOMMENDED. A bare `darwin-rebuild switch --flake`
      # on a `StartInterval` is structurally a ROLLBACK MACHINE, measured
      # twice on ryn (2026-07-02):
      #   1. nix's `github:` fetcher falls back to a CACHED tarball on an
      #      API 403 and deploys it — rolling the node back to whatever was
      #      cached (0.1.53 -> 0.1.48).
      #   2. a run that starts before a push and finishes after it
      #      re-registers the OLDER system over the newer one.
      #   3. no single-flight: a multi-minute build under a 60s interval
      #      stacks overlapping switches contending on activation locks.
      # It stays selectable because retirement is a typed flag rather than a
      # deletion, and because a node mid-migration may need it. It is not
      # the default.
      scriptDarwinFragment =
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

      # ── macOS backend: `sentinela` — the attested daemon (default) ──────
      # ONE KeepAlive process that loops internally, so single-flight is
      # structural rather than a lock. It resolves HEAD over the git
      # protocol (never the GitHub API), builds rev-pinned, RE-probes before
      # activating (so a mid-build push defers instead of rolling back),
      # attests each deploy to a BLAKE3 chain, and writes a heartbeat every
      # tick — the last of which is what lets a reader tell a converged loop
      # from a dead one.
      sentinelaDarwinFragment =
        {
          config,
          ...
        }:
        let
          cfg = lib.getAttrFromPath optionPath config;
          bin =
            if sentinelaBin != null then
              sentinelaBin
            else
              throw "iroha.gitops.mkGitopsModule: `sentinelaBin` (path to the sentinela binary) is required when darwinBackend = \"sentinela\".";
        in
        {
          config = lib.mkIf cfg.enable {
            environment.etc."pleme-gitops/config.yaml".text = builtins.toJSON sentinelaSettings;
            # ★ THE BINARY MUST BE REACHABLE, NOT ONLY REFERENCED. When it
            # exists solely as a store path inside the plist, `sentinela
            # status` — the one surface that reports whether this node is
            # converging — cannot be run by the operator or by a rebuild
            # wrapper. That is how 4136 consecutive failed ticks stayed
            # invisible for 27.9 days on ryn.
            environment.systemPackages = [ bin ];
            launchd.daemons.${reconcileName}.serviceConfig = {
              ProgramArguments = [
                "${bin}/bin/sentinela"
                "run"
              ];
              KeepAlive = true;
              RunAtLoad = true;
              StandardOutPath = "${stateDir}/stdout.log";
              StandardErrorPath = "${stateDir}/stderr.log";
              EnvironmentVariables = {
                SENTINELA_CONFIG = configPath;
                NIX_CONFIG = "experimental-features = nix-command flakes";
              };
            };
          };
        };

      darwinFragment =
        builtins.seq _darwinBackendChecked (
          if darwinBackend == "sentinela" then sentinelaDarwinFragment else scriptDarwinFragment
        );

      # ── home-manager: the OBSERVER, deliberately not a reconciler ───────
      # ★ WHY THIS ARM DOES NOT RECONCILE. Pull-GitOps converges a SYSTEM,
      # and in this fleet home-manager is activated as part of that system
      # switch. An HM arm that ran its own `home-manager switch` would be a
      # second loop racing the first for the same generation — the exact
      # "no third loop" that fleet doctrine forbids.
      #
      # What the user scope legitimately owns is READING the verdict. The
      # reconciler runs as root and writes root-owned state; without this
      # arm the operator has no user-scope way to ask "is my machine at
      # HEAD?" — which is how a dead daemon went unnoticed while every
      # human-facing surface stayed silent. So the HM projection puts the
      # status binary on the user's PATH and nothing else. It is an arm of
      # the same typed declaration, so it can never drift from the daemon it
      # reports on.
      hmFragment =
        { config, ... }:
        let
          cfg = lib.getAttrFromPath optionPath config;
        in
        {
          config = lib.mkIf cfg.enable {
            home.packages = lib.optionals (sentinelaBin != null) [ sentinelaBin ];
            home.sessionVariables.SENTINELA_CONFIG = configPath;
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
      homeManager = mkClassModule core.classes.homeManager hmFragment;
      meta = {
        inherit
          name
          optionPath
          enablePath
          repository
          source
          nixosBackend
          ;
        # The validated value: reading it from meta forces the closed-sum
        # check, so an invalid backend cannot be observed as if it were
        # accepted.
        darwinBackend = _darwinBackendChecked;
        kind = "gitops";
        # Both spellings, derived from the one typed source — exposed so a
        # test can assert they agree rather than trusting that they do.
        gitUrl = source.gitUrl;
        flakeRef = source.flakeRef;
      };
    };
  # ── the source algebra, exported for option-level consumers ──────────
  # A repo whose nodes VARY (one host tracking a different fork/branch)
  # needs `source` to be a module OPTION, not a call-time argument — and
  # must still derive the two spellings the same way, or the divergence
  # this letter removes grows back one layer up. So the type and the
  # derivation are exported rather than sealed inside mkGitopsModule.
  #
  # `check` mirrors parseSource's requirements so a malformed source is an
  # OPTION-TYPE error at the definition site (naming the offending node)
  # rather than a throw from deep inside a renderer.
  gitopsSourceType = lib.types.submodule {
    options = {
      kind = lib.mkOption {
        type = lib.types.enum [
          "github"
          "git"
        ];
        description = "Which source shape this is; selects the required fields.";
      };
      owner = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "GitHub owner (kind = \"github\").";
      };
      repo = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "GitHub repository name (kind = \"github\").";
      };
      url = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Git URL (kind = \"git\").";
      };
      branch = lib.mkOption {
        type = lib.types.str;
        default = "main";
        description = "The branch whose HEAD is the deploy target.";
      };
    };
  };

  # attrs -> { kind; branch; gitUrl; flakeRef; … }. The ONE place the two
  # spellings are derived; every renderer and every consumer reads it.
  deriveSource = parseSource;
in
{
  inherit mkGitopsModule gitopsSourceType deriveSource;
}
