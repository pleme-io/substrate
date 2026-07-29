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
let
  check = import ../types/assertions.nix;
  validLanguages = [ "go" "typescript" "npm" "java" "csharp" "python" "ruby" "php" "rust" "terraform" "helm" "c" "shell" "nushell" "docker" "kustomize" "hugo" "docs" ];
  validBuilders = [ "tool" "library" "package" "check" "devShell" ];
  _lang = check.enum "language" validLanguages language;
  _builder = check.enum "builder" validBuilders builder;
  _version = check.str "version" version;
  _desc = check.str "description" description;
  _tags = check.list "tags" tags;
  _npmFlags = check.list "npmFlags" npmFlags;
  _cDeps = check.list "cDeps" cDeps;
  _cNativeDeps = check.list "cNativeDeps" cNativeDeps;
  _extraDevPackages = check.list "extraDevPackages" extraDevPackages;
  _extraAttrs = check.attrs "extraAttrs" extraAttrs;
  _versionLdflags = check.attrs "versionLdflags" versionLdflags;
  _pnameCheck = assert (builder == "devShell" || pname != null)
    || throw "repo-flake: 'pname' is required when builder is '${builder}' (not devShell)"; true;
in
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

  goToolBuilder = import ../build/go/tool.nix;
  goLibCheckBuilder = import ../build/go/library-check.nix;
  uvPythonBuilder = import ../build/python/uv.nix;
  javaMavenBuilder = import ../build/java/maven.nix;
  dotnetPkgBuilder = import ../build/dotnet/build.nix;
  terraformBuilder = import ../infra/terraform-module.nix;
  actionBuilder = import ../build/web/github-action.nix;

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
    substrateLib = (import ../default.nix { inherit pkgs; }).mkTypescriptPackage or null;
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

  # ★ A SKIP IS NOT A PASS, AND A FAILURE IS NOT A SKIP.
  #
  # Eight of these apps used to be written as
  #
  #     npx eslint . 2>/dev/null || echo "no eslint config"
  #
  # which reports the SAME green exit for two states that could not be
  # more different: "this repo has no linter configured" and "the linter
  # ran and found violations". The `2>/dev/null` then throws away the
  # diagnostic that would have told them apart, so `nix run .#lint` on a
  # repo full of real lint errors printed a reassuring sentence and exited
  # 0. That is a verdict computed and discarded — ★★ UNREPRESENTABILITY
  # §II.3 tier ⊥, "discarded" subclass — and it is invisible in a log,
  # because the log looks exactly like the healthy case.
  #
  # `set -euo pipefail` is on every app for the same reason: without it a
  # bare failing command mid-script is silently stepped over.
  mkApp = name: script: {
    type = "app";
    program = toString (pkgs.writeShellScript "repo-${name}" ''
      set -euo pipefail
      ${script}
    '');
  };

  # Decide PRESENCE first, from an explicit subject test — then run the
  # tool BARE so its exit status is the verdict. An absent subject is a
  # NAMED skip that says what would have made it run; it is never
  # confused with a clean pass, and a real failure is never confused
  # with an absent subject.
  guarded =
    {
      subject,
      hint,
      cmd,
    }:
    ''
      if ${subject}; then
        ${cmd}
      else
        echo "skip: ${hint} — nothing to check, and this is NOT a pass"
      fi
    '';

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
      lint = mkApp "lint" (guarded {
        subject = ''ls eslint.config.* .eslintrc* >/dev/null 2>&1'';
        hint = "no eslint config (eslint.config.* / .eslintrc*)";
        cmd = ''${pkgs.nodejs_22}/bin/npx eslint .'';
      });
      test = mkApp "test" (guarded {
        # `npm test` on a package with no `scripts.test` exits non-zero,
        # which the old `|| echo` shape could not tell from a failing
        # suite. Ask package.json directly instead.
        subject = ''${pkgs.nodejs_22}/bin/node -e 'process.exit(require("./package.json").scripts?.test?0:1)' '';
        hint = "package.json declares no scripts.test";
        cmd = ''${pkgs.nodejs_22}/bin/npm test'';
      });
      fmt = mkApp "fmt" (guarded {
        subject = ''ls .prettierrc* prettier.config.* >/dev/null 2>&1'';
        hint = "no prettier config (.prettierrc* / prettier.config.*)";
        cmd = ''${pkgs.nodejs_22}/bin/npx prettier --write .'';
      });
    }
    else if language == "python" then {
      lint = mkApp "lint" ''${pkgs.ruff}/bin/ruff check .'';
      test = mkApp "test" (guarded {
        subject = ''[ -d tests ] || [ -d test ] || [ -f pytest.ini ] || [ -f tox.ini ] || [ -f setup.cfg ] || [ -f pyproject.toml ]'';
        hint = "no pytest subject (tests/ | test/ | pytest.ini | tox.ini | setup.cfg | pyproject.toml)";
        cmd = ''${pkgs.python3}/bin/python -m pytest'';
      });
      fmt = mkApp "fmt" ''${pkgs.ruff}/bin/ruff format .'';
    }
    else if language == "java" then {
      test = mkApp "test" (guarded {
        subject = ''[ -f pom.xml ]'';
        hint = "no pom.xml";
        cmd = ''${pkgs.maven}/bin/mvn test'';
      });
      lint = mkApp "lint" (guarded {
        subject = ''[ -f pom.xml ]'';
        hint = "no pom.xml";
        cmd = ''${pkgs.maven}/bin/mvn verify -DskipTests'';
      });
    }
    else if language == "rust" then {
      lint = mkApp "lint" ''${pkgs.clippy}/bin/cargo-clippy --check -- -D warnings'';
      test = mkApp "test" ''cargo test'';
      fmt = mkApp "fmt" ''${pkgs.rustfmt}/bin/cargo-fmt --all'';
    }
    else if language == "terraform" then {
      validate = mkApp "validate" ''${pkgs.opentofu}/bin/tofu init -backend=false && ${pkgs.opentofu}/bin/tofu validate'';
      fmt = mkApp "fmt" ''${pkgs.opentofu}/bin/tofu fmt -recursive .'';
      lint = mkApp "lint" ''${pkgs.tflint}/bin/tflint --no-color .'';
    }
    else if language == "helm" then {
      # ★ The old loop body was `[ -f "$chart/Chart.yaml" ] && helm lint
      # "$chart"`, and its bug was NOT the one it looks like. `helm lint`
      # was the last command in the loop, so a SINGLE failing chart did
      # propagate exit 1. What it discarded was every failure that had a
      # passing chart after it: with `charts/a-bad` broken and
      # `charts/z-good` fine, the loop printed "1 chart(s) failed" for
      # a-bad, carried on, and exited 0 with z-good's status. Measured
      # 2026-07-28 — OLD EXIT=0, NEW EXIT=1 on that exact pair. So the
      # verdict was computed, printed, and then overwritten by the next
      # iteration (★★ UNREPRESENTABILITY §II.3 tier ⊥, "discarded").
      #
      # It also had the opposite defect: with no `nullglob`, an empty
      # `charts/` left the literal `charts/*/`, the `[ -f ]` failed, and
      # the loop exited 1 — a SPURIOUS RED over zero subjects, which
      # trains an operator to ignore the app. Counting the subjects fixes
      # both directions at once.
      #
      # Aggregate-before-assert: every chart is linted, every failure is
      # named, then the app fails once — so one run reports all broken
      # charts rather than only the first.
      lint = mkApp "lint" ''
        found=0
        failed=0
        for chart in charts/*/; do
          [ -f "$chart/Chart.yaml" ] || continue
          found=$((found + 1))
          ${pkgs.kubernetes-helm}/bin/helm lint "$chart" || { echo "FAIL: $chart"; failed=$((failed + 1)); }
        done
        if [ "$found" -eq 0 ]; then
          echo "skip: no charts/*/Chart.yaml — nothing to lint, and this is NOT a pass"
        elif [ "$failed" -gt 0 ]; then
          echo "$failed of $found chart(s) FAILED lint"
          exit 1
        else
          echo "$found/$found chart(s) linted clean"
        fi
      '';
      template = mkApp "template" ''
        found=0
        failed=0
        for chart in charts/*/; do
          [ -f "$chart/Chart.yaml" ] || continue
          found=$((found + 1))
          ${pkgs.kubernetes-helm}/bin/helm template "$chart" || { echo "FAIL: $chart"; failed=$((failed + 1)); }
        done
        if [ "$found" -eq 0 ]; then
          echo "skip: no charts/*/Chart.yaml — nothing to template, and this is NOT a pass"
        elif [ "$failed" -gt 0 ]; then
          echo "$failed of $found chart(s) FAILED to template"
          exit 1
        else
          echo "$found/$found chart(s) templated"
        fi
      '';
    }
    else if language == "ruby" then {
      # The old chain was `rake test || rspec || echo "no tests"`, so a
      # FAILING rake suite silently fell through to rspec, and a failing
      # rspec fell through to a green echo. Select the runner from what
      # the repo actually ships, then let it decide.
      test = mkApp "test" (guarded {
        subject = ''[ -f Rakefile ] || [ -d spec ]'';
        hint = "no Rakefile and no spec/";
        cmd = ''
          if [ -d spec ]; then
            ${pkgs.ruby}/bin/bundle exec rspec
          else
            ${pkgs.ruby}/bin/bundle exec rake test
          fi
        '';
      });
      lint = mkApp "lint" (guarded {
        subject = ''ls .rubocop.yml .rubocop.yaml >/dev/null 2>&1'';
        hint = "no .rubocop.yml";
        cmd = ''${pkgs.ruby}/bin/bundle exec rubocop'';
      });
    }
    else if language == "shell" then {
      lint = mkApp "lint" ''
        shopt -s nullglob globstar
        # `**/*.sh` under globstar already matches zero-or-more leading
        # directories, so it covers top-level `*.sh` too. Listing both
        # globs (as this did) hands shellcheck every top-level script
        # TWICE and prints every finding twice.
        scripts=(**/*.sh)
        if [ "''${#scripts[@]}" -eq 0 ]; then
          echo "skip: no *.sh files — nothing to lint, and this is NOT a pass"
        else
          ${pkgs.shellcheck}/bin/shellcheck "''${scripts[@]}"
        fi
      '';
    }
    else {};

in buildOutput // {
  devShells.default = pkgs.mkShellNoCC {
    packages = devPackages ++ (map (p: if builtins.isString p then pkgs.${p} else p) extraDevPackages);
  };
  apps = lifecycleApps;
})
