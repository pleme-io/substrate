# Universal Repo Flake Builder
#
# Single abstraction for all repo types: Go tools, Go libraries, npm packages,
# TypeScript packages, Java/Maven, .NET, Python, Terraform, Helm, Ruby, PHP,
# and devShell-only repos. Eliminates boilerplate across consumer flakes.
#
# Usage in a flake.nix:
#   outputs = inputs: (import "${inputs.substrate}/lib/repo-flake.nix" {
#     inherit (inputs) nixpkgs flake-utils;
#   }) {
#     self = inputs.self;
#     language = "go";
#     builder = "tool";
#     pname = "k8s-auth-validator";
#     vendorHash = "sha256-PJ6MrKN0SmSHQRdfiaKW0jDgXqCvc58ITzUTLlr4tYY=";
#     description = "Akeyless K8s auth config validator";
#   };
#
# Builder types:
#   "tool"      — CLI tool (packages.default + devShell)
#   "library"   — library check (checks.default + devShell)
#   "package"   — installable package (packages.default + devShell)
#   "check"     — validation check (checks.default + devShell)
#   "devShell"  — development shell only
#
# Language → builder mapping determines which substrate builder to use:
#   go + tool     → mkGoTool
#   go + library  → mkGoLibraryCheck
#   typescript + package → mkTypescriptPackage (via pleme-linker)
#   npm + package → buildNpmPackage
#   java + package → mkJavaMavenPackage
#   csharp + package → mkDotnetPackage
#   python + package → mkPythonPackage
#   terraform + check → mkTerraformModuleCheck
#   * + devShell  → mkShellNoCC with language-appropriate tools
{
  nixpkgs,
  flake-utils,
}:
{
  self,
  language,
  builder ? "devShell",
  pname ? null,
  version ? "0.0.0-dev",
  description ? "",
  homepage ? null,
  license ? null,

  # Go-specific
  vendorHash ? null,
  proxyVendor ? false,
  subPackages ? null,
  tags ? [],
  ldflags ? null,
  versionLdflags ? {},

  # npm-specific
  npmDepsHash ? null,
  npmFlags ? [],
  dontNpmBuild ? true,
  npmBuildScript ? null,
  sourceRoot ? null,

  # TypeScript/pleme-linker specific
  plemeLinker ? null,
  cliEntry ? null,
  binName ? null,

  # Java-specific
  mvnHash ? null,
  jdk ? null,
  mvnParameters ? null,

  # .NET-specific
  nugetDeps ? null,
  projectFile ? null,

  # Python-specific
  propagatedBuildInputs ? null,
  pythonImportsCheck ? null,

  # Terraform-specific
  moduleDir ? ".",

  # General
  extraBuildInputs ? [],
  extraNativeBuildInputs ? [],
  extraDevPackages ? [],
  extraAttrs ? {},
}:
flake-utils.lib.eachDefaultSystem (system: let
  pkgs = import nixpkgs { inherit system; };
  lib = pkgs.lib;

  # ── Language-specific dev shell packages ───────────────────────────
  devPackages = {
    go = with pkgs; [ go gopls gotools ];
    typescript = with pkgs; [ nodejs_22 ];
    npm = with pkgs; [ nodejs_22 ];
    java = with pkgs; [ (if jdk != null then jdk else jdk17) maven ];
    csharp = with pkgs; [ dotnet-sdk_8 ];
    python = with pkgs; [ python3 uv ];
    ruby = with pkgs; [ ruby bundler ];
    php = with pkgs; [ php83 php83Packages.composer ];
    rust = with pkgs; [ cargo rustc rustfmt clippy ];
    terraform = with pkgs; [ opentofu tflint terraform-docs ];
    helm = with pkgs; [ kubernetes-helm kubectl ];
    c = with pkgs; [ gcc gnumake autoconf automake pkg-config ];
    shell = with pkgs; [ shellcheck bash ];
    nushell = with pkgs; [ nushell python3 ];
    docker = with pkgs; [ docker ];
    kustomize = with pkgs; [ kubectl kustomize ];
    hugo = with pkgs; [ hugo go nodejs_22 ];
    docs = with pkgs; [ nodejs_22 ];
  }.${language} or (with pkgs; [ ]);

  effectiveLicense =
    if license != null then license
    else {
      go = lib.licenses.asl20;
      typescript = lib.licenses.mit;
      npm = lib.licenses.mit;
      java = lib.licenses.asl20;
      csharp = lib.licenses.asl20;
      python = lib.licenses.asl20;
      ruby = lib.licenses.mit;
      terraform = lib.licenses.mpl20;
    }.${language} or lib.licenses.asl20;

  meta = {
    inherit description;
    license = effectiveLicense;
    platforms = lib.platforms.all;
  } // lib.optionalAttrs (homepage != null) { inherit homepage; };

  # ── Builder dispatch ───────────────────────────────────────────────

  goToolBuilder = import ./go-tool.nix;
  goLibCheckBuilder = import ./go-library-check.nix;
  pythonPkgBuilder = import ./python-package.nix;
  uvPythonBuilder = import ./python-uv.nix;
  javaMavenBuilder = import ./java-maven.nix;
  dotnetPkgBuilder = import ./dotnet-build.nix;
  terraformBuilder = import ./terraform-module.nix;

  # Go tool
  goToolPkg = goToolBuilder.mkGoTool pkgs ({
    inherit pname version proxyVendor tags;
    src = self;
    vendorHash = vendorHash;
    description = description;
    homepage = homepage;
    license = effectiveLicense;
  }
  // lib.optionalAttrs (subPackages != null) { inherit subPackages; }
  // lib.optionalAttrs (ldflags != null) { inherit ldflags; }
  // lib.optionalAttrs (versionLdflags != {}) { inherit versionLdflags; }
  // extraAttrs);

  # Go library check
  goLibCheck = goLibCheckBuilder.mkGoLibraryCheck pkgs ({
    inherit pname version proxyVendor;
    src = self;
    vendorHash = vendorHash;
  } // extraAttrs);

  # npm package
  npmPkg = pkgs.buildNpmPackage ({
    inherit pname version;
    src = self;
    npmDepsHash = npmDepsHash;
    inherit dontNpmBuild;
    inherit meta;
  }
  // lib.optionalAttrs (npmFlags != []) { inherit npmFlags; }
  // lib.optionalAttrs (npmBuildScript != null) { npmBuildScript = npmBuildScript; }
  // lib.optionalAttrs (sourceRoot != null) { inherit sourceRoot; }
  // extraAttrs);

  # TypeScript package via pleme-linker
  tsPkg = let
    substrateLib = (import ./default.nix { inherit pkgs; }).mkTypescriptPackage or null;
  in if substrateLib != null && plemeLinker != null then
    substrateLib {
      name = pname;
      src = self;
      plemeLinker = plemeLinker.packages.${system}.default;
    }
  else null;

  # Java Maven package
  javaPkg = javaMavenBuilder.mkJavaMavenPackage pkgs ({
    inherit pname version;
    src = self;
    mvnHash = if mvnHash != null then mvnHash else "";
    description = description;
    homepage = homepage;
    license = effectiveLicense;
  }
  // lib.optionalAttrs (jdk != null) { inherit jdk; }
  // lib.optionalAttrs (mvnParameters != null) { inherit mvnParameters; }
  // extraAttrs);

  # .NET package
  dotnetPkg = dotnetPkgBuilder.mkDotnetPackage pkgs ({
    inherit pname version;
    src = self;
    nugetDeps = if nugetDeps != null then nugetDeps else ./deps.json;
    description = description;
    homepage = homepage;
    license = effectiveLicense;
  }
  // lib.optionalAttrs (projectFile != null) { inherit projectFile; }
  // extraAttrs);

  # Python package (UV-based pyproject.toml builder — default)
  pythonPkg = uvPythonBuilder.mkUvPythonPackage pkgs ({
    inherit pname version;
    src = self;
    description = description;
    homepage = homepage;
    license = effectiveLicense;
  }
  // lib.optionalAttrs (propagatedBuildInputs != null) {
    propagatedBuildInputs = map (name: pkgs.python3Packages.${name}) propagatedBuildInputs;
  }
  // lib.optionalAttrs (pythonImportsCheck != null) { inherit pythonImportsCheck; }
  // extraAttrs);

  # Terraform module check
  terraformCheck = terraformBuilder.mkTerraformModuleCheck pkgs ({
    inherit pname version moduleDir;
    src = self;
    description = description;
    homepage = homepage;
    license = effectiveLicense;
  } // extraAttrs);

  # ── Output assembly ────────────────────────────────────────────────

  buildOutput =
    if builder == "devShell" then {}
    else if language == "go" && builder == "tool" then { packages.default = goToolPkg; }
    else if language == "go" && builder == "library" then { checks.default = goLibCheck; }
    else if language == "npm" && builder == "package" then { packages.default = npmPkg; }
    else if language == "typescript" && builder == "package" && tsPkg != null then { packages.default = tsPkg; }
    else if language == "java" && builder == "package" then { packages.default = javaPkg; }
    else if language == "csharp" && builder == "package" then { packages.default = dotnetPkg; }
    else if language == "python" && builder == "package" then { packages.default = pythonPkg; }
    else if language == "terraform" && builder == "check" then { checks.default = terraformCheck; }
    else {};

in buildOutput // {
  devShells.default = pkgs.mkShellNoCC {
    packages = devPackages ++ extraDevPackages;
  };
})
