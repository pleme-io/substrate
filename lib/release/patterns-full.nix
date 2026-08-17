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
    "caixa-deps-resolve" = {
      uses = "pleme-io/actions/caixa-deps-resolve@main";
      backend = "tatara-lisp";
      role = "Resolve :depends-on entries in a caixa.lisp to actual git checkouts at the requested ref. Materializes git-as-package-repo for caixa.";
    };
    "caixa-publish" = {
      uses = "pleme-io/actions/caixa-publish@main";
      backend = "shell";
      role = "Publish caixa-rendered Helm chart to an OCI registry. Wraps helm-publish but consumes the caixa-render output dir.";
    };
    "caixa-publish-to-git" = {
      uses = "pleme-io/actions/caixa-publish-to-git@main";
      backend = "tatara-lisp";
      role = "Tag the current commit with the caixa.lisp :version field — turns the repo into a git-as-package-repo that downstream caixas can :depends-on by tag.";
    };
    "caixa-render" = {
      uses = "pleme-io/actions/caixa-render@main";
      backend = "shell";
      role = "Render cluster artifacts (Helm chart + Kubernetes manifests + Flux + CI workflows) from a (defcaixa ...) form via the `feira` CLI.";
    };
    "caixa-render-pr" = {
      uses = "pleme-io/actions/caixa-render-pr@main";
      backend = "tatara-lisp";
      role = "Render every .caixa.lisp at the repo root via pleme-doc-gen + open a PR if the rendered artifacts drift from on-disk files. The META-PRIMITIVE that closes the typed-source → mechanical-render → PR loop without operator intervention.";
    };
  };
  cloud = {
    "aws-assume-role" = {
      uses = "pleme-io/actions/aws-assume-role@main";
      backend = "shell";
      role = "Assume an AWS IAM role via OIDC (no long-lived creds). Exports AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY + AWS_SESSION_TOKEN to subsequent steps.";
    };
    "aws-cost-report" = {
      uses = "pleme-io/actions/aws-cost-report@main";
      backend = "tatara-lisp";
      role = "Pull last-month AWS cost via Cost Explorer.";
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
    "cloudflare-cache-purge" = {
      uses = "pleme-io/actions/cloudflare-cache-purge@main";
      backend = "tatara-lisp";
      role = "Purge Cloudflare cache for zone or URLs.";
    };
    "cloudflare-d1-migrate" = {
      uses = "pleme-io/actions/cloudflare-d1-migrate@main";
      backend = "tatara-lisp";
      role = "Run a D1 schema migration via wrangler d1 migrations apply.";
    };
    "cloudflare-d1-query" = {
      uses = "pleme-io/actions/cloudflare-d1-query@main";
      backend = "tatara-lisp";
      role = "Execute SQL against a Cloudflare D1 database.";
    };
    "cloudflare-do-list" = {
      uses = "pleme-io/actions/cloudflare-do-list@main";
      backend = "tatara-lisp";
      role = "List Durable Object instances by namespace.";
    };
    "cloudflare-kv-get" = {
      uses = "pleme-io/actions/cloudflare-kv-get@main";
      backend = "tatara-lisp";
      role = "Get a value from Workers KV.";
    };
    "cloudflare-kv-put" = {
      uses = "pleme-io/actions/cloudflare-kv-put@main";
      backend = "tatara-lisp";
      role = "Put a key/value into a Workers KV namespace.";
    };
    "cloudflare-pages-deploy" = {
      uses = "pleme-io/actions/cloudflare-pages-deploy@main";
      backend = "shell";
      role = "Deploy a static build dir to Cloudflare Pages via wrangler. Universal — works with any output dir (Vite, mkdocs, cargo doc, hand-built static).";
    };
    "cloudflare-queue-publish" = {
      uses = "pleme-io/actions/cloudflare-queue-publish@main";
      backend = "tatara-lisp";
      role = "Publish a message to a Cloudflare Queue.";
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
    "twilio-voice-call" = {
      uses = "pleme-io/actions/twilio-voice-call@main";
      backend = "tatara-lisp";
      role = "Trigger a Twilio voice call via API for ops alerts.";
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
      role = "Push an OCI image tarball (Nix dockerTools output) to a registry via doca (pure-Rust OCI push, retry-on-transient)";
    };
    "podman-build" = {
      uses = "pleme-io/actions/podman-build@main";
      backend = "tatara-lisp";
      role = "Build a container image with podman (rootless, daemonless alternative to docker).";
    };
    # ── RETIRING THE ACTIONS DID NOT RETIRE THE BINARY ──────────────────────
    # The two entries below are honestly measured and honestly worded, and put
    # together they still mislead: they retire the two *actions*, and a reader
    # scanning this catalog reasonably concludes skopeo is gone from the fleet.
    # It is not. Measured 2026-08-01 across 951 pleme-io repos: SIXTEEN live
    # `${pkgs.skopeo}/bin/skopeo copy` invocations in NINE files across five
    # repos, none an action and none visible to this catalog —
    #
    #   aresta/flake.nix (1) · blackmatter-akeyless/flake.nix (1) ·
    #   enxerto/flake.nix (1) · infrastructure/github-runner/…/flake.nix (3) ·
    #   pangea-architectures/services/akeyless-{sra,csi-provider,ztwa,gateway,
    #     secrets-injection}-image/flake.nix (2 each = 10)
    #
    # An earlier revision of this paragraph said ELEVEN and called the five
    # pangea files "byte-identical". Both were wrong — they carry two copies
    # each, not one. Left visible rather than silently rewritten, because the
    # correction below is about exactly this failure mode.
    #
    # ── CORRECTED 2026-08-01, SAME DAY: "eleven, ONE class" was wrong twice ──
    # The real figures, from reading all nine files rather than two: SIXTEEN
    # executable `skopeo copy` invocations across NINE files in FIVE repos.
    # (28 raw occurrences fleet-wide; the other 12 are prose in this catalog,
    # hardened-images, substrate and tatara-infra. Control: `doca` returns 270
    # on the same probe, so the count is real and not a dead grep.)
    #
    # And they are FOUR conversion classes, not one. This matters because the
    # original note said "just use the primitive", and that is false for three
    # of the four:
    #
    #   1. GHCR, no auth      aresta, enxerto            --insecure-policy
    #   2. private + creds    blackmatter-akeyless       --dest-creds
    #   3. runner, w/ retry   github-runner (x3)         --dest-creds --retry-times
    #   4. Zot, OCI media     pangea-architectures (5x2) --dest-authfile --format oci
    #
    # ── AND THAT CLASS ANALYSIS WAS ALSO WRONG (measured 2026-08-01) ────────
    # The paragraph above said only class 1 was convertible, that class 4's
    # `--format oci` had no doca equivalent, and that converting it "would
    # change the media types of five live images". EVERY PART OF THAT IS FALSE.
    # Read from `tools/oci-push/src/main.rs`, not inferred:
    #
    #   --format oci    doca emits OCI media types UNCONDITIONALLY. Lines 74-76:
    #                   MT_CONFIG/MT_LAYER_GZIP/MT_MANIFEST are all
    #                   application/vnd.oci.image.*, and there are ZERO
    #                   `vnd.docker.distribution.manifest` emission sites — doca
    #                   has no docker-manifest push path to accidentally take.
    #                   skopeo's `--format oci` is therefore a NO-OP equivalent,
    #                   not a missing feature.
    #   --dest-creds    dest-user / dest-pass inputs.
    #   self-signed     dest-ca-cert + insecure (wired through `with:` 2026-07-29).
    #   --retry-times   push_with_retry: 5 attempts, backoff 1s/2s/4s/8s, and the
    #                   source says 5 was chosen to MATCH the skopeo call site it
    #                   replaces. Strictly better than skopeo's: it retries only
    #                   TRANSIENT failures, so a 401 or a malformed archive fails
    #                   fast instead of burning the budget with backoff.
    #
    # ── CLASS 4's TARGET DOES NOT SERVE A REGISTRY TODAY (2026-08-02) ──────
    # Before threading a CA path, probe the endpoint. All 10 class-4
    # invocations push to ONE host -- `zot.alpha.1.k8s.quero.lol`, 15 textual
    # references across the five flakes -- and it does not answer as a registry:
    #
    #   DNS      CNAME -> pixie.porkbun.com -> 207.207.210.229
    #   TLS      curl: (60) SSL: no alternative certificate subject name
    #            matches target hostname 'zot.alpha.1.k8s.quero.lol'
    #   -k       HTTP 301 from openresty -- a generic ingress redirect, not a
    #            /v2/ registry response
    #
    # CONTROL, AND IT CHANGED THE CONCLUSION: `grafana.quero.cloud` -- known
    # live -- resolves to the SAME CNAME and the SAME IP. So pixie.porkbun.com
    # is this fleet's shared ingress, NOT a parking page, and "the domain is
    # dead" would have been wrong. What is true is narrower: the ingress has no
    # cert covering this hostname and returns a generic 301 rather than a
    # registry, so nothing is serving a Zot there right now.
    #
    # CONSEQUENCE FOR THE MIGRATION: the class-4 TLS question is unanswerable
    # while the endpoint does not serve TLS for its own name. Whether doca needs
    # --dest-ca-cert depends on what cert a RESTORED Zot presents, and that is
    # not knowable from a 301. Converting these ten now would be writing
    # untestable code against a host that cannot accept a push from skopeo
    # either.
    #
    # So class 4 is not blocked on doca and not blocked on a CA path -- it is
    # blocked on an endpoint. `pending-class4-endpoint: zot.alpha.1.k8s.quero.lol
    #  serves a 301, not /v2/. Establish whether it is retired, moved, or
    #  unprovisioned before converting the ten call sites that target it.`
    #
    # ── CLASS 4 IS NOT A DROP-IN — TLS TRUST DIFFERS (measured 2026-08-02) ──
    # "Covered by doca" is true at the FEATURE level and still not a
    # copy-paste conversion, because skopeo and doca trust different roots.
    #
    #   skopeo  uses the SYSTEM trust store. The five pangea-architectures
    #           call sites pass NO ca flag at all, so the Zot's self-signed CA
    #           must already be installed on the host — and it works.
    #   doca    is oci-client with `default-features = false, features =
    #           ["rustls-tls"]` (Cargo.toml) — webpki COMPILED-IN roots. Its
    #           `ca_cert_path` builds `extra_root_certificates`, EXTRA on top
    #           of that set, and the code comment says so explicitly: "pinning
    #           a self-signed in-cluster cert". There is no system-store read.
    #
    # So converting class 4 by deleting the skopeo flags would leave doca
    # unable to verify the Zot at all — five LIVE images failing on TLS, from
    # a change that looks like pure simplification. `--dest-authfile` genuinely
    # does map to nothing (doca reads $HOME/.docker/config.json ambiently,
    # runner-verified), and `--format oci` genuinely maps to nothing (doca is
    # OCI-only). Two of the three flags vanish and the third is load-bearing —
    # which is the worst possible mix, because the first two teach you the
    # pattern that breaks on the third.
    #
    # The correct conversion threads a CA path, exactly as the already-working
    # doca consumers do: camelot-hardened-images.yml passes
    # `dest-ca-cert: /usr/local/share/ca-certificates/zot-camelot.crt`, and
    # actions/zot-pull-scan exposes src-ca-cert/dest-ca-cert for this reason.
    # pangea-architectures' flakes have no such path today; supplying one is
    # real work, not a flag rename.
    #
    # GENERAL RULE this is the second instance of: a flag that exists on the
    # OLD tool and not the NEW one means one of two OPPOSITE things — the new
    # tool does it unconditionally (--format oci), or the new tool does not do
    # it at all (--dest-authfile's system-store cousin). Absence of a knob is
    # not evidence either way. Read the source; the two look identical from the
    # call site.
    #
    # So all four classes are covered by doca TODAY. The remaining work is
    # mechanical conversion of 16 call sites, not a doca enhancement, and the
    # `Backend::Skopeo` fallback was already deleted 2026-07-31.
    #
    # THREE CONSECUTIVE REVISIONS OF THIS NOTE WERE WRONG, and the direction
    # flipped each time: under-count (11 for 16), then over-generalise (one
    # class for four), then over-caution (four blockers for zero). The constant
    # was reasoning about a tool from the SHAPE OF THE CALL SITE rather than
    # from the tool's source. A skopeo flag existing does not imply doca needs
    # a matching flag — it may already do that thing unconditionally, which is
    # exactly what `--format oci` turned out to be. Read the replacement's
    # source before pricing the replacement.
    #
    # WHY THE FIRST COUNT WAS WRONG, because the mechanism recurs: the original
    # figure came from counting matching grep LINES, then reading two files and
    # generalising the shape to the rest. Grouping by SYMPTOM ("they all call
    # skopeo copy") silently asserts a shared FIX, which is a different and much
    # stronger claim than a shared symptom. Both errors ran the same direction —
    # under-count, over-generalise — and neither would have been caught by
    # re-running the grep, only by opening every file.
    #
    # `pending-skopeo-callsites: 16 invocations / 9 files / 4 classes.
    #  1 CONVERTED (aresta, class 1, 2026-08-02). No doca enhancement needed,
    #  but conversion is NOT uniformly mechanical: class 4 (10 sites) must
    #  thread a --dest-ca-cert path it does not have today, or five live
    #  images lose the ability to verify the Zot's self-signed cert.`
    #
    # THE DESTINATION ALREADY EXISTS AND IS ALREADY CONVERTED. `lib/service/
    # image-release.nix` (`mkImageReleaseApp`) threads `ociPush` → `DOCA_BIN`;
    # forge's image_release.rs moved off skopeo. So these eleven are not blocked
    # on a missing capability — they hand-roll around a primitive that is
    # already doca-based (Operating Principle #1: use the primitive, don't
    # re-implement its near-miss).
    #
    # HOW THE COUNT WAS NEARLY MISSED, because the trap generalizes: the first
    # probe was `grep -rn --include=*.nix … .` from the pleme-io root and it
    # returned 0 — the recorded org-root gitignore trap. A 0 with no control is
    # indistinguishable from clean, and it was only caught because the same run
    # probed a known-present string and got 0 for THAT too. Per-repo iteration
    # (`for d in */; do grep -r "$d"`) returns 31 mentions / 16 uncommented / 11
    # real. Always pair an absence claim with a positive control that must be
    # non-zero, and never trust a fleet-wide grep issued from the org root.
    #
    # `pending-skopeo-callsites: 11 flake call sites → mkImageReleaseApp.`
    "skopeo-copy" = {
      uses = "pleme-io/actions/skopeo-copy@main";
      backend = "tatara-lisp";
      role = "RETIRED 2026-07-31 — zero consumers fleet-wide, measured with a control (actions/oci-image-push@ returns 3 in substrate, so the probe reads these repos correctly; actions/skopeo-copy@ returns 0 everywhere). Use pleme-io/actions/oci-image-push (doca: pure-Rust, per-call auth, retry-on-transient) or doca transfer for registry-to-registry. Kept, not deleted, per MODULARIZE-DON''T-DELETE. Historically: copied an OCI image between registries via skopeo copy.";
    };
    "skopeo-login" = {
      uses = "pleme-io/actions/skopeo-login@main";
      backend = "tatara-lisp";
      role = "RETIRED 2026-07-31 — zero consumers remain fleet-wide. doca is per-CALL auth, so there is no login step to perform. Kept, not deleted, per MODULARIZE-DON''T-DELETE. Historically: logged skopeo into a registry (ECR-aware), writing skopeo''s own auth file rather than ~/.docker/config.json.";
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
      role = "Auto-detect the repo type from manifest file presence at the root. Emits a typed identifier (rust-workspace / rust-single-crate / go / npm / python / helm / ansible-collection / ruby-gem / github-action / caixa / unknown) that downstream jobs route on.";
    };
  };
  docs = {
    "api-spec-diff" = {
      uses = "pleme-io/actions/api-spec-diff@main";
      backend = "tatara-lisp";
      role = "Detect breaking changes in an OpenAPI / GraphQL / gRPC spec between base + head refs. Useful PR-time gate for API surface stability.";
    };
    "changelog-fragments-merge" = {
      uses = "pleme-io/actions/changelog-fragments-merge@main";
      backend = "tatara-lisp";
      role = "Merge .changelog/ fragments into CHANGELOG.md (Keep a Changelog).";
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
    "git-cliff" = {
      uses = "pleme-io/actions/git-cliff@main";
      backend = "tatara-lisp";
      role = "Run git-cliff to generate a changelog from conventional commits.";
    };
    "git-commit-tag" = {
      uses = "pleme-io/actions/git-commit-tag@main";
      backend = "tatara-lisp";
      role = "Configure github-actions bot identity, stage typed paths, commit with a typed message template, and create an annotated tag. Refuses to cut a tag that is not ABOVE the highest already-released version (release-monotonicity guard) or that already exists (collision guard). Composes with git-push-with-token for the push half.";
    };
    "git-credentials" = {
      uses = "pleme-io/actions/git-credentials@main";
      backend = "tatara-lisp";
      role = "Route github.com fetches through a resolved PAT so a build can clone PRIVATE pleme-io git dependencies. The git twin of registry-login: the BOT_PAT > GITHUB_TOKEN priority order and the load-bearing extraheader-unset live here, ONCE, instead of being hand-repeated in every reusable that builds Rust/Go with private deps. On the Free plan BOT_PAT reaches PUBLIC repos only, so a private caller passes it empty and the fallback lands on the repo-scoped GITHUB_TOKEN — the two approved tracks, expressed once.";
    };
    "git-path-commit-count" = {
      uses = "pleme-io/actions/git-path-commit-count@main";
      backend = "tatara-lisp";
      role = "Count commits reachable from a ref that touched a given pathspec — a deterministic, monotonic build/patch number with no counter-state to maintain. Generic — any repo, any path, no secrets. Requires a checkout with real history (fetch-depth: 0); a shallow clone under-counts silently, so this action refuses to guess and errors instead.";
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
    "helm-mirror" = {
      uses = "pleme-io/actions/helm-mirror@main";
      backend = "tatara-lisp";
      role = "Mirror a Helm monorepo''s third-party subchart deps into the pleme-io OCI registry (hermetic supply chain)";
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
    "nix-image" = {
      uses = "pleme-io/actions/nix-image@main";
      backend = "tatara-lisp";
      role = "Build native-arch nix OCI image tarballs via dockerTools (NO Dockerfile, NO QEMU), one per arch, resolving the flake attr from a typed {base}/{arch}/{svc} template — covers substrate mkImageReleaseApp (dockerImage-<arch>), mkGoDockerImage multi-service (dockerImage-<arch>-<svc>), and a multi-service image repo (dockerImage:<arch>:<svc>). Fan out over runs-on:[camelot,<arch>] for a native build. Routes through the sui super-cache when SUI_ENDPOINT is set (LiveTODO); correct local nix build otherwise.";
    };
  };
  npm = {
    "npm-bump" = {
      uses = "pleme-io/actions/npm-bump@main";
      backend = "tatara-lisp";
      role = "Bump an npm package.json version via `npm version --no-git-tag-version <type>`, refresh package-lock.json. Sibling of cargo-bump for the npm ecosystem.";
    };
    "npm-mirror-pull" = {
      uses = "pleme-io/actions/npm-mirror-pull@main";
      backend = "tatara-lisp";
      role = "Pull an npm tarball for offline mirroring.";
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
      role = "Ship every workspace member to the Rust registry in topological (leaves-first) dependency order, derived from cargo metadata with dev-deps excluded and exact-pinned targets leading their batch. Auto-renames any conflicting crate to pleme-io-<original> + commits the rename back to main + retries. A member that fails permanently costs exactly that member; the rest still ship and the run reports red at the end. Pure tlisp logic, no shell beyond install glue.";
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
      role = "Promote a built artifact between environments (dev → staging → prod) without rebuilding. kind=image-retag re-tags an existing OCI image (bit-identical artifact per stage); kind=helm-chart-version writes the exact chart/image version into the next environment''s committed values file as a GitOps commit (the AUTOBUMP/eclusa FedRAMP chart-version-promotion leg).";
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
      role = "Execute an embedded .tlisp source string with tatara-script (binary-first, nix-install fallback)";
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
    "cargo-publish-each-member" = {
      uses = "pleme-io/actions/cargo-publish-each-member@main";
      backend = "tatara-lisp";
      role = "Publish each workspace member to crates.io at its own [package].version. For multi-crate workspaces WITHOUT a shared [workspace.package].version (rust-url / bindgen / dirs-next / ratatui pattern). Bumps each member individually, tags member-name-v-version, publishes per-member; rust-workspace-publish is for the engenho-style shared-version pattern.";
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
    "cosign-sign" = {
      uses = "pleme-io/actions/cosign-sign@main";
      backend = "tatara-lisp";
      role = ">-";
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
    "airtable-record-create" = {
      uses = "pleme-io/actions/airtable-record-create@main";
      backend = "tatara-lisp";
      role = "Create a record in an Airtable base.";
    };
    "aldrava-dispatch" = {
      uses = "pleme-io/actions/aldrava-dispatch@main";
      backend = "tatara-lisp";
      role = "The typed knock: match a PR comment against a registered command catalog, resolve commenter trust, and dispatch the target (label relabel / workflow_dispatch / repository_dispatch) — never mutates on an untrusted knock.";
    };
    "aldrava-lint" = {
      uses = "pleme-io/actions/aldrava-lint@main";
      backend = "tatara-lisp";
      role = "Validate a (defcommentcommand ...) catalog file — catches a typo or malformed command definition at PR time instead of at the next real knock.";
    };
    "aldrava-resolve" = {
      uses = "pleme-io/actions/aldrava-resolve@main";
      backend = "tatara-lisp";
      role = "Resolve a uniform run context (checkout ref, branch ref, base ref, PR author, is-develop) from whatever event triggered this job — a label add, workflow_dispatch, schedule, or repository_dispatch — so a downstream pipeline behaves the same regardless of trigger source. No command matching, no trust decision: that already happened upstream in aldrava-dispatch.";
    };
    "algolia-index-push" = {
      uses = "pleme-io/actions/algolia-index-push@main";
      backend = "tatara-lisp";
      role = "Push records to an Algolia index.";
    };
    "anchor-build" = {
      uses = "pleme-io/actions/anchor-build@main";
      backend = "tatara-lisp";
      role = "Build a Solana Anchor program.";
    };
    "anthropic-message" = {
      uses = "pleme-io/actions/anthropic-message@main";
      backend = "tatara-lisp";
      role = "POST a single message to the Anthropic Claude API.";
    };
    "apprise-notify" = {
      uses = "pleme-io/actions/apprise-notify@main";
      backend = "tatara-lisp";
      role = "Send via Apprise (any of 100+ services).";
    };
    "arduino-cli-build" = {
      uses = "pleme-io/actions/arduino-cli-build@main";
      backend = "tatara-lisp";
      role = "Compile an Arduino sketch via arduino-cli.";
    };
    "asana-task-create" = {
      uses = "pleme-io/actions/asana-task-create@main";
      backend = "tatara-lisp";
      role = "Create an Asana task via the API.";
    };
    "attestation-gate" = {
      uses = "pleme-io/actions/attestation-gate@main";
      backend = "tatara-lisp";
      role = "FedRAMP provenance GATE — verify a tameshi/cartorio attestation receipt (presence + blake3 algorithm + content-address tamper-evidence + optional chain/digest/SBOM/SLSA pillar checks) and REFUSE to promote an unattested or tampered artifact version. The verify/gate dual of tameshi-attest + cartorio-attest. Cryptographic signature verification is a named LiveTODO (require-signed=true fails honestly).";
    };
    "auth0-rule-deploy" = {
      uses = "pleme-io/actions/auth0-rule-deploy@main";
      backend = "tatara-lisp";
      role = "Deploy an Auth0 Action/Rule.";
    };
    "bigorna" = {
      uses = "pleme-io/actions/bigorna@main";
      backend = "tatara-lisp";
      role = "CI ENTRY: set up a buildx builder with NATIVE per-arch nodes (no QEMU) + a sui-store cache front, in one step. An unchanged `docker buildx build` afterward runs native-multi-arch + warm.";
    };
    "breathe-band-lint" = {
      uses = "pleme-io/actions/breathe-band-lint@main";
      backend = "tatara-lisp";
      role = "Static coverage gate for breathe bands in a GitOps tree — every bandable workload has a MemoryBand, every band targetRef resolves, no BestEffort on stateful/control-plane, every band declares spec.mode. Parses committed YAML only; never contacts a cluster. The fourth baseline-debt sibling of action-shell-lint / runtime-install-lint / no-cve-suppression.";
    };
    "breathe-runner" = {
      uses = "pleme-io/actions/breathe-runner@main";
      backend = "tatara-lisp";
      role = "Preflight posture gate for camelot breathable spot runners — assert the job landed on a 100%-spot, scale-to-zero, taint-isolated in-cluster GHA runner (never rio) and arm the retirada drain->checkpoint hook. First verb of a super-cache-ci build.";
    };
    "browserstack-test" = {
      uses = "pleme-io/actions/browserstack-test@main";
      backend = "tatara-lisp";
      role = "Run BrowserStack cross-browser tests.";
    };
    "build-matrix" = {
      uses = "pleme-io/actions/build-matrix@main";
      backend = "tatara-lisp";
      role = "Enumerate a flake''s colon-triple image attrs (dockerImage:<arch>:<svc>) and emit the GitHub Actions image×arch build matrix. Step 2 of the super-cache-ci graph job — the single-responsibility sibling of gen-build-spec (which gates spec freshness; this fans the fresh spec across every (service, arch) the flake actually exposes). TIER: SHIPPABLE-NOW — deterministic `nix eval` enumeration, honest per-service arch discovery (an arm64 row appears iff the flake exposes dockerImage:arm64:<svc>), never a hard-coded arch pair. TYPED EMISSION: the matrix JSON is composed by jq, never hand-concatenated.";
    };
    "bun-publish" = {
      uses = "pleme-io/actions/bun-publish@main";
      backend = "tatara-lisp";
      role = "Build + publish via bunx.";
    };
    "cartorio-attest" = {
      uses = "pleme-io/actions/cartorio-attest@main";
      backend = "tatara-lisp";
      role = "FedRAMP three-pillar compliance receipt for a delivered image digest: a BLAKE3 chain-linked receipt + an SBOM from Nix inputs (CycloneDX from the Nix closure) + SLSA v1.0 provenance. Sibling of tameshi-attest (the build receipt), sharing the BLAKE3 core, adding the SBOM+SLSA pillars.";
    };
    "cdk-deploy" = {
      uses = "pleme-io/actions/cdk-deploy@main";
      backend = "tatara-lisp";
      role = "Run cdk deploy for an AWS CDK app.";
    };
    "cdktf-deploy" = {
      uses = "pleme-io/actions/cdktf-deploy@main";
      backend = "tatara-lisp";
      role = "Run cdktf deploy for a CDK-for-Terraform app.";
    };
    "clickup-task-create" = {
      uses = "pleme-io/actions/clickup-task-create@main";
      backend = "tatara-lisp";
      role = "Create a ClickUp task.";
    };
    "codacy-coverage-upload" = {
      uses = "pleme-io/actions/codacy-coverage-upload@main";
      backend = "tatara-lisp";
      role = "Upload coverage to Codacy.";
    };
    "codeql-scan" = {
      uses = "pleme-io/actions/codeql-scan@main";
      backend = "shell";
      role = "GitHub CodeQL SAST scan. Polymorphic — auto-detects language; uploads SARIF to GitHub Code Scanning.";
    };
    "commitlint" = {
      uses = "pleme-io/actions/commitlint@main";
      backend = "tatara-lisp";
      role = "Validate commit messages with commitlint.";
    };
    "confluence-page-create" = {
      uses = "pleme-io/actions/confluence-page-create@main";
      backend = "tatara-lisp";
      role = "Create a Confluence page via REST API.";
    };
    "container-boot-check" = {
      uses = "pleme-io/actions/container-boot-check@main";
      backend = "tatara-lisp";
      role = "Start a container and poll a health command until it responds or a bounded attempt count is exhausted. Generic — any image, any health command, no secrets. Dumps container logs on timeout so a boot failure is never silent.";
    };
    "conventional-commit-lint" = {
      uses = "pleme-io/actions/conventional-commit-lint@main";
      backend = "tatara-lisp";
      role = "Enforce conventional-commit format on the latest commits.";
    };
    "coverage-upload" = {
      uses = "pleme-io/actions/coverage-upload@main";
      backend = "tatara-lisp";
      role = "Generate test coverage + upload to Codecov. Polymorphic — detects ecosystem (rust uses cargo-tarpaulin, npm uses jest --coverage, python uses pytest --cov).";
    };
    "crates-mirror-pull" = {
      uses = "pleme-io/actions/crates-mirror-pull@main";
      backend = "tatara-lisp";
      role = "Pull a crate from crates.io for offline mirroring.";
    };
    "crossplane-apply" = {
      uses = "pleme-io/actions/crossplane-apply@main";
      backend = "tatara-lisp";
      role = "Apply Crossplane Composition + claims to a cluster.";
    };
    "dagster-materialize" = {
      uses = "pleme-io/actions/dagster-materialize@main";
      backend = "tatara-lisp";
      role = "Materialize a Dagster asset via dagster CLI.";
    };
    "darwin-zig-build" = {
      uses = "pleme-io/actions/darwin-zig-build@main";
      backend = "tatara-lisp";
      role = "cargo zigbuild --release for an apple-darwin target (cross-compiles from Linux), stage binary + sha256 into ./dist";
    };
    "dbt-build" = {
      uses = "pleme-io/actions/dbt-build@main";
      backend = "tatara-lisp";
      role = "Run dbt build for a data warehouse model project.";
    };
    "deno-deploy" = {
      uses = "pleme-io/actions/deno-deploy@main";
      backend = "tatara-lisp";
      role = "Deploy to Deno Deploy via deployctl.";
    };
    "doca" = {
      uses = "pleme-io/actions/doca@main";
      backend = "shell";
      role = "Typed OCI artifact manager (push / transfer / inspect / tag / list) via nix run github:pleme-io/substrate#oci-push. Inputs surfaced as INPUT_* env; the binary reads them as flag fallbacks — no shell flag-mapping.";
    };
    "elasticsearch-snapshot" = {
      uses = "pleme-io/actions/elasticsearch-snapshot@main";
      backend = "tatara-lisp";
      role = "Trigger an Elasticsearch snapshot.";
    };
    "envoy-config-validate" = {
      uses = "pleme-io/actions/envoy-config-validate@main";
      backend = "tatara-lisp";
      role = "Validate an Envoy proxy config.";
    };
    "esp-idf-build" = {
      uses = "pleme-io/actions/esp-idf-build@main";
      backend = "tatara-lisp";
      role = "Build an ESP-IDF project.";
    };
    "fastly-cache-purge" = {
      uses = "pleme-io/actions/fastly-cache-purge@main";
      backend = "tatara-lisp";
      role = "Purge Fastly cache.";
    };
    "ferrite-check" = {
      uses = "pleme-io/actions/ferrite-check@main";
      backend = "tatara-lisp";
      role = "Per-package MATERIALIZABILITY gate of the camelot image pipeline: for ONE package (a flake image attr) verify it can be materialized (its attr resolves to a derivation via a cheap `nix eval`, NOT a derive) BEFORE the expensive build, content-address its SOURCE, and emit a PoMS — a Proof-of-Materialization-Spec receipt — cached by that source hash so a re-run over unchanged source is a pure cache hit (no re-eval, no derive). Single-responsibility sibling of build-matrix (the fan) + gen-build-spec (the freshness gate); it gates one fan cell's materializability. TYPED EMISSION: the PoMS JSON is composed by jq, never hand-concatenated; the receipt hash is a real BLAKE3 (the action FAILS rather than emit a receipt that lies about its algorithm). Sibling of tameshi-attest (build receipt) + cartorio-attest (delivery receipt) on ONE chain (carries chain.prev, shares the BLAKE3 core).";
    };
    "ffmpeg-transcode" = {
      uses = "pleme-io/actions/ffmpeg-transcode@main";
      backend = "tatara-lisp";
      role = "Run ffmpeg transcode on input file(s).";
    };
    "flake-input-preseed" = {
      uses = "pleme-io/actions/flake-input-preseed@main";
      backend = "tatara-lisp";
      role = "WARM flake-input lever — pull a heavy flake input''s SOURCE FOD out of the super-cache into the local store BEFORE the build, so the in-flake locked eval reuses the content-addressed path and SKIPS the ~40s eval-time git clone. nix''s git/tarball fetcher never substitutes a source tree, so `substituters=<sui>` alone is a no-op for source — this explicit `nix copy --from` is the load-bearing form of the lever. Pairs with super-cache-save''s flake-inputs push. TIER-HONEST: a miss (endpoint down / source not yet pushed / path unresolvable) degrades to the clone and is reported, never faked; require=true fails loud.";
    };
    "foundry-test" = {
      uses = "pleme-io/actions/foundry-test@main";
      backend = "tatara-lisp";
      role = "Run forge test.";
    };
    "gen-build-spec" = {
      uses = "pleme-io/actions/gen-build-spec@main";
      backend = "tatara-lisp";
      role = "Emit the typed *.build-spec.json for a repo via `gen build .` and enforce the GEN-TYPED-SPEC-CONTRACT stale gate (a committed spec that drifts from the regen is a CI FAILURE, never a runtime fetch). Step 3 of the super-cache-ci pipeline — produces the spec-path + spec-hash the tiered cache verbs key on. TIER-HONEST: lang=cargo is the NOW path (gen-cargo conquered, ledger row 9); npm/pip/gomod are a named LiveTODO (row 10); an absent `gen` reports an honest gen-absent-livetodo branch unless require-gen=true.";
    };
    "ghcr-publish" = {
      uses = "pleme-io/actions/ghcr-publish@main";
      backend = "tatara-lisp";
      role = "Push a nix OCI image tarball to a private registry (ghcr.io/pleme-io/<svc>) under the AUTOBUMP exact tag <arch>-r<run>-<sha>, plus an optional moving <arch>-latest human pointer (never a deploy source). Auth is a pre-condition (docker/login-action first).";
    };
    "gitea-mirror-push" = {
      uses = "pleme-io/actions/gitea-mirror-push@main";
      backend = "tatara-lisp";
      role = "Mirror push the repo to a Gitea instance.";
    };
    "gitlab-mirror-push" = {
      uses = "pleme-io/actions/gitlab-mirror-push@main";
      backend = "tatara-lisp";
      role = "Mirror push the repo to a GitLab remote.";
    };
    "godot-export" = {
      uses = "pleme-io/actions/godot-export@main";
      backend = "tatara-lisp";
      role = "Export a Godot project for a target preset.";
    };
    "google-calendar-event-create" = {
      uses = "pleme-io/actions/google-calendar-event-create@main";
      backend = "tatara-lisp";
      role = "Create a Google Calendar event via service account.";
    };
    "hardhat-deploy" = {
      uses = "pleme-io/actions/hardhat-deploy@main";
      backend = "tatara-lisp";
      role = "Deploy contracts via Hardhat.";
    };
    "hf-hub-upload" = {
      uses = "pleme-io/actions/hf-hub-upload@main";
      backend = "tatara-lisp";
      role = "Upload a model/dataset to Hugging Face Hub.";
    };
    "hubspot-contact-upsert" = {
      uses = "pleme-io/actions/hubspot-contact-upsert@main";
      backend = "tatara-lisp";
      role = "Upsert a HubSpot contact.";
    };
    "influxdb-write" = {
      uses = "pleme-io/actions/influxdb-write@main";
      backend = "tatara-lisp";
      role = "Write line-protocol points to InfluxDB.";
    };
    "infracost-comment" = {
      uses = "pleme-io/actions/infracost-comment@main";
      backend = "tatara-lisp";
      role = "Run infracost on a Terraform plan + comment cost diff on PR.";
    };
    "istio-apply" = {
      uses = "pleme-io/actions/istio-apply@main";
      backend = "tatara-lisp";
      role = "Apply Istio config (Gateway, VirtualService, etc).";
    };
    "jira-issue-create" = {
      uses = "pleme-io/actions/jira-issue-create@main";
      backend = "tatara-lisp";
      role = "Create a Jira issue via REST API.";
    };
    "jupyter-notebook-render" = {
      uses = "pleme-io/actions/jupyter-notebook-render@main";
      backend = "tatara-lisp";
      role = "Execute + export a Jupyter notebook to HTML.";
    };
    "k6-load-test" = {
      uses = "pleme-io/actions/k6-load-test@main";
      backend = "tatara-lisp";
      role = "Run a k6 load test script + emit summary JSON. Pairs with thresholds for PR-time perf regression gating.";
    };
    "keycloak-realm-import" = {
      uses = "pleme-io/actions/keycloak-realm-import@main";
      backend = "tatara-lisp";
      role = "Import a Keycloak realm via kc.sh.";
    };
    "linear-issue-create" = {
      uses = "pleme-io/actions/linear-issue-create@main";
      backend = "tatara-lisp";
      role = "Create a Linear issue via GraphQL API.";
    };
    "linear-issue-update" = {
      uses = "pleme-io/actions/linear-issue-update@main";
      backend = "tatara-lisp";
      role = "Update a Linear issue's state/labels/etc.";
    };
    "linkerd-inject" = {
      uses = "pleme-io/actions/linkerd-inject@main";
      backend = "tatara-lisp";
      role = "Inject Linkerd sidecars into k8s manifests.";
    };
    "make-scenario-run" = {
      uses = "pleme-io/actions/make-scenario-run@main";
      backend = "tatara-lisp";
      role = "Run a Make.com scenario via webhook.";
    };
    "manifest-list-join" = {
      uses = "pleme-io/actions/manifest-list-join@main";
      backend = "tatara-lisp";
      role = "Compose separately-pushed per-arch images (amd64=<ref>,arm64=<ref>) into one multi-arch OCI image index and push it under the multi-arch deploy coordinate r<run>-<sha>; report the index digest — the single exact coordinate an environment pins.";
    };
    "meilisearch-index" = {
      uses = "pleme-io/actions/meilisearch-index@main";
      backend = "tatara-lisp";
      role = "Index documents to Meilisearch.";
    };
    "modal-deploy" = {
      uses = "pleme-io/actions/modal-deploy@main";
      backend = "tatara-lisp";
      role = "Deploy a Modal function/app.";
    };
    "n8n-trigger-workflow" = {
      uses = "pleme-io/actions/n8n-trigger-workflow@main";
      backend = "tatara-lisp";
      role = "Trigger an n8n workflow via webhook.";
    };
    "newrelic-deploy-marker" = {
      uses = "pleme-io/actions/newrelic-deploy-marker@main";
      backend = "tatara-lisp";
      role = "Send a New Relic deployment marker.";
    };
    "no-cve-suppression" = {
      uses = "pleme-io/actions/no-cve-suppression@main";
      backend = "tatara-lisp";
      role = "Fail on ANY CVE-suppression surface — .trivyignore / vulnix whitelist / grype ignore / VEX not_affected entries AND the workflow-YAML gate-weakeners (*-advisory-only:true, ignore-unfixed:true, scan-ignore-file). A CVE is remediated at cause, never suppressed — see theory/NIX-HARDENING.md §VII.6. The third baseline-debt sibling of action-shell-lint / runtime-install-lint.";
    };
    "notion-db-row-add" = {
      uses = "pleme-io/actions/notion-db-row-add@main";
      backend = "tatara-lisp";
      role = "Add a row to a Notion database.";
    };
    "notion-page-create" = {
      uses = "pleme-io/actions/notion-page-create@main";
      backend = "tatara-lisp";
      role = "Create a Notion page via the API.";
    };
    "ntfy-push" = {
      uses = "pleme-io/actions/ntfy-push@main";
      backend = "tatara-lisp";
      role = "Push a notification to ntfy.sh (mobile/ops alert).";
    };
    "nx-affected-test" = {
      uses = "pleme-io/actions/nx-affected-test@main";
      backend = "tatara-lisp";
      role = "Run nx affected:test for incremental CI.";
    };
    "nx-cloud-distribute" = {
      uses = "pleme-io/actions/nx-cloud-distribute@main";
      backend = "tatara-lisp";
      role = "Distribute Nx tasks to Nx Cloud agents.";
    };
    "okta-app-sync" = {
      uses = "pleme-io/actions/okta-app-sync@main";
      backend = "tatara-lisp";
      role = "Sync Okta apps from a YAML catalog.";
    };
    "ollama-pull" = {
      uses = "pleme-io/actions/ollama-pull@main";
      backend = "tatara-lisp";
      role = "Pull an Ollama model.";
    };
    "onepassword-fetch" = {
      uses = "pleme-io/actions/onepassword-fetch@main";
      backend = "shell";
      role = "Fetch a secret from 1Password via Service Account token. Sibling of akeyless-secret-fetch.";
    };
    "openai-embeddings-batch" = {
      uses = "pleme-io/actions/openai-embeddings-batch@main";
      backend = "tatara-lisp";
      role = "Compute embeddings via OpenAI batch API.";
    };
    "openai-fine-tune-trigger" = {
      uses = "pleme-io/actions/openai-fine-tune-trigger@main";
      backend = "tatara-lisp";
      role = "Trigger an OpenAI fine-tune job.";
    };
    "opentelemetry-trace-emit" = {
      uses = "pleme-io/actions/opentelemetry-trace-emit@main";
      backend = "tatara-lisp";
      role = "Emit an OTLP trace span for this workflow run.";
    };
    "output-contract-sync" = {
      uses = "pleme-io/actions/output-contract-sync@main";
      backend = "tatara-lisp";
      role = "Generate the two-boundary output contract for pleme-io/actions and gate it — byte-diffs the generated tatara-script outputs block + catalog against what is committed, and catches the wrapper-side gap the runtime gate cannot see.";
    };
    "pangea-grafana-converge" = {
      uses = "pleme-io/actions/pangea-grafana-converge@main";
      backend = "tatara-lisp";
      role = "MODEL-2 (remote-reconcile) FedRAMP observability executor — health-probe a remote Grafana REST endpoint (inbound-only + scoped SA token) then drive the shipped pangea rio-observability workspace + deployment-agnostic pangea-grafana provider + magma runner against it, converging the remote Grafana from our side. Reports the runner''s real status; the exact flake app attr is a named LiveTODO, never faked.";
    };
    "pinecone-upsert" = {
      uses = "pleme-io/actions/pinecone-upsert@main";
      backend = "tatara-lisp";
      role = "Upsert vectors to Pinecone.";
    };
    "platformio-build" = {
      uses = "pleme-io/actions/platformio-build@main";
      backend = "tatara-lisp";
      role = "Build a PlatformIO embedded project.";
    };
    "posthog-event" = {
      uses = "pleme-io/actions/posthog-event@main";
      backend = "tatara-lisp";
      role = "POST an event to PostHog for product analytics.";
    };
    "pull-request-gate" = {
      uses = "pleme-io/actions/pull-request-gate@main";
      backend = "tatara-lisp";
      role = "Gate pull_request_target events: allow approved authors, label bots, auto-close+lock external drive-by PRs that only modify documentation. Defends against vendor badge-trojan spam.";
    };
    "puppeteer-screenshot" = {
      uses = "pleme-io/actions/puppeteer-screenshot@main";
      backend = "tatara-lisp";
      role = "Capture page screenshots via puppeteer.";
    };
    "qdrant-collection-create" = {
      uses = "pleme-io/actions/qdrant-collection-create@main";
      backend = "tatara-lisp";
      role = "Create a Qdrant collection.";
    };
    "qiskit-job-submit" = {
      uses = "pleme-io/actions/qiskit-job-submit@main";
      backend = "tatara-lisp";
      role = "Submit a Qiskit circuit job to IBM Quantum.";
    };
    "readme-sync" = {
      uses = "pleme-io/actions/readme-sync@main";
      backend = "tatara-lisp";
      role = "Sync ReadMe.io docs from a repo.";
    };
    "redis-flush" = {
      uses = "pleme-io/actions/redis-flush@main";
      backend = "tatara-lisp";
      role = "Flush a Redis DB (use with extreme care).";
    };
    "registry-login" = {
      uses = "pleme-io/actions/registry-login@main";
      backend = "tatara-lisp";
      role = "Resolve an OCI-registry credential from the typed fallback (BOT_PAT > GHCR_TOKEN > GITHUB_TOKEN) and log the chosen client (helm | docker) into the registry. The single overlay every publish reusable calls in place of a hand-repeated `secrets.BOT_PAT || secrets.GHCR_TOKEN || ...` expression — the priority order lives here, once. BOT_PAT carries write:packages on the org-shared ghcr.io/pleme-io/* namespace (a repo-scoped GITHUB_TOKEN 403s on cross-namespace push); on the Free plan it reaches public repos only, so a private caller passes it empty and the fallback lands on GITHUB_TOKEN — the two approved tracks, expressed once.";
    };
    "renovate-trigger" = {
      uses = "pleme-io/actions/renovate-trigger@main";
      backend = "tatara-lisp";
      role = "Force Renovate to rerun on a repo.";
    };
    "replicate-run" = {
      uses = "pleme-io/actions/replicate-run@main";
      backend = "tatara-lisp";
      role = "Run a model on Replicate via the API.";
    };
    "retool-workflow-run" = {
      uses = "pleme-io/actions/retool-workflow-run@main";
      backend = "tatara-lisp";
      role = "Trigger a Retool workflow.";
    };
    "runner-resolve" = {
      uses = "pleme-io/actions/runner-resolve@main";
      backend = "tatara-lisp";
      role = "Resolve the runs-on label for a job via typed precedence: an explicit override > an optional repo-committed config file (.github/runner.yml) > the caller-supplied default > a visibility-aware billing-safe default (private repo -> Camelot self-hosted, public repo -> free GitHub-hosted minutes). GitHub Actions runs-on: cannot read a same-job step output, so every workflow adopting this action MUST call it as its OWN job and have every other job in the same workflow depend on it via needs.<job-id>.outputs.runner. The visibility-aware tier is the ONLY posture this action bakes in — it exists to make the org standing invariant (\"a CI path either flows through a genuinely public repo or Camelot self-hosted, never a metered GitHub-hosted runner on a private repo\") the default outcome of omitting `default`, not something every caller re-derives by hand. A caller that needs something else always wins via override/config-path/an explicit default.";
    };
    "banned-tool-lint" = {
      uses = "pleme-io/actions/banned-tool-lint@main";
      backend = "tatara-lisp";
      role = "Fail on a NEW call site of a banned external tool — today skopeo, replaced fleet-wide by doca (substrate#oci-push). Matches INVOCATIONS only (a quoted exec argument, `command -v <tool>`, `<tool> copy|inspect|login|delete|list-tags|sync`, a `#<tool>` nix attr), never a mention in prose or a comment: 299 files in the fleet mention skopeo and only a fraction execute it, so a mention-based rule would be nearly all false positives and would teach people to ignore the gate. A RATCHET like its siblings — existing call sites live in a baseline with a stated reason each and are reported every run, never silently accepted; only a new one fails, so the count can only go down. The banned set is one TAB-separated table (banned-tools.txt), so banning the next tool is a row, not code. A missing or empty table FAILS rather than passing vacuously. SCOPE: pleme-io-owned repos; akeylesslabs/* and akeyless-community/* are deliberately excluded (operator decision, 2026-08-01). The fifth baseline-debt sibling of action-shell-lint / runtime-install-lint / no-cve-suppression / breathe-band-lint. ★ MEASURED REACH 2026-08-01, and it is NOT the SCOPE line above: exactly ONE workflow step invokes this action fleet-wide — `actions/.github/workflows/ci.yml` as `uses: ./banned-tool-lint`, a SELF-lint of the repo that defines it. Counted over 950 repo checkouts; the four siblings measure 2/2/3/1 steps the same way. So `SCOPE: pleme-io-owned repos` states the rule's INTENT, not its enforcement: every repo below carries a LIVE skopeo invocation that this gate does not read — substrate itself (lib/util/config.nix `package = pkgs.skopeo`, lib/service/image-release.nix + product-sdlc.nix `SKOPEO_BIN`), forge (cli/src/tools.rs SKOPEO const), image-sync (src/main.rs, 2 `Command::new`), formigueiro (formigueiro-image/src/lib.rs), engenho (engenho-substrate/src/oci_renderer.rs `binary: skopeo`), batata-quente (flake.nix runtimeInputs). A ratchet that reads one repo cannot ratchet the other 949, so `pending-banned-tool-reach:` — adopt the step in the repos that actually execute skopeo, highest-value first (substrate, forge, image-sync), before treating the doca sweep as gated. ★★ TWO MEASUREMENT TRAPS, both hit while measuring THIS entry, both worth more than the finding: (1) THE CATALOG IS A PHANTOM CONSUMER. This file carries 339 `uses = \"pleme-io/actions/<name>@main\"` rows — one per catalogued action — so ANY adoption probe that greps for `actions/<name>@` returns >=1 for all 339 whether or not a workflow ever calls them. That is how this action first measured as `1 consumer: substrate` when substrate invokes it zero times; the sole hit was line 1743 of this very file. Adoption must be counted over `.github/workflows/**` and nothing else. (2) A CONTROL ONLY PROVES THE PROBE FINDS WHAT THE CONTROL LOOKS LIKE. The first step-level probe used `^\\s*uses:`, which cannot match the standard list-item form `- uses:` and therefore read the whole fleet as zero — and it was believed, because its two positive controls (oci-image-push, image-scan) both returned 3. Both happened to be the RARE dash-less continuation form, so a control chosen for being known-present validated a probe blind to the dominant syntax. A control must be sampled from the same shape distribution as the subject, or it certifies the blindness instead of catching it.";
    };
    "runtime-install-lint" = {
      uses = "pleme-io/actions/runtime-install-lint@main";
      backend = "tatara-lisp";
      role = "Fail on runtime tool installation (curl|tar, curl|sh, apt-get/apt/pip/npm/go/cargo install) in any action.yml or run.tlisp, AND per-job Nix installation (nix-installer-action / `nix shell nixpkgs#…`) in any .github/workflows/*.yml. The tool must ship as a Nix-hardened image / baked runner image instead — see theory/NIX-HARDENING.md §VI, §VI.1.";
    };
    "salesforce-record-create" = {
      uses = "pleme-io/actions/salesforce-record-create@main";
      backend = "tatara-lisp";
      role = "Create a Salesforce record via REST API.";
    };
    "selenium-grid-test" = {
      uses = "pleme-io/actions/selenium-grid-test@main";
      backend = "tatara-lisp";
      role = "Run Selenium tests against a Grid endpoint.";
    };
    "semgrep-scan" = {
      uses = "pleme-io/actions/semgrep-scan@main";
      backend = "tatara-lisp";
      role = "Semgrep SAST scan with configurable rule set.";
    };
    "ses-email-send" = {
      uses = "pleme-io/actions/ses-email-send@main";
      backend = "tatara-lisp";
      role = "Send transactional email via AWS SES.";
    };
    "shopify-theme-deploy" = {
      uses = "pleme-io/actions/shopify-theme-deploy@main";
      backend = "tatara-lisp";
      role = "Deploy a Shopify theme via theme CLI.";
    };
    "sonarcloud-quality-gate" = {
      uses = "pleme-io/actions/sonarcloud-quality-gate@main";
      backend = "tatara-lisp";
      role = "Wait for SonarCloud quality gate decision.";
    };
    "spin-deploy" = {
      uses = "pleme-io/actions/spin-deploy@main";
      backend = "tatara-lisp";
      role = "Deploy a Fermyon Spin app to Fermyon Cloud.";
    };
    "step-summary-publish" = {
      uses = "pleme-io/actions/step-summary-publish@main";
      backend = "tatara-lisp";
      role = "Render a templated markdown to $GITHUB_STEP_SUMMARY.";
    };
    "stripe-product-sync" = {
      uses = "pleme-io/actions/stripe-product-sync@main";
      backend = "tatara-lisp";
      role = "Sync products from a typed YAML to Stripe.";
    };
    "stripe-webhook-test" = {
      uses = "pleme-io/actions/stripe-webhook-test@main";
      backend = "tatara-lisp";
      role = "Send a Stripe webhook event from CLI for integration tests.";
    };
    "sui-dockerfile-node-cache" = {
      uses = "pleme-io/actions/sui-dockerfile-node-cache@main";
      backend = "shell";
      role = ">-";
    };
    "sui-remote-build" = {
      uses = "pleme-io/actions/sui-remote-build@main";
      backend = "tatara-lisp";
      role = "BUILD-job remote-execution verb — dispatch a derivation to a REAPI spot worker over the sui daemon (RAM eval, tmpfs sandbox, DB store), keyed by the gen build-spec. DEGRADED-UNTIL-STORE: the REAPI worker binary + TieredBackend are a named LiveTODO — gracefully falls back to the correct LOCAL daemon-node build (worker=local, built=false honest, never a faked build); require-build=true fails loud.";
    };
    "sui-service-up" = {
      uses = "pleme-io/actions/sui-service-up@main";
      backend = "tatara-lisp";
      role = "Resolve, health-check, and export the sui service (sui-daemon-graph) endpoint + selected store/cache/sandbox tiers for a super-cache-ci build. Does not own daemon lifecycle — the daemon is an external rio cluster app or a job-scoped sidecar. TIER-HONEST: the live Postgres/Redis (never-touch-disk) connect is a named LiveTODO.";
    };
    "sui-warm-hydrate" = {
      uses = "pleme-io/actions/sui-warm-hydrate@main";
      backend = "tatara-lisp";
      role = "GRAPH-job warm verb — pre-load the sui daemon''s tiered super-cache (Redis L1 → Postgres L2 → object L3) with the fan-out''s content keys BEFORE the build matrix explodes, so every parallel build job starts warm. DEGRADED-UNTIL-STORE: the warm-set RPC + TieredBackend are a named LiveTODO — today an HONEST no-op (warmed=false, warm-count=0, never a faked warm); require-warm=true fails loud.";
    };
    "super-cache-build" = {
      uses = "pleme-io/actions/super-cache-build@main";
      backend = "tatara-lisp";
      role = "THE CORE super-cache-ci verb — build a derivation via the sui service against the tiered super-cache, keyed by the gen build-spec (RAM eval, tmpfs sandbox, DB store). Skips the derive on a restore cache hit. TIER-HONEST: the pure derive decision + the cache-hit short-circuit are shipped + unit-tested; the live derive (sui-graph build RPC/CLI) is a named LiveTODO — sui-daemon-client is a library not a binary — reported honestly, never a faked green (require-build=true fails loud).";
    };
    "super-cache-restore" = {
      uses = "pleme-io/actions/super-cache-restore@main";
      backend = "tatara-lisp";
      role = "Probe the tiered super-cache (Redis L1 -> Postgres L2 -> object L3) for a build''s outputs and report the hit + tier (the warm path). TIER-HONEST: the Redis/Pg tiers via the sui service are a named LiveTODO behind sui''s shipped StorageBackend/Store traits; the now-path resolves a local content-addressed object tier and reports an honest miss otherwise.";
    };
    "super-cache-save" = {
      uses = "pleme-io/actions/super-cache-save@main";
      backend = "tatara-lisp";
      role = "Persist a build''s outputs to the durable super-cache tiers, write-if-absent, content-addressed, no lock (the eliminate-the-shared-cell pattern; concurrent-runner coherence is free). TIER-HONEST: the durable Postgres/object tiers are a named LiveTODO behind sui''s shipped Store/StorageBackend traits; the now-path persists to a local content-addressed object tier and is an honest no-op when no tier is configured.";
    };
    "syft-attest" = {
      uses = "pleme-io/actions/syft-attest@main";
      backend = "tatara-lisp";
      role = "Generate an in-toto attestation containing an SBOM via syft.";
    };
    "tameshi-attest" = {
      uses = "pleme-io/actions/tameshi-attest@main";
      backend = "tatara-lisp";
      role = "Assemble + BLAKE3-hash a typed super-cache-ci build receipt (spec-hash + output-hashes + cache tier + timings + image digests) into a content-addressed, independently-verifiable JSON. The final verb of a super-cache-ci build. Requires a BLAKE3 provider on the runner (b3sum on PATH, else nix).";
    };
    "tlisp-test" = {
      uses = "pleme-io/actions/tlisp-test@main";
      backend = "tatara-lisp";
      role = "Discover + run every *.test.tlisp via tatara-script --test. Each test runs as the stdlib + the sibling unit (<base>.tlisp) + the test, with TLISP_TEST=1 so the unit defines its functions but skips its main. Fails if any (deftest ...) fails.";
    };
    "trivy-fs-scan" = {
      uses = "pleme-io/actions/trivy-fs-scan@main";
      backend = "tatara-lisp";
      role = "Run trivy fs scan on the repo source tree.";
    };
    "turbo-build" = {
      uses = "pleme-io/actions/turbo-build@main";
      backend = "tatara-lisp";
      role = "Run turbo build across a monorepo.";
    };
    "typesense-import" = {
      uses = "pleme-io/actions/typesense-import@main";
      backend = "tatara-lisp";
      role = "Import documents to Typesense.";
    };
    "unity-build" = {
      uses = "pleme-io/actions/unity-build@main";
      backend = "tatara-lisp";
      role = "Build a Unity project for a target platform.";
    };
    "vex-attest" = {
      uses = "pleme-io/actions/vex-attest@main";
      backend = "tatara-lisp";
      role = ">-";
    };
    "wasmer-publish" = {
      uses = "pleme-io/actions/wasmer-publish@main";
      backend = "tatara-lisp";
      role = "Publish a wasm package to Wasmer registry.";
    };
    "weaviate-schema-apply" = {
      uses = "pleme-io/actions/weaviate-schema-apply@main";
      backend = "tatara-lisp";
      role = "Apply a Weaviate schema definition.";
    };
    "woocommerce-product-sync" = {
      uses = "pleme-io/actions/woocommerce-product-sync@main";
      backend = "tatara-lisp";
      role = "Sync products to WooCommerce REST API.";
    };
    "zapier-webhook-trigger" = {
      uses = "pleme-io/actions/zapier-webhook-trigger@main";
      backend = "tatara-lisp";
      role = "Trigger a Zapier webhook.";
    };
    "zot-pull-scan" = {
      uses = "pleme-io/actions/zot-pull-scan@main";
      backend = "shell";
      role = "The zot faucet gate: pull an image from a private zot registry, then gate admission through image-scan -- the fleet''s ONE canonical Trivy severity implementation -- scanning the PULLED bytes, never a re-resolved tag. Nothing enters the trusted zone unscanned, and nothing enters on a scan failure, a parse failure, or a misconfigured override either.";
    };
    "zot-push" = {
      uses = "pleme-io/actions/zot-push@main";
      backend = "tatara-lisp";
      role = "Push a nix OCI image tarball to the PRIVATE in-cluster Zot registry (zot.zot-system.svc.cluster.local:5000/akeyless-<svc>) under the AUTOBUMP exact tag <arch>-r<run>-<sha>, and report the pushed repository digest (the exact deploy coordinate). FedRAMP-sensitive images NEVER go to ghcr.io.";
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
