# ============================================================================
# RUBY GEM SCAFFOLD — Generate a complete Ruby gem or Pangea provider
# ============================================================================
# Creates the full project structure for a new Ruby gem with optional
# RSpec testing, RuboCop linting, and Pangea IaC provider integration.
#
# This implements the convergence computing principle: declare the desired
# state (gem specification), and the scaffold converges it into existence.
#
# Usage:
#   scaffold = import "${substrate}/lib/build/ruby/ruby-gem-scaffold.nix" { inherit lib; };
#   files = scaffold.generate ({
#     name = "my-gem";
#   } // scaffold.templates.library);
{ lib }:

{
  # ========================================================================
  # generate — Produce the complete file tree for a new Ruby gem
  # ========================================================================
  generate = {
    name,
    description ? "A pleme-io Ruby gem",
    features ? [ "rspec" "rubocop" ],
    version ? "0.1.0",
    author ? "pleme-io",
    repo ? "pleme-io/${name}",
  }: let
    hasFeature = f: builtins.elem f features;
    gemName = name;
    # Convert kebab-case to snake_case for Ruby module paths
    snakeName = builtins.replaceStrings ["-"] ["_"] name;
    # Convert to PascalCase for Ruby module name
    pascalName = lib.concatMapStrings (s:
      let first = builtins.substring 0 1 s;
          rest = builtins.substring 1 (builtins.stringLength s) s;
      in (lib.toUpper first) + rest
    ) (lib.splitString "-" name);

    # ====================================================================
    # File generators
    # ====================================================================

    gemfile = ''
      source "https://rubygems.org"

      gemspec
    ''
    + lib.optionalString (hasFeature "rspec") ''

      group :test do
        gem "rspec", "~> 3.13"
      end
    ''
    + lib.optionalString (hasFeature "rubocop") ''

      group :development do
        gem "rubocop", "~> 1.68"
      end
    '';

    gemspec = ''
      Gem::Specification.new do |spec|
        spec.name          = "${gemName}"
        spec.version       = ${pascalName}::VERSION
        spec.authors       = ["${author}"]
        spec.summary       = "${description}"
        spec.homepage      = "https://github.com/${repo}"
        spec.license       = "MIT"

        spec.required_ruby_version = ">= 3.2.0"
        spec.files = Dir["lib/**/*", "LICENSE", "README.md"]
        spec.require_paths = ["lib"]
    ''
    + lib.optionalString (hasFeature "pangea") ''

        spec.add_dependency "pangea-core", "~> 0.1"
        spec.add_dependency "dry-struct", "~> 1.6"
        spec.add_dependency "dry-types", "~> 1.7"
    ''
    + ''
      end
    '';

    flakeNix = ''
      {
        inputs = {
          nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
          ruby-nix.url = "github:inscapist/ruby-nix";
          flake-utils.url = "github:numtide/flake-utils";
          substrate = {
            url = "github:pleme-io/substrate";
            inputs.nixpkgs.follows = "nixpkgs";
          };
        };

        outputs = { self, nixpkgs, ruby-nix, flake-utils, substrate, ... }:
          (import "''${substrate}/lib/build/ruby/gem-flake.nix" {
            inherit nixpkgs ruby-nix flake-utils substrate;
          }) {
            inherit self;
            name = "${gemName}";
          };
      }
    '';

    mainRb = ''
      require_relative "${snakeName}/version"

      module ${pascalName}
      end
    '';

    versionRb = ''
      module ${pascalName}
        VERSION = "${version}"
      end
    '';

    specHelper = ''
      require "${snakeName}"

      RSpec.configure do |config|
        config.expect_with :rspec do |expectations|
          expectations.include_chain_clauses_in_custom_matcher_descriptions = true
        end
        config.mock_with :rspec do |mocks|
          mocks.verify_partial_doubles = true
        end
        config.shared_context_metadata_behavior = :apply_to_host_groups
      end
    '';

    mainSpec = ''
      require "spec_helper"

      RSpec.describe ${pascalName} do
        it "has a version number" do
          expect(${pascalName}::VERSION).not_to be_nil
        end
      end
    '';

    rubocopYml = ''
      AllCops:
        TargetRubyVersion: 3.2
        NewCops: enable
        SuggestExtensions: false

      Style/Documentation:
        Enabled: false

      Metrics/BlockLength:
        Exclude:
          - "spec/**/*"
    '';

    gitignore = ''
      *.gem
      .bundle/
      Gemfile.lock
      pkg/
      tmp/
      .DS_Store
    '';

  in {
    files = {
      "Gemfile" = gemfile;
      "${gemName}.gemspec" = gemspec;
      "flake.nix" = flakeNix;
      ".gitignore" = gitignore;
      "LICENSE" = "MIT License\n\nCopyright (c) 2026 pleme-io\n";
      "lib/${snakeName}.rb" = mainRb;
      "lib/${snakeName}/version.rb" = versionRb;
    }
    // lib.optionalAttrs (hasFeature "rspec") {
      "spec/spec_helper.rb" = specHelper;
      "spec/${snakeName}_spec.rb" = mainSpec;
    }
    // lib.optionalAttrs (hasFeature "rubocop") {
      ".rubocop.yml" = rubocopYml;
    };

    meta = {
      inherit name description version author repo features;
      moduleName = pascalName;
    };

    deployment = {
      inherit name version;
      type = "ruby-gem";
      registry = "rubygems.org";
    };
  };

  # ========================================================================
  # Predefined gem templates
  # ========================================================================

  templates = {
    library = {
      features = [ "rspec" "rubocop" ];
    };

    pangea = {
      features = [ "rspec" "rubocop" "pangea" ];
    };
  };
}
