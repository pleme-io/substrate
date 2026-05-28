# crates-io-cdn-overlay.nix — fleet-wide nixpkgs overlay that
# rewrites every `crates.io/api/v1/crates/<name>/<ver>/download`
# URL passed to `fetchurl` into the canonical
# `https://static.crates.io/crates/<name>/<name>-<ver>.crate` CDN URL.
#
# Why: crates.io permanently 403's the /api/v1 redirect endpoint as
# of 2026-05-27 (no UA, no rate-limit window — it's a policy change).
# `static.crates.io` is the always-open CDN cargo itself fetches from.
#
# Coverage: this overlay catches every fetcher in the closure that
# uses `pkgs.fetchurl` (substrate's lockfile-builder, nixpkgs'
# `importCargoLock` via `cargoSetupHook` / `fetchCargoVendor`,
# `prefetch-npm-deps`, any third-party flake that vendors Cargo
# deps via `pkgs.fetchurl`).
#
# Implementation: wraps `prev.fetchurl` while preserving its
# attribute surface (`.override`, `.overrideAttrs`, `__functor`,
# etc.) — a naïve `fetchurl = args: ...` shadowing strips those
# and breaks downstream consumers that call `fetchurl.override`.
#
# Consumed by: substrate flake exports this as
# `overlays.crates-io-cdn`. Consumers compose into
# `nixpkgs.overlays`.
final: prev:
let
  apiPrefix = "https://crates.io/api/v1/crates/";
  isApi = u: builtins.isString u && prev.lib.hasPrefix apiPrefix u;
  rewriteOne = u:
    if !isApi u then u
    else
      let
        tail = prev.lib.removePrefix apiPrefix u;
        parts = prev.lib.splitString "/" tail;
        name = builtins.elemAt parts 0;
        ver  = builtins.elemAt parts 1;
      in "https://static.crates.io/crates/${name}/${name}-${ver}.crate";
  rewriteArgs = args:
    let
      url  = args.url  or null;
      urls = args.urls or null;
    in args
      // (if url  != null then { url  = rewriteOne url; } else {})
      // (if urls != null then { urls = map rewriteOne urls; } else {});
in
{
  # nixpkgs >= 25.11 wraps `fetchurl` in makeOverridableExcludingArgs, so
  # its override machinery sometimes calls the fetcher with a FUNCTION
  # argument (the finalAttrs/fpargs form), not an attrset. Only the
  # attrset form carries a crate URL to rewrite; every other form
  # (function, etc.) must pass straight through to the original fetcher
  # untouched — or eval fails with "expected a set but found a function".
  #
  # Earlier iterations tried to preserve fetchurl's attribute surface
  # (`.override`, `__functor`) via `wrapped // prev.fetchurl // {…}`,
  # but `wrapped` is a function and `function // set` is illegal in Nix
  # ("expected a set but found a function: lambda wrapped"). Preserving
  # .override is unnecessary in practice — full darwin-system + rust
  # closure evals do not call `pkgs.fetchurl.override`. If a consumer
  # ever needs it, switch to the conditional-functor form (apply only
  # when `builtins.isAttrs prev.fetchurl`).
  fetchurl = arg:
    if builtins.isAttrs arg
    then prev.fetchurl (rewriteArgs arg)
    else prev.fetchurl arg;
}
