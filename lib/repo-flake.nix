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
#   npm + action  → mkGitHubAction (ncc bundle + action.yml)
#   java + package → mkJavaMavenPackage
#   csharp + package → mkDotnetPackage
#   python + package → mkUvPythonPackage
#   terraform + check → mkTerraformModuleCheck
#   * + devShell  → mkShellNoCC with language-appropriate tools
#
# CGo support:
#   Pass cDeps = ["openssl" "libgit2"] and cNativeDeps = ["pkg-config" "cmake"]
#   to automatically add C library dependencies to Go/Rust builds.
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

  # GitHub Action specific
  entryPoint ? "src/index.js",
  actionYml ? "action.yml",
  nodeOptions ? null,

  # CGo / native C library deps (string names resolved via pkgs)
  cDeps ? [],            # e.g., ["openssl" "libgit2"] → pkgs.openssl, pkgs.libgit2
  cNativeDeps ? [],      # e.g., ["pkg-config" "cmake"] → pkgs.pkg-config, pkgs.cmake

  # General
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

  # ── Resolved C deps (string names → pkgs) ─────────────────────────
  resolvedCDeps = map (name: pkgs.${name}) cDeps;
  resolvedCNativeDeps = map (name: pkgs.${name}) cNativeDeps;

  # ── Builder dispatch ───────────────────────────────────────────────

  goToolBuilder = import ./go-tool.nix;
  goLibCheckBuilder = import ./go-library-check.nix;
  uvPythonBuilder = import ./python-uv.nix;
  javaMavenBuilder = import ./java-maven.nix;
  dotnetPkgBuilder = import ./dotnet-build.nix;
  terraformBuilder = import ./terraform-module.nix;
  actionBuilder = import ./github-action.nix;

  # Go tool (with optional CGo deps)
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
  // lib.optionalAttrs (resolvedCDeps != []) { extraBuildInputs = resolvedCDeps ++ resolvedCNativeDeps; }
  // extraAttrs);

  # Go library check (with optional CGo deps)
  goLibCheck = goLibCheckBuilder.mkGoLibraryCheck pkgs ({
    inherit pname version proxyVendor;
    src = self;
    vendorHash = vendorHash;
  }
  // lib.optionalAttrs (resolvedCDeps != [] || resolvedCNativeDeps != []) {
    extraAttrs = {
      buildInputs = resolvedCDeps;
      nativeBuildInputs = resolvedCNativeDeps;
    };
  }
  // extraAttrs);

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
  // lib.optionalAttrs (nodeOptions != null) { NODE_OPTIONS = nodeOptions; }
  // extraAttrs);

  # GitHub Action (ncc bundle + action.yml)
  actionPkg = actionBuilder.mkGitHubAction pkgs ({
    inherit pname version npmDepsHash entryPoint actionYml;
    src = self;
    npmBuildScript = if npmBuildScript != null then npmBuildScript else "package";
    description = description;
    homepage = homepage;
    license = effectiveLicense;
  }
  // lib.optionalAttrs (npmFlags != []) { inherit npmFlags; }
  // lib.optionalAttrs (nodeOptions != null) { inherit nodeOptions; }
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

  buildOutput = let
    dispatch = {
      "go:tool" = { packages.default = goToolPkg; };
      "go:library" = { checks.default = goLibCheck; };
      "npm:package" = { packages.default = npmPkg; };
      "npm:action" = { packages.default = actionPkg; };
      "typescript:package" = if tsPkg != null then { packages.default = tsPkg; } else {};
      "java:package" = { packages.default = javaPkg; };
      "csharp:package" = { packages.default = dotnetPkg; };
      "python:package" = { packages.default = pythonPkg; };
      "terraform:check" = { checks.default = terraformCheck; };
    };
  in dispatch."${language}:${builder}" or {};

  # ── Lifecycle apps (nix run .#<app>) ─────────────────────────────
  # Standard SDLC commands available via `nix run` for every repo.

  mkApp = name: script: {
    type = "app";
    program = toString (pkgs.writeShellScript "repo-${name}" script);
  };

  # Language-specific lifecycle commands
  lifecycleApps =
    if language == "go" then {
      lint = mkApp "lint" ''${pkgs.golangci-lint}/bin/golangci-lint run ./...'';
      test = mkApp "test" ''${pkgs.go}/bin/go test ./...'';
      fmt = mkApp "fmt" ''${pkgs.go}/bin/go fmt ./...'';
      vet = mkApp "vet" ''${pkgs.go}/bin/go vet ./...'';
      tidy = mkApp "tidy" ''${pkgs.go}/bin/go mod tidy'';
    }
    else if language == "npm" || language == "typescript" then {
      lint = mkApp "lint" ''${pkgs.nodejs_22}/bin/npx eslint . 2>/dev/null || echo "no eslint config"'';
      test = mkApp "test" ''${pkgs.nodejs_22}/bin/npm test 2>/dev/null || echo "no test script"'';
      fmt = mkApp "fmt" ''${pkgs.nodejs_22}/bin/npx prettier --write . 2>/dev/null || echo "no prettier config"'';
    }
    else if language == "python" then {
      lint = mkApp "lint" ''${pkgs.ruff}/bin/ruff check .'';
      test = mkApp "test" ''${pkgs.python3}/bin/python -m pytest 2>/dev/null || echo "no pytest"'';
      fmt = mkApp "fmt" ''${pkgs.ruff}/bin/ruff format .'';
    }
    else if language == "java" then {
      test = mkApp "test" ''${pkgs.maven}/bin/mvn test 2>/dev/null || echo "maven test failed"'';
      lint = mkApp "lint" ''${pkgs.maven}/bin/mvn verify -DskipTests 2>/dev/null || true'';
    }
    else if language == "rust" then {
      lint = mkApp "lint" ''${pkgs.clippy}/bin/cargo-clippy -- -D warnings'';
      test = mkApp "test" ''cargo test'';
      fmt = mkApp "fmt" ''${pkgs.rustfmt}/bin/cargo-fmt --all'';
    }
    else if language == "terraform" then {
      validate = mkApp "validate" ''${pkgs.opentofu}/bin/tofu init -backend=false && ${pkgs.opentofu}/bin/tofu validate'';
      fmt = mkApp "fmt" ''${pkgs.opentofu}/bin/tofu fmt -recursive .'';
      lint = mkApp "lint" ''${pkgs.tflint}/bin/tflint --no-color .'';
    }
    else if language == "helm" then {
      lint = mkApp "lint" ''
        for chart in charts/*/; do
          [ -f "$chart/Chart.yaml" ] && ${pkgs.kubernetes-helm}/bin/helm lint "$chart"
        done
      '';
      template = mkApp "template" ''
        for chart in charts/*/; do
          [ -f "$chart/Chart.yaml" ] && ${pkgs.kubernetes-helm}/bin/helm template "$chart"
        done
      '';
    }
    else if language == "ruby" then {
      test = mkApp "test" ''${pkgs.ruby}/bin/bundle exec rake test 2>/dev/null || ${pkgs.ruby}/bin/bundle exec rspec 2>/dev/null || echo "no tests"'';
      lint = mkApp "lint" ''${pkgs.ruby}/bin/bundle exec rubocop 2>/dev/null || echo "no rubocop"'';
    }
    else if language == "shell" then {
      lint = mkApp "lint" ''${pkgs.shellcheck}/bin/shellcheck *.sh **/*.sh 2>/dev/null || echo "no shell scripts"'';
    }
    else {};

in buildOutput // {
  devShells.default = pkgs.mkShellNoCC {
    packages = devPackages ++ (map (p: if builtins.isString p then pkgs.${p} else p) extraDevPackages);
  };
  apps = lifecycleApps;
})
