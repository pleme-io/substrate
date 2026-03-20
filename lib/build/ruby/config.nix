# Ruby Configuration Module
#
# Single source of truth for Ruby version across all pleme-io Ruby projects.
# All Ruby gems and services should use this unless they have a specific reason
# to override. Mirrors the pattern of rust-overlay.nix for Rust.
#
# Usage:
#   rubyConfig = import "${substrate}/lib/ruby-config.nix";
#   ruby = rubyConfig.getRuby pkgs;
#   requiredVersion = rubyConfig.requiredRubyVersion;
#
{
  # Default Ruby version — latest stable
  rubyVersion = "3.4";

  # Get the Ruby package from nixpkgs
  getRuby = pkgs: pkgs.ruby_3_4;

  # Required Ruby version string for gemspecs
  requiredRubyVersion = ">=3.4.0";
}
