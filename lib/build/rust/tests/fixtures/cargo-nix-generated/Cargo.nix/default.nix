# FIXTURE — the shape crate2nix's `tools.nix`.generatedCargoNix produces:
# a DIRECTORY holding default.nix, not a file. `import` accepts it;
# `builtins.readFile` does not. The tie must report `absent` rather than
# trying to read the directory, and must do so from the primitive, not by
# trusting every caller to pass the committed path instead.
{ pkgs ? import <nixpkgs> { } }:
{
  internal.crates = { };
  marker = "generated-fixture-was-imported";
}
