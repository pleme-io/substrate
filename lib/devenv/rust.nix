# Devenv module for Rust development.
#
# Provides: Rust stable toolchain, cargo-watch, pkg-config, openssl,
# Darwin SDK deps, clippy + rustfmt git hooks.
#
# Usage (in a devenv shell definition):
#   imports = [ "${substrate}/lib/devenv/rust.nix" ];
{ pkgs, lib, ... }: {
  languages.rust = {
    enable = true;
    channel = "stable";
  };

  packages = with pkgs; [
    pkg-config
    openssl
    cargo-watch
    cargo-edit
    rust-analyzer
  ] ++ lib.optionals pkgs.stdenv.isDarwin (
    (with pkgs.darwin.apple_sdk.frameworks; [
      Security SystemConfiguration CoreFoundation
    ]) ++ (with pkgs; [
      libiconv
      darwin.apple_sdk.libs.xpc
    ])
  );

  env = {
    RUST_BACKTRACE = "1";
    RUST_LOG = "debug";
  };

  git-hooks.hooks = {
    clippy.enable = lib.mkDefault true;
    rustfmt.enable = lib.mkDefault true;
  };
}
