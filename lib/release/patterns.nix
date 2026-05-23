# substrate/lib/release/patterns.nix
#
# Comprehensive primitive catalog. Every pleme-io/actions/* with
# the metadata downstream consumers need to compose into pipelines.
#
# This is the COMPLETE surface — not just release recipes (see
# catalog.nix for the release subset). Every typed primitive that
# substrate knows how to compose lives here.
#
# Categories:
#   dispatch      — repo-type detection
#   bump          — version bumping (per language)
#   publish       — registry publishing (per language)
#   git           — commit/tag/push
#   gh            — github release / PR / issue
#   docs          — changelog / readme / api docs
#   validation    — lint / format / typecheck (pending)
#   security      — audit / SBOM / provenance (pending)
#   image         — OCI image build + push
#   spec          — OpenAPI watch + codegen
#   tatara        — universal tlisp executor (the runtime)

{
  dispatch = {
    detect-repo-type = {
      uses = "pleme-io/actions/detect-repo-type@main";
      kind = "composite";
      backend = "tatara-lisp";
      role = "polymorphic dispatcher input";
      outputs = [ "repo-type" "manifest-path" ];
      detects = [
        "rust-workspace" "rust-single-crate" "npm" "python" "helm"
        "ansible-collection" "ruby-gem" "github-action" "unknown"
      ];
    };
  };

  bump = {
    rust-workspace-bump = {
      uses = "pleme-io/actions/rust-workspace-bump@main";
      backend = "tatara-lisp";
      ecosystem = "rust-workspace";
      tool = "cargo set-version --workspace --bump <type>";
    };
    cargo-bump = {
      uses = "pleme-io/actions/cargo-bump@main";
      backend = "tatara-lisp";
      ecosystem = "rust-single-crate";
      tool = "cargo set-version --bump <type>";
    };
    npm-bump = {
      uses = "pleme-io/actions/npm-bump@main";
      backend = "tatara-lisp";
      ecosystem = "npm";
      tool = "npm version --no-git-tag-version <type>";
    };
    python-bump = {
      uses = "pleme-io/actions/python-bump@main";
      backend = "tatara-lisp";
      ecosystem = "python";
      tool = "uv version --bump <type>";
    };
    helm-bump = {
      uses = "pleme-io/actions/helm-bump@main";
      backend = "tatara-lisp";
      ecosystem = "helm";
      tool = "in-tlisp semver + yq on Chart.yaml";
    };
    substrate-bump = {
      uses = "pleme-io/actions/substrate-bump@main";
      backend = "tatara-lisp";
      ecosystem = "polymorphic — ansible / ruby-gem";
      tool = "dispatch to .#bump / .#gem:bump";
    };
  };

  publish = {
    rust-workspace-publish = {
      uses = "pleme-io/actions/rust-workspace-publish@main";
      backend = "tatara-lisp";
      ecosystem = "rust-workspace";
      tool = "cargo publish per-crate, multi-pass dep order";
      retry-on = [ "rate-limit" "dep-not-yet-published" "name-conflict (renames)" ];
    };
    cargo-publish-crate = {
      uses = "pleme-io/actions/cargo-publish-crate@main";
      backend = "tatara-lisp";
      ecosystem = "rust-single-crate";
      tool = "cargo publish";
      retry-on = [ "rate-limit" ];
    };
    npm-publish = {
      uses = "pleme-io/actions/npm-publish@main";
      backend = "tatara-lisp";
      ecosystem = "npm";
      tool = "npm publish";
      retry-on = [ "rate-limit" ];
    };
    python-publish = {
      uses = "pleme-io/actions/python-publish@main";
      backend = "tatara-lisp";
      ecosystem = "python";
      tool = "uv build + uv publish";
      retry-on = [ "rate-limit" ];
    };
    helm-publish = {
      uses = "pleme-io/actions/helm-publish@main";
      backend = "tatara-lisp";
      ecosystem = "helm";
      tool = "helm package + helm push (OCI)";
      retry-on = [ "rate-limit" ];
    };
    helm-oci-publish = {
      uses = "pleme-io/actions/helm-oci-publish@main";
      backend = "tatara-lisp";
      ecosystem = "helm (older interface)";
      tool = "helm push to OCI";
    };
    gem-publish = {
      uses = "pleme-io/actions/gem-publish@main";
      backend = "tatara-lisp";
      ecosystem = "ruby-gem";
      tool = "gem push";
    };
    ansible-collection-publish = {
      uses = "pleme-io/actions/ansible-collection-publish@main";
      backend = "tatara-lisp";
      ecosystem = "ansible-collection";
      tool = "ansible-galaxy collection publish";
    };
  };

  git = {
    git-commit-tag = {
      uses = "pleme-io/actions/git-commit-tag@main";
      backend = "tatara-lisp";
      role = "bot identity + stage + commit + annotated tag";
    };
    git-push-with-token = {
      uses = "pleme-io/actions/git-push-with-token@main";
      backend = "tatara-lisp (Docker image)";
      role = "rewrite origin URL with token + push branch + tags";
    };
  };

  gh = {
    gh-release-create = {
      uses = "pleme-io/actions/gh-release-create@main";
      backend = "tatara-lisp";
      role = "create GitHub Release with auto-notes + asset uploads";
    };
    derive-version-from-tag = {
      uses = "pleme-io/actions/derive-version-from-tag@v1";
      backend = "tatara-lisp (Docker image)";
      role = "strip 'v' prefix from tag → emit version string";
    };
  };

  docs = {
    changelog-generate = {
      uses = "pleme-io/actions/changelog-generate@main";
      backend = "tatara-lisp";
      role = "git log → CHANGELOG.md (markdown / keepachangelog / conventional)";
    };
  };

  validation = {
    tlisp-lint = {
      uses = "pleme-io/actions/tlisp-lint@main";
      backend = "tatara-lisp";
      role = "paren / string / comment balance check for *.tlisp files";
    };
    nix-flake-check = {
      uses = "pleme-io/actions/nix-flake-check@main";
      backend = "tatara-lisp";
      role = "nix flake check + lock verification";
    };
    # pending — see docs/RECIPES.md backlog
  };

  build = {
    rust-cross-build = {
      uses = "pleme-io/actions/rust-cross-build@main";
      backend = "tatara-lisp";
      role = "cargo build for multi-platform binaries";
    };
    oci-image-push = {
      uses = "pleme-io/actions/oci-image-push@main";
      backend = "tatara-lisp";
      role = "multi-arch docker image push to ghcr";
    };
    ansible-collection-build = {
      uses = "pleme-io/actions/ansible-collection-build@main";
      backend = "tatara-lisp";
      role = "ansible-galaxy collection build";
    };
  };

  spec = {
    spec-watch = {
      uses = "pleme-io/actions/spec-watch@main";
      backend = "tatara-lisp";
      role = "BLAKE3 hash an upstream spec URL + emit changed flag";
    };
    iac-forge = {
      uses = "pleme-io/actions/iac-forge@main";
      backend = "tatara-lisp";
      role = "OpenAPI → multi-backend codegen via iac-forge CLI";
    };
  };

  runtime = {
    tatara-script = {
      uses = "pleme-io/actions/tatara-script@v1";
      backend = "Rust (tatara-lisp-script binary)";
      role = "universal tlisp executor — every tlisp action's runtime";
    };
  };

  # ── Pending primitives (planned, not yet shipped) ──────────────
  # These extend the catalog without changing existing entries.
  # Add a `pleme-io/actions/<name>/` dir + entry here as each lands.
  #
  # validation:
  #   format-check        polymorphic fmt --check (rustfmt / prettier / black / ruff)
  #   lint-gate           polymorphic linter (clippy / eslint / ruff / shellcheck)
  #   test-gate           polymorphic test runner (cargo test / npm test / pytest)
  #   license-header-check  SPDX header verifier across language families
  #   typecheck-gate      mypy / tsc / cargo check
  #
  # security:
  #   cargo-audit         cargo audit + report
  #   npm-audit           npm audit + report
  #   pip-audit           pip-audit / safety
  #   sbom-generate       syft / cyclonedx generation
  #   provenance-attest   sigstore / cosign sign
  #   image-scan          trivy / grype container scan
  #
  # delivery:
  #   slack-notify        post release to slack
  #   discord-notify      post release to discord
  #   docs-publish        cargo doc / mkdocs / typedoc → ghpages
  #   coverage-upload     codecov / coveralls
  #   yank-version        rollback a published version
}
