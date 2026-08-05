# sql-apply-image — the OCI image carrying the typed SQL migration runner, so a
# K8s Job can invoke it. A container's `command:` can only run what is INSIDE its
# image, which is the one place the "just call the tool" answer needs an image
# built first.
#
# distroless-static, and that is the whole point: the shell runner this replaces
# forced a busybox-carrying base because the runner WAS a script. A Rust binary
# that talks to the database over TCP needs no shell, no database CLI, and no
# libc, so the image carries the binary, a CA bundle and a nonroot user. Nothing
# to `exec` even if something tried.
#
# Linux-only: dockerTools cannot build a Linux image on darwin. A darwin eval
# yields a stub with the real command, matching how hardened-images and
# camelot-bootstrap guard their own image attrs, so `nix flake check` on a Mac
# does not error.
{ pkgs }:
let
  sqlApply = import ./sql-apply.nix { inherit pkgs; };
  hardened = import ./oci/hardened-base.nix { inherit pkgs; };
in
if pkgs.stdenv.isLinux then
  hardened.mkPackageImage {
    service = "sql-apply";
    base = hardened.bases.distroless-static;
    package = sqlApply;
    publishName = "ghcr.io/pleme-io/sql-apply";
    publishTag = "0.1.0";
    entrypoint = [ "${sqlApply}/bin/sql-apply" ];
    env = [ "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ];
    user = "${toString hardened.nonrootUid}:${toString hardened.nonrootGid}";
  }
else
  pkgs.runCommand "sql-apply-image-darwin-stub" { } ''
    mkdir -p "$out"
    echo "Build the OCI image on Linux: nix build .#sql-apply-image --system x86_64-linux" > "$out/README"
  ''
