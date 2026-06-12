# Tests — iroha.wrapped-package (the typed wrapper chokepoint: compiled
# postBuild [flags / env force-vs-default / PATH-prefix / rename /
# multicall], symlinkJoin shape, wrapSpec round-trip, meta.mainProgram,
# name fallback chain, typed throws). Pure-eval: stub pkgs whose
# symlinkJoin returns an inspectable attrset — no real derivations.
{ lib, iroha }:
let
  inherit (iroha) mkWrappedPackage;

  # ── stub pkgs (zero real nixpkgs) ────────────────────────────────────
  stubPkgs = {
    makeWrapper = "MAKEWRAPPER";
    symlinkJoin = args: {
      stub = "symlinkJoin";
      inherit args;
    };
  };

  # ── fixtures ─────────────────────────────────────────────────────────
  base = {
    pname = "tend";
    meta = {
      mainProgram = "tend";
    };
    passthru = {
      existing = 1;
    };
  };

  wrap =
    extra:
    mkWrappedPackage (
      {
        pkgs = stubPkgs;
        basePackage = base;
      }
      // extra
    );

  plain = wrap { };

  # Everything at once — the strongest single compile assertion.
  full = wrap {
    prependFlags = [ "alpha" ];
    appendFlags = [ "omega" ];
    env = {
      FOO = "bar";
      BAZ = {
        value = "qux";
        force = true;
      };
    };
    pathAdd = [
      "DRVA"
      "DRVB"
    ];
    rename = "t2";
    multicall = [
      "m1"
      "m2"
    ];
  };
