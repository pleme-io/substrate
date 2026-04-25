# ============================================================================
# STATIC-SITE-DEV-LOOP — packaged dev experience for headless-CMS blogs
# ============================================================================
#
# Companion to `rust-static-site-flake.nix` and `cloudflare-pages-deploy.nix`.
# Where those handle generation + deployment, this recipe wires up the
# inner dev loop: file watching, hot reload, drafts, Hashnode (or any
# headless CMS) response cache, mock webhook signing, prod-parity preview.
#
# Strategy:
#
#   The actual dev daemon is a Rust binary that the consumer ships as a
#   workspace member at `crates/<name>-dev/`. This recipe doesn't build it
#   into the Nix store — instead each app exec's `cargo run --profile
#   dev-fast -p <devCrate> -- <subcommand>`. First invocation pays a cargo
#   build (~30-60s); subsequent invocations are instant.
#
#   The reference implementation lives at pleme-io/zuihitsu — copy
#   `crates/zuihitsu-dev/` into your blog, rename the crate, and consume
#   this recipe. (When zuihitsu-dev is extracted to its own published crate
#   this recipe will gain `mkDevBin` and skip the manual copy.)
#
# Usage:
#
#   let devLoop = import "${substrate}/lib/build/web/static-site-dev-loop.nix" {
#         inherit pkgs;
#       };
#       loopApps = devLoop.mkAllApps {
#         name = "zuihitsu";                    # binary-name prefix
#         devCrate = "zuihitsu-dev";            # workspace member
#         workerWrangler = "crates/zuihitsu-worker/wrangler.toml";
#         distDir = "dist";
#       };
#   in {
#     apps = loopApps;
#   }
#
# Each app is a 1-2 line shell wrapper around either `cargo run` or one of
# wrangler / cloudflared. Conforms to the pleme-io "no shell beyond 3-line
# glue" policy (canonical in ~/.claude/CLAUDE.md, repo-level guidance in
# pleme-io/CLAUDE.md §★★ PRIME DIRECTIVE).

{ pkgs }:

let
  # All consumer apps need cargo + wrangler + cloudflared on PATH. We
  # intentionally don't pin a Rust toolchain here — the consumer's flake is
  # responsible for providing rust via fenix / nixpkgs / etc., and
  # pre-pending it to PATH before invoking these wrappers (which is what
  # `mkApp` in zuihitsu's flake does already via `binPath`).
  # `pkgs.wrangler` is the modern top-level path; `pkgs.nodePackages.wrangler`
  # was deprecated upstream in 2024. Stay current.
  baseTools = [
    pkgs.nodejs_20
    pkgs.wrangler
    pkgs.cloudflared
  ];
  basePath = pkgs.lib.makeBinPath baseTools;

  # Internal helper. We don't reuse the consumer's own mkApp because we want
  # this recipe to be drop-in independent — but the resulting `program`
  # value is shape-compatible with `nix run`.
  mkExec = label: script: {
    type = "app";
    program = "${pkgs.writeShellScriptBin label ''
      set -euo pipefail
      export PATH=${basePath}:$PATH
      ${script}
    ''}/bin/${label}";
  };
in
{
  ## Watch / build / serve loop. The consumer's daemon owns the behaviour;
  ## this is a thin wrapper.
  mkDevApp = {
    name,
    devCrate ? "${name}-dev",
    profile ? "dev-fast",
    extraArgs ? "",
  }: mkExec "${name}-dev-watch" ''
    exec cargo run --profile ${profile} -p ${devCrate} -- daemon ${extraArgs} "$@"
  '';

  ## Cache invalidation + sitegen warm pass.
  mkFetchApp = {
    name,
    devCrate ? "${name}-dev",
    profile ? "dev-fast",
  }: mkExec "${name}-dev-fetch" ''
    exec cargo run --profile ${profile} -p ${devCrate} -- fetch "$@"
  '';

  ## `<name>-dev draft <slug>` — scaffold a markdown draft.
  mkDraftApp = {
    name,
    devCrate ? "${name}-dev",
    profile ? "dev-fast",
  }: mkExec "${name}-dev-draft" ''
    exec cargo run --profile ${profile} -p ${devCrate} -- draft "$@"
  '';

  ## HMAC-sign + POST a fake webhook payload to a local worker.
  mkWorkerTestApp = {
    name,
    devCrate ? "${name}-dev",
    profile ? "dev-fast",
  }: mkExec "${name}-dev-worker-test" ''
    exec cargo run --profile ${profile} -p ${devCrate} -- worker-test "$@"
  '';

  ## `wrangler dev` for the worker. Expects the consumer to have already run
  ## the worker-build app (worker-rs cdylib → wasm + shim).
  mkWorkerDevApp = {
    name,
    workerDir,
  }: mkExec "${name}-worker-dev" ''
    cd ${workerDir}
    exec wrangler dev
  '';

  ## Cloudflared quick-tunnel exposing the local worker to the public
  ## internet. Use sparingly — only needed for live Hashnode webhook smoke
  ## tests.
  mkTunnelApp = {
    name,
    port ? 8787,
  }: mkExec "${name}-tunnel" ''
    exec cloudflared tunnel --url http://localhost:${toString port}
  '';

  ## `wrangler pages dev` over the dist/ directory — closer to prod (Pages
  ## routing rules, _headers, _redirects). Use as the last-mile smoke test
  ## before deploy.
  mkPreviewApp = {
    name,
    distDir ? "dist",
  }: mkExec "${name}-preview" ''
    exec wrangler pages dev "''${1:-${distDir}}"
  '';

  ## Convenience: emit all of the above as a single attrset suitable for
  ## merging into `apps.<system>` directly.
  mkAllApps = {
    name,
    devCrate ? "${name}-dev",
    profile ? "dev-fast",
    workerDir ? null,
    workerPort ? 8787,
    distDir ? "dist",
  }: let
    self = import ./static-site-dev-loop.nix { inherit pkgs; };
    base = {
      dev = self.mkDevApp { inherit name devCrate profile; };
      fetch = self.mkFetchApp { inherit name devCrate profile; };
      draft = self.mkDraftApp { inherit name devCrate profile; };
      worker-test = self.mkWorkerTestApp { inherit name devCrate profile; };
      tunnel = self.mkTunnelApp { inherit name; port = workerPort; };
      preview = self.mkPreviewApp { inherit name distDir; };
    };
    workerExtras = pkgs.lib.optionalAttrs (workerDir != null) {
      worker-dev = self.mkWorkerDevApp { inherit name workerDir; };
    };
  in
    base // workerExtras;
}
