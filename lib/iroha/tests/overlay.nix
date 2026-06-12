# Tests — iroha.overlay (input re-exports, fix overlays + catalog,
# unstable pins, layer/composite composition). Overlays are exercised by
# APPLYING them to fake prev/final sets — no pkgs, no builds.
{ lib, iroha }:
let
  inherit (iroha)
    mkInputOverlay
    mkFixOverlay
    mkFixCatalog
    mkUnstablePin
    composeLayers
    ;

  fakeInput = {
    packages.x86_64-linux = {
      default = "drv-default";
      host-tool = "drv-host";
    };
  };

  linuxPrev = {
    stdenv.hostPlatform = {
      system = "x86_64-linux";
      isDarwin = false;
    };
  };
  darwinPrev = {
    stdenv.hostPlatform = {
      system = "aarch64-darwin";
      isDarwin = true;
    };
  };

  # overrideAttrs probe: captures what the fix function computes from a
  # fake `old`, exposing it as `.overridden`.
  probePkg = {
    overrideAttrs = f: {
      overridden = f {
        doCheck = true;
        old = true;
      };
    };
  };

  fakeUnstable = {
    legacyPackages.x86_64-linux.onnx = "unstable-onnx";
  };

  # ── mkFixCatalog fixtures ─────────────────────────────────────────────
  cat = mkFixCatalog {
    fixes = {
      alpha = {
        reason = "alpha tests flaky in sandbox";
        skipTests = true;
      };
      beta = {
        reason = "beta tests flaky in sandbox";
        skipTests = true;
        enabled = false;
      };
      gamma = {
        package = "gamma-pkg";
        reason = "gamma needs a build patch";
        skipTests = true;
      };
    };
    flags.alpha = false; # flag wins over fixSpec default enabled = true
  };

  catBoth = mkFixCatalog {
    fixes = {
      p1 = {
        reason = "p1 flaky";
        skipTests = true;
      };
      p2 = {
        reason = "p2 flaky";
        skipTests = true;
      };
    };
  };

  # ── composeLayers fixture ─────────────────────────────────────────────
  cl = composeLayers {
    layers = {
      base = [
        (final: prev: { a = 1; })
        {
          overlay = final: prev: { b = prev.a + 1; };
          provenance = {
            kind = "input";
            input = "tend";
          };
        }
      ];
      extra = [ (final: prev: { c = 3; }) ];
    };
    composites.dev = [
      "base"
      "extra"
    ];
  };
