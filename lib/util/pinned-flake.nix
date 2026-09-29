# pinned-flake.nix — fetch a pleme-io tool flake at the revision a pin records.
#
# substrate reaches gen and ferrite through JSON pin files rather than flake
# inputs, so a release bumps one file instead of every consumer's lock. Six
# builders spelled the same `builtins.getFlake "github:pleme-io/<repo>/<rev>"`
# plus the same host-tool fallback by hand; this is that shape once. The URL
# is unchanged, so every consumer's derivation is unchanged.
{ }:

rec {
  # atRev { repo; rev; } -> the flake github:pleme-io/<repo> at <rev>.
  atRev = { repo, rev }: builtins.getFlake "github:pleme-io/${repo}/${rev}";

  # fromPin { repo; pinFile; } -> atRev with the rev read from a pin JSON.
  fromPin = { repo, pinFile }:
    atRev { inherit repo; rev = (builtins.fromJSON (builtins.readFile pinFile)).rev; };

  # tool flake system -> packages.<system>.host-tool, or .default when the
  # flake publishes no host-tool (gen does; older revisions did not).
  hostTool = flake: system:
    flake.packages.${system}.host-tool or flake.packages.${system}.default;
}
