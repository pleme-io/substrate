# Devenv module for Rust service development.
#
# Extends the base Rust module with PostgreSQL, Redis, and protobuf.
# Services start automatically with `devenv up`.
#
# Usage (in a devenv shell definition):
#   imports = [ "${substrate}/lib/devenv/rust-service.nix" ];
#   env.DATABASE_URL = "postgresql://myservice_test:test_password@localhost:5432/myservice_test";
{ pkgs, lib, ... }: {
  imports = [ ./rust.nix ];

  services.postgres = {
    enable = lib.mkDefault true;
    listen_addresses = "127.0.0.1";
  };

  services.redis = {
    enable = lib.mkDefault true;
  };

  packages = with pkgs; [
    protobuf
    postgresql
    sqlx-cli
    cmake
    perl
  ];

  env = {
    PROTOC = "${pkgs.protobuf}/bin/protoc";
    REDIS_URL = lib.mkDefault "redis://localhost:6379";
  };
}
