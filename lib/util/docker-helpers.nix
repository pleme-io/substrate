# ============================================================================
# DOCKER HELPERS - Shared Docker image building fragments
# ============================================================================
# Composable fragments for Docker image builders across web-docker.nix,
# ruby-build.nix, wasm-build.nix, and crate2nix-builders.nix.
#
# Internal helper — not exported from lib/default.nix.
{
  # fakeRootCommands for a web user (101:101) — used by web-docker.nix, wasm-build.nix
  mkWebUserSetup = ''
    mkdir -p etc
    echo 'root:x:0:0:System administrator:/root:/bin/sh' > etc/passwd
    echo 'web:x:101:101:web:/app:/sbin/nologin' >> etc/passwd
    echo 'root:x:0:' > etc/group
    echo 'web:x:101:' >> etc/group
  '';

  # extraCommands for an app user (1000:1000) — used by ruby-build.nix
  mkAppUserSetup = ''
    mkdir -p etc
    echo "app:x:1000:1000::/:/bin/false" > etc/passwd
    echo "app:x:1000:" > etc/group
  '';

  # extraCommands for standard temp/log directories
  mkTmpDirs = ''
    mkdir -p var/log run tmp
    chmod -R 777 var/log run tmp
  '';

  # SSL_CERT_FILE env var string — used in Docker image Env lists
  mkSslEnv = pkgs: "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";

  # Base container contents for services that need TLS + basic shell
  mkBaseContents = pkgs: with pkgs; [ cacert busybox ];
}
