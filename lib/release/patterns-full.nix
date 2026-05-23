# auto-generated from pleme-io/actions/*/action.yml
# regenerate: pleme-doc-gen --actions-dir <repo> patterns > patterns-full.nix
# See substrate/docs/INTERLOCK.md for the vision.

{
  akeyless = {
    "akeyless-auth" = {
      uses = "pleme-io/actions/akeyless-auth@main";
      backend = "tatara-lisp";
      role = "Akeyless login via access-id + (access-key | SAML | JWT). Exports AKEYLESS_TOKEN to subsequent steps so siblings (secret-fetch / rotate / etc) can reuse.";
    };
    "akeyless-export-config" = {
      uses = "pleme-io/actions/akeyless-export-config@main";
      backend = "tatara-lisp";
      role = "Export an Akeyless gateway config snapshot (auth methods + roles + items) for audit / diff / backup.";
    };
    "akeyless-injector-validate" = {
      uses = "pleme-io/actions/akeyless-injector-validate@main";
      backend = "tatara-lisp";
      role = "Validate Akeyless sidecar injector annotations on a set of k8s manifests. Sanity-check that secret references point at valid Akeyless paths before applying.";
    };
    "akeyless-rotate" = {
      uses = "pleme-io/actions/akeyless-rotate@main";
      backend = "tatara-lisp";
      role = "Rotate a rotated-secret in Akeyless. Reads $AKEYLESS_TOKEN.";
    };
    "akeyless-secret-fetch" = {
      uses = "pleme-io/actions/akeyless-secret-fetch@main";
      backend = "tatara-lisp";
      role = "Fetch a static / dynamic / rotated secret from Akeyless. Reads $AKEYLESS_TOKEN (set by akeyless-auth) — operator typically invokes akeyless-auth in a prior step.";
    };
  };
  ansible = {
    "ansible-collection-build" = {
      uses = "pleme-io/actions/ansible-collection-build@main";
      backend = "tatara-lisp";
      role = "Build an Ansible collection tarball via substrate flake (nix run .#build)";
    };
    "ansible-collection-publish" = {
      uses = "pleme-io/actions/ansible-collection-publish@main";
      backend = "tatara-lisp";
      role = "Publish an Ansible collection to Galaxy via substrate flake (nix run .#publish)";
    };
  };
  backup = {
    "restic-backup" = {
      uses = "pleme-io/actions/restic-backup@main";
      backend = "tatara-lisp";
      role = "Run a restic backup to any supported repo (s3/b2/sftp/etc).";
    };
  };
  build = {
    "rust-cross-build" = {
      uses = "pleme-io/actions/rust-cross-build@main";
      backend = "tatara-lisp";
      role = "cargo build --release for a target, stage binary + sha256 into ./dist";
    };
  };
  bump = {
    "rust-workspace-bump" = {
      uses = "pleme-io/actions/rust-workspace-bump@main";
      backend = "tatara-lisp";
      role = "Bump a Rust workspace.package.version via `cargo set-version --workspace --bump <type>`, regen Cargo.nix, commit + tag locally. No shell — composes existing rust + tatara-script + git primitives.";
    };
    "substrate-bump" = {
      uses = "pleme-io/actions/substrate-bump@main";
      backend = "tatara-lisp";
      role = "Bump version using substrate flake `bump` app (nix run .#bump -- <type>)";
    };
  };
  caixa = {
    "caixa-bump" = {
      uses = "pleme-io/actions/caixa-bump@main";
      backend = "tatara-lisp";
      role = "Bump the :version field inside a (defcaixa ...) form. Sibling of cargo-bump / npm-bump for the tatara-lisp + caixa SDLC primitive.";
    };
    "caixa-publish" = {
      uses = "pleme-io/actions/caixa-publish@main";
      backend = "shell";
      role = "Publish caixa-rendered Helm chart to an OCI registry. Wraps helm-publish but consumes the caixa-render output dir.";
    };
    "caixa-render" = {
      uses = "pleme-io/actions/caixa-render@main";
      backend = "shell";
      role = "Render cluster artifacts (Helm chart + Kubernetes manifests + Flux + CI workflows) from a (defcaixa ...) form via the `feira` CLI.";
    };
  };
  cloud = {
    "aws-assume-role" = {
      uses = "pleme-io/actions/aws-assume-role@main";
      backend = "shell";
      role = "Assume an AWS IAM role via OIDC (no long-lived creds). Exports AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY + AWS_SESSION_TOKEN to subsequent steps.";
    };
    "aws-s3-upload" = {
      uses = "pleme-io/actions/aws-s3-upload@main";
      backend = "tatara-lisp";
      role = "Upload a file or directory to S3. Pairs with aws-assume-role for IAM. Useful for build-artifact ship, backup, SBOM archive, etc.";
    };
    "azure-deploy" = {
      uses = "pleme-io/actions/azure-deploy@main";
      backend = "tatara-lisp";
      role = "Deploy via Azure CLI (az deployment group create).";
    };
    "cloudflare-pages-deploy" = {
      uses = "pleme-io/actions/cloudflare-pages-deploy@main";
      backend = "shell";
      role = "Deploy a static build dir to Cloudflare Pages via wrangler. Universal — works with any output dir (Vite, mkdocs, cargo doc, hand-built static).";
    };
    "cloudflare-r2-upload" = {
      uses = "pleme-io/actions/cloudflare-r2-upload@main";
      backend = "shell";
      role = "Upload a file or directory to Cloudflare R2 via wrangler r2 object put. S3-compatible alternative.";
    };
    "cloudflare-worker-deploy" = {
      uses = "pleme-io/actions/cloudflare-worker-deploy@main";
      backend = "shell";
      role = "Deploy a Cloudflare Worker via wrangler. Reads wrangler.toml at repo root or at the given path.";
    };
    "doctl-deploy" = {
      uses = "pleme-io/actions/doctl-deploy@main";
      backend = "tatara-lisp";
      role = "Deploy a DigitalOcean App Platform app.";
    };
    "fly-deploy" = {
      uses = "pleme-io/actions/fly-deploy@main";
      backend = "tatara-lisp";
      role = "Deploy a Fly.io app via flyctl. Uses fly.toml at repo root; honors $FLY_API_TOKEN env var.";
    };
    "gcp-auth" = {
      uses = "pleme-io/actions/gcp-auth@main";
      backend = "shell";
      role = "GCP Workload Identity Federation login (no service-account JSON key). Exports GOOGLE_APPLICATION_CREDENTIALS to subsequent steps.";
    };
    "heroku-deploy" = {
      uses = "pleme-io/actions/heroku-deploy@main";
      backend = "tatara-lisp";
      role = "Deploy via git push heroku main.";
    };
    "netlify-deploy" = {
      uses = "pleme-io/actions/netlify-deploy@main";
      backend = "tatara-lisp";
      role = "Deploy to Netlify via netlify CLI.";
    };
    "railway-up" = {
      uses = "pleme-io/actions/railway-up@main";
      backend = "tatara-lisp";
      role = "Deploy via railway up.";
    };
    "render-deploy" = {
      uses = "pleme-io/actions/render-deploy@main";
      backend = "tatara-lisp";
      role = "Trigger a Render service deploy via API.";
    };
    "vercel-deploy" = {
      uses = "pleme-io/actions/vercel-deploy@main";
      backend = "tatara-lisp";
      role = "Deploy to Vercel via vercel CLI.";
    };
  };
  comms = {
    "discord-notify" = {
      uses = "pleme-io/actions/discord-notify@main";
      backend = "tatara-lisp";
      role = "Post a typed release event to a Discord webhook. Sibling of slack-notify.";
    };
    "email-notify" = {
      uses = "pleme-io/actions/email-notify@main";
      backend = "shell";
      role = "Send a plain-text email via SMTP. Sibling of slack-notify / discord-notify for ops contexts where webhooks aren''t available.";
    };
    "matrix-notify" = {
      uses = "pleme-io/actions/matrix-notify@main";
      backend = "tatara-lisp";
      role = "Send a message to a Matrix room via the appservice REST API.";
    };
    "mattermost-notify" = {
      uses = "pleme-io/actions/mattermost-notify@main";
      backend = "tatara-lisp";
      role = "POST to a Mattermost webhook.";
    };
    "pagerduty-notify" = {
      uses = "pleme-io/actions/pagerduty-notify@main";
      backend = "tatara-lisp";
      role = "Trigger / resolve a PagerDuty incident via the Events API v2. Useful for CI-driven on-call paging.";
    };
    "slack-notify" = {
      uses = "pleme-io/actions/slack-notify@main";
      backend = "tatara-lisp";
      role = "Post a typed release event to a Slack webhook. Universal — works for any release flow that wants typed notifications.";
    };
    "teams-notify" = {
      uses = "pleme-io/actions/teams-notify@main";
      backend = "tatara-lisp";
      role = "Post an adaptive card to a Microsoft Teams incoming webhook.";
    };
    "telegram-notify" = {
      uses = "pleme-io/actions/telegram-notify@main";
      backend = "tatara-lisp";
      role = "Send a message to a Telegram chat via bot API.";
    };
    "twilio-sms" = {
      uses = "pleme-io/actions/twilio-sms@main";
      backend = "tatara-lisp";
      role = "Send an SMS via Twilio.";
    };
  };
  container = {
    "buildah-build" = {
      uses = "pleme-io/actions/buildah-build@main";
      backend = "tatara-lisp";
      role = "Build an OCI image with buildah (rootless alternative).";
    };
    "buildkit-cache-warm" = {
      uses = "pleme-io/actions/buildkit-cache-warm@main";
      backend = "tatara-lisp";
      role = "Pre-warm buildkit''s registry-mounted layer cache for an image. Useful for cold-start CD runners or fan-out builds.";
    };
    "crane-mutate" = {
      uses = "pleme-io/actions/crane-mutate@main";
      backend = "tatara-lisp";
      role = "Mutate an OCI image's labels/tags via crane.";
    };
    "docker-build-and-push" = {
      uses = "pleme-io/actions/docker-build-and-push@main";
      backend = "tatara-lisp";
      role = "Multi-arch docker buildx build + push to ghcr.io (or any OCI registry). Universal — works on any Dockerfile-bearing repo.";
    };
    "ko-build" = {
      uses = "pleme-io/actions/ko-build@main";
      backend = "tatara-lisp";
      role = "Containerless Go image build + push via ko. No Dockerfile required.";
    };
    "oci-image-push" = {
      uses = "pleme-io/actions/oci-image-push@main";
      backend = "tatara-lisp";
      role = "Push an OCI image tarball (Nix dockerTools output) to a registry — skopeo fallback";
    };
    "podman-build" = {
      uses = "pleme-io/actions/podman-build@main";
      backend = "tatara-lisp";
      role = "Build a container image with podman (rootless, daemonless alternative to docker).";
    };
    "skopeo-copy" = {
      uses = "pleme-io/actions/skopeo-copy@main";
      backend = "tatara-lisp";
      role = "Copy an OCI image between registries via skopeo copy.";
    };
  };
  data = {
    "json-schema-check" = {
      uses = "pleme-io/actions/json-schema-check@main";
      backend = "tatara-lisp";
      role = "Validate JSON files against JSON Schema.";
    };
    "yaml-lint" = {
      uses = "pleme-io/actions/yaml-lint@main";
      backend = "tatara-lisp";
      role = "Run yamllint on yaml files.";
    };
  };
  db = {
    "atlas-migrate" = {
      uses = "pleme-io/actions/atlas-migrate@main";
      backend = "tatara-lisp";
      role = "Apply schema migrations via Atlas.";
    };
    "db-backup" = {
      uses = "pleme-io/actions/db-backup@main";
      backend = "tatara-lisp";
      role = "Dump a database to a backup artifact. PostgreSQL via pg_dump, MySQL via mysqldump.";
    };
    "db-migrate" = {
      uses = "pleme-io/actions/db-migrate@main";
      backend = "tatara-lisp";
      role = "Polymorphic DB migration — sqlx-migrate / alembic / knex / etc by detect.";
    };
    "flyway-migrate" = {
      uses = "pleme-io/actions/flyway-migrate@main";
      backend = "tatara-lisp";
      role = "Run flyway migrate.";
    };
    "prisma-migrate" = {
      uses = "pleme-io/actions/prisma-migrate@main";
      backend = "tatara-lisp";
      role = "Run prisma migrate deploy.";
    };
    "sqitch-deploy" = {
      uses = "pleme-io/actions/sqitch-deploy@main";
      backend = "tatara-lisp";
      role = "Run sqitch deploy.";
    };
  };
  devx = {
    "devcontainer-build" = {
      uses = "pleme-io/actions/devcontainer-build@main";
      backend = "tatara-lisp";
      role = "Build a devcontainer image via @devcontainers/cli.";
    };
    "pre-commit-run" = {
      uses = "pleme-io/actions/pre-commit-run@main";
      backend = "tatara-lisp";
      role = "Run pre-commit on all files.";
    };
  };
  dispatch = {
    "caixa-detect" = {
      uses = "pleme-io/actions/caixa-detect@main";
      backend = "tatara-lisp";
      role = "Find caixa.tlisp (or any .tlisp file containing (defcaixa ...)) at repo root. Emits the file path + the caixa kind (Biblioteca | Binario | Servico | Supervisor | Aplicacao).";
    };
    "detect-repo-type" = {
      uses = "pleme-io/actions/detect-repo-type@main";
      backend = "tatara-lisp";
      role = "Auto-detect the repo type from manifest file presence at the root. Emits a typed identifier (rust-workspace / rust-single-crate / npm / python / helm / ansible-collection / ruby-gem / github-action / unknown) that downstream jobs route on.";
    };
  };
  docs = {
    "api-spec-diff" = {
      uses = "pleme-io/actions/api-spec-diff@main";
      backend = "tatara-lisp";
      role = "Detect breaking changes in an OpenAPI / GraphQL / gRPC spec between base + head refs. Useful PR-time gate for API surface stability.";
    };
    "changelog-generate" = {
      uses = "pleme-io/actions/changelog-generate@main";
      backend = "tatara-lisp";
      role = "Generate a CHANGELOG.md (or fragment) from git log since a base ref. Universal primitive — language-agnostic, used by every release flow that wants typed changelogs.";
    };
    "docs-publish" = {
      uses = "pleme-io/actions/docs-publish@main";
      backend = "tatara-lisp";
      role = "Polymorphic doc generation + deploy to GitHub Pages. Detects repo type + routes to cargo doc / mkdocs / typedoc. The third compounding leg of the publish-side primitives (release + sbom + docs).";
    };
    "docusaurus-build" = {
      uses = "pleme-io/actions/docusaurus-build@main";
      backend = "tatara-lisp";
      role = "Build a Docusaurus site.";
    };
    "hugo-build" = {
      uses = "pleme-io/actions/hugo-build@main";
      backend = "tatara-lisp";
      role = "Build a Hugo site.";
    };
    "mdbook-build" = {
      uses = "pleme-io/actions/mdbook-build@main";
      backend = "tatara-lisp";
      role = "Build an mdBook.";
    };
    "mkdocs-build" = {
      uses = "pleme-io/actions/mkdocs-build@main";
      backend = "tatara-lisp";
      role = "Build mkdocs site.";
    };
    "toc-update" = {
      uses = "pleme-io/actions/toc-update@main";
      backend = "tatara-lisp";
      role = "Auto-update markdown table-of-contents between <!-- toc --> markers. Idempotent — re-runs are no-op when TOC matches headings.";
    };
    "vitepress-build" = {
      uses = "pleme-io/actions/vitepress-build@main";
      backend = "tatara-lisp";
      role = "Build a VitePress site.";
    };
    "zola-build" = {
      uses = "pleme-io/actions/zola-build@main";
      backend = "tatara-lisp";
      role = "Build a Zola site.";
    };
  };
  frontend = {
    "cypress-test" = {
      uses = "pleme-io/actions/cypress-test@main";
      backend = "tatara-lisp";
      role = "Run cypress run.";
    };
    "lighthouse-ci" = {
      uses = "pleme-io/actions/lighthouse-ci@main";
      backend = "tatara-lisp";
      role = "Run Lighthouse CI on a URL list + assert score thresholds.";
    };
    "percy-snapshot" = {
      uses = "pleme-io/actions/percy-snapshot@main";
      backend = "tatara-lisp";
      role = "Capture Percy visual regression snapshots.";
    };
    "playwright-test" = {
      uses = "pleme-io/actions/playwright-test@main";
      backend = "tatara-lisp";
      role = "Run @playwright/test suite.";
    };
    "storybook-deploy" = {
      uses = "pleme-io/actions/storybook-deploy@main";
      backend = "tatara-lisp";
      role = "Build + deploy a Storybook to gh-pages.";
    };
  };
  gh = {
    "derive-version-from-tag" = {
      uses = "pleme-io/actions/derive-version-from-tag@main";
      backend = "tatara-lisp";
      role = "Strip leading \"v\" from a tag ref to derive a SemVer version string";
    };
    "gh-release-create" = {
      uses = "pleme-io/actions/gh-release-create@main";
      backend = "tatara-lisp";
      role = "Create a GitHub Release for a tag with optional auto-generated notes + asset uploads. Universal primitive — any language, any package shape.";
    };
  };
  git = {
    "git-commit-tag" = {
      uses = "pleme-io/actions/git-commit-tag@main";
      backend = "tatara-lisp";
      role = "Configure github-actions bot identity, stage typed paths, commit with a typed message template, and create an annotated tag. Composes with git-push-with-token for the push half.";
    };
    "git-push-with-token" = {
      uses = "pleme-io/actions/git-push-with-token@main";
      backend = "tatara-lisp";
      role = "Rewrite origin URL with the given token, push branch + tags so downstream workflows can be triggered";
    };
  };
  helm = {
    "helm-bump" = {
      uses = "pleme-io/actions/helm-bump@main";
      backend = "tatara-lisp";
      role = "Bump a Helm Chart.yaml version field via in-place yaml-edit. Sibling of cargo-bump for the Helm ecosystem.";
    };
    "helm-oci-publish" = {
      uses = "pleme-io/actions/helm-oci-publish@main";
      backend = "tatara-lisp";
      role = "Lint, package, and push a Helm chart to an OCI registry";
    };
    "helm-publish" = {
      uses = "pleme-io/actions/helm-publish@main";
      backend = "tatara-lisp";
      role = "Publish a Helm chart to an OCI registry (default ghcr.io/pleme-io/helm); skip if (name, version) already exists.";
    };
  };
  hygiene = {
    "branch-protect-sync" = {
      uses = "pleme-io/actions/branch-protect-sync@main";
      backend = "tatara-lisp";
      role = "Apply branch-protection rules from a JSON spec.";
    };
    "codeowners-validate" = {
      uses = "pleme-io/actions/codeowners-validate@main";
      backend = "tatara-lisp";
      role = "Validate .github/CODEOWNERS against repo file tree (catch unowned paths).";
    };
    "gh-team-sync" = {
      uses = "pleme-io/actions/gh-team-sync@main";
      backend = "shell";
      role = "Sync GitHub team membership from a declarative YAML spec via gh api. Source-of-truth for org RBAC.";
    };
    "stale-issue-bot" = {
      uses = "pleme-io/actions/stale-issue-bot@main";
      backend = "tatara-lisp";
      role = "Mark stale issues + close after threshold.";
    };
  };
  iac = {
    "iac-forge" = {
      uses = "pleme-io/actions/iac-forge@main";
      backend = "tatara-lisp";
      role = "Run iac-forge codegen against a spec + provider TOML";
    };
    "pulumi-up" = {
      uses = "pleme-io/actions/pulumi-up@main";
      backend = "tatara-lisp";
      role = "Run pulumi up on a stack.";
    };
    "terraform-apply" = {
      uses = "pleme-io/actions/terraform-apply@main";
      backend = "tatara-lisp";
      role = "Run terraform apply against a previously-generated plan file. Pairs with terraform-plan.";
    };
    "terraform-plan" = {
      uses = "pleme-io/actions/terraform-plan@main";
      backend = "tatara-lisp";
      role = "Run terraform init + plan + emit plan file. Pairs with terraform-apply for the GitOps split-flow.";
    };
  };
  k8s = {
    "argocd-sync" = {
      uses = "pleme-io/actions/argocd-sync@main";
      backend = "tatara-lisp";
      role = "Trigger argocd app sync + wait for Healthy/Synced. Sibling of flux-reconcile.";
    };
    "flux-reconcile" = {
      uses = "pleme-io/actions/flux-reconcile@main";
      backend = "tatara-lisp";
      role = "Trigger FluxCD reconcile on a HelmRelease / Kustomization / GitRepository / OCIRepository. Useful in CD pipelines that want to force-converge after a release lands.";
    };
    "helm-deploy" = {
      uses = "pleme-io/actions/helm-deploy@main";
      backend = "tatara-lisp";
      role = "helm upgrade --install with --wait. Sibling of helm-publish — this is for in-cluster installation, not registry push.";
    };
    "helmfile-apply" = {
      uses = "pleme-io/actions/helmfile-apply@main";
      backend = "tatara-lisp";
      role = "Run helmfile apply.";
    };
    "k8s-rollout-wait" = {
      uses = "pleme-io/actions/k8s-rollout-wait@main";
      backend = "tatara-lisp";
      role = "Wait for a single k8s rollout to converge. Sibling of kubectl-apply (which applies + waits on detected resources); this targets a single named resource for finer-grained gating.";
    };
    "kubectl-apply" = {
      uses = "pleme-io/actions/kubectl-apply@main";
      backend = "tatara-lisp";
      role = "Apply k8s manifests + wait for rollout. Universal — works with any kubectl-reachable cluster.";
    };
    "kustomize-render" = {
      uses = "pleme-io/actions/kustomize-render@main";
      backend = "tatara-lisp";
      role = "kustomize build → emit rendered manifests. Optional in-place commit to a target branch for GitOps workflows.";
    };
    "tanka-apply" = {
      uses = "pleme-io/actions/tanka-apply@main";
      backend = "tatara-lisp";
      role = "Run tk apply on a Tanka environment.";
    };
    "velero-backup" = {
      uses = "pleme-io/actions/velero-backup@main";
      backend = "tatara-lisp";
      role = "Run velero backup create.";
    };
  };
  language = {
    "dotnet-publish" = {
      uses = "pleme-io/actions/dotnet-publish@main";
      backend = "tatara-lisp";
      role = "dotnet publish + push to NuGet.";
    };
    "go-build" = {
      uses = "pleme-io/actions/go-build@main";
      backend = "tatara-lisp";
      role = "Build Go binaries with go build.";
    };
    "go-test" = {
      uses = "pleme-io/actions/go-test@main";
      backend = "tatara-lisp";
      role = "Run go test with coverage.";
    };
    "golangci-lint" = {
      uses = "pleme-io/actions/golangci-lint@main";
      backend = "tatara-lisp";
      role = "Run golangci-lint with configurable preset.";
    };
    "goreleaser" = {
      uses = "pleme-io/actions/goreleaser@main";
      backend = "tatara-lisp";
      role = "Run goreleaser to publish Go binaries to GH Releases.";
    };
    "gradle-build" = {
      uses = "pleme-io/actions/gradle-build@main";
      backend = "tatara-lisp";
      role = "Build a Gradle project (Java/Kotlin/Scala).";
    };
    "hex-publish" = {
      uses = "pleme-io/actions/hex-publish@main";
      backend = "tatara-lisp";
      role = "Publish an Elixir package to hex.pm.";
    };
    "maven-build" = {
      uses = "pleme-io/actions/maven-build@main";
      backend = "tatara-lisp";
      role = "Build a Maven project.";
    };
    "mix-test" = {
      uses = "pleme-io/actions/mix-test@main";
      backend = "tatara-lisp";
      role = "Run mix test on an Elixir project.";
    };
    "swift-build" = {
      uses = "pleme-io/actions/swift-build@main";
      backend = "tatara-lisp";
      role = "Run swift build on a Swift package.";
    };
    "wasm-build" = {
      uses = "pleme-io/actions/wasm-build@main";
      backend = "shell";
      role = "Build a Rust crate to wasm32 (wasm32-unknown-unknown / wasm32-wasi). Universal — wraps cargo + wasm-pack when needed.";
    };
    "xcodebuild" = {
      uses = "pleme-io/actions/xcodebuild@main";
      backend = "tatara-lisp";
      role = "Build an Xcode project/workspace.";
    };
    "zig-test" = {
      uses = "pleme-io/actions/zig-test@main";
      backend = "tatara-lisp";
      role = "Run zig build test.";
    };
  };
  messaging = {
    "kafka-publish" = {
      uses = "pleme-io/actions/kafka-publish@main";
      backend = "tatara-lisp";
      role = "Publish a message to a Kafka topic via kcat.";
    };
    "nats-publish" = {
      uses = "pleme-io/actions/nats-publish@main";
      backend = "tatara-lisp";
      role = "Publish a message to a NATS subject via natscli.";
    };
  };
  meta = {
    "action-shell-lint" = {
      uses = "pleme-io/actions/action-shell-lint@main";
      backend = "tatara-lisp";
      role = "Enforce the ★★ NO-SHELL directive on pleme-io/actions/* — scans every action.yml + counts shell-line bodies outside the canonical loader; rejects PRs that exceed threshold.";
    };
    "adoption-audit" = {
      uses = "pleme-io/actions/adoption-audit@main";
      backend = "tatara-lisp";
      role = "Scan a GH org for AUTO-RELEASE directive adoption — counts repos with/without the canonical 3-workflow surface. Emits a markdown report + sets typed outputs. Runs cheap on free public CI.";
    };
    "defaction-render" = {
      uses = "pleme-io/actions/defaction-render@main";
      backend = "shell";
      role = "Render a typed (defaction ...) or (defworkflow ...) .lisp source into the action triple (action.yml + run.tlisp + README.md) or workflow yaml. The Pillar 12 (generation over composition) primitive at the CI layer.";
    };
  };
  mobile = {
    "app-store-connect" = {
      uses = "pleme-io/actions/app-store-connect@main";
      backend = "tatara-lisp";
      role = "Upload an iOS build to App Store Connect via altool.";
    };
    "eas-build" = {
      uses = "pleme-io/actions/eas-build@main";
      backend = "tatara-lisp";
      role = "Run expo eas build for iOS/Android.";
    };
    "fastlane-deploy" = {
      uses = "pleme-io/actions/fastlane-deploy@main";
      backend = "tatara-lisp";
      role = "Run a fastlane lane to deploy iOS/Android build.";
    };
    "flutter-build" = {
      uses = "pleme-io/actions/flutter-build@main";
      backend = "tatara-lisp";
      role = "Build a Flutter app for a target.";
    };
  };
  networking = {
    "tailscale-auth" = {
      uses = "pleme-io/actions/tailscale-auth@main";
      backend = "tatara-lisp";
      role = "Authenticate runner with Tailscale via OAuth or auth-key.";
    };
    "wireguard-up" = {
      uses = "pleme-io/actions/wireguard-up@main";
      backend = "tatara-lisp";
      role = "Bring up a WireGuard tunnel for ephemeral runner access.";
    };
  };
  nix = {
    "nix-attic-push" = {
      uses = "pleme-io/actions/nix-attic-push@main";
      backend = "tatara-lisp";
      role = "Push a built nix path to an Attic binary cache.";
    };
    "nix-build" = {
      uses = "pleme-io/actions/nix-build@main";
      backend = "tatara-lisp";
      role = "Build a flake output (universal). Optionally pushes to cachix/attic afterward.";
    };
    "nix-cachix-push" = {
      uses = "pleme-io/actions/nix-cachix-push@main";
      backend = "tatara-lisp";
      role = "Push a built nix path to a Cachix binary cache.";
    };
  };
  npm = {
    "npm-bump" = {
      uses = "pleme-io/actions/npm-bump@main";
      backend = "tatara-lisp";
      role = "Bump an npm package.json version via `npm version --no-git-tag-version <type>`, refresh package-lock.json. Sibling of cargo-bump for the npm ecosystem.";
    };
    "npm-publish" = {
      uses = "pleme-io/actions/npm-publish@main";
      backend = "tatara-lisp";
      role = "Publish an npm package to npmjs.org; skip if (name, version) already exists; auto-rename to @pleme-io/<original> on name conflict.";
    };
  };
  observability = {
    "datadog-event" = {
      uses = "pleme-io/actions/datadog-event@main";
      backend = "tatara-lisp";
      role = "Post a typed event to Datadog Events API. Universal for release markers, deploy events, alert correlations.";
    };
    "grafana-annotation" = {
      uses = "pleme-io/actions/grafana-annotation@main";
      backend = "tatara-lisp";
      role = "Create a Grafana annotation (release marker, deploy event, incident note). Visible on every dashboard that overlaps the time range.";
    };
    "honeycomb-marker" = {
      uses = "pleme-io/actions/honeycomb-marker@main";
      backend = "tatara-lisp";
      role = "Add a Honeycomb marker (release/deploy correlation).";
    };
    "loki-log-push" = {
      uses = "pleme-io/actions/loki-log-push@main";
      backend = "tatara-lisp";
      role = "Push a batch of log lines to a Loki ingester.";
    };
    "otel-collector-deploy" = {
      uses = "pleme-io/actions/otel-collector-deploy@main";
      backend = "tatara-lisp";
      role = "Deploy an OpenTelemetry Collector config to a k8s ConfigMap.";
    };
    "prometheus-push" = {
      uses = "pleme-io/actions/prometheus-push@main";
      backend = "tatara-lisp";
      role = "Push metrics to a Prometheus pushgateway. Useful for emitting deploy/release counters from CI.";
    };
    "pyroscope-push" = {
      uses = "pleme-io/actions/pyroscope-push@main";
      backend = "tatara-lisp";
      role = "Push a profiling sample to a Pyroscope server.";
    };
    "sentry-release" = {
      uses = "pleme-io/actions/sentry-release@main";
      backend = "tatara-lisp";
      role = "Create a Sentry release + associate commits.";
    };
  };
  publish = {
    "rust-workspace-publish" = {
      uses = "pleme-io/actions/rust-workspace-publish@main";
      backend = "tatara-lisp";
      role = "Ship every workspace member to the Rust registry in topological dependency order. Auto-renames any conflicting crate to pleme-io-<original> + commits the rename back to main + retries. Pure tlisp logic, no shell beyond install glue.";
    };
  };
  python = {
    "python-bump" = {
      uses = "pleme-io/actions/python-bump@main";
      backend = "tatara-lisp";
      role = "Bump a Python pyproject.toml version field via uv version --bump. Sibling of cargo-bump for the Python ecosystem.";
    };
    "python-publish" = {
      uses = "pleme-io/actions/python-publish@main";
      backend = "tatara-lisp";
      role = "Publish a Python package to pypi.org via uv publish; skip if (name, version) already exists; sleep + retry on rate limit.";
    };
  };
  quality = {
    "benchmark-runner" = {
      uses = "pleme-io/actions/benchmark-runner@main";
      backend = "shell";
      role = "Polymorphic benchmark runner — criterion for Rust, pytest-benchmark for Python. Pushes results to a benches branch for trend tracking.";
    };
    "mutation-test" = {
      uses = "pleme-io/actions/mutation-test@main";
      backend = "tatara-lisp";
      role = "Polymorphic mutation testing — cargo-mutants for Rust, stryker for npm/python. Surface real test gaps the regular test-gate doesn''t catch.";
    };
    "pa11y-ci" = {
      uses = "pleme-io/actions/pa11y-ci@main";
      backend = "tatara-lisp";
      role = "Run pa11y-ci accessibility scan.";
    };
    "sonarqube-scan" = {
      uses = "pleme-io/actions/sonarqube-scan@main";
      backend = "tatara-lisp";
      role = "Run SonarQube/SonarCloud scan + push results.";
    };
  };
  release-mgmt = {
    "changesets" = {
      uses = "pleme-io/actions/changesets@main";
      backend = "tatara-lisp";
      role = "Run npm/changesets version + publish flow.";
    };
    "release-please" = {
      uses = "pleme-io/actions/release-please@main";
      backend = "tatara-lisp";
      role = "Run google/release-please-action.";
    };
    "release-promote" = {
      uses = "pleme-io/actions/release-promote@main";
      backend = "tatara-lisp";
      role = "Promote a built artifact between environments (dev → staging → prod). Re-tags an existing image/version rather than rebuilding — ensures bit-identical artifact at each stage.";
    };
    "semantic-release" = {
      uses = "pleme-io/actions/semantic-release@main";
      backend = "tatara-lisp";
      role = "Run semantic-release (conventional-commits → version).";
    };
    "yank-version" = {
      uses = "pleme-io/actions/yank-version@main";
      backend = "tatara-lisp";
      role = "Polymorphic yank/unpublish — cargo yank / npm deprecate / pip remove. Surgical rollback for a single bad version (does NOT delete previous versions).";
    };
  };
  ruby = {
    "gem-publish" = {
      uses = "pleme-io/actions/gem-publish@main";
      backend = "tatara-lisp";
      role = "Build & push a Ruby gem to RubyGems.org, tolerating identical-version re-pushes";
    };
  };
  runtime = {
    "tatara-script" = {
      uses = "pleme-io/actions/tatara-script@main";
      backend = "shell";
      role = "Execute an embedded .tlisp source string with tatara-script (binary-first, cargo-install fallback)";
    };
  };
  rust = {
    "cargo-bump" = {
      uses = "pleme-io/actions/cargo-bump@main";
      backend = "tatara-lisp";
      role = "Bump a single-crate Rust repo via cargo set-version --bump <type>, regenerate Cargo.nix, refresh Cargo.lock. Sibling of rust-workspace-bump for non-workspace Rust repos.";
    };
    "cargo-publish-crate" = {
      uses = "pleme-io/actions/cargo-publish-crate@main";
      backend = "tatara-lisp";
      role = "Publish a single Rust crate to crates.io; skips if (name, version) already exists; sleeps + retries on 429 rate-limit. Sibling of rust-workspace-publish for non-workspace Rust repos.";
    };
  };
  sdlc = {
    "dependabot-trigger" = {
      uses = "pleme-io/actions/dependabot-trigger@main";
      backend = "tatara-lisp";
      role = "Trigger Dependabot to re-evaluate dependency updates via gh api.";
    };
    "dependency-update" = {
      uses = "pleme-io/actions/dependency-update@main";
      backend = "tatara-lisp";
      role = "Polymorphic dependency lock refresh + open PR if anything changed. Detects ecosystem (rust → cargo update; npm → npm update; python → uv lock --upgrade; nix → nix flake update). Idempotent — exits 0 with no PR when nothing to update.";
    };
    "issue-create" = {
      uses = "pleme-io/actions/issue-create@main";
      backend = "tatara-lisp";
      role = "Create (or reuse) a GitHub issue for a typed event. Useful for workflow auto-reporting (test failures, broken deps, drift, etc.). Idempotent via title-match deduplication.";
    };
    "nix-flake-update" = {
      uses = "pleme-io/actions/nix-flake-update@main";
      backend = "tatara-lisp";
      role = "Run `nix flake update` + open PR if flake.lock changed. Idempotent — exits 0 with no PR when lock is current. Specific case of dependency-update for nix-only repos.";
    };
    "onboard-auto-release" = {
      uses = "pleme-io/actions/onboard-auto-release@main";
      backend = "tatara-lisp";
      role = "Scaffold the canonical 3-workflow pleme-io auto-release surface into a repo (auto-release.yml + pre-merge-gate.yml + security-gate.yml). Idempotent — skips files that already exist unless --force is set.";
    };
    "pr-comment" = {
      uses = "pleme-io/actions/pr-comment@main";
      backend = "tatara-lisp";
      role = "Post or update a comment on a pull request. Idempotent via a magic marker — re-running updates the existing comment instead of spamming.";
    };
    "status-badge" = {
      uses = "pleme-io/actions/status-badge@main";
      backend = "tatara-lisp";
      role = "Generate an SVG status badge (shields.io-style) for a label/value pair. Universal — used to render build/test/coverage/version badges into a repo or a static site.";
    };
  };
  security = {
    "bandit" = {
      uses = "pleme-io/actions/bandit@main";
      backend = "tatara-lisp";
      role = "Run bandit Python security scan.";
    };
    "checkov" = {
      uses = "pleme-io/actions/checkov@main";
      backend = "tatara-lisp";
      role = "Run checkov IaC security scan.";
    };
    "conftest" = {
      uses = "pleme-io/actions/conftest@main";
      backend = "tatara-lisp";
      role = "Run conftest OPA-based policy check.";
    };
    "cosign-verify" = {
      uses = "pleme-io/actions/cosign-verify@main";
      backend = "tatara-lisp";
      role = "Verify a cosign signature on an artifact or image.";
    };
    "cyclonedx-merge" = {
      uses = "pleme-io/actions/cyclonedx-merge@main";
      backend = "tatara-lisp";
      role = "Merge multiple CycloneDX SBOMs into a single combined doc.";
    };
    "gh-secrets-sync" = {
      uses = "pleme-io/actions/gh-secrets-sync@main";
      backend = "tatara-lisp";
      role = "Sync GitHub repo/org/env secrets from a typed YAML spec (encrypted).";
    };
    "gosec" = {
      uses = "pleme-io/actions/gosec@main";
      backend = "tatara-lisp";
      role = "Run gosec Go security scan.";
    };
    "image-scan" = {
      uses = "pleme-io/actions/image-scan@main";
      backend = "tatara-lisp";
      role = "Scan a container image for vulnerabilities + secrets via Trivy. Emits typed severity + vuln-count outputs. Configurable fail-on-severity gate.";
    };
    "kics-scan" = {
      uses = "pleme-io/actions/kics-scan@main";
      backend = "tatara-lisp";
      role = "Run KICS IaC security scan.";
    };
    "license-finder" = {
      uses = "pleme-io/actions/license-finder@main";
      backend = "tatara-lisp";
      role = "Scan dependencies for license compatibility via license_finder.";
    };
    "license-header-check" = {
      uses = "pleme-io/actions/license-header-check@main";
      backend = "tatara-lisp";
      role = "Verify every source file has a typed SPDX-License-Identifier header. Universal — works on any source tree; configurable extensions + license set.";
    };
    "provenance-attest" = {
      uses = "pleme-io/actions/provenance-attest@main";
      backend = "tatara-lisp";
      role = "Sign artifacts with sigstore/cosign keyless OIDC. Universal — works on any file (binary, tarball, SBOM, container image digest). Produces a .sig + .cert pair downstream consumers can verify with cosign verify-blob.";
    };
    "sbom-generate" = {
      uses = "pleme-io/actions/sbom-generate@main";
      backend = "tatara-lisp";
      role = "Generate a CycloneDX or SPDX SBOM from the repo via syft. Universal — works on any source tree (Rust, Node, Python, Helm, Docker context, etc).";
    };
    "secrets-scan" = {
      uses = "pleme-io/actions/secrets-scan@main";
      backend = "tatara-lisp";
      role = "gitleaks-based secret scan across the repo. Emits typed finding count + severity. Configurable fail-on-found gate.";
    };
    "security-audit" = {
      uses = "pleme-io/actions/security-audit@main";
      backend = "tatara-lisp";
      role = "Polymorphic dependency-vulnerability audit. Detects repo type + routes to cargo-audit / npm-audit / pip-audit / etc. Emits a typed severity summary.";
    };
    "slsa-attest" = {
      uses = "pleme-io/actions/slsa-attest@main";
      backend = "tatara-lisp";
      role = "Generate SLSA provenance attestation for a build artifact (Level 3 via in-toto).";
    };
    "snyk-test" = {
      uses = "pleme-io/actions/snyk-test@main";
      backend = "tatara-lisp";
      role = "Snyk dependency vulnerability scan with severity gate.";
    };
    "tfsec" = {
      uses = "pleme-io/actions/tfsec@main";
      backend = "tatara-lisp";
      role = "Run tfsec on Terraform code.";
    };
    "vault-fetch" = {
      uses = "pleme-io/actions/vault-fetch@main";
      backend = "tatara-lisp";
      role = "Fetch a secret from HashiCorp Vault via JWT-OIDC auth.";
    };
  };
  spec = {
    "spec-watch" = {
      uses = "pleme-io/actions/spec-watch@main";
      backend = "tatara-lisp";
      role = "Detect changes in an upstream OpenAPI/JSON spec by sha256 against a cached value";
    };
  };
  storage = {
    "artifact-fetch" = {
      uses = "pleme-io/actions/artifact-fetch@main";
      backend = "tatara-lisp";
      role = "Fetch an artifact from a previous workflow run (cross-workflow handoff).";
    };
    "gcs-sync" = {
      uses = "pleme-io/actions/gcs-sync@main";
      backend = "tatara-lisp";
      role = "Sync a local directory to GCS via gsutil rsync.";
    };
    "s3-mirror" = {
      uses = "pleme-io/actions/s3-mirror@main";
      backend = "tatara-lisp";
      role = "Mirror a local directory tree to S3 with --delete semantics (aws s3 sync).";
    };
  };
  uncategorized = {
    "codeql-scan" = {
      uses = "pleme-io/actions/codeql-scan@main";
      backend = "shell";
      role = "GitHub CodeQL SAST scan. Polymorphic — auto-detects language; uploads SARIF to GitHub Code Scanning.";
    };
    "coverage-upload" = {
      uses = "pleme-io/actions/coverage-upload@main";
      backend = "tatara-lisp";
      role = "Generate test coverage + upload to Codecov. Polymorphic — detects ecosystem (rust uses cargo-tarpaulin, npm uses jest --coverage, python uses pytest --cov).";
    };
    "k6-load-test" = {
      uses = "pleme-io/actions/k6-load-test@main";
      backend = "tatara-lisp";
      role = "Run a k6 load test script + emit summary JSON. Pairs with thresholds for PR-time perf regression gating.";
    };
    "onepassword-fetch" = {
      uses = "pleme-io/actions/onepassword-fetch@main";
      backend = "shell";
      role = "Fetch a secret from 1Password via Service Account token. Sibling of akeyless-secret-fetch.";
    };
    "semgrep-scan" = {
      uses = "pleme-io/actions/semgrep-scan@main";
      backend = "tatara-lisp";
      role = "Semgrep SAST scan with configurable rule set.";
    };
  };
  validation = {
    "nix-flake-check" = {
      uses = "pleme-io/actions/nix-flake-check@main";
      backend = "tatara-lisp";
      role = "Run `nix flake check` with DeterminateSystems Nix";
    };
    "npm-gate" = {
      uses = "pleme-io/actions/npm-gate@main";
      backend = "tatara-lisp";
      role = "PR-time quality gate for an npm repo: prettier --check + eslint + npm test (each conditionally run based on script presence in package.json).";
    };
    "python-gate" = {
      uses = "pleme-io/actions/python-gate@main";
      backend = "tatara-lisp";
      role = "PR-time quality gate for a Python repo: ruff format --check + ruff check + pytest. Universal across uv/poetry/hatch layouts.";
    };
    "rust-gate" = {
      uses = "pleme-io/actions/rust-gate@main";
      backend = "tatara-lisp";
      role = "PR-time quality gate for a Rust repo: cargo fmt --check + cargo clippy + cargo test. Universal for both workspace + single-crate shapes.";
    };
    "tlisp-lint" = {
      uses = "pleme-io/actions/tlisp-lint@main";
      backend = "tatara-lisp";
      role = "Validate every *.tlisp file under the repo: balanced parens, balanced strings, balanced comments, and (when tatara-script is installed) a parser-level dry-run. Catches the parse-error class of bug at PR time instead of after-tag.";
    };
    "typecheck-gate" = {
      uses = "pleme-io/actions/typecheck-gate@main";
      backend = "tatara-lisp";
      role = "Polymorphic typecheck gate — runs cargo check / tsc --noEmit / mypy based on repo type. Faster than the full test-gate when you just want type validity.";
    };
  };
  workflow = {
    "airflow-trigger" = {
      uses = "pleme-io/actions/airflow-trigger@main";
      backend = "tatara-lisp";
      role = "Trigger an Airflow DAG via REST API.";
    };
    "temporal-trigger" = {
      uses = "pleme-io/actions/temporal-trigger@main";
      backend = "tatara-lisp";
      role = "Start a Temporal workflow via tctl/temporal CLI.";
    };
  };
}
