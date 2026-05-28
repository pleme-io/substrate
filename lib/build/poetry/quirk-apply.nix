# quirk-apply.nix — typed `PoetryQuirk` dispatch. Source of truth:
# `gen-poetry/src/quirks.rs::PoetryQuirk`. The Nix overrides table
# produced here is intended to be threaded into poetry2nix's
# `defaultPoetryOverrides.extend (final: prev: { ... })` chain.
{ lib }:
let
  overrideBuildSystemApply = { package, backend }: attrs: {
    poetryOverrides = (attrs.poetryOverrides or {}) // {
      "${package}".buildSystem = backend;
    };
  };

  overrideAttrsApply = { package, attr, value }: attrs: {
    poetryOverrides = (attrs.poetryOverrides or {}) // {
      "${package}".attrs = ((attrs.poetryOverrides."${package}".attrs or {})) //
        { "${attr}" = value; };
    };
  };

  skipCheckApply = package: attrs: {
    poetryOverrides = (attrs.poetryOverrides or {}) // {
      "${package}".doCheck = false;
    };
  };

  preferWheelApply = { package, prefer }: attrs: {
    poetryOverrides = (attrs.poetryOverrides or {}) // {
      "${package}".preferWheel = prefer;
    };
  };
in
import ../shared/mk-quirk-applier.nix {
  inherit lib;
  helpers = {
    "override-build-system" = quirk: overrideBuildSystemApply {
      inherit (quirk) package backend;
    };
    "override-attrs" = quirk: overrideAttrsApply {
      inherit (quirk) package attr value;
    };
    "skip-check" = quirk: skipCheckApply quirk.package;
    "prefer-wheel" = quirk: preferWheelApply {
      inherit (quirk) package prefer;
    };
  };
}
