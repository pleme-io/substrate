# Shared Docker Image Builder
#
# Universal typed Docker image builder that replaces the per-language
# implementations in go/docker.nix, web/docker.nix, and wasm/build.nix.
# Language-specific builders become thin wrappers that construct a
# DockerImageSpec and delegate here.
#
# This is the cross-cutting concern factored to a single location —
# one of the key convergence optimizations in the substrate refactoring.
#
# Depends on: pkgs (for dockerTools, cacert, busybox)
#
# Usage:
#   shared = import ./docker-image.nix { inherit pkgs; };
#   image = shared.mkTypedDockerImage {
#     name = "auth";
#     binary = myBinary;
#     ports = { http = 8080; health = 8081; };
#   };
{ pkgs }:

let
  inherit (pkgs) lib dockerTools cacert busybox;
  dockerHelpers = import ../../util/docker-helpers.nix;
in rec {
  # ── Universal Docker Image Builder ────────────────────────────────
  # Builds a layered OCI image from a binary package. This is the
  # shared implementation underlying all language-specific Docker
  # builders.
  #
  # Parameters follow the DockerImageSpec type from types/deploy-spec.nix.
  mkTypedDockerImage = {
    name,
    binary,
    tag ? "latest",
    architecture ? "amd64",
    ports ? {},
    env ? [],
    user ? "65534:65534",
    entrypoint ? null,
    extraContents ? [],
    workDir ? "/app",
    extraCommands ? "",
    fakeRootCommands ? null,
    labels ? {},
  }: let
    sslEnv = dockerHelpers.mkSslEnv pkgs;

    exposedPorts = lib.mapAttrs' (_: port:
      lib.nameValuePair "${toString port}/tcp" {}
    ) ports;

    defaultEntrypoint = [ "${binary}/bin/${lib.getName binary}" ];
    resolvedEntrypoint = if entrypoint != null then entrypoint else defaultEntrypoint;

    baseEnv = [
      sslEnv
      "GIT_SHA=nix-build"
    ] ++ env;

    imageArgs = {
      inherit name tag architecture;
      contents = [ binary cacert busybox ] ++ extraContents;
      config = {
        Entrypoint = resolvedEntrypoint;
        ExposedPorts = exposedPorts;
        Env = baseEnv;
        WorkingDir = workDir;
        User = user;
      } // (if labels != {} then { Labels = labels; } else {});
    } // (if extraCommands != "" then { inherit extraCommands; } else {})
      // (if fakeRootCommands != null then { inherit fakeRootCommands; } else {});
  in dockerTools.buildLayeredImage imageArgs;

  # ── Web Application Docker Image ─────────────────────────────────
  # Specialized builder for web apps served by a static file server
  # (Hanabi or nginx). Copies built assets into the image.
  mkWebDockerImage = {
    name,
    builtApp,
    webServer,
    tag ? "latest",
    architecture ? "amd64",
    ports ? { http = 80; health = 8080; },
    env ? [],
    envConfigPath ? null,
    user ? "web",
  }: let
    sslEnv = dockerHelpers.mkSslEnv pkgs;

    exposedPorts = lib.mapAttrs' (_: port:
      lib.nameValuePair "${toString port}/tcp" {}
    ) ports;
  in dockerTools.buildLayeredImage {
    inherit name tag architecture;
    contents = [ webServer cacert pkgs.curl busybox ];
    fakeRootCommands = dockerHelpers.mkWebUserSetup;
    extraCommands = ''
      mkdir -p app/static
      cp -r ${builtApp}/* app/static/
      ${if envConfigPath != null then "cp ${envConfigPath} app/static/env.js" else ""}
      chmod -R 755 app/static
      ${dockerHelpers.mkTmpDirs}
    '';
    config = {
      Cmd = [ "${webServer}/bin/hanabi" ];
      ExposedPorts = exposedPorts;
      Env = [
        sslEnv
        "NODE_ENV=production"
      ] ++ env;
      WorkingDir = "/app/static";
      User = user;
    };
  };

  # ── Service Docker Image with Migrations ──────────────────────────
  # For Rust/Go services that include SQL migrations alongside the binary.
  mkServiceDockerImage = {
    name,
    binary,
    tag ? "latest",
    architecture ? "amd64",
    ports ? { http = 8080; health = 8081; metrics = 9090; },
    env ? [],
    extraContents ? [],
    migrationsPath ? null,
    labels ? {},
  }: mkTypedDockerImage {
    inherit name binary tag architecture ports env extraContents labels;
    user = "65534:65534";
    extraCommands = if migrationsPath != null then ''
      mkdir -p app/migrations
      if [ -d "${migrationsPath}" ]; then
        cp -r ${migrationsPath}/* app/migrations/ || true
      fi
    '' else "";
  };
}
