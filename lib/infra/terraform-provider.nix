# Terraform Provider Builder
#
# Wraps buildGoModule with Terraform provider conventions:
# version injection, registry metadata, and local dev installation.
#
# Usage:
#   provider = import "${substrate}/lib/terraform-provider.nix" pkgs {
#     pname = "terraform-provider-akeyless-gen";
#     version = "0.1.0";
#     src = ./.;
#     vendorHash = null;
#     registryOwner = "pleme-io";
#     registryName = "akeyless-gen";
#   };
#
# Returns:
#   { package, devShell, apps }
#   - package: the provider binary
#   - devShell: dev shell with go, terraform, gopls
#   - apps: { build, install, generate, test }
{
  # Build a Terraform provider from Go source.
  mkTerraformProvider = pkgs: {
    pname,
    version,
    src,
    vendorHash ? null,
    registryOwner,
    registryName,
    ldflags ? [
      "-s" "-w"
      "-X main.version=${version}"
    ],
    doCheck ? false,
    extraBuildInputs ? [],
    description ? "${pname} — Terraform provider",
    homepage ? null,
    license ? pkgs.lib.licenses.mit,
    # Path to terraform-forge-cli binary (optional, for generate app)
    terraformForgeCli ? null,
    # Paths for generate command
    specPath ? null,
    resourcesPath ? null,
    providerToml ? null,
  }: let
    lib = pkgs.lib;

    package = pkgs.buildGoModule {
      inherit pname version src vendorHash doCheck ldflags;
      nativeBuildInputs = extraBuildInputs;
      meta = {
        inherit description license;
        mainProgram = pname;
      } // lib.optionalAttrs (homepage != null) { inherit homepage; };
    };

    system = pkgs.stdenv.hostPlatform.system;
    goOs = if lib.hasPrefix "x86_64-linux" system then "linux"
           else if lib.hasPrefix "aarch64-linux" system then "linux"
           else if lib.hasPrefix "x86_64-darwin" system then "darwin"
           else if lib.hasPrefix "aarch64-darwin" system then "darwin"
           else "unknown";
    goArch = if lib.hasPrefix "x86_64" system then "amd64"
             else if lib.hasPrefix "aarch64" system then "arm64"
             else "unknown";

    registryDir = "registry.terraform.io/${registryOwner}/${registryName}/${version}/${goOs}_${goArch}";

    installScript = pkgs.writeShellScriptBin "${pname}-install" ''
      set -euo pipefail
      PLUGIN_DIR="$HOME/.terraform.d/plugins/${registryDir}"
      mkdir -p "$PLUGIN_DIR"
      cp ${package}/bin/${pname} "$PLUGIN_DIR/"
      echo "Installed ${pname} ${version} to $PLUGIN_DIR"
    '';

    testScript = pkgs.writeShellScriptBin "${pname}-test" ''
      set -euo pipefail
      cd ${src}
      ${pkgs.go}/bin/go test ./...
    '';

  in {
    inherit package;

    devShell = pkgs.mkShellNoCC {
      packages = [
        pkgs.go
        pkgs.gopls
        pkgs.gotools
        pkgs.terraform
      ];
    };

    apps = {
      build = {
        type = "app";
        program = "${package}/bin/${pname}";
      };
      install = {
        type = "app";
        program = "${installScript}/bin/${pname}-install";
      };
      test = {
        type = "app";
        program = "${testScript}/bin/${pname}-test";
      };
    };
  };
}
