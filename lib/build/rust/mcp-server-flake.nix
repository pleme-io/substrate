# Complete multi-system flake outputs for a kaname-based MCP server (Rust).
#
# This is a thin specialization of rust-tool-release-flake.nix that bakes in
# MCP-server-flavored defaults so consumers don't have to repeat them:
#
#   - module.withMcp           defaults to true   (MCP IS the point)
#   - module.mcpSubcommand     defaults to "mcp"
#   - module.description       defaults to "MCP server: <toolName>"
#
# Pre-fills the trio's HM module so `programs.<toolName>.enableMcpBin = true;`
# automatically wires the `<toolName>-mcp` shim into ~/.local/bin — no
# downstream HM module file needed.
#
# Usage in a flake:
#   outputs = { self, nixpkgs, crate2nix, flake-utils, substrate, devenv, ... }:
#     (import "${substrate}/lib/mcp-server-flake.nix" {
#       inherit nixpkgs crate2nix flake-utils devenv;
#     }) {
#       toolName = "zoekt-mcp";
#       src = self;
#       repo = "pleme-io/zoekt-mcp";
#     };
#
# To override defaults (e.g. add HTTP serve, change description), pass a
# `module` attrset — it merges over the MCP-flavored defaults:
#
#   {
#     toolName = "zoekt-mcp";
#     src = self;
#     module = {
#       description = "Zoekt code-search MCP server";
#       withHttp = true;     # add programs.zoekt-mcp.enableHttpService
#     };
#   };
{
  nixpkgs,
  crate2nix,
  flake-utils,
  fenix ? null,
  devenv ? null,
  forge ? null,
}:
{
  toolName,
  module ? {},
  ...
} @ args:
let
  rustToolFlake = import ./tool-release-flake.nix {
    inherit nixpkgs crate2nix flake-utils fenix devenv forge;
  };

  # MCP-flavored module defaults — merged with caller-supplied module attrset.
  # Caller wins via `//`, but `withMcp` and `mcpSubcommand` are forced so MCP
  # behaviour is guaranteed even if a caller forgets to set them.
  mcpModule = {
    description = module.description or "MCP server: ${toolName}";
    withMcp = true;
    mcpSubcommand = module.mcpSubcommand or "mcp";
  } // (builtins.removeAttrs module [ "description" "withMcp" "mcpSubcommand" ]);

  forwardedArgs = (builtins.removeAttrs args [ "module" ]) // {
    module = mcpModule;
  };
in
  rustToolFlake forwardedArgs
