# Health supervisor builder for web containers
{ pkgs }:

{
  # Build the health-supervisor binary for web containers
  #
  # Parameters:
  #   healthSupervisorSrc: Path to health-supervisor source directory
  #   architecture: "amd64" or "arm64"
  mkHealthSupervisor = {
    healthSupervisorSrc,
    architecture ? "amd64",
  }:
    let
      check = import ../types/assertions.nix;
      _ = check.architecture "architecture" architecture;

      # Select correct musl target based on architecture
      muslTarget =
        if architecture == "arm64"
        then "aarch64-unknown-linux-musl"
        else "x86_64-unknown-linux-musl";

      # Create crane library for health-supervisor
      craneLib = (pkgs.crane.mkLib pkgs).overrideToolchain (
        pkgs.fenix.fromToolchainFile {
          file = healthSupervisorSrc + "/rust-toolchain.toml";
          # SHA256 of the toolchain archive — update when rust-toolchain.toml changes.
          # Compute with: nix-prefetch-url --unpack <toolchain-url>
          sha256 = "sha256-SXRtAuO4IqnOQq5yGo+Ojxwxc/FRlKEpgwfVzwbLRV4=";
        }
      );

      # Target-specific rustflags environment variable name
      targetEnvName = pkgs.lib.toUpper (pkgs.lib.replaceStrings ["-"] ["_"] muslTarget);

      # Common build arguments
      commonArgs = {
        src = craneLib.cleanCargoSource healthSupervisorSrc;
        strictDeps = true;
        CARGO_BUILD_TARGET = muslTarget;
        "CARGO_TARGET_${targetEnvName}_RUSTFLAGS" = "-C target-feature=+crt-static -C link-arg=-s";

        nativeBuildInputs = with pkgs; [
          cmake
          perl
        ];
      };

      # Build dependencies (cached separately for faster builds)
      cargoArtifacts = craneLib.buildDepsOnly commonArgs;

      # Build the health-supervisor binary
      healthSupervisor = craneLib.buildPackage (commonArgs
        // {
          inherit cargoArtifacts;
          doCheck = false;
        });
    in
      healthSupervisor;
}
