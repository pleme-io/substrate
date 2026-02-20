# Ruby Service/Tool Builder Module
# Provides reusable functions for building Ruby applications with bundix/ruby-nix
#
# Usage:
#   mkRubyDockerImage { ... }  - Build Docker image for Ruby app
#   mkRubyRegenApp { ... }     - Create regen app for gemset.nix
#   mkRubyPushApp { ... }      - Create push app using forge
#   mkRubyServiceApps { ... }  - Create full regen/push/release app set
#
{ pkgs, forgeCmd, defaultGhcrToken }:

let
  inherit (pkgs) writeShellScript bundler bundix;

in rec {
  # ============================================================================
  # RUBY DOCKER IMAGE BUILDER
  # ============================================================================
  # Build a Docker image for a Ruby application
  #
  # rubyPackage: The built Ruby package (from bundlerApp or stdenv)
  # rubyEnv: The Ruby environment with gems
  # ruby: The Ruby interpreter
  # name: Image name (e.g., "ghcr.io/myorg/my-tool")
  # tag: Image tag (default: "latest")
  # cmd: Container command (default: uses rubyPackage)
  # env: Additional environment variables
  # extraContents: Additional packages to include
  #
  mkRubyDockerImage = {
    rubyPackage,
    rubyEnv,
    ruby,
    name,
    tag ? "latest",
    cmd ? null,
    env ? [],
    extraContents ? [],
    workingDir ? "/",
    exposedPorts ? {},
  }: pkgs.dockerTools.buildLayeredImage {
    inherit name tag;

    contents = [
      rubyPackage
      rubyEnv
      ruby
      pkgs.cacert
      pkgs.coreutils
    ] ++ extraContents;

    config = {
      Cmd = if cmd != null then cmd else [ "${rubyPackage}/bin/${baseNameOf name}" ];
      WorkingDir = workingDir;
      Env = [
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
        "DRY_TYPES_WARNINGS=false"
      ] ++ env;
      ExposedPorts = exposedPorts;
    };

    extraCommands = ''
      mkdir -p tmp
      chmod 1777 tmp
      mkdir -p etc
      echo "app:x:1000:1000::/:/bin/false" > etc/passwd
      echo "app:x:1000:" > etc/group
    '';
  };

  # ============================================================================
  # REGEN APP (Regenerate gemset.nix)
  # ============================================================================
  # Create an app that regenerates Gemfile.lock and gemset.nix using bundix
  #
  # srcDir: Path to the Ruby project directory
  # name: Name of the tool (for messages)
  #
  mkRubyRegenApp = {
    srcDir,
    name,
  }: {
    type = "app";
    program = toString (writeShellScript "regen-${name}" ''
      set -euo pipefail

      SRC_DIR="${srcDir}"

      if [ ! -d "$SRC_DIR" ]; then
        echo "Error: Source directory not found at $SRC_DIR"
        exit 1
      fi

      echo "Regenerating ${name} gemset.nix..."
      echo "Source directory: $SRC_DIR"
      echo ""

      cd "$SRC_DIR"

      # Update Gemfile.lock
      ${bundler}/bin/bundle lock --update

      # Regenerate gemset.nix using bundix
      ${bundix}/bin/bundix

      echo ""
      echo "Done! Updated:"
      echo "  $SRC_DIR/Gemfile.lock"
      echo "  $SRC_DIR/gemset.nix"
    '');
  };

  # ============================================================================
  # PUSH APP (Push Docker image using forge)
  # ============================================================================
  # Create an app that builds and pushes a Ruby Docker image
  #
  # flakePath: Path to the flake that builds the image
  # imageOutput: Flake output for the image (e.g., "compilerImage")
  # registry: Target registry (e.g., "ghcr.io/myorg/my-tool")
  # name: Name of the tool (for messages)
  #
  mkRubyPushApp = {
    flakePath,
    imageOutput,
    registry,
    name,
  }: {
    type = "app";
    program = toString (writeShellScript "push-${name}" ''
      set -euo pipefail
      ${if defaultGhcrToken != "" then ''export GITHUB_TOKEN="${defaultGhcrToken}"
      export GHCR_TOKEN="${defaultGhcrToken}"'' else ''export GITHUB_TOKEN="''${GITHUB_TOKEN:-''${GHCR_TOKEN:-$(cat "$HOME/.config/github/token" 2>/dev/null || true)}}"
      export GHCR_TOKEN="$GITHUB_TOKEN"''}

      FLAKE_PATH="${flakePath}"

      if [ ! -d "$FLAKE_PATH" ]; then
        echo "Error: Flake directory not found at $FLAKE_PATH"
        exit 1
      fi

      echo "Building and pushing ${name}..."
      echo "Flake path: $FLAKE_PATH"
      echo ""

      # Step 1: Build the image
      echo "Step 1/2: Building Docker image..."
      ${pkgs.nix}/bin/nix build "$FLAKE_PATH#${imageOutput}" --out-link "$FLAKE_PATH/result-${name}"

      if [ ! -L "$FLAKE_PATH/result-${name}" ]; then
        echo "Build failed"
        exit 1
      fi

      IMAGE_PATH=$(readlink -f "$FLAKE_PATH/result-${name}")
      echo "Build complete: $IMAGE_PATH"
      echo ""

      # Step 2: Push with forge
      echo "Step 2/2: Pushing to GitHub Packages..."
      exec ${forgeCmd} push \
        --image-path "$IMAGE_PATH" \
        --registry "${registry}" \
        --auto-tags \
        --retries 3
    '');
  };

  # ============================================================================
  # SERVICE APPS (Full regen/push/release set)
  # ============================================================================
  # Create the complete app set for a Ruby service
  #
  # srcDir: Path to the Ruby project directory
  # flakePath: Path to the flake (defaults to srcDir)
  # imageOutput: Flake output for the image
  # registry: Target registry
  # name: Name of the tool
  #
  mkRubyServiceApps = {
    srcDir,
    flakePath ? srcDir,
    imageOutput,
    registry,
    name,
  }: {
    "regen:${name}" = mkRubyRegenApp { inherit srcDir name; };
    "push:${name}" = mkRubyPushApp { inherit flakePath imageOutput registry name; };
    "release:${name}" = {
      type = "app";
      program = toString (writeShellScript "release-${name}" ''
        set -euo pipefail
        echo "Releasing ${name}..."
        echo ""

        # Regen first to ensure gemset.nix is up to date
        nix run .#regen:${name}
        echo ""

        # Then push
        nix run .#push:${name}
        echo ""

        echo "Release complete!"
      '');
    };
  };
}
