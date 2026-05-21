# ============================================================================
# ANSIBLE COLLECTION BUILDER - Package modules into Galaxy collection
# ============================================================================
# Takes generated Python modules (from ansible-forge) and packages them as
# an installable Ansible Galaxy collection with proper metadata.
#
# Apps (every body is a .tlisp script — zero inlined bash logic):
#   build      - build collection tarball
#   install    - install collection locally
#   publish    - publish to Ansible Galaxy
#   check-all  - lint + build + sanity tests
#   lint       - ansible-lint on all modules
#   bump       - version bump (major/minor/patch)
#
# Each app's program is a 2-line `exec tatara-script SCRIPT_FILE "$@"`
# wrapper around an embedded .tlisp source. The shell shim is the smallest
# possible adapter to satisfy nix-run's "program is an executable path"
# contract; every line of actual logic is in tatara-lisp.
#
# tatara-script lookup strategy: consumers control where the binary comes
# from via the `tataraScript` attr (default `"tatara-script"`, expected on
# PATH). Pass a derivation like `inputs.tatara-lisp.packages.${system}.tatara-script`
# to pin to a specific tatara-lisp build.
#
# Usage in collection flake.nix:
#   let ansibleCollection = import "${substrate}/lib/ansible-collection.nix";
#   in ansibleCollection.mkAnsibleCollection pkgs {
#     namespace = "pleme";
#     name = "akeyless";
#     version = "0.1.0";
#     src = ./.;
#     # optional — pin tatara-script (otherwise resolves from PATH)
#     tataraScript = inputs.tatara-lisp.packages.${system}.tatara-script;
#   }
#
# This returns: { packages, devShells, apps }
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
  #   tataraScript    - path to tatara-script binary or bare command name
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
    tataraScript ? "tatara-script",
  }: let
    lib = pkgs.lib;
    ansible = pkgs.ansible;
    python = pkgs.python3;
    collectionName = "${namespace}-${name}-${version}";

    # Resolve tataraScript to a shell-quotable invocation. If a derivation
    # was passed, point at its bin/tatara-script; otherwise treat it as a
    # bare command on $PATH.
    tataraInvocation =
      if lib.isDerivation tataraScript
      then "${tataraScript}/bin/tatara-script"
      else tataraScript;

    # Compile a .tlisp source string into a runnable nix-app program.
    # Writes the source to /nix/store, then wraps it in a shell shim that
    # invokes tatara-script <script-file> "$@". The shim is the smallest
    # possible adapter to the apps-take-a-path contract; everything else
    # lives in the .tlisp source.
    mkTataraScript = scriptName: src: let
      scriptFile = pkgs.writeText "${scriptName}.tlisp" src;
    in pkgs.writeShellScript "${scriptName}-wrapper" ''
      exec ${tataraInvocation} ${scriptFile} "$@"
    '';

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
        program = toString (mkTataraScript "${namespace}-${name}-build" ''
          ;; Build the Ansible Galaxy collection tarball.
          ;; Ensures galaxy.yml + meta/runtime.yml exist (copied from the
          ;; flake-baked defaults if missing), then shells out to
          ;; ansible-galaxy. Path to the ansible binary is hard-coded via
          ;; the Nix store so the script doesn't depend on the caller's PATH.
          (define ansible-bin "${ansible}/bin/ansible-galaxy")
          (define galaxy-default "${galaxyYml}")
          (define runtime-default "${runtimeYml}")

          (unless (path-exists? "galaxy.yml")
            (log-info "galaxy.yml missing — copying flake-baked default")
            (write-file "galaxy.yml" (read-file galaxy-default)))

          (mkdir-p "meta")
          (unless (path-exists? "meta/runtime.yml")
            (log-info "meta/runtime.yml missing — copying flake-baked default")
            (write-file "meta/runtime.yml" (read-file runtime-default)))

          (define status (exec-check ansible-bin "collection" "build" "--force"))
          (unless (= status 0)
            (log-error (string-append "ansible-galaxy build failed with status " (string-format "{}" status)))
            (exit status))

          ;; Re-read galaxy.yml after build so the printed name reflects
          ;; the version ansible-galaxy actually used (not the flake-baked
          ;; default, which may be stale after a bump).
          (define built (yaml-read "galaxy.yml"))
          (define built-v (alist-get built "version"))
          (print-line (string-append "Built: ${namespace}-${name}-" built-v ".tar.gz"))
        '');
      };

      install = {
        type = "app";
        program = toString (mkTataraScript "${namespace}-${name}-install" ''
          ;; Install the previously-built collection tarball locally.
          ;; Reads version from galaxy.yml at runtime so install picks up
          ;; whatever `nix run .#bump` just wrote, not the flake-baked
          ;; default. The tarball name is "${namespace}-${name}-<v>.tar.gz".
          (define ansible-bin "${ansible}/bin/ansible-galaxy")

          (unless (path-exists? "galaxy.yml")
            (log-error "galaxy.yml not found in CWD")
            (exit 1))

          (define galaxy (yaml-read "galaxy.yml"))
          (define v (alist-get galaxy "version"))
          (when (or (null? v) (equal? v ""))
            (log-error "galaxy.yml has no `version:` field")
            (exit 1))

          (define tarball (string-append "${namespace}-${name}-" v ".tar.gz"))
          (unless (path-exists? tarball)
            (log-error (string-append "Collection not built yet: " tarball " missing. Run: nix run .#build"))
            (exit 1))

          (define status (exec-check ansible-bin "collection" "install" tarball "--force"))
          (unless (= status 0)
            (log-error (string-append "ansible-galaxy install failed with status " (string-format "{}" status)))
            (exit status))

          (print-line (string-append "Installed: ${namespace}.${name} " v))
        '');
      };

      publish = {
        type = "app";
        program = toString (mkTataraScript "${namespace}-${name}-publish" ''
          ;; Publish the built collection tarball to Ansible Galaxy.
          ;; Reads version from galaxy.yml at runtime so it stays in sync
          ;; with whatever `nix run .#bump` last wrote. Errors loudly if
          ;; the Galaxy token isn't in env or the tarball is missing.
          (define ansible-bin "${ansible}/bin/ansible-galaxy")
          (define token (env-get "ANSIBLE_GALAXY_TOKEN" ""))
          (when (equal? token "")
            (log-error "Error: ANSIBLE_GALAXY_TOKEN is not set.")
            (exit 1))

          (unless (path-exists? "galaxy.yml")
            (log-error "galaxy.yml not found in CWD")
            (exit 1))

          (define galaxy (yaml-read "galaxy.yml"))
          (define v (alist-get galaxy "version"))
          (when (or (null? v) (equal? v ""))
            (log-error "galaxy.yml has no `version:` field")
            (exit 1))

          (define tarball (string-append "${namespace}-${name}-" v ".tar.gz"))
          (unless (path-exists? tarball)
            (log-error (string-append "Collection not built yet: " tarball " missing. Run: nix run .#build"))
            (exit 1))

          (define status (exec-check ansible-bin "collection" "publish" tarball "--token" token))
          (unless (= status 0)
            (log-error (string-append "ansible-galaxy publish failed with status " (string-format "{}" status)))
            (exit status))

          (print-line (string-append "Published: ${namespace}.${name} " v))
        '');
      };

      lint = {
        type = "app";
        program = toString (mkTataraScript "${namespace}-${name}-lint" ''
          ;; Validate Python syntax across every plugin module. Walks
          ;; plugins/ looking for *.py files and shells each into
          ;; `python -c "import ast; ast.parse(open(p).read())"`. Python's
          ;; own SyntaxError trace is the human-readable failure message;
          ;; we just propagate its non-zero exit and stop on first failure.
          (define python-bin "${python}/bin/python")
          (define plugins (filter (lambda (p) (string-ends-with? p ".py"))
                                  (if (is-dir? "plugins") (walk-dir "plugins") (list))))

          (print-line "=> Checking Python syntax")
          (for-each
            (lambda (p)
              (define status (exec-check python-bin "-c"
                                         (string-append "import ast; ast.parse(open('" p "').read())")))
              (unless (= status 0)
                (log-error (string-append "Syntax error in " p))
                (exit status)))
            plugins)

          (print-line "=> All modules have valid syntax")
        '');
      };

      check-all = {
        type = "app";
        program = toString (mkTataraScript "${namespace}-${name}-check-all" ''
          ;; lint + build composed as one .tlisp body. Reuses (sh-exec) to
          ;; invoke the per-app wrappers so any future change to the build
          ;; or lint logic flows through naturally.
          (define ansible-bin "${ansible}/bin/ansible-galaxy")
          (define python-bin "${python}/bin/python")
          (define galaxy-default "${galaxyYml}")
          (define runtime-default "${runtimeYml}")

          ;; lint
          (print-line "=> Checking Python syntax")
          (define plugins (filter (lambda (p) (string-ends-with? p ".py"))
                                  (if (is-dir? "plugins") (walk-dir "plugins") (list))))
          (for-each
            (lambda (p)
              (define status (exec-check python-bin "-c"
                                         (string-append "import ast; ast.parse(open('" p "').read())")))
              (unless (= status 0)
                (log-error (string-append "Syntax error in " p))
                (exit status)))
            plugins)

          ;; build
          (print-line "=> Building collection")
          (unless (path-exists? "galaxy.yml")
            (write-file "galaxy.yml" (read-file galaxy-default)))
          (mkdir-p "meta")
          (unless (path-exists? "meta/runtime.yml")
            (write-file "meta/runtime.yml" (read-file runtime-default)))
          (define status (exec-check ansible-bin "collection" "build" "--force"))
          (unless (= status 0)
            (log-error (string-append "ansible-galaxy build failed with status " (string-format "{}" status)))
            (exit status))

          (print-line "All checks passed.")
        '');
      };

      bump = {
        type = "app";
        program = toString (mkTataraScript "${namespace}-${name}-bump" ''
          ;; Version-bump galaxy.yml + commit + tag. Reads the CURRENT
          ;; version from galaxy.yml (not the flake-baked default) so a
          ;; second consecutive bump works correctly. The bump kind comes
          ;; from argv (default: patch). Single sed/awk equivalents are
          ;; implemented in tlisp via string-split / string-join so there
          ;; is zero shell substitution surface.
          (define bump-type (argv-get 0 "patch"))

          (unless (path-exists? "galaxy.yml")
            (log-error "galaxy.yml not found in CWD")
            (exit 1))

          (define galaxy (yaml-read "galaxy.yml"))
          (define current (alist-get galaxy "version"))
          (when (or (null? current) (equal? current ""))
            (log-error "galaxy.yml has no `version:` field — cannot bump")
            (exit 1))

          ;; Parse "X.Y.Z" → (X Y Z) as integers. Anything non-numeric
          ;; throws via string->number's underlying parse.
          (define parts (string-split current "."))
          (unless (= (length parts) 3)
            (log-error (string-append "Expected MAJOR.MINOR.PATCH version, got: " current))
            (exit 1))

          (define (parse-int s)
            ;; Cheap parse via json-parse since tatara-lisp-script exposes
            ;; no string->number. A bare digit string is valid JSON.
            (json-parse s))
          (define M (parse-int (nth 0 parts)))
          (define N (parse-int (nth 1 parts)))
          (define P (parse-int (nth 2 parts)))

          (define new-version
            (cond
              ((equal? bump-type "major")
               (string-append (string-format "{}" (+ M 1)) ".0.0"))
              ((equal? bump-type "minor")
               (string-append (string-format "{}" M) "." (string-format "{}" (+ N 1)) ".0"))
              ((equal? bump-type "patch")
               (string-append (string-format "{}" M) "." (string-format "{}" N) "." (string-format "{}" (+ P 1))))
              (else
                (log-error "Usage: bump [major|minor|patch]")
                (exit 1))))

          ;; Rewrite the `version:` line in galaxy.yml in place. We do this
          ;; line-oriented (not via yaml-serialize) so comments + formatting
          ;; survive — galaxy.yml is human-edited too.
          (define body (read-file "galaxy.yml"))
          (define lines (string-split body "\n"))
          (define new-lines
            (map
              (lambda (line)
                (if (string-starts-with? line "version:")
                  (string-append "version: " new-version)
                  line))
              lines))
          (write-file "galaxy.yml" (string-join "\n" new-lines))

          (define add-status (exec-check "git" "add" "galaxy.yml"))
          (unless (= add-status 0) (exit add-status))
          (define commit-status (exec-check "git" "commit" "-m"
                                            (string-append "release: ${namespace}.${name} v" new-version)))
          (unless (= commit-status 0) (exit commit-status))
          (define tag-status (exec-check "git" "tag" (string-append "v" new-version)))
          (unless (= tag-status 0) (exit tag-status))

          (print-line (string-append "Bumped: " current " -> " new-version))
        '');
      };
    };
  };
}
