# Complete multi-system flake outputs for a pleme-io GitHub Action whose
# behavior is implemented as a Go binary.
#
# Wraps `tool-release-flake.nix` (Go) with two extra outputs:
#   1. `packages.<system>.action-yml` — the rendered action.yml as a Nix
#      package (a single-file derivation). Consumers can `nix build .#action-yml`
#      then `cp result/action.yml .` to materialize the file at the repo root,
#      or wire it as a release-workflow step.
#   2. `apps.<system>.write-action-yml` — an app that writes the rendered
#      action.yml directly to `./action.yml` in the consumer's repo, so a
#      developer can `nix run .#write-action-yml` to refresh the file after
#      editing the typed declaration.
#
# Composite action.yml hoists every `${{ inputs.<name> }}` to env: per the
# `yaml.github-actions.security.run-shell-injection` rule. The binary reads
# inputs via the INPUT_<UPPER_NAME> env vars.
#
# The action-yml renderer is shared with the Rust action flake — see
# ../rust/action-yml-render.nix (language-agnostic: it only needs toolName +
# the typed action attrset + lib).
#
# Usage in a consumer flake:
#
#   outputs = { self, nixpkgs, flake-utils, substrate, ... }:
#     (import "${substrate}/lib/build/go/action-release-flake.nix" {
#       inherit nixpkgs;
#     }) {
#       toolName = "terragrunt-apply";
#       src = self;
#       repo = "pleme-io/terragrunt-apply";
#       vendorHash = "sha256-...";
#       action = {
#         description = "Run terragrunt plan/apply/destroy with typed inputs";
#         inputs = [
#           { name = "working-directory"; description = "Leaf directory"; required = true; }
#           { name = "action"; description = "plan / apply / destroy"; default = "plan"; }
#         ];
#         outputs = [
#           { name = "plan-summary"; description = "Plan additions/changes/destroys count"; }
#         ];
#       };
#     };
{
  nixpkgs,
  forge ? null,
}:
{
  toolName,
  action,
  systems ? ["aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux"],
  ...
} @ args:
let
  toolReleaseFlake = import ./tool-release-flake.nix {
    inherit nixpkgs;
  };

  # Forward all go-tool args (toolName, src, repo, vendorHash, etc.) but strip
  # the `action` attr — that's our extension, not consumed by tool-release.
  toolFlake = toolReleaseFlake (builtins.removeAttrs args [ "action" ]);

  renderActionYml = system: let
    pkgs = import nixpkgs { inherit system; };
    rendered = import ../rust/action-yml-render.nix {
      inherit toolName action;
      inherit (pkgs) lib;
    };
  in rendered;

  mkActionYmlPackage = system: let
    pkgs = import nixpkgs { inherit system; };
    rendered = renderActionYml system;
  in pkgs.runCommand "${toolName}-action-yml" { } ''
    mkdir -p $out
    cat > $out/action.yml <<'EOF'
${rendered}EOF
  '';

  mkWriteActionYmlApp = system: let
    pkgs = import nixpkgs { inherit system; };
    rendered = renderActionYml system;
    script = pkgs.writeShellScriptBin "write-action-yml" ''
      set -euo pipefail
      target="$PWD/action.yml"
      cat > "$target" <<'EOF'
${rendered}EOF
      echo "wrote $target"
    '';
  in {
    type = "app";
    program = "${script}/bin/write-action-yml";
  };

  perSystemExtras = system: {
    "action-yml" = mkActionYmlPackage system;
  };

  perSystemAppExtras = system: {
    "write-action-yml" = mkWriteActionYmlApp system;
  };

  # Attach the action-yml package + write-action-yml app to every system's
  # outputs.
  withActionYml = flake: flake // {
    packages = flake.packages // (builtins.listToAttrs (map (system:
      { name = system; value = (flake.packages.${system} or {}) // (perSystemExtras system); }
    ) systems));
    apps = (flake.apps or {}) // (builtins.listToAttrs (map (system:
      { name = system; value = ((flake.apps.${system} or {})) // (perSystemAppExtras system); }
    ) systems));
  };
in
  withActionYml toolFlake
