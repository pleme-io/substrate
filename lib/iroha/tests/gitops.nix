# Tests — iroha.gitops (pull-based GitOps reconcile module emitter:
# option surface + services.comin (NixOS) + launchd.daemons.<name>-reconcile
# darwin-rebuild periodic job (macOS), flakeAttr default-to-hostname +
# override, branch + interval, class tagging, typed throws).
{ lib, iroha }:
let
  inherit (iroha) mkGitopsModule deriveSource gitopsSourceType;

  # ── stub option universes ────────────────────────────────────────────
  # services.comin (NixOS pull-deploy daemon) + an option root for extras.
  nixosUniverse =
    { lib, ... }:
    {
      options = {
        services.comin = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
      };
    };
  # launchd.daemons + networking.hostName (the darwin fragment resolves the
  # default flake attr from the host name).
  darwinUniverse =
    { lib, ... }:
    {
      options = {
        launchd.daemons = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        networking.hostName = lib.mkOption {
          type = lib.types.str;
          default = "cid";
        };
        # The sentinela backend renders its config to /etc and puts the
        # binary on the system PATH, so both must exist in the universe or
        # the darwin arm cannot be evaluated at all.
        environment.etc = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        environment.systemPackages = lib.mkOption {
          type = lib.types.listOf lib.types.anything;
          default = [ ];
        };
      };
    };

  evalNixos =
    modules:
    lib.evalModules {
      class = "nixos";
      modules = [
        nixosUniverse
        { _module.args.pkgs = { }; }
      ]
      ++ modules;
    };
  evalDarwin =
    modules:
    lib.evalModules {
      class = "darwin";
      modules = [
        darwinUniverse
        { _module.args.pkgs = { }; }
      ]
      ++ modules;
    };
  # home-manager universe: home.packages / sessionVariables, plus a
  # launchd.agents option that MUST stay empty — the assertion that the HM
  # arm observes rather than reconciles needs somewhere an agent could
  # have landed, or its emptiness proves nothing.
  hmUniverse =
    { lib, ... }:
    {
      options = {
        home.packages = lib.mkOption {
          type = lib.types.listOf lib.types.anything;
          default = [ ];
        };
        home.sessionVariables = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        launchd.agents = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
      };
    };
  evalHm =
    modules:
    lib.evalModules {
      class = "homeManager";
      modules = [
        hmUniverse
        { _module.args.pkgs = { }; }
      ]
      ++ modules;
    };

  enable = { services.gitops.enable = true; };

  # ── specs under test ─────────────────────────────────────────────────
  # Canonical: all defaults (name=gitops, branch=main, interval=300, comin).
  gitops = mkGitopsModule {
    source = {
      kind = "github";
      owner = "pleme-io";
      repo = "nix";
    };
    darwinBackend = "script";
  };

  # custom branch + interval, explicit flakeAttr override.
  pinned = mkGitopsModule {
    source = {
      kind = "github";
      owner = "pleme-io";
      repo = "nix";
      branch = "production";
    };
    interval = 600;
    flakeAttr = "rio";
    darwinBackend = "script";
  };

  # custom name + namespace + extra typed options + custom darwinCommand.
  fancy = mkGitopsModule {
    name = "fleet-reconcile";
    description = "fleet pull reconcile";
    namespace = "blackmatter.services";
    darwinCommand = "/run/current-system/sw/bin/darwin-rebuild";
    extraOptions = l: {
      paused = l.mkOption {
        type = l.types.bool;
        default = false;
      };
    };
    source = {
      kind = "git";
      url = "https://git.example.org/fleet.git";
    };
    interval = 120;
    darwinBackend = "script";
  };
