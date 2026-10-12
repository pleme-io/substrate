{ pkgs, lib ? pkgs.lib }:
let
  trioLib = import ../module-trio.nix { inherit lib; };
  checks = import ../iroha/checks.nix { inherit lib; };
  inherit (trioLib.support) renders refuses arms;

  dummyPkg = pkgs.runCommand "trio-dummy" { } "mkdir -p $out/bin; touch $out/bin/trio-dummy";

  anyAttrs = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
  anyList = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
  anyStr = lib.mkOption { type = lib.types.str; default = "/home/test"; };

  stubs = {
    nixos = {
      options = {
        assertions = anyList;
        environment.etc = anyAttrs;
        environment.systemPackages = anyList;
        systemd.services = anyAttrs;
        systemd.timers = anyAttrs;
      };
    };
    darwin = {
      options = {
        assertions = anyList;
        environment.etc = anyAttrs;
        environment.systemPackages = anyList;
        launchd.daemons = anyAttrs;
      };
    };
    homeManager = {
      options = {
        assertions = anyList;
        home.homeDirectory = anyStr;
        home.packages = anyList;
        home.file = anyAttrs;
        home.activation = anyAttrs;
        home.sessionVariables = anyAttrs;
        launchd.agents = anyAttrs;
        systemd.user.services = anyAttrs;
        systemd.user.timers = anyAttrs;
        blackmatter.components.anvil.mcp.servers = anyAttrs;
      };
    };
  };

  pkgsOn = isDarwin: pkgs // {
    stdenv = pkgs.stdenv // {
      inherit isDarwin;
      hostPlatform = pkgs.stdenv.hostPlatform // {
        inherit isDarwin;
        isLinux = !isDarwin;
      };
    };
    trio-dummy = dummyPkg;
  };

  evalArm =
    {
      module,
      arm,
      settings,
      isDarwin ? arm == "darwin",
    }:
    lib.evalModules {
      class = if arm == "homeManager" then "homeManager" else arm;
      modules = [
        module
        stubs.${arm}
        settings
      ];
      specialArgs = { pkgs = pkgsOn isDarwin; };
    };

  failed = e: map (a: a.message) (builtins.filter (a: !a.assertion) e.config.assertions);

  enableAt = path: extra: lib.setAttrByPath path ({ enable = true; } // extra);

  binaryTrio = trioLib.mkModuleTrio {
    name = "bind";
    description = "binary concept";
    packageAttr = "trio-dummy";
    withSystemDaemon = true;
    support.darwin = refuses "no-surface" "bind speaks a linux-only kernel interface";
  };

  packageTrio = trioLib.mkModuleTrio {
    kind = "package";
    name = "pkgc";
    description = "package concept";
    packageAttr = "trio-dummy";
    platforms = [ "linux" ];
  };

  registryTrio = trioLib.mkModuleTrio {
    kind = "registry";
    name = "reg";
    description = "registry concept";
    entries = {
      type = lib.types.str;
      default = {
        a = "first";
        b = "second";
      };
    };
    selector = {
      over = "entries";
      default = "a";
    };
    settings = _: {
      suffix = lib.mkOption {
        type = lib.types.str;
        default = "!";
      };
    };
    projections =
      { cfg, ... }:
      {
        chosen = {
          type = lib.types.str;
          value = cfg.registry.${cfg.selected} + cfg.suffix;
        };
      };
    render.nixos =
      { config, lib, ... }:
      {
        config = lib.mkIf config.pleme.reg.enable { environment.etc.reg.text = config.pleme.reg.chosen; };
      };
    support = {
      darwin = refuses "owned-elsewhere" "darwin reads the registry through its profile";
      homeManager = refuses "no-surface" "a user scope cannot write /etc";
    };
  };

  serviceTrio = trioLib.mkModuleTrio {
    kind = "service";
    name = "svc";
    description = "service concept";
    packageAttr = "trio-dummy";
    binaryName = "trio-dummy";
    scope = "system";
    args = [ "serve" ];
  };

  settingsFor = {
    binary = {
      nixos = {
        services.bind = {
          enable = true;
          package = dummyPkg;
        };
      };
      darwin = {
        services.bind = {
          enable = true;
          package = dummyPkg;
        };
      };
      homeManager = {
        programs.bind = {
          enable = true;
          package = dummyPkg;
        };
      };
    };
    package = lib.genAttrs arms (_: enableAt [ "pleme" "pkgc" ] { package = dummyPkg; });
    registry = lib.genAttrs arms (_: enableAt [ "pleme" "reg" ] { });
    service = lib.genAttrs arms (_: enableAt [ "pleme" "svc" ] { package = dummyPkg; });
  };

  trios = {
    binary = binaryTrio;
    package = packageTrio;
    registry = registryTrio;
    service = serviceTrio;
  };

  rendered = {
    binary = {
      nixos = e: builtins.elem dummyPkg e.config.environment.systemPackages;
      darwin = _: false;
      homeManager = e: builtins.elem dummyPkg e.config.home.packages;
    };
    package = {
      nixos = e: builtins.elem dummyPkg e.config.environment.systemPackages;
      darwin = _: false;
      homeManager = e: builtins.elem dummyPkg e.config.home.packages;
    };
    registry = {
      nixos = e: e.config.environment.etc.reg.text == "first!";
      darwin = _: false;
      homeManager = _: false;
    };
    service = {
      nixos = e: e.config.systemd.services ? svc;
      darwin = e: e.config.launchd.daemons ? svc;
      homeManager = _: false;
    };
  };

  verdictOf = kind: arm: trios.${kind}.concept.support.${arm};

  cell =
    kind: arm:
    let
      v = verdictOf kind arm;
      on = evalArm {
        module = trios.${kind}.${arm + "Module"};
        inherit arm;
        settings = settingsFor.${kind}.${arm};
      };
      off = evalArm {
        module = trios.${kind}.${arm + "Module"};
        inherit arm;
        settings = { };
      };
    in
    if v.verdict == "renders" then
      {
        expr = [
          (failed on)
          (rendered.${kind}.${arm} on)
        ];
        expected = [
          [ ]
          true
        ];
      }
    else
      {
        expr = [
          (builtins.length (failed on))
          (lib.hasInfix "(${v.why}:" (lib.head (failed on)))
          (lib.hasInfix v.detail (lib.head (failed on)))
          (failed off)
        ];
        expected = [
          1
          true
          true
          [ ]
        ];
      };

  matrix = lib.genAttrs trioLib.kinds (kind: lib.genAttrs arms (arm: cell kind arm));

  matrixTests = lib.concatMapAttrs (
    kind: row: lib.mapAttrs' (arm: t: lib.nameValuePair "test-${kind}-${arm}" t) row
  ) matrix;

  expectedVerdicts = {
    binary = {
      nixos = "renders";
      darwin = "refuses";
      homeManager = "renders";
    };
    package = {
      nixos = "renders";
      darwin = "refuses";
      homeManager = "renders";
    };
    registry = {
      nixos = "renders";
      darwin = "refuses";
      homeManager = "refuses";
    };
    service = {
      nixos = "renders";
      darwin = "renders";
      homeManager = "refuses";
    };
  };

  throws = x: !(builtins.tryEval (builtins.deepSeq x x)).success;

  regOn = selected: evalArm {
    module = registryTrio.nixosModule;
    arm = "nixos";
    settings = enableAt [ "pleme" "reg" ] { inherit selected; };
  };

  linuxHostPackage = evalArm {
    module = packageTrio.homeManagerModule;
    arm = "homeManager";
    isDarwin = true;
    settings = settingsFor.package.homeManager;
  };

  unconfigured = trioLib.mkModuleTrio {
    kind = "registry";
    name = "half";
    description = "half";
    entries = {
      type = lib.types.str;
      default = { };
    };
    render.nixos = { };
  };

  dispatched = class: (lib.evalModules {
    inherit class;
    modules = [
      registryTrio.module
      stubs.${if class == "homeManager" then "homeManager" else class}
    ];
    specialArgs = { pkgs = pkgsOn (class == "darwin"); };
  }).config.pleme.reg.enable;

  tests = matrixTests // {
    test-every-kind-has-a-row-for-every-arm = {
      expr = lib.mapAttrs (_: row: builtins.attrNames row) matrix;
      expected = lib.genAttrs [ "binary" "package" "registry" "service" ] (_: lib.sort lib.lessThan arms);
    };
    test-the-kinds-are-the-matrix-rows = {
      expr = trioLib.kinds;
      expected = builtins.attrNames expectedVerdicts;
    };
    test-verdicts-per-kind = {
      expr = lib.mapAttrs (kind: _: lib.mapAttrs (arm: _: (verdictOf kind arm).verdict) expectedVerdicts.${kind}) expectedVerdicts;
      expected = expectedVerdicts;
    };
    test-new-kinds-keep-one-namespace-across-arms = {
      expr = map (k: lib.unique (builtins.attrValues trios.${k}.concept.paths)) [ "package" "registry" "service" ];
      expected = [
        [ [ "pleme" "pkgc" ] ]
        [ [ "pleme" "reg" ] ]
        [ [ "pleme" "svc" ] ]
      ];
    };
    test-the-selector-moves-the-projection = {
      expr = map (s: (regOn s).config.environment.etc.reg.text) [ "a" "b" ];
      expected = [ "first!" "second!" ];
    };
    test-an-unknown-selection-is-an-eval-error = {
      expr = throws (regOn "c").config.environment.etc.reg.text;
      expected = true;
    };
    test-a-projection-is-read-only = {
      expr = throws (evalArm {
        module = registryTrio.nixosModule;
        arm = "nixos";
        settings = enableAt [ "pleme" "reg" ] { chosen = "forged"; };
      }).config.pleme.reg.chosen;
      expected = true;
    };
    test-a-refused-arm-defaults-off-even-when-the-spec-defaults-on = {
      expr = (evalArm {
        module = (trioLib.mkModuleTrio {
          kind = "registry";
          name = "ond";
          description = "on by default";
          enable.default = true;
          entries = {
            type = lib.types.str;
            default = { };
          };
          render.nixos = { };
          support = {
            darwin = refuses "no-surface" "no darwin surface";
            homeManager = refuses "no-surface" "no user surface";
          };
        }).darwinModule;
        arm = "darwin";
        settings = { };
      }).config.pleme.ond.enable;
      expected = false;
    };
    test-a-package-names-the-host-a-home-arm-cannot-build-for = {
      expr = lib.any (m: lib.hasInfix "(unbuildable:" m) (failed linuxHostPackage);
      expected = true;
    };
    test-a-registry-arm-with-neither-renderer-nor-refusal-throws = {
      expr = throws unconfigured.concept.support;
      expected = true;
    };
    test-a-refusal-reason-outside-the-lattice-throws = {
      expr = throws (refuses "because" "x");
      expected = true;
    };
    test-a-refusal-without-detail-throws = {
      expr = throws (refuses "scope" "");
      expected = true;
    };
    test-support-for-an-unknown-arm-throws = {
      expr = throws (trioLib.mkModuleTrio {
        kind = "package";
        name = "x";
        description = "x";
        support.windows = renders;
      }).concept.support;
      expected = true;
    };
    test-an-unknown-kind-throws = {
      expr = throws (trioLib.mkModuleTrio {
        kind = "widget";
        name = "x";
        description = "x";
      });
      expected = true;
    };
    test-the-module-picks-its-arm-by-class = {
      expr = map dispatched [ "nixos" "darwin" "homeManager" ];
      expected = [ false false false ];
    };
    test-a-classless-evaluation-gets-the-schema-alone = {
      expr =
        let
          e = lib.evalModules {
            modules = [
              registryTrio.module
              { pleme.reg.selected = "b"; }
            ];
            specialArgs = { pkgs = pkgsOn false; };
          };
        in
        [
          e.config.pleme.reg.chosen
          (e.options ? environment)
        ];
      expected = [
        "second!"
        false
      ];
    };
    test-a-binary-in-a-classless-evaluation-is-refused = {
      expr = throws (lib.evalModules {
        modules = [ binaryTrio.module ];
      }).config;
      expected = true;
    };
    test-a-foreign-class-is-refused = {
      expr = throws (lib.evalModules {
        class = "flake";
        modules = [ registryTrio.module ];
      }).config;
      expected = true;
    };
    test-a-binary-with-a-namespace-keeps-one-path-across-arms =
      let
        t = trioLib.mkModuleTrio {
          name = "nsb";
          description = "namespaced binary";
          packageAttr = "trio-dummy";
          namespace = "pleme";
        };
        on = arm: evalArm {
          module = t.${arm + "Module"};
          inherit arm;
          settings = enableAt [ "pleme" "nsb" ] { package = dummyPkg; };
        };
      in
      {
        expr = [
          (lib.unique (builtins.attrValues t.concept.paths))
          (builtins.elem dummyPkg (on "nixos").config.environment.systemPackages)
          (builtins.elem dummyPkg (on "homeManager").config.home.packages)
        ];
        expected = [
          [ [ "pleme" "nsb" ] ]
          true
          true
        ];
      };
    test-binary-without-support-is-the-untouched-trio = {
      expr = builtins.attrNames (trioLib.mkModuleTrio {
        name = "plain";
        description = "plain";
      }).concept.support;
      expected = lib.sort lib.lessThan arms;
    };
  };
in
let
  suite = checks.mkEvalChecks {
    name = "module-trio-kinds";
    inherit tests;
  };
in
suite.asCheck pkgs // { inherit (suite) failures summary; }
