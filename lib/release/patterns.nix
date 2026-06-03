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
        "rust-workspace" "rust-single-crate" "go" "npm" "python" "helm"
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
    go-relver = {
      # Go has no manifest version field — the GIT TAG is the version
      # (pull-model). relver is the typed semver/changed-since-tag/idempotent
      # tag-create+push engine; the "bump" is the tag, not a file edit.
      uses = "pleme-io/substrate#relver";
      backend = "rust (relver binary)";
      ecosystem = "go";
      tool = "relver next --bump <type> (tag-only; honor /vN via --tag-glob)";
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
    go-noop = {
      # Pull-model: there is NO upload. pkg.go.dev / proxy.golang.org fetch
      # lazily on first `go get` after the tag push (FSM-MODULE Proxied state
      # is a NO-OP confirmation, not a publish). Documented here so the
      # polymorphic dispatcher has a publish row for every ecosystem.
      uses = "(none — pull-model)";
      backend = "none";
      ecosystem = "go";
      tool = "no-op confirm: poll proxy.golang.org @v/<version>.info then hermetic `go get`";
      retry-on = [ "proxy-not-yet-indexed (poll budget → ProxyTimedOut, retryable)" ];
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
    docs-publish = {
      uses = "pleme-io/actions/docs-publish@main";
      backend = "tatara-lisp";
      role = "polymorphic doc gen + deploy to gh-pages (cargo doc / mkdocs / typedoc)";
    };
  };

  delivery = {
    slack-notify = {
      uses = "pleme-io/actions/slack-notify@main";
      backend = "tatara-lisp";
      role = "post typed release event to Slack webhook with attachments + fields";
    };
    onboard-auto-release = {
      uses = "pleme-io/actions/onboard-auto-release@main";
      backend = "tatara-lisp";
      role = "scaffold the canonical 3-workflow surface into a repo + optional PR open";
    };
    coverage-upload = {
      uses = "pleme-io/actions/coverage-upload@main";
      backend = "tatara-lisp";
      role = "polymorphic coverage gen + Codecov upload (tarpaulin / npm / pytest --cov)";
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
    rust-gate = {
      uses = "pleme-io/actions/rust-gate@main";
      backend = "tatara-lisp";
      ecosystem = "rust-workspace + rust-single-crate";
      role = "cargo fmt --check + cargo clippy + cargo test";
    };
    npm-gate = {
      uses = "pleme-io/actions/npm-gate@main";
      backend = "tatara-lisp";
      ecosystem = "npm";
      role = "prettier/lint/test (conditional on package.json scripts)";
    };
    python-gate = {
      uses = "pleme-io/actions/python-gate@main";
      backend = "tatara-lisp";
      ecosystem = "python";
      role = "ruff format --check + ruff check + pytest";
    };
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

  security = {
    security-audit = {
      uses = "pleme-io/actions/security-audit@main";
      backend = "tatara-lisp";
      role = "polymorphic dep-vuln scan (cargo-audit / npm-audit / pip-audit)";
      configurable = "fail-on-severity threshold + ignore-list";
    };
    sbom-generate = {
      uses = "pleme-io/actions/sbom-generate@main";
      backend = "tatara-lisp";
      role = "syft-backed CycloneDX/SPDX SBOM, universal source-tree input";
    };
    license-header-check = {
      uses = "pleme-io/actions/license-header-check@main";
      backend = "tatara-lisp";
      role = "SPDX-License-Identifier header sweep, configurable extensions";
    };
    provenance-attest = {
      uses = "pleme-io/actions/provenance-attest@main";
      backend = "tatara-lisp";
      role = "sigstore/cosign keyless OIDC signing for any artifact";
    };
    image-scan = {
      uses = "pleme-io/actions/image-scan@main";
      backend = "tatara-lisp";
      role = "trivy container scan, configurable fail-on-severity";
    };
  };

  sdlc = {
    dependency-update = {
      uses = "pleme-io/actions/dependency-update@main";
      backend = "tatara-lisp";
      role = "polymorphic lockfile refresh + auto-PR (cargo / npm / uv / nix)";
    };
    nix-flake-update = {
      uses = "pleme-io/actions/nix-flake-update@main";
      backend = "tatara-lisp";
      role = "nix flake update + auto-PR (specific case of dependency-update)";
    };
    pr-comment = {
      uses = "pleme-io/actions/pr-comment@main";
      backend = "tatara-lisp";
      role = "idempotent PR comment via magic marker (upsert, no spam)";
    };
    issue-create = {
      uses = "pleme-io/actions/issue-create@main";
      backend = "tatara-lisp";
      role = "create or reuse GH issue (title-match dedup for auto-reporting)";
    };
    status-badge = {
      uses = "pleme-io/actions/status-badge@main";
      backend = "tatara-lisp";
      role = "shields.io-style SVG badge renderer (universal)";
    };
  };

  container = {
    docker-build-and-push = {
      uses = "pleme-io/actions/docker-build-and-push@main";
      backend = "tatara-lisp";
      role = "multi-arch buildx + push to ghcr (or any OCI registry)";
    };
  };

  k8s = {
    kubectl-apply = {
      uses = "pleme-io/actions/kubectl-apply@main";
      backend = "tatara-lisp";
      role = "apply manifests + wait for rollout (deploy/sts/ds)";
    };
    helm-deploy = {
      uses = "pleme-io/actions/helm-deploy@main";
      backend = "tatara-lisp";
      role = "helm upgrade --install --wait (in-cluster install — not registry push)";
    };
    flux-reconcile = {
      uses = "pleme-io/actions/flux-reconcile@main";
      backend = "tatara-lisp";
      role = "trigger flux reconcile on HelmRelease / Kustomization / *Repository";
    };
    kustomize-render = {
      uses = "pleme-io/actions/kustomize-render@main";
      backend = "shell";
      role = "kustomize build → rendered manifests";
    };
  };

  cloud = {
    aws-assume-role = {
      uses = "pleme-io/actions/aws-assume-role@main";
      backend = "shell";
      role = "OIDC IAM role assumption (no long-lived creds)";
    };
    cloudflare-pages-deploy = {
      uses = "pleme-io/actions/cloudflare-pages-deploy@main";
      backend = "shell";
      role = "wrangler pages deploy any static build dir";
    };
    fly-deploy = {
      uses = "pleme-io/actions/fly-deploy@main";
      backend = "shell";
      role = "flyctl deploy with strategy + region";
    };
  };

  comms = {
    slack-notify = {
      uses = "pleme-io/actions/slack-notify@main";
      backend = "tatara-lisp";
      role = "POST embed to Slack incoming webhook";
    };
    discord-notify = {
      uses = "pleme-io/actions/discord-notify@main";
      backend = "tatara-lisp";
      role = "POST embed to Discord incoming webhook";
    };
  };

  quality = {
    secrets-scan = {
      uses = "pleme-io/actions/secrets-scan@main";
      backend = "tatara-lisp";
      role = "gitleaks-driven repo secret scan with fail-on-found gate";
    };
  };

  # ── Pending primitives — mined backlog for next iterations ────
  # Each is a focused 1-action PR following the established
  # template (action.yml + run.tlisp + README + auto-balances).
  #
  # container:
  #   docker-build-and-push / ko-build / nixos-image-build /
  #   buildkit-cache-warm
  #
  # k8s:
  #   kubectl-apply / helm-deploy / flux-reconcile / argocd-sync /
  #   kustomize-render / k8s-rollout-wait
  #
  # cloud:
  #   aws-assume-role / aws-s3-upload / cloudflare-pages-deploy /
  #   cloudflare-worker-deploy / fly-deploy / gcp-auth
  #
  # akeyless suite:
  #   akeyless-auth / akeyless-secret-fetch / akeyless-rotate /
  #   akeyless-export-config / akeyless-injector-validate
  #
  # comms extras:
  #   discord-notify / pagerduty-notify / email-notify
  #
  # quality extras:
  #   mutation-test / benchmark-runner / flaky-test-detector /
  #   secrets-scan
  #
  # docs extras:
  #   api-spec-diff / toc-update / example-runner
  #
  # delivery extras:
  #   yank-version / release-promote
  #
}