in
{
  # ── mkInputOverlay ────────────────────────────────────────────────────
  input-overlay-reexports-default = {
    expr = ((mkInputOverlay {
      input = fakeInput;
      name = "tend";
    }) null linuxPrev).tend;
    expected = "drv-default";
  };
  input-overlay-prefers-host-tool = {
    expr = ((mkInputOverlay {
      input = fakeInput;
      name = "gen";
      preferAttrs = [
        "host-tool"
        "default"
      ];
    }) null linuxPrev).gen;
    expected = "drv-host";
  };
  input-overlay-custom-package-attr = {
    expr = builtins.attrNames ((mkInputOverlay {
      input = fakeInput;
      name = "gen";
      packageAttr = "gen-cli";
    }) null linuxPrev);
    expected = [ "gen-cli" ];
  };
  input-overlay-missing-attr-throws = {
    # The throw is lazy — force the package attr to surface it.
    expr = (builtins.tryEval ((mkInputOverlay {
      input = fakeInput;
      name = "tend";
      preferAttrs = [ "nope" ];
    }) null linuxPrev).tend).success;
    expected = false;
  };
  input-overlay-fallback-used = {
    expr = ((mkInputOverlay {
      input = fakeInput;
      name = "tend";
      preferAttrs = [ "nope" ];
      fallback = "fb-drv";
    }) null linuxPrev).tend;
    expected = "fb-drv";
  };

  # ── mkFixOverlay ──────────────────────────────────────────────────────
  fix-overlay-skip-tests-flows-doCheck-false = {
    expr = ((mkFixOverlay {
      package = "foo";
      reason = "flaky sandbox tests";
      skipTests = true;
    }) null (linuxPrev // { foo = probePkg; })).foo.overridden;
    expected = {
      doCheck = false;
    };
  };
  fix-overlay-skipTests-and-override-compose = {
    expr = ((mkFixOverlay {
      package = "foo";
      reason = "needs patch + test skip";
      skipTests = true;
      override = old: {
        sawOld = old.old;
        patched = true;
      };
    }) null (linuxPrev // { foo = probePkg; })).foo.overridden;
    expected = {
      doCheck = false;
      patched = true;
      sawOld = true;
    };
  };
  fix-overlay-darwin-only = {
    expr = {
      # Non-Darwin prev: the overlay is a pure identity ({ }).
      linuxResult = (mkFixOverlay {
        package = "foo";
        reason = "darwin-only sandbox failure";
        skipTests = true;
        darwinOnly = true;
      }) null (linuxPrev // { foo = probePkg; });
      # Darwin prev: the fix applies.
      darwinDoCheck = ((mkFixOverlay {
        package = "foo";
        reason = "darwin-only sandbox failure";
        skipTests = true;
        darwinOnly = true;
      }) null (darwinPrev // { foo = probePkg; })).foo.overridden.doCheck;
    };
    expected = {
      linuxResult = { };
      darwinDoCheck = false;
    };
  };
  fix-overlay-missing-package-throws = {
    # Never a silent identity — force the attr to surface the throw.
    expr = (builtins.tryEval ((mkFixOverlay {
      package = "ghost";
      reason = "fix for a package prev does not have";
      skipTests = true;
    }) null linuxPrev).ghost).success;
    expected = false;
  };
  fix-overlay-missing-reason-throws = {
    expr = (builtins.tryEval (mkFixOverlay {
      package = "foo";
      skipTests = true;
    })).success;
    expected = false;
  };
  fix-overlay-no-change-throws = {
    # Neither skipTests nor override: the fix would change nothing.
    expr = (builtins.tryEval (mkFixOverlay {
      package = "foo";
      reason = "drift";
    })).success;
    expected = false;
  };

  # ── mkFixCatalog ──────────────────────────────────────────────────────
  fix-catalog-flag-disables-enabled-fix = {
    # alpha disabled by flag, beta disabled by spec — only gamma remains.
    expr = builtins.attrNames cat.overlays;
    expected = [ "gamma" ];
  };
  fix-catalog-flag-enables-disabled-fix = {
    expr = builtins.attrNames
      (mkFixCatalog {
        fixes.beta = {
          reason = "beta flaky";
          skipTests = true;
          enabled = false;
        };
        flags.beta = true;
      }).overlays;
    expected = [ "beta" ];
  };
  fix-catalog-raw-arm-list-append = {
    # The raw arm carries fixes a single-package overrideAttrs cannot
    # express (the pythonPackagesExtensions / haskell.* class): the fix IS
    # an overlay, provenance still mandatory, darwinOnly still gates.
    expr =
      let
        c = mkFixCatalog {
          fixes = {
            python-exts = {
              reason = "python network tests fail in sandbox";
              overlay = final: prev: {
                pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [ "ext" ];
              };
            };
          };
        };
        applied = c.composed { } {
          pythonPackagesExtensions = [ "base" ];
          stdenv.hostPlatform = {
            system = "x86_64-linux";
            isDarwin = false;
          };
        };
      in
      {
        appended = applied.pythonPackagesExtensions;
        kind = c.catalog.python-exts.kind;
      };
    expected = {
      appended = [
        "base"
        "ext"
      ];
      kind = "raw";
    };
  };
  fix-catalog-raw-arm-darwin-gate = {
    expr =
      let
        c = mkFixCatalog {
          fixes = {
            mac-only = {
              reason = "darwin-only list fix";
              darwinOnly = true;
              overlay = final: prev: { touched = true; };
            };
          };
        };
      in
      c.composed { } {
        stdenv.hostPlatform = {
          system = "x86_64-linux";
          isDarwin = false;
        };
      };
    expected = { };
  };
  fix-catalog-raw-arm-missing-reason-throws = {
    expr =
      (builtins.tryEval (
        ((mkFixCatalog { fixes.bad.overlay = final: prev: { }; }).composed { } { }) ? anything
      )).success;
    expected = false;
  };
  fix-catalog-kind-overrideattrs-for-classic-fixes = {
    expr = cat.catalog.gamma.kind;
    expected = "overrideAttrs";
  };
  fix-catalog-registry-carries-all-fixes = {
    # The catalog is the provenance registry: disabled fixes stay listed,
    # package defaults to the attr name unless given.
    expr = {
      names = builtins.attrNames cat.catalog;
      alphaEnabled = cat.catalog.alpha.enabled;
      betaEnabled = cat.catalog.beta.enabled;
      gammaEnabled = cat.catalog.gamma.enabled;
      alphaPackage = cat.catalog.alpha.package;
      gammaPackage = cat.catalog.gamma.package;
      gammaReason = cat.catalog.gamma.reason;
    };
    expected = {
      names = [
        "alpha"
        "beta"
        "gamma"
      ];
      alphaEnabled = false;
      betaEnabled = false;
      gammaEnabled = true;
      alphaPackage = "alpha";
      gammaPackage = "gamma-pkg";
      gammaReason = "gamma needs a build patch";
    };
  };
  fix-catalog-composed-applies-enabled-fixes = {
    expr =
      let
        res = catBoth.composed null (
          linuxPrev
          // {
            p1 = probePkg;
            p2 = probePkg;
          }
        );
      in
      {
        p1 = res.p1.overridden.doCheck;
        p2 = res.p2.overridden.doCheck;
      };
    expected = {
      p1 = false;
      p2 = false;
    };
  };
  fix-catalog-missing-reason-throws = {
    expr = (builtins.tryEval
      (mkFixCatalog { fixes.x = { skipTests = true; }; }).catalog.x.reason
    ).success;
    expected = false;
  };

  # ── mkUnstablePin ─────────────────────────────────────────────────────
  unstable-pin-picks-from-legacyPackages = {
    expr = ((mkUnstablePin {
      unstable = fakeUnstable;
      packages = [ "onnx" ];
      reason = "stable lags on onnxruntime API v23";
    }) null linuxPrev).onnx;
    expected = "unstable-onnx";
  };
  unstable-pin-empty-packages-throws = {
    expr = (builtins.tryEval (mkUnstablePin {
      unstable = fakeUnstable;
      packages = [ ];
      reason = "nothing to pin";
    })).success;
    expected = false;
  };
  unstable-pin-missing-reason-throws = {
    expr = (builtins.tryEval (mkUnstablePin {
      unstable = fakeUnstable;
      packages = [ "onnx" ];
    })).success;
    expected = false;
  };
  unstable-pin-missing-package-throws = {
    expr = (builtins.tryEval ((mkUnstablePin {
      unstable = fakeUnstable;
      packages = [ "nope" ];
      reason = "pin a package unstable lacks";
    }) null linuxPrev).nope).success;
    expected = false;
  };

  # ── composeLayers ─────────────────────────────────────────────────────
  compose-layers-later-entry-sees-earlier-through-prev = {
    # composeManyExtensions [first second]: second's prev includes first's
    # output — b reads prev.a.
    expr = cl.layers.base null linuxPrev;
    expected = {
      a = 1;
      b = 2;
    };
  };
  compose-layers-composite-resolves-in-order = {
    expr = cl.composites.dev null linuxPrev;
    expected = {
      a = 1;
      b = 2;
      c = 3;
    };
  };
  compose-layers-registry = {
    expr = {
      base = cl.registry.layers.base;
      dev = cl.registry.composites.dev;
    };
    expected = {
      base = [
        { kind = "opaque"; } # bare function: default provenance
        {
          kind = "input";
          input = "tend";
        }
      ];
      dev = [
        "base"
        "extra"
      ];
    };
  };
  compose-layers-unknown-composite-member-throws = {
    # Resolution is forced eagerly — forcing the composite VALUE throws,
    # no application to a package set needed.
    expr = (builtins.tryEval
      (composeLayers {
        layers.base = [ (final: prev: { }) ];
        composites.broken = [ "nope" ];
      }).composites.broken
    ).success;
    expected = false;
  };
  compose-layers-bad-entry-throws = {
    expr = (builtins.tryEval
      (composeLayers { layers.bad = [ "not-an-overlay" ]; }).layers.bad
    ).success;
    expected = false;
  };
}
