# Go Service Docker Image Builder
#
# Builds minimal, secure Docker images for Go services. Equivalent of
# mkCrate2nixDockerImage for Rust, but for Go binaries.
#
# Features:
# - Alpine-based minimal images
# - Non-root user (65534:65534)
# - Multi-architecture (amd64/arm64)
# - Health check port configuration
# - SSL certificate bundle included
# - Layered for cache efficiency
#
# Usage:
#   mkGoDockerImage = (import "${substrate}/lib/go-docker.nix").mkGoDockerImage;
#   image = mkGoDockerImage pkgs {
#     name = "my-service";
#     binary = myGoBinary;        # result of buildGoModule
#     architecture = "amd64";     # or "arm64"
#     ports = { http = 8080; health = 8081; metrics = 9090; };
#     env = [ "LOG_LEVEL=info" ];
#   };
{
  # Build a layered Docker image from a Go binary.
  mkGoDockerImage = pkgs: {
    name,
    binary,
    tag ? "latest",
    architecture ? "amd64",
    ports ? { http = 8080; health = 8081; },
    env ? [],
    user ? "65534:65534",
    workDir ? "/app",
    entrypoint ? null,
    extraContents ? [],
  }: let
    inherit (pkgs) lib dockerTools cacert busybox;
    check = import ../../types/assertions.nix;
    _ = check.all [
      (check.nonEmptyStr "name" name)
      (check.str "tag" tag)
      (check.architecture "architecture" architecture)
      (check.namedPorts "ports" ports)
      (check.list "env" env)
      (check.str "user" user)
      (check.str "workDir" workDir)
      (check.list "extraContents" extraContents)
    ];

    mainPort = ports.http or ports.api or (lib.head (lib.attrValues ports));
    healthPort = ports.health or mainPort;

    sslEnv = "SSL_CERT_FILE=${cacert}/etc/ssl/certs/ca-bundle.crt";

    exposedPorts = lib.mapAttrs' (_: port:
      lib.nameValuePair "${toString port}/tcp" {}
    ) ports;

    defaultEntrypoint = [ "${binary}/bin/${name}" ];
  in
  dockerTools.buildLayeredImage {
    inherit name tag architecture;
    contents = [ binary cacert busybox ] ++ extraContents;
    config = {
      Entrypoint = if entrypoint != null then entrypoint else defaultEntrypoint;
      ExposedPorts = exposedPorts;
      Env = [
        sslEnv
        "GIT_SHA=nix-build"
      ] ++ env;
      WorkingDir = workDir;
      User = user;
    };
  };

  # Build a multi-stage Go binary + Docker image in one call.
  mkGoServiceImage = pkgs: {
    name,
    src,
    version ? "0.1.0",
    subPackages ? [ "cmd/${name}" ],
    vendorHash ? null,
    tag ? "latest",
    architecture ? "amd64",
    ports ? { http = 8080; health = 8081; },
    env ? [],
    buildInputs ? [],
    ldflags ? [],
  }: let
    binary = pkgs.buildGoModule {
      pname = name;
      inherit version src vendorHash subPackages ldflags;
      inherit buildInputs;
      CGO_ENABLED = 0;
      meta.mainProgram = name;
    };
  in
  (pkgs.callPackage ./go-docker.nix {}).mkGoDockerImage pkgs {
    inherit name binary tag architecture ports env;
  };
}
