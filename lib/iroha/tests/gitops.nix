# Tests — iroha.gitops (pull-based GitOps reconcile module emitter:
# option surface + services.comin (NixOS) + launchd.daemons.<name>-reconcile
# darwin-rebuild periodic job (macOS), flakeAttr default-to-hostname +
# override, branch + interval, class tagging, typed throws).
{ lib, iroha }:
let
  inherit (iroha) mkGitopsModule;

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

  enable = { services.gitops.enable = true; };

  # ── specs under test ─────────────────────────────────────────────────
  # Canonical: all defaults (name=gitops, branch=main, interval=300, comin).
  gitops = mkGitopsModule {
    repository = "github:pleme-io/nix";
  };

  # custom branch + interval, explicit flakeAttr override.
  pinned = mkGitopsModule {
    repository = "git@github.com:pleme-io/nix.git";
    branch = "production";
    interval = 600;
    flakeAttr = "rio";
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
    repository = "github:pleme-io/nix/feature";
    interval = 120;
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
      url = "github:pleme-io/nix";
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
      url = "git@github.com:pleme-io/nix.git";
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
      "git@github.com:pleme-io/nix.git#rio"
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
        "github:pleme-io/nix/feature#cid"
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
    expr = fancy.meta;
    expected = {
      name = "fleet-reconcile";
      kind = "gitops";
      repository = "github:pleme-io/nix/feature";
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
            repository = "github:pleme-io/nix";
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
            repository = "github:pleme-io/nix";
            nixosBackend = "argocd";
          }).nixos
          { services.gitops.enable = true; }
        ]).config.services.comin.enable
      ).success;
    expected = false;
  };
}
