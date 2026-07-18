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
  # Hardened by default (Pillar 8 / oci/hardened-base.nix). `wolfi` is the
  # right base for this file specifically: unlike the Rust CLI-tool builder
  # (tool-image.nix, distroless-glibc, no shell), this "universal" builder
  # exposes `extraCommands`/`fakeRootCommands` escape hatches to consumers
  # (mkWebDockerImage below genuinely needs both, to merge a built static
  # bundle into a fixed directory and to stamp a custom passwd/group) and
  # has always shipped `busybox` unconditionally -- dropping the runtime
  # shell out from under an existing consumer would be a silent behavior
  # change we can't verify against every out-of-repo caller. `wolfi`
  # (cacert + nonroot passwd/group stub + glibc + busybox) is a strict
  # superset of the old ad-hoc `[cacert busybox]` base, so this is a pure
  # hardening win (TLS roots + a real nonroot user convention) with zero
  # loss of the shell surface the escape hatches rely on.
  hardened = import ../oci/hardened-base.nix { inherit pkgs; };
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
    user ? "${toString hardened.nonrootUid}:${toString hardened.nonrootGid}",
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

    # cacert + busybox now come from `fromImage` (hardened.bases.wolfi);
    # the caller's own `binary` + `extraContents` are the only new layers.
    imageContents = [ binary ] ++ extraContents;

    imageArgs = {
      inherit name tag architecture;
      fromImage = hardened.bases.wolfi;
      contents = imageContents;
      config = {
        Entrypoint = resolvedEntrypoint;
        ExposedPorts = exposedPorts;
        Env = baseEnv;
        WorkingDir = workDir;
        User = user;
      } // (if labels != {} then { Labels = labels; } else {});
    } // (if extraCommands != "" then { inherit extraCommands; } else {})
      // (if fakeRootCommands != null then { inherit fakeRootCommands; } else {});
  in (dockerTools.buildLayeredImage imageArgs) // {
    # SBOM-correctness passthru -- see oci/hardened-base.nix's own
    # mkPackageImage comment: buildLayeredImage's gzip'd tarball defeats
    # Nix's reference scanner, so a real closure list needs computing
    # separately from the pre-compression contents.
    closureInfo = pkgs.closureInfo {
      rootPaths = (hardened.bases.wolfi.contents or []) ++ imageContents;
    };
  };

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

    # Hanabi-serves-a-static-bundle pattern: `extraCommands` merges the
    # built app + optional runtime env.js into one fixed `/app/static`
    # directory, and `fakeRootCommands` stamps a custom "web" (101) user --
    # neither has an equivalent in oci/hardened-base.nix's `mkPackageImage`
    # (package-plus-extraContents, no directory-merge primitive, no custom
    # named-user support), so this stays a direct `buildLayeredImage` call.
    # What DOES convert cleanly: the base. `wolfi` is a strict superset of
    # the old ad-hoc `[cacert curl busybox]` (adds the nonroot passwd/group
    # stub, which `fakeRootCommands` below immediately overwrites with the
    # "web" convention anyway) -- pure hardening win, zero behavior change.
    imageContents = [ webServer pkgs.curl ];
  in dockerTools.buildLayeredImage {
    inherit name tag architecture;
    fromImage = hardened.bases.wolfi;
    contents = imageContents;
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
  } // {
    closureInfo = pkgs.closureInfo {
      rootPaths = (hardened.bases.wolfi.contents or []) ++ imageContents;
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
    user = "${toString hardened.nonrootUid}:${toString hardened.nonrootGid}";
    extraCommands = if migrationsPath != null then ''
      mkdir -p app/migrations
      if [ -d "${migrationsPath}" ]; then
        cp -r ${migrationsPath}/* app/migrations/ || true
      fi
    '' else "";
  };
}