in
{
  # ── symlinkJoin shape ────────────────────────────────────────────────
  paths-is-exactly-base-package = {
    expr = plain.args.paths == [ base ];
    expected = true;
  };
  native-build-inputs-carries-make-wrapper = {
    expr = plain.args.nativeBuildInputs;
    expected = [ "MAKEWRAPPER" ];
  };
  drv-name-is-name-wrapped = {
    expr = plain.args.name;
    expected = "tend-wrapped";
  };

  # ── compiled postBuild ───────────────────────────────────────────────
  no-flags-wraps-bare = {
    expr = plain.args.postBuild;
    expected = "wrapProgram \"$out/bin/\"tend";
  };
  prepend-before-append-order = {
    expr =
      (wrap {
        prependFlags = [ "alpha" ];
        appendFlags = [ "omega" ];
      }).args.postBuild;
    expected = "wrapProgram \"$out/bin/\"tend --add-flags alpha --append-flags omega";
  };
  flags-land-as-one-escaped-word = {
    # A space-bearing flag list compiles to ONE shell word for wrapProgram:
    # the value of --add-flags is escapeShellArg(escapeShellArgs flags).
    expr =
      (wrap {
        prependFlags = [
          "--msg"
          "hello world"
        ];
      }).args.postBuild;
    expected =
      "wrapProgram \"$out/bin/\"tend --add-flags "
      + lib.escapeShellArg (
        lib.escapeShellArgs [
          "--msg"
          "hello world"
        ]
      );
  };
  env-force-set-vs-set-default-sorted = {
    # force → --set, plain str → --set-default; sorted name order (BAZ < FOO).
    expr =
      (wrap {
        env = {
          FOO = "bar";
          BAZ = {
            value = "qux";
            force = true;
          };
        };
      }).args.postBuild;
    expected = "wrapProgram \"$out/bin/\"tend --set BAZ qux --set-default FOO bar";
  };
  env-attrs-without-force-defaults-to-set-default = {
    expr = (wrap { env.ONLY.value = "v"; }).args.postBuild;
    expected = "wrapProgram \"$out/bin/\"tend --set-default ONLY v";
  };
  path-add-prefixes-path-with-bin-dirs = {
    expr =
      (wrap {
        pathAdd = [
          "DRVA"
          "DRVB"
        ];
      }).args.postBuild;
    expected = "wrapProgram \"$out/bin/\"tend --prefix PATH : DRVA/bin:DRVB/bin";
  };
  rename-compiles-mv-then-wrap-on-new-name = {
    expr = (wrap { rename = "t2"; }).args.postBuild;
    expected = "mv \"$out/bin/\"tend \"$out/bin/\"t2\nwrapProgram \"$out/bin/\"t2";
  };
  multicall-links-point-at-exposed-name = {
    # With rename, the multicall symlinks target the RENAMED wrapper.
    expr =
      (wrap {
        rename = "t2";
        multicall = [ "m1" ];
      }).args.postBuild;
    expected = "mv \"$out/bin/\"tend \"$out/bin/\"t2\nwrapProgram \"$out/bin/\"t2\nln -s \"$out/bin/\"t2 \"$out/bin/\"m1";
  };
  full-spec-compiles-end-to-end = {
    expr = full.args.postBuild;
    expected = lib.concatStringsSep "\n" [
      "mv \"$out/bin/\"tend \"$out/bin/\"t2"
      "wrapProgram \"$out/bin/\"t2 --add-flags alpha --append-flags omega --set BAZ qux --set-default FOO bar --prefix PATH : DRVA/bin:DRVB/bin"
      "ln -s \"$out/bin/\"t2 \"$out/bin/\"m1"
      "ln -s \"$out/bin/\"t2 \"$out/bin/\"m2"
    ];
  };

  # ── wrapSpec round-trip (closed-loop auditability) ───────────────────
  wrap-spec-round-trips-normalized = {
    expr = full.args.passthru.iroha.wrapSpec;
    expected = {
      name = "tend";
      binary = "tend";
      exposed = "t2";
      rename = "t2";
      prependFlags = [ "alpha" ];
      appendFlags = [ "omega" ];
      env = {
        BAZ = {
          value = "qux";
          force = true;
        };
        FOO = {
          value = "bar";
          force = false;
        };
      };
      pathBins = [
        "DRVA/bin"
        "DRVB/bin"
      ];
      multicall = [
        "m1"
        "m2"
      ];
    };
  };
  passthru-preserved-alongside-wrap-spec = {
    expr = {
      existing = plain.args.passthru.existing;
      hasSpec = plain.args.passthru.iroha ? wrapSpec;
    };
    expected = {
      existing = 1;
      hasSpec = true;
    };
  };

  # ── meta ─────────────────────────────────────────────────────────────
  meta-main-program-follows-rename = {
    expr = full.args.meta;
    expected = {
      mainProgram = "t2";
    };
  };
  meta-main-program-defaults-to-binary = {
    expr = plain.args.meta.mainProgram;
    expected = "tend";
  };

  # ── name / binary fallback chains ────────────────────────────────────
  explicit-name-wins = {
    expr = (wrap { name = "custom"; }).args.name;
    expected = "custom-wrapped";
  };
  name-falls-back-to-name-attr = {
    expr =
      (mkWrappedPackage {
        pkgs = stubPkgs;
        basePackage = {
          name = "foo-1.2";
        };
      }).args.name;
    expected = "foo-1.2-wrapped";
  };
  name-underivable-throws = {
    expr =
      (builtins.tryEval
        (mkWrappedPackage {
          pkgs = stubPkgs;
          basePackage = { };
        }).args.name
      ).success;
    expected = false;
  };
  binary-explicit-override-wins = {
    expr = (wrap { binary = "tendctl"; }).args.postBuild;
    expected = "wrapProgram \"$out/bin/\"tendctl";
  };
  binary-falls-back-to-name-without-main-program = {
    expr =
      (mkWrappedPackage {
        pkgs = stubPkgs;
        basePackage = {
          pname = "bare";
        };
      }).args.postBuild;
    expected = "wrapProgram \"$out/bin/\"bare";
  };

  # ── typed throws ─────────────────────────────────────────────────────
  missing-pkgs-throws = {
    expr =
      (builtins.tryEval (mkWrappedPackage {
        basePackage = base;
      })).success;
    expected = false;
  };
  missing-base-package-throws = {
    expr = (builtins.tryEval (mkWrappedPackage { pkgs = stubPkgs; }).args.name).success;
    expected = false;
  };
  rename-equals-binary-throws = {
    expr = (builtins.tryEval (wrap { rename = "tend"; }).args.postBuild).success;
    expected = false;
  };
  env-bad-value-throws = {
    expr = {
      nonStr = (builtins.tryEval (wrap { env.FOO = 42; }).args.postBuild).success;
      attrsWithoutValue = (builtins.tryEval (wrap { env.FOO.force = true; }).args.postBuild).success;
    };
    expected = {
      nonStr = false;
      attrsWithoutValue = false;
    };
  };
}
