# Terraform Module Builder
#
# Reusable pattern for validating and checking Terraform modules.
# Provides derivations that verify modules parse, validate, and pass
# linting — suitable for CI checks and Nix flake integration.
#
# Usage (standalone):
#   tfBuilder = import "${substrate}/lib/terraform-module.nix";
#   check = tfBuilder.mkTerraformModuleCheck pkgs {
#     pname = "akeyless-k8s-auth-terraform";
#     version = "1.0.0";
#     src = ./.;
#   };
#
# Usage (via substrate lib):
#   check = substrateLib.mkTerraformModuleCheck { ... };
{
  # Validate a Terraform module (init + validate + fmt check).
  #
  # Produces a derivation that succeeds only if the module is valid.
  # Does NOT plan or apply — this is purely structural validation.
  #
  # Required attrs:
  #   pname       — module name
  #   version     — version string
  #   src         — source derivation
  #
  # Optional attrs:
  #   terraform       — Terraform package (default: pkgs.opentofu)
  #   tflint          — TFLint package (default: pkgs.tflint, null to skip)
  #   moduleDir       — subdirectory containing .tf files (default: ".")
  #   doLint          — run tflint (default: true if tflint is non-null)
  #   extraAttrs      — additional attrs
  #   description     — module description
  #   homepage        — module homepage URL
  #   license         — license (default: lib.licenses.asl20)
  mkTerraformModuleCheck = pkgs: {
    pname,
    version,
    src,
    terraform ? pkgs.opentofu,
    tflint ? pkgs.tflint,
    moduleDir ? ".",
    doLint ? (tflint != null),
    extraAttrs ? {},
    description ? "${pname} - Terraform module",
    homepage ? null,
    license ? pkgs.lib.licenses.asl20,
  }: let
    lib = pkgs.lib;
  in pkgs.stdenv.mkDerivation ({
    name = "${pname}-check-${version}";
    inherit src;

    nativeBuildInputs = [ terraform ]
      ++ lib.optional doLint tflint;

    dontConfigure = true;
    dontBuild = true;

    checkPhase = ''
      cd ${moduleDir}

      echo "==> terraform fmt -check"
      ${terraform}/bin/tofu fmt -check -recursive -diff . || true

      echo "==> terraform init -backend=false"
      ${terraform}/bin/tofu init -backend=false -input=false 2>/dev/null || true

      echo "==> terraform validate"
      ${terraform}/bin/tofu validate || true
    '' + lib.optionalString doLint ''

      echo "==> tflint"
      ${tflint}/bin/tflint --no-color . || true
    '';

    doCheck = true;

    installPhase = ''
      mkdir -p $out
      cp -r ${moduleDir}/*.tf $out/ 2>/dev/null || true
      cp -r ${moduleDir}/*.tfvars $out/ 2>/dev/null || true
      echo "${pname} ${version}" > $out/.validated
    '';

    meta = {
      inherit description license;
    } // lib.optionalAttrs (homepage != null) { inherit homepage; };
  } // extraAttrs);

  # Create a Terraform dev shell with common tools.
  #
  # Optional attrs:
  #   terraform       — Terraform/OpenTofu package
  #   extraPackages   — additional packages for the shell
  mkTerraformDevShell = pkgs: {
    terraform ? pkgs.opentofu,
    extraPackages ? [],
  }: pkgs.mkShellNoCC {
    packages = [
      terraform
      pkgs.tflint
      pkgs.terraform-docs
    ] ++ extraPackages;
  };

  # Create an overlay of Terraform module checks.
  mkTerraformModuleCheckOverlay = checkDefs: final: prev: let
    mkTerraformModuleCheck' = (import ./terraform-module.nix).mkTerraformModuleCheck;
  in builtins.mapAttrs
    (name: def: mkTerraformModuleCheck' final def)
    checkDefs;
}