in
{
  # ── NixOS enabled: services.comin enabled + remote url == repository ──
  nixos-comin-enabled-and-remote-url = {
    expr =
      let
        c = (evalNixos [ gitops.nixos enable ]).config.services.comin;
        remote = builtins.head c.remotes;
      in
      {
        cominEnable = c.enable;
        url = remote.url;
        remoteName = remote.name;
      };
    expected = {
      cominEnable = true;
      # The GIT url — comin clones directly and cannot fetch a flake ref.
      url = "https://github.com/pleme-io/nix.git";
      remoteName = "origin";
    };
  };
  nixos-comin-branch-and-interval = {
    expr =
      let
        remote = builtins.head (evalNixos [ pinned.nixos enable ]).config.services.comin.remotes;
      in
      {
        branch = remote.branches.main.name;
        period = remote.poller.period;
        url = remote.url;
      };
    expected = {
      branch = "production";
      period = 600;
      url = "https://github.com/pleme-io/nix.git";
    };
  };
  nixos-default-branch-and-interval = {
    expr =
      let
        remote = builtins.head (evalNixos [ gitops.nixos enable ]).config.services.comin.remotes;
      in
      {
        branch = remote.branches.main.name;
        period = remote.poller.period;
      };
    expected = {
      branch = "main";
      period = 300;
    };
  };

  # ── NixOS disabled: services.comin stays empty ───────────────────────
  nixos-disabled-emits-nothing = {
    expr = (evalNixos [ gitops.nixos ]).config.services.comin;
    expected = { };
  };

  # ── darwin enabled: launchd ProgramArguments has darwinCommand + ──────
  #    the flake ref (repo#attr, attr defaulting to host name) + interval.
  darwin-reconcile-programarguments-default-attr = {
    expr =
      let
        sc = (evalDarwin [ gitops.darwin enable ]).config.launchd.daemons."gitops-reconcile".serviceConfig;
      in
      {
        prog = sc.ProgramArguments;
        interval = sc.StartInterval;
        runAtLoad = sc.RunAtLoad;
        keepAlive = sc.KeepAlive;
      };
    expected = {
      # attr defaults to networking.hostName = "cid" (stub universe).
      prog = [
        "darwin-rebuild"
        "switch"
        "--flake"
        "github:pleme-io/nix#cid"
      ];
      interval = 300;
      runAtLoad = true;
      keepAlive = false;
    };
  };
  darwin-reconcile-flakeattr-override = {
    expr =
      (evalDarwin [
        pinned.darwin
        { services.gitops.enable = true; }
      ]).config.launchd.daemons."gitops-reconcile".serviceConfig.ProgramArguments;
    expected = [
      "darwin-rebuild"
      "switch"
      "--flake"
      "github:pleme-io/nix#rio"
    ];
  };
  darwin-custom-name-command-and-interval = {
    expr =
      let
        sc = (evalDarwin [
          fancy.darwin
          { blackmatter.services.fleet-reconcile.enable = true; }
        ]).config.launchd.daemons."fleet-reconcile-reconcile".serviceConfig;
      in
      {
        prog = sc.ProgramArguments;
        interval = sc.StartInterval;
      };
    expected = {
      prog = [
        "/run/current-system/sw/bin/darwin-rebuild"
        "switch"
        "--flake"
        "git+https://git.example.org/fleet.git#cid"
      ];
      interval = 120;
    };
  };

  # ── darwin disabled: launchd.daemons stays empty ─────────────────────
  darwin-disabled-emits-nothing = {
    expr = (evalDarwin [ gitops.darwin ]).config.launchd.daemons;
    expected = { };
  };

  # ── extraOptions land + are settable ─────────────────────────────────
  extra-options-default-and-settable = {
    expr = {
      dflt = (evalNixos [
        fancy.nixos
        { blackmatter.services.fleet-reconcile.enable = true; }
      ]).config.blackmatter.services.fleet-reconcile.paused;
      set = (evalNixos [
        fancy.nixos
        {
          blackmatter.services.fleet-reconcile.enable = true;
          blackmatter.services.fleet-reconcile.paused = true;
        }
      ]).config.blackmatter.services.fleet-reconcile.paused;
    };
    expected = {
      dflt = false;
      set = true;
    };
  };

  # ── meta ─────────────────────────────────────────────────────────────
  meta-fields = {
    expr = builtins.removeAttrs fancy.meta [ "source" ];
    expected = {
      name = "fleet-reconcile";
      kind = "gitops";
      repository = "git+https://git.example.org/fleet.git";
      gitUrl = "https://git.example.org/fleet.git";
      flakeRef = "git+https://git.example.org/fleet.git";
      nixosBackend = "comin";
      darwinBackend = "script";
      optionPath = [
        "blackmatter"
        "services"
        "fleet-reconcile"
      ];
      enablePath = [
        "blackmatter"
        "services"
        "fleet-reconcile"
        "enable"
      ];
    };
  };
}
# ── class tagging: the nixos module is rejected under a darwin eval ──
// iroha.mkModuleEvalCheck {
  name = "gitops-nixos-module-under-darwin-class";
  modules = [ gitops.nixos ];
  class = "darwin";
  universe = [
    (
      { lib, ... }:
      {
        options.services.comin = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
        config._module.args.pkgs = { };
      }
    )
  ];
  expectClassReject = true;
}
// {
  # ── typed throws (lazy — force the field that throws) ───────────────
  missing-repository-throws = {
    # repository feeds meta.repository (lazy) — force it.
    expr =
      (builtins.tryEval
        (mkGitopsModule {
          name = "x";
        }).meta.repository
      ).success;
    expected = false;
  };
  non-int-interval-throws = {
    # interval flows into the comin poller.period (lazy) — force via eval.
    expr =
      (builtins.tryEval
        (builtins.head (evalNixos [
          (mkGitopsModule {
            source = { kind = "github"; owner = "pleme-io"; repo = "nix"; };
            interval = "300";
          }).nixos
          { services.gitops.enable = true; }
        ]).config.services.comin.remotes).poller.period
      ).success;
    expected = false;
  };
  bad-nixos-backend-throws = {
    # nixosBackend is validated eagerly via _backendChecked which is forced
    # when the comin config is realized — force via eval.
    expr =
      (builtins.tryEval
        (evalNixos [
          (mkGitopsModule {
            source = { kind = "github"; owner = "pleme-io"; repo = "nix"; };
            nixosBackend = "argocd";
          }).nixos
          { services.gitops.enable = true; }
        ]).config.services.comin.enable
      ).success;
    expected = false;
  };

  # ── ★ THE DIVERGENCE THIS TYPE EXISTS TO KILL ────────────────────────
  # One source, two spellings, each arm getting the one it can actually
  # use. Previously `repository` was a single string, so whichever form the
  # caller passed, the other backend was handed a URL it could not consume:
  # comin cannot fetch `github:owner/repo`, and `darwin-rebuild --flake`
  # cannot take `https://….git` without a `git+` scheme.
  #
  # Red run: point the comin remote back at `source.flakeRef` and this goes
  # red on `cominUrl`, which is the exact live misconfiguration it pins.
  one-source-renders-both-spellings = {
    expr =
      let
        g = mkGitopsModule {
          source = { kind = "github"; owner = "pleme-io"; repo = "nix"; };
          flakeAttr = "cid";
          darwinBackend = "script";
        };
        cominUrl = (builtins.head (evalNixos [ g.nixos enable ]).config.services.comin.remotes).url;
        argv = (evalDarwin [ g.darwin enable ]).config.launchd.daemons."gitops-reconcile".serviceConfig.ProgramArguments;
      in
      {
        inherit cominUrl;
        darwinFlakeRef = builtins.elemAt argv 3;
      };
    expected = {
      cominUrl = "https://github.com/pleme-io/nix.git";
      darwinFlakeRef = "github:pleme-io/nix#cid";
    };
  };

  # The retired single-string input is an EVAL ERROR, not a silent
  # coercion — a caller passing it is passing exactly one of the two
  # spellings and would get a broken arm on the other platform.
  retired-repository-arg-throws = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq (mkGitopsModule { repository = "github:pleme-io/nix"; }).meta true
      )).success;
    expected = false;
  };

  # A source with no kind, or an unknown kind, cannot be guessed at.
  missing-source-throws = {
    expr = (builtins.tryEval (builtins.deepSeq (mkGitopsModule { }).meta true)).success;
    expected = false;
  };
  unknown-source-kind-throws = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq (mkGitopsModule { source = { kind = "svn"; url = "x"; }; }).meta true
      )).success;
    expected = false;
  };
  github-source-without-repo-throws = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq
          (mkGitopsModule { source = { kind = "github"; owner = "pleme-io"; }; }).meta
          true
      )).success;
    expected = false;
  };

  # ── the darwin backend is a closed sum ───────────────────────────────
  bad-darwin-backend-throws = {
    expr =
      (builtins.tryEval
        (mkGitopsModule {
          source = { kind = "github"; owner = "pleme-io"; repo = "nix"; };
          darwinBackend = "chef";
          flakeAttr = "cid";
          sentinelaBin = "/nix/store/fake-sentinela";
        }).meta.darwinBackend
      ).success;
    expected = false;
  };

  # The DEFAULT darwin backend is the attested daemon, not the periodic
  # `darwin-rebuild switch` timer. The timer is a rollback machine (it
  # rolled ryn back twice on 2026-07-02); it stays selectable, but a node
  # must opt INTO it rather than get it by saying nothing.
  darwin-defaults-to-the-attested-daemon = {
    expr =
      let
        g = mkGitopsModule {
          source = { kind = "github"; owner = "pleme-io"; repo = "nix"; };
          flakeAttr = "cid";
          sentinelaBin = "/nix/store/fake-sentinela";
        };
        argv = (evalDarwin [ g.darwin enable ]).config.launchd.daemons."gitops-reconcile".serviceConfig;
      in
      {
        program = builtins.head argv.ProgramArguments;
        verb = builtins.elemAt argv.ProgramArguments 1;
        # One long-running process: single-flight is structural, so the
        # interval-driven overlap the script backend needs a lock for
        # cannot arise.
        keepAlive = argv.KeepAlive;
        backend = g.meta.darwinBackend;
      };
    expected = {
      program = "/nix/store/fake-sentinela/bin/sentinela";
      verb = "run";
      keepAlive = true;
      backend = "sentinela";
    };
  };

  # The daemon backend needs its binary; a store path, never PATH lookup
  # inside launchd.
  sentinela-backend-without-binary-throws = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq
          (evalDarwin [
            (mkGitopsModule {
              source = { kind = "github"; owner = "pleme-io"; repo = "nix"; };
              flakeAttr = "cid";
            }).darwin
            enable
          ]).config.launchd.daemons."gitops-reconcile".serviceConfig.ProgramArguments
          true
      )).success;
    expected = false;
  };

  # ── the home-manager arm: observer, never a second reconciler ────────
  # It must put the status binary on the user PATH and must NOT emit a
  # launchd agent — an HM arm that reconciled would race the system loop
  # for the same generation.
  home-manager-arm-observes-and-does-not-reconcile = {
    expr =
      let
        g = mkGitopsModule {
          source = { kind = "github"; owner = "pleme-io"; repo = "nix"; };
          flakeAttr = "cid";
          sentinelaBin = "/nix/store/fake-sentinela";
        };
        c = (evalHm [ g.homeManager { services.gitops.enable = true; } ]).config;
      in
      {
        packages = c.home.packages;
        configVar = c.home.sessionVariables.SENTINELA_CONFIG;
        agents = builtins.attrNames c.launchd.agents;
      };
    expected = {
      packages = [ "/nix/store/fake-sentinela" ];
      configVar = "/etc/pleme-gitops/config.yaml";
      agents = [ ];
    };
  };

  # ── the exported source algebra ──────────────────────────────────────
  # A consumer whose nodes vary declares `source` as an OPTION and must
  # still derive the two spellings identically, or the divergence grows
  # back one layer up. Same function, so it cannot.
  derive-source-github = {
    expr = removeAttrs (deriveSource {
      kind = "github";
      owner = "pleme-io";
      repo = "nix";
    }) [ "kind" ];
    expected = {
      owner = "pleme-io";
      repo = "nix";
      branch = "main";
      gitUrl = "https://github.com/pleme-io/nix.git";
      flakeRef = "github:pleme-io/nix";
    };
  };
  derive-source-git-adds-the-flake-scheme-once = {
    expr = {
      plain = (deriveSource {
        kind = "git";
        url = "https://git.example.org/f.git";
      }).flakeRef;
      already = (deriveSource {
        kind = "git";
        url = "git+ssh://git.example.org/f.git";
      }).flakeRef;
    };
    expected = {
      plain = "git+https://git.example.org/f.git";
      already = "git+ssh://git.example.org/f.git";
    };
  };
  # The exported option type accepts a well-formed source and rejects an
  # unknown kind at the DEFINITION site (naming the node), rather than
  # throwing from inside a renderer.
  source-option-type-accepts-and-rejects = {
    expr =
      let
        evalSrc =
          def:
          (lib.evalModules {
            modules = [
              {
                options.src = lib.mkOption { type = gitopsSourceType; };
              }
              { src = def; }
            ];
          }).config.src.kind;
      in
      {
        good = evalSrc {
          kind = "github";
          owner = "o";
          repo = "r";
        };
        bad = (builtins.tryEval (evalSrc { kind = "svn"; })).success;
      };
    expected = {
      good = "github";
      bad = false;
    };
  };
}
