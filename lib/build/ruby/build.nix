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
  # Hardened by default (Pillar 8 / oci/hardened-base.nix). `distroless-glibc`
  # (not `wolfi`) is the right base here: Ruby/bundler-driven apps commonly
  # shell out via Open3/system() expecting REAL GNU coreutils, and adding
  # `pkgs.coreutils` on top of `wolfi`'s busybox would collide on the same
  # `/bin/*` paths (busybox's multi-call symlinks vs coreutils' own
  # binaries). `distroless-glibc` (cacert + nonroot passwd/group stub +
  # glibc, no busybox) is a clean drop-in for the old ad-hoc `[cacert]`,
  # leaving `coreutils` as the sole shell-tool provider, unchanged.
  hardened = import ../oci/hardened-base.nix { inherit pkgs; };
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
  }: let
    check = import ../../types/assertions.nix;
    _ = check.all [
      (check.nonEmptyStr "name" name)
      (check.str "tag" tag)
      (check.list "env" env)
      (check.list "extraContents" extraContents)
    ];
    imageContents = [
      rubyPackage
      rubyEnv
      ruby
      pkgs.coreutils
    ] ++ extraContents;
  in pkgs.dockerTools.buildLayeredImage {
    inherit name tag;

    fromImage = hardened.bases.distroless-glibc;
    contents = imageContents;

    config = let dockerHelpers = import ../../util/docker-helpers.nix; in {
      Cmd = if cmd != null then cmd else [ "${rubyPackage}/bin/${baseNameOf name}" ];
      WorkingDir = workingDir;
      Env = [
        (dockerHelpers.mkSslEnv pkgs)
        "DRY_TYPES_WARNINGS=false"
      ] ++ env;
      ExposedPorts = exposedPorts;
      # This image previously had no `User` at all (implicit root), even
      # though `mkAppUserSetup` below already stamps a matching "app"
      # (1000:1000) passwd/group entry — wiring the two together is a
      # bonus hardening fix, not a base-selection change.
      User = "1000:1000";
    };

    # `mkAppUserSetup` overwrites the hardened base's own nonroot(65532)
    # passwd/group stub with this file's established "app" (1000) user
    # convention — kept as-is (not touching the ruby app-user identity),
    # `mkdir tmp; chmod 1777 tmp` is now redundant with the base's own
    # `/tmp` stub but harmless.
    extraCommands = let dockerHelpers = import ../../util/docker-helpers.nix; in ''
      mkdir -p tmp
      chmod 1777 tmp
      ${dockerHelpers.mkAppUserSetup}
    '';
  } // {
    closureInfo = pkgs.closureInfo {
      rootPaths = (hardened.bases.distroless-glibc.contents or []) ++ imageContents;
    };
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
  }: let
    check = import ../../types/assertions.nix;
    _ = check.nonEmptyStr "name" name;
  in {
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
  # GEM BUMP APP (Bump gem version via forge)
  # ============================================================================
  # Create an app that bumps the version in lib/*/version.rb
  #
  # srcDir: Path to the Ruby project directory
  # name: Name of the gem
  # level: patch (default), minor, or major
  #
  mkRubyGemBumpApp = {
    srcDir,
    name,
    level ? "patch",
  }: let
    check = import ../../types/assertions.nix;
    _ = check.all [
      (check.nonEmptyStr "name" name)
      (check.enum "level" [ "patch" "minor" "major" ] level)
    ];
  in {
    type = "app";
    program = toString (writeShellScript "gem-bump-${name}" ''
      set -euo pipefail
      exec ${forgeCmd} gem bump \
        --working-dir "${srcDir}" \
        --name "${name}" \
        --level "${level}"
    '');
  };

  # ============================================================================
  # GEM BUILD APP (Build .gem file via forge)
  # ============================================================================
  # Create an app that builds a .gem file from a gemspec using forge
  #
  # srcDir: Path to the Ruby project directory
  # name: Name of the gem (must match *.gemspec basename)
  #
  mkRubyGemBuildApp = {
    srcDir,
    name,
  }: {
    type = "app";
    program = toString (writeShellScript "gem-build-${name}" ''
      set -euo pipefail
      exec ${forgeCmd} gem build \
        --working-dir "${srcDir}" \
        --name "${name}"
    '');
  };

  # ============================================================================
  # GEM PUSH APP (Build and push gem to RubyGems.org via forge)
  # ============================================================================
  # Create an app that builds and pushes a gem using forge
  #
  # srcDir: Path to the Ruby project directory
  # name: Name of the gem (must match *.gemspec basename)
  #
  mkRubyGemPushApp = {
    srcDir,
    name,
  }: {
    type = "app";
    program = toString (writeShellScript "gem-push-${name}" ''
      set -euo pipefail
      exec ${forgeCmd} gem push \
        --working-dir "${srcDir}" \
        --name "${name}"
    '');
  };

  # ============================================================================
  # GEM TEST APP (Run tests via forge)
  # ============================================================================
  # Create an app that runs the gem's test suite
  #
  # srcDir: Path to the Ruby project directory
  # name: Name of the gem
  #
  mkRubyGemTestApp = {
    srcDir,
    name,
  }: {
    type = "app";
    program = toString (writeShellScript "test-${name}" ''
      set -euo pipefail
      exec ${forgeCmd} gem test \
        --working-dir "${srcDir}" \
        --name "${name}"
    '');
  };

  # ============================================================================
  # GEM SDLC APPS (Full regen/build/push/release set for gems)
  # ============================================================================
  # Create the complete app set for a Ruby gem library
  #
  # srcDir: Path to the Ruby project directory
  # name: Name of the gem
  #
  mkRubyGemApps = {
    srcDir,
    name,
  }: let
    check = import ../../types/assertions.nix;
    _ = check.nonEmptyStr "name" name;
  in {
    test = mkRubyGemTestApp { inherit srcDir name; };
    regen = mkRubyRegenApp { inherit srcDir name; };
    "gem:bump" = mkRubyGemBumpApp { inherit srcDir name; };
    "gem:build" = mkRubyGemBuildApp { inherit srcDir name; };
    "gem:push" = mkRubyGemPushApp { inherit srcDir name; };
    "gem:release" = {
      type = "app";
      program = toString (writeShellScript "gem-release-${name}" ''
        set -euo pipefail
        echo "Releasing gem ${name}..."
        echo ""

        # Regen to ensure gemset.nix is up to date
        nix run .#regen
        echo ""

        # Build and push via forge
        nix run .#gem:push
        echo ""

        echo "Gem release complete!"
      '');
    };
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
  }: let
    check = import ../../types/assertions.nix;
    _ = check.all [
      (check.nonEmptyStr "name" name)
      (check.nonEmptyStr "registry" registry)
    ];
  in {
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
