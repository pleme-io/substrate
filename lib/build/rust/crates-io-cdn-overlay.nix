# crates-io-cdn-overlay.nix — fleet-wide nixpkgs overlay that
# rewrites every `crates.io/api/v1/crates/<name>/<ver>/download`
# URL passed to `fetchurl` into the canonical
# `https://static.crates.io/crates/<name>/<name>-<ver>.crate` CDN URL.
#
# Why: crates.io permanently 403's the /api/v1 redirect endpoint as
# of 2026-05-27 (no UA, no rate-limit window — it's a policy change).
# `static.crates.io` is the always-open CDN cargo itself fetches from.
#
# Coverage: this overlay catches every fetcher in the closure —
# substrate's lockfile-builder (which already routes through
# canonicalRegistryUrl), nixpkgs' built-in `cargoSetupHook` /
# `fetchCargoVendor` / `prefetch-npm-deps` / any `buildRustPackage`
# call, and third-party flakes that use `pkgs.fetchurl` directly with
# a Cargo.lock URL.
#
# Consumed by: substrate flake exports this as `overlays.crates-io-cdn`.
# Consumers compose:
#
#   nixpkgs.lib.composeManyExtensions [
#     substrate.overlays.crates-io-cdn
#     # … other overlays
#   ]
final: prev: {
  fetchurl = args@{ url ? null, urls ? null, ... }:
    let
      apiPrefix = "https://crates.io/api/v1/crates/";
      isApi = u: builtins.isString u && prev.lib.hasPrefix apiPrefix u;
      # Extract `<name>/<ver>/download` and rebuild the CDN URL.
      # The api URL shape is fixed: `<prefix><name>/<ver>/download`.
      rewriteOne = u:
        if !isApi u then u
        else
          let
            tail = prev.lib.removePrefix apiPrefix u;
            parts = prev.lib.splitString "/" tail;
            name = builtins.elemAt parts 0;
            ver  = builtins.elemAt parts 1;
          in "https://static.crates.io/crates/${name}/${name}-${ver}.crate";
      newUrl  = if url  != null then rewriteOne url else null;
      newUrls = if urls != null then map rewriteOne urls else null;
      patched = args
        // (if url  != null then { url  = newUrl;  } else {})
        // (if urls != null then { urls = newUrls; } else {});
    in prev.fetchurl patched;
}
