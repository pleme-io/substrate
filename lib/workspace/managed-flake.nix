# Managed Flake Generator
#
# Generates a flake.nix file that can be placed at a target directory
# via home-manager activation (not symlink — real file copy).
#
# The generated flake provides workspace orchestration apps:
# gem management, flake updates, testing, git status, fleet flows.
#
# Usage in a home-manager module (e.g. blackmatter-pleme):
#
#   managedFlake = import "${substrate}/lib/workspace/managed-flake.nix" {
#     inherit lib pkgs;
#   };
#
#   home.activation.pleme-workspace = lib.hm.dag.entryAfter ["writeBoundary"] ''
#     install -m 644 ${managedFlake.generate workspace-config} ~/code/github/pleme-io/flake.nix
#   '';
#
{ lib, pkgs }:

let
  # Generate a complete flake.nix string from a workspace configuration.
  #
  # @param config.description [String] Flake description
  # @param config.nixpkgsRef [String] nixpkgs flake ref (default: "github:NixOS/nixpkgs/nixos-25.11")
  # @param config.systems [List] Target systems
  # @param config.gems [AttrSet] Gem registry: name → { version, deps }
  # @param config.flakeRepos [List] Repos with flake.nix for bulk updates
  # @param config.testRepos [AttrSet] { rspec = [...]; minitest = [...]; cargo = [...]; }
  # @param config.flows [AttrSet] Fleet flow definitions
  # @param config.extraApps [String] Additional Nix app definitions (raw Nix code)
  generate = config: pkgs.writeText "managed-flake.nix" (generateFlakeContent config);

  # Generate the raw flake.nix content string.
  generateFlakeContent = config: let
    nixpkgsRef = config.nixpkgsRef or "github:NixOS/nixpkgs/nixos-25.11";
    systems = config.systems or ["aarch64-darwin" "x86_64-linux" "aarch64-linux"];
    description = config.description or "Workspace orchestration";
    gems = config.gems or {};
    gemNames = builtins.attrNames gems;
    flakeRepos = config.flakeRepos or [];
    testRepos = config.testRepos or {};
    flows = config.flows or {};
    extraApps = config.extraApps or "";

    gemNamesStr = builtins.concatStringsSep " " gemNames;
    nonCoreGems = builtins.filter (n: n != "pangea-core") gemNames;
    nonCoreGemsStr = builtins.concatStringsSep " " nonCoreGems;
    flakeReposStr = builtins.concatStringsSep " " flakeRepos;
    rspecRepos = builtins.concatStringsSep " " (testRepos.rspec or []);
    minitestRepos = builtins.concatStringsSep " " (testRepos.minitest or []);
    cargoRepos = builtins.concatStringsSep " " (testRepos.cargo or []);
    systemsStr = builtins.concatStringsSep " " (map (s: ''"${s}"'') systems);
    flowsJson = builtins.toJSON { inherit flows; };

  in ''
    {
      description = "${description}";

      inputs = {
        nixpkgs.url = "${nixpkgsRef}";
        flake-utils.url = "github:numtide/flake-utils";
        fleet = {
          url = "github:pleme-io/fleet";
          inputs.nixpkgs.follows = "nixpkgs";
        };
      };

      outputs = { self, nixpkgs, flake-utils, fleet }:
        flake-utils.lib.eachSystem [${systemsStr}] (system:
        let
          pkgs = import nixpkgs { inherit system; };
          fleetBin = "''${fleet.packages.''${system}.default}/bin/fleet";
          ws = "$PWD";

          mkApp = name: script: {
            type = "app";
            program = toString (pkgs.writeShellScript "ws-''${name}" '''
              set -euo pipefail
              ''${script}
            ''');
          };

          fleetYaml = pkgs.writeText "workspace-fleet.yaml" (builtins.toJSON {
            flows = builtins.fromJSON '''${flowsJson}'''.flows;
          });

          mkFleetApp = flowName: mkApp "flow-''${flowName}" '''
            cd ''${ws}
            if [ ! -f fleet.yaml ]; then
              cp ''${fleetYaml} fleet.yaml
            fi
            ''${fleetBin} flow run ''${flowName} "$@"
          ''';

        in {
          apps = {
            gem-build-all = mkApp "gem-build-all" '''
              echo "Building all gems..."
              cd ''${ws}
              for gem in ${gemNamesStr}; do
                echo "==> Building $gem"
                cd ''${ws}/$gem && ''${pkgs.ruby}/bin/gem build $gem.gemspec
              done
              echo "All gems built."
            ''';

            gem-publish-all = mkApp "gem-publish-all" '''
              echo "Publishing all gems in dependency order..."
              cd ''${ws}

              echo "==> Publishing pangea-core"
              cd ''${ws}/pangea-core
              ''${pkgs.ruby}/bin/gem build pangea-core.gemspec
              ''${pkgs.ruby}/bin/gem push pangea-core-*.gem
              echo "    done"

              for gem in ${nonCoreGemsStr}; do
                echo "==> Publishing $gem"
                cd ''${ws}/$gem
                ''${pkgs.ruby}/bin/gem build $gem.gemspec
                ''${pkgs.ruby}/bin/gem push $gem-*.gem
                echo "    done"
              done

              echo "All gems published."
            ''';

            gem-status = mkApp "gem-status" '''
              echo "Gem publish status:"
              echo "--------------------------------------------"
              for gem in ${gemNamesStr}; do
                local_ver=$(''${pkgs.ruby}/bin/ruby -e "
                  Dir.glob('''${ws}/''' + gem + '''/lib/*/version.rb''').each do |f|
                    content = File.read(f)
                    if m = content.match(/VERSION\s*=\s*['''\"%%]([^'''\"%%]+)['''\"%%]/)
                      puts m[1]; break
                    end
                  end
                " 2>/dev/null)
                published=$(''${pkgs.ruby}/bin/gem search -r "^$gem$" 2>/dev/null | ''${pkgs.gnugrep}/bin/grep -o '([^)]*)' | tr -d '()' || echo "NOT_PUBLISHED")
                printf "  %-22s local=%-8s published=%s\n" "$gem" "$local_ver" "$published"
              done
            ''';

            gem-bump = mkApp "gem-bump" '''
              gem_name="''${1:-}"
              new_version="''${2:-}"
              if [ -z "$gem_name" ] || [ -z "$new_version" ]; then
                echo "Usage: nix run .#gem-bump -- <gem-name> <new-version>"
                exit 1
              fi
              cd ''${ws}/$gem_name
              version_file=$(find lib -name "version.rb" | head -1)
              ''${pkgs.gnused}/bin/sed -i "s/VERSION = .*/VERSION = %($new_version).freeze/" "$version_file"
              ''${pkgs.git}/bin/git add "$version_file"
              ''${pkgs.git}/bin/git commit -m "Bump version to $new_version"
              echo "$gem_name bumped to $new_version"
            ''';

            flake-update-all = mkApp "flake-update-all" '''
              echo "Updating flake.locks..."
              cd ''${ws}
              for repo in ${flakeReposStr}; do
                if [ -d "$repo" ] && [ -f "$repo/flake.nix" ]; then
                  echo "==> $repo"
                  cd ''${ws}/$repo && ''${pkgs.nix}/bin/nix flake update 2>&1 | tail -1
                fi
              done
              echo "Done."
            ''';

            flake-update-commit-push = mkApp "flake-update-commit-push" '''
              echo "Updating, committing, pushing flake.locks..."
              cd ''${ws}
              for repo in ${flakeReposStr}; do
                if [ -d "$repo" ] && [ -f "$repo/flake.nix" ]; then
                  cd ''${ws}/$repo
                  ''${pkgs.nix}/bin/nix flake update 2>/dev/null
                  changed=$(''${pkgs.git}/bin/git status --short flake.lock 2>/dev/null)
                  if [ -n "$changed" ]; then
                    echo "==> $repo"
                    ''${pkgs.git}/bin/git add flake.lock
                    ''${pkgs.git}/bin/git commit -m "Update flake.lock" 2>/dev/null
                    ''${pkgs.git}/bin/git push origin main 2>/dev/null
                  fi
                fi
              done
              echo "Done."
            ''';

            test-all = mkApp "test-all" '''
              echo "Running tests..."
              cd ''${ws}
              failed=0

              for repo in ${rspecRepos}; do
                if [ -d "$repo" ]; then
                  echo "==> $repo (rspec)"
                  cd ''${ws}/$repo
                  ''${pkgs.nix}/bin/nix run .#test 2>/dev/null && echo "    passed" || { echo "    FAILED"; failed=$((failed + 1)); }
                fi
              done

              for repo in ${minitestRepos}; do
                if [ -d "$repo" ]; then
                  echo "==> $repo (minitest)"
                  cd ''${ws}/$repo
                  ''${pkgs.ruby}/bin/ruby -Itest/unit -e "Dir.glob('test/unit/*_test.rb').each{|f| require File.expand_path(f)}" 2>/dev/null && echo "    passed" || { echo "    FAILED"; failed=$((failed + 1)); }
                fi
              done

              for repo in ${cargoRepos}; do
                if [ -d "$repo" ]; then
                  echo "==> $repo (cargo)"
                  cd ''${ws}/$repo
                  ''${pkgs.nix}/bin/nix run .#test 2>/dev/null && echo "    passed" || { echo "    FAILED"; failed=$((failed + 1)); }
                fi
              done

              echo "--------------------------------------------"
              [ $failed -eq 0 ] && echo "All tests passed." || { echo "$failed repo(s) FAILED."; exit 1; }
            ''';

            git-status = mkApp "git-status" '''
              echo "Git status:"
              echo "--------------------------------------------"
              cd ''${ws}
              for dir in */; do
                repo="''${dir%/}"
                if [ -d "$repo/.git" ]; then
                  status=$(''${pkgs.git}/bin/git -C "$repo" status --short 2>/dev/null)
                  branch=$(''${pkgs.git}/bin/git -C "$repo" branch --show-current 2>/dev/null)
                  if [ -z "$status" ]; then
                    printf "  %-30s %-10s clean\n" "$repo" "$branch"
                  else
                    lines=$(echo "$status" | wc -l | tr -d ' ')
                    printf "  %-30s %-10s %s changed\n" "$repo" "$branch" "$lines"
                  fi
                fi
              done
            ''';

            flow-list = mkApp "flow-list" '''
              cd ''${ws}
              [ ! -f fleet.yaml ] && cp ''${fleetYaml} fleet.yaml
              ''${fleetBin} flow list
            ''';

            ${extraApps}
          } // builtins.listToAttrs (
            builtins.map (flowName: {
              name = "flow-''${flowName}";
              value = mkFleetApp flowName;
            }) (builtins.attrNames (builtins.fromJSON '''${flowsJson}'''.flows))
          );
        });
    }
  '';

in {
  inherit generate generateFlakeContent;
}
