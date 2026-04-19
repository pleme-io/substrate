# mkRustLambda — build a Rust Lambda function as a deployable zip.
#
# Wraps `tool-release.nix` to cross-compile the handler crate against
# the Lambda runtime target (`aarch64-unknown-linux-musl` for Arm64,
# `x86_64-unknown-linux-musl` for x86_64), then packages the resulting
# `bootstrap` binary into a zip with a single top-level entry — the
# exact shape AWS Lambda's `provided.al2023` custom runtime expects.
#
# The output package is `${name}-lambda-zip` and its `result/bootstrap.zip`
# is a deterministic, content-addressed artifact. Feed the flake-level
# output (`packages.<system>.lambda-zip`) into the typescape
# `LambdaZipSource::LocalBuild { nix_ref = "github:...#lambda-zip" }`;
# the per-workspace `nix run .#deploy` app (see `lambda-deploy.nix`)
# then pulls the zip at apply time and hands terraform the path +
# content hash.
#
# Consumers usually don't call this directly — they go through
# `lambda-flake.nix` for a zero-boilerplate flake. This file is the
# builder primitive.
#
# Usage (from a flake):
#   let
#     base = (import "${substrate}/lib/build/rust/tool-release-flake.nix" {
#       inherit nixpkgs crate2nix flake-utils fenix;
#     }) { toolName = "bootstrap"; src = self; repo = "pleme-io/my-lambda"; };
#
#     lambda = import "${substrate}/lib/build/rust/lambda.nix" {
#       inherit nixpkgs flake-utils;
#     };
#   in
#     base // {
#       packages = nixpkgs.lib.genAttrs systems (system: let
#         pkgs = import nixpkgs { inherit system; };
#         binaryPkg = base.packages.${system}."bootstrap-aarch64-unknown-linux-musl" or null;
#       in (base.packages.${system} or {}) // (
#         if binaryPkg != null then {
#           lambda-zip = lambda.mkLambdaZip {
#             inherit pkgs;
#             name = "my-lambda";
#             binary = binaryPkg;
#             architecture = "arm64";
#           };
#         } else {}
#       ));
#     };
{
  nixpkgs,
  flake-utils ? null,
  ...
}: {
  # Map a Lambda architecture string to the rustc musl target triple
  # used by `tool-release.nix` cross-builds. Only musl targets are
  # supported because Lambda runtimes don't ship glibc.
  targetForArchitecture = architecture:
    if architecture == "arm64"
    then "aarch64-unknown-linux-musl"
    else if architecture == "x86_64"
    then "x86_64-unknown-linux-musl"
    else throw "unsupported Lambda architecture: ${architecture} (expected 'arm64' or 'x86_64')";

  # Package a pre-built `bootstrap` binary into a Lambda zip.
  #
  # Inputs:
  #   pkgs         — nixpkgs set for the host system (the zip is built
  #                  on the host, but contains the target-architecture
  #                  binary).
  #   name         — used for derivation name + zip filename prefix.
  #   binary       — derivation that produces `${binary}/bin/bootstrap`.
  #   architecture — "arm64" or "x86_64". Purely informational at this
  #                  level; the zip layout is the same either way.
  #
  # Output: a derivation whose `$out` is a zip file containing a
  # single top-level entry named `bootstrap` (executable). The file
  # layout is:
  #   bootstrap                     <-- the Rust musl binary
  #
  # There's no `bootstrap/` directory; AWS runs `bootstrap` directly.
  mkLambdaZip = {
    pkgs,
    name,
    binary,
    architecture ? "arm64",
  }: let
    # The zip filename has to be a path ending in `.zip` — nix-on-macOS
    # builders otherwise refuse to emit a zip.
    zipName = "${name}-lambda-${architecture}.zip";
  in
    pkgs.runCommand zipName {
      nativeBuildInputs = [pkgs.zip];
      # Passthrough so consumers can discover the source architecture
      # without re-parsing the derivation name.
      passthru = {
        inherit architecture;
        binaryPath = "${binary}/bin/bootstrap";
      };
    } ''
      set -euo pipefail
      mkdir -p work
      # AWS Lambda `provided.al2023` runtime executes a file literally
      # named `bootstrap` at the zip root. Preserve the binary's
      # executable bit — zip otherwise loses it on some hosts.
      install -m 0755 ${binary}/bin/bootstrap work/bootstrap
      cd work
      # -9 = max compression. -X = strip extra file attrs so the zip
      # stays deterministic across build hosts (important for
      # source_code_hash content-addressing).
      zip -9 -X $out bootstrap
    '';

  # Convenience wrapper that asks for the binary by target triple.
  # Useful when you already have a `packages.<system>.<toolName>-<target>`
  # layout from `tool-release-flake.nix` — the common case for our
  # canonical Rust Lambdas.
  mkLambdaZipFromToolRelease = {
    pkgs,
    name,
    toolReleasePackages, # e.g. base.packages.${system}
    toolName ? "bootstrap",
    architecture ? "arm64",
  }: let
    target =
      if architecture == "arm64"
      then "aarch64-unknown-linux-musl"
      else "x86_64-unknown-linux-musl";
    attrName = "${toolName}-${target}";
    binary = toolReleasePackages.${attrName} or (throw
      "mkLambdaZipFromToolRelease: packages.<system>.${attrName} missing — \
       did you configure tool-release-flake for this target?");
    self = import ./lambda.nix {inherit nixpkgs;};
  in
    self.mkLambdaZip {
      inherit pkgs name binary architecture;
    };
}
