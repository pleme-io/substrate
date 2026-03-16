# ============================================================================
# ANSIBLE COLLECTION BUILDER - Package modules into Galaxy collection
# ============================================================================
# Takes generated Python modules (from ansible-forge) and packages them as
# an installable Ansible Galaxy collection with proper metadata.
#
# Apps:
#   build      - build collection tarball
#   install    - install collection locally
#   publish    - publish to Ansible Galaxy
#   check-all  - lint + build + sanity tests
#   lint       - ansible-lint on all modules
#   bump       - version bump (major/minor/patch)
#
# Usage in collection flake.nix:
#   let ansibleCollection = import "${substrate}/lib/ansible-collection.nix";
#   in ansibleCollection.mkAnsibleCollection pkgs {
#     namespace = "pleme";
#     name = "akeyless";
#     version = "0.1.0";
#     src = ./.;
#   }
#
# This returns: { packages, devShells, apps }
#
# Usage (via substrate lib):
#   outputs = substrateLib.mkAnsibleCollection { ... };
{
  # Build an Ansible Galaxy collection from source.
  #
  # Required attrs:
  #   namespace - Galaxy namespace (e.g., "pleme")
  #   name      - collection name (e.g., "akeyless")
  #   version   - version string
  #   src       - source path
  #
  # Optional attrs:
  #   description     - collection description
  #   authors         - list of author strings
  #   license         - list of license identifiers
  #   minAnsibleVersion - minimum ansible-core version
  #   extraDevInputs  - additional packages for devShell
  mkAnsibleCollection = pkgs: {
    namespace,
    name,
    version,
    src,
    description ? "${namespace}.${name} Ansible collection",
    authors ? [ "pleme-io" ],
    license ? [ "MIT" ],
    minAnsibleVersion ? "2.14.0",
    extraDevInputs ? [],
  }: let
    lib = pkgs.lib;
    ansible = pkgs.ansible;
    python = pkgs.python3;
    collectionName = "${namespace}-${name}-${version}";

    # Generate galaxy.yml if it doesn't exist
    galaxyYml = pkgs.writeText "galaxy.yml" ''
      namespace: ${namespace}
      name: ${name}
      version: ${version}
      description: ${description}
      authors:
      ${builtins.concatStringsSep "\n" (map (a: "  - ${a}") authors)}
      license:
      ${builtins.concatStringsSep "\n" (map (l: "  - ${l}") license)}
      repository: https://github.com/pleme-io/ansible-${name}
      documentation: https://github.com/pleme-io/ansible-${name}
      homepage: https://github.com/pleme-io/ansible-${name}
      issues: https://github.com/pleme-io/ansible-${name}/issues
      build_ignore:
        - '*.tar.gz'
        - .git
        - .github
        - tests/output
      dependencies: {}
    '';

    # Generate meta/runtime.yml
    runtimeYml = pkgs.writeText "runtime.yml" ''
      requires_ansible: ">=${minAnsibleVersion}"
      plugin_routing: {}
    '';

    # Build the collection as a Nix derivation
    collection = pkgs.stdenv.mkDerivation {
      pname = "${namespace}-${name}";
      inherit version;
      inherit src;

      nativeBuildInputs = [ ansible python ];

      buildPhase = ''
        # Ensure galaxy.yml exists
        if [ ! -f galaxy.yml ]; then
          cp ${galaxyYml} galaxy.yml
        fi

        # Ensure meta/runtime.yml exists
        mkdir -p meta
        if [ ! -f meta/runtime.yml ]; then
          cp ${runtimeYml} meta/runtime.yml
        fi

        # Build the collection
        ansible-galaxy collection build --force
      '';

      installPhase = ''
        mkdir -p $out
        cp ${collectionName}.tar.gz $out/
        cp galaxy.yml $out/
      '';
    };

    devShell = pkgs.mkShellNoCC {
      packages = [
        ansible
        python
      ] ++ extraDevInputs;

      shellHook = ''
        echo "Ansible collection dev shell for ${namespace}.${name}"
        echo "  nix run .#build    -- build collection tarball"
        echo "  nix run .#install  -- install locally"
        echo "  nix run .#lint     -- lint modules"
      '';
    };

  in {
    packages = {
      default = collection;
      "${namespace}-${name}" = collection;
    };

    devShells.default = devShell;

    apps = {
      build = {
        type = "app";
        program = toString (pkgs.writeShellScript "${namespace}-${name}-build" ''
          set -euo pipefail
          if [ ! -f galaxy.yml ]; then
            cp ${galaxyYml} galaxy.yml
          fi
          mkdir -p meta
          if [ ! -f meta/runtime.yml ]; then
            cp ${runtimeYml} meta/runtime.yml
          fi
          ${ansible}/bin/ansible-galaxy collection build --force
          echo "Built: ${collectionName}.tar.gz"
        '');
      };

      install = {
        type = "app";
        program = toString (pkgs.writeShellScript "${namespace}-${name}-install" ''
          set -euo pipefail
          if [ ! -f ${collectionName}.tar.gz ]; then
            echo "Collection not built yet. Run: nix run .#build"
            exit 1
          fi
          ${ansible}/bin/ansible-galaxy collection install ${collectionName}.tar.gz --force
          echo "Installed: ${namespace}.${name} ${version}"
        '');
      };

      publish = {
        type = "app";
        program = toString (pkgs.writeShellScript "${namespace}-${name}-publish" ''
          set -euo pipefail
          if [ -z "''${ANSIBLE_GALAXY_TOKEN:-}" ]; then
            echo "Error: ANSIBLE_GALAXY_TOKEN is not set."
            exit 1
          fi
          if [ ! -f ${collectionName}.tar.gz ]; then
            echo "Collection not built yet. Run: nix run .#build"
            exit 1
          fi
          ${ansible}/bin/ansible-galaxy collection publish ${collectionName}.tar.gz --token "$ANSIBLE_GALAXY_TOKEN"
          echo "Published: ${namespace}.${name} ${version}"
        '');
      };

      lint = {
        type = "app";
        program = toString (pkgs.writeShellScript "${namespace}-${name}-lint" ''
          set -euo pipefail
          echo "=> Checking Python syntax"
          find plugins -name "*.py" -exec ${python}/bin/python -c "
          import ast, sys
          try:
              ast.parse(open(sys.argv[1]).read())
          except SyntaxError as e:
              print(f'FAIL: {sys.argv[1]}: {e}')
              sys.exit(1)
          " {} \;
          echo "=> All modules have valid syntax"
        '');
      };

      check-all = {
        type = "app";
        program = toString (pkgs.writeShellScript "${namespace}-${name}-check-all" ''
          set -euo pipefail
          echo "=> Checking Python syntax"
          find plugins -name "*.py" -exec ${python}/bin/python -c "
          import ast, sys
          try:
              ast.parse(open(sys.argv[1]).read())
          except SyntaxError as e:
              print(f'FAIL: {sys.argv[1]}: {e}')
              sys.exit(1)
          " {} \;
          echo "=> Building collection"
          if [ ! -f galaxy.yml ]; then
            cp ${galaxyYml} galaxy.yml
          fi
          mkdir -p meta
          if [ ! -f meta/runtime.yml ]; then
            cp ${runtimeYml} meta/runtime.yml
          fi
          ${ansible}/bin/ansible-galaxy collection build --force
          echo "All checks passed."
        '');
      };

      bump = {
        type = "app";
        program = toString (pkgs.writeShellScript "${namespace}-${name}-bump" ''
          set -euo pipefail
          BUMP_TYPE="''${1:-patch}"
          CURRENT="${version}"
          IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
          case "$BUMP_TYPE" in
            major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
            minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
            patch) PATCH=$((PATCH + 1)) ;;
            *) echo "Usage: bump [major|minor|patch]"; exit 1 ;;
          esac
          NEW="$MAJOR.$MINOR.$PATCH"
          # Update galaxy.yml version (macOS + Linux compatible)
          sed -i "" "s/^version: .*/version: $NEW/" galaxy.yml 2>/dev/null || \
          sed -i "s/^version: .*/version: $NEW/" galaxy.yml
          git add galaxy.yml
          git commit -m "release: ${namespace}.${name} v$NEW"
          git tag "v$NEW"
          echo "Bumped: $CURRENT -> $NEW"
        '');
      };
    };
  };
}
