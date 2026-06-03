# substrate/lib/release/catalog.nix
#
# Queryable catalog of the auto-release recipes substrate ships
# today. Operators (and other recipes) introspect this to see
# what ecosystems are covered + which actions wire each one.
#
# Per the ★★ AUTO-RELEASE prime directive: every adopting repo
# uses pleme-io/substrate/.github/workflows/auto-release.yml as
# the polymorphic entry; this file is the typed source of truth
# for what the dispatcher routes to.
#
# Usage from a flake:
#   substrate.lib.release.catalog  → attrset keyed by repo-type
#
# Usage from a doc generator:
#   builtins.attrNames substrate.lib.release.catalog
#   → ["rust-workspace" "rust-single-crate" "go" "npm" "python" "helm"
#      "ansible-collection" "ruby-gem" "github-action"]

{
  rust-workspace = {
    detect = "Cargo.toml + [workspace]";
    upstream = "crates.io (every member crate)";
    bump-action = "pleme-io/actions/rust-workspace-bump@main";
    publish-action = "pleme-io/actions/rust-workspace-publish@main";
    workflow = "pleme-io/substrate/.github/workflows/rust-auto-release.yml@main";
    secrets = [ "CRATES_API_TOKEN" "BOT_PAT?" ];
    semantics = "auto-rename on name conflict, multi-pass dep-order, skip-already-published, rate-limit sleep+retry";
    status = "shipping";
    reference-impl = "pleme-io/engenho — 15 crates live at v0.1.4";
  };

  rust-single-crate = {
    detect = "Cargo.toml + [package] (no [workspace])";
    upstream = "crates.io";
    bump-action = "pleme-io/actions/cargo-bump@main";
    publish-action = "pleme-io/actions/cargo-publish-crate@main";
    workflow = "pleme-io/substrate/.github/workflows/cargo-auto-release.yml@main";
    secrets = [ "CRATES_API_TOKEN" "BOT_PAT?" ];
    semantics = "skip-already-published, rate-limit sleep+retry";
    status = "shipping";
    reference-impl = "pleme-io/todoku, tsunagu, garasu, shikumi, ... (single-crate libs)";
  };

  go = {
    detect = "go.mod";
    # Pull-model: proxy.golang.org indexes lazily on first `go get` — there
    # is NO upload step (contrast cargo publish). The only publish side
    # effect is `git push origin <tag>` (LAYOUT-05 / VER-12, FSM-MODULE).
    upstream = "pkg.go.dev (via proxy.golang.org — pull-model, lazy index)";
    bump-action = "pleme-io/substrate#relver (typed semver tag engine — tag-only, no manifest version field)";
    publish-action = "(no-op — pull-model; publish = the tag push itself, proxy.golang.org pulls lazily)";
    workflow = "pleme-io/substrate/.github/workflows/go-auto-release.yml@main";
    secrets = [ "BOT_PAT?" ];  # GITHUB_TOKEN suffices for the tag push
    semantics = "FSM-MODULE: Drafted→Validated(go vet/test/build + go.sum tidy)→Tagged(relver semver bump + annotated tag + push; honor /vN)→Proxied(NO-OP confirm pkg.go.dev/proxy.golang.org)→Verified(hermetic go get resolves exact version)";
    status = "shipping";
    reference-impl = "(pending first consumer — Go SDKs / CLI)";
    # cli/binary RELEASE-FSM (FSM-RELEASE): go-binary-release.yml (goreleaser
    # cross-build + checksum + cosign + GH Release + Homebrew brews).
    # daemon/service IMAGE-FSM (FSM-IMAGE): lib/build/go/service-flake.nix
    # `forge image-release` (cosign + SBOM + CVE) — not duplicated here.
  };

  npm = {
    detect = "package.json";
    upstream = "npmjs.org";
    bump-action = "pleme-io/actions/npm-bump@main";
    publish-action = "pleme-io/actions/npm-publish@main";
    workflow = "pleme-io/substrate/.github/workflows/npm-auto-release.yml@main";
    secrets = [ "NPM_TOKEN" "BOT_PAT?" ];
    semantics = "skip-already-published (@scope encoding), rate-limit sleep+retry";
    status = "shipping";
    reference-impl = "(pending first consumer)";
  };

  python = {
    detect = "pyproject.toml";
    upstream = "pypi.org";
    bump-action = "pleme-io/actions/python-bump@main";
    publish-action = "pleme-io/actions/python-publish@main";
    workflow = "pleme-io/substrate/.github/workflows/python-auto-release.yml@main";
    secrets = [ "PYPI_API_TOKEN" "BOT_PAT?" ];
    semantics = "uv version --bump + uv build + uv publish; skip-already, rate-limit retry";
    status = "shipping";
    reference-impl = "(pending first consumer)";
  };

  helm = {
    detect = "Chart.yaml";
    upstream = "OCI registry (default ghcr.io/pleme-io/helm)";
    bump-action = "pleme-io/actions/helm-bump@main";
    publish-action = "pleme-io/actions/helm-publish@main";
    workflow = "pleme-io/substrate/.github/workflows/helm-auto-release.yml@main";
    secrets = [ "BOT_PAT?" ];  # GITHUB_TOKEN suffices for ghcr.io
    semantics = "in-tlisp semver bump on Chart.yaml; helm push to OCI v2 manifest; skip-already";
    status = "shipping";
    reference-impl = "(pending first consumer)";
  };

  ansible-collection = {
    detect = "galaxy.yml";
    upstream = "ansible-galaxy";
    bump-action = "pleme-io/actions/substrate-bump@main (polymorphic; routes to .#bump)";
    publish-action = "pleme-io/actions/ansible-collection-publish@main";
    workflow = "pleme-io/substrate/.github/workflows/ansible-collection-auto-bump.yml@main";
    secrets = [ "ANSIBLE_GALAXY_TOKEN" "BOT_PAT?" ];
    semantics = "polymorphic substrate-bump branch + per-collection publish";
    status = "shipping (pre-dates the unified pattern; integration with auto-release.yml dispatcher pending)";
    reference-impl = "ansible-collection-akeyless, ansible-collection-pleme-io";
  };

  ruby-gem = {
    detect = "*.gemspec at root";
    upstream = "rubygems.org";
    bump-action = "pleme-io/actions/substrate-bump@main (polymorphic; routes to .#gem:bump)";
    publish-action = "pleme-io/actions/gem-publish@main";
    workflow = "pleme-io/substrate/.github/workflows/gem-release.yml@main";
    secrets = [ "RUBYGEMS_API_KEY" "BOT_PAT?" ];
    semantics = "polymorphic substrate-bump + gem publish";
    status = "shipping (pre-dates the unified pattern)";
    reference-impl = "pangea-core, pangea-aws, ...";
  };

  github-action = {
    detect = "action.yml at repo root";
    upstream = "ghcr.io action image + v<MAJOR>.<MINOR>.<PATCH> tag + floating v<MAJOR> ref";
    bump-action = "(typically tag-triggered, no auto-bump)";
    publish-action = "pleme-io/substrate/.github/workflows/action-release.yml@main";
    workflow = "pleme-io/substrate/.github/workflows/action-release.yml@main";
    secrets = [ "GITHUB_TOKEN" ];
    semantics = "tag-triggered; validates action.yml; cuts GH Release; fast-forwards major branch (v1)";
    status = "shipping (pre-dates the unified pattern)";
    reference-impl = "pleme-io/actions — 17 actions live at v0.13.x";
  };
}
