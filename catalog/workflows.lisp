; substrate workflow catalog — the typed reflection of every reusable
; workflow this repo publishes.
;
; WHY THIS FILE EXISTS
;
; substrate ships 71 reusable workflows carrying 1449 consumer call-sites
; across the fleet, and until now nothing declared what any of them TAKES,
; EMITS, or OWNS. That is the gap this closes: a consumer had to read the YAML
; to learn a workflow's contract, and nothing could measure whether a pattern
; already had a home — which is how 144 hand-authored workflows accumulated in
; 99 repos underneath an 81%-adopted substrate.
;
; ENFORCED, not decorative: `catalog/check.tlisp` fails when a reusable
; workflow exists with no row here, so adding one REQUIRES landing its entry in
; the same commit (the fleet's CATALOG REFLECTION rule).
;
; `:consumers` is a MEASURED count over locally-cloned repos as of 2026-08-04,
; not a live query — a repo that is not cloned here contributes 0. Treat a zero
; as "no local caller found", never as proof of death.


(defworkflow cargo-auto-release
  :file      "cargo-auto-release.yml"
  :pattern   rust-workspace
  :inputs    (bump-type crate-path source-paths add-paths no-verify regenerate-cargo-nix runner)
  :outputs   ()
  :secrets   (CRATES_API_TOKEN BOT_PAT)
  :consumers 362)

(defworkflow reusable-gen-spec
  :file      "reusable-gen-spec.yml"
  :pattern   gen-spec
  :inputs    (gen-ref runner)
  :outputs   ()
  :secrets   ()
  :consumers 337)

(defworkflow pre-merge-gate
  :file      "pre-merge-gate.yml"
  :pattern   gate
  :inputs    (run-rust-gate run-npm-gate run-python-gate run-tlisp-lint run-workflow-shim-lint run-publish-verify runner)
  :outputs   ()
  :secrets   (CRATES_API_TOKEN NPM_TOKEN PYPI_API_TOKEN BOT_PAT)
  :consumers 166)

(defworkflow security-gate
  :file      "security-gate.yml"
  :pattern   gate
  :inputs    (fail-on-severity license check-license-headers runner)
  :outputs   ()
  :secrets   ()
  :consumers 164)

(defworkflow rust-auto-release
  :file      "rust-auto-release.yml"
  :pattern   rust
  :inputs    (bump-type source-paths add-paths rename-prefix no-verify runner)
  :outputs   ()
  :secrets   (CRATES_API_TOKEN BOT_PAT)
  :consumers 51)

(defworkflow go-auto-release
  :file      "go-auto-release.yml"
  :pattern   go
  :inputs    (bump-type module-path changed-globs tag-glob go-version proxy-poll-attempts runner)
  :outputs   ()
  :secrets   (BOT_PAT)
  :consumers 45)

(defworkflow nix-image-auto-release
  :file      "nix-image-auto-release.yml"
  :pattern   nix
  :inputs    (release-app registry-host runner working-directory scan-before-push image-attr scan-image-ref scan-fail-on-severity scan-ignore-unfixed scan-ignore-file scan-vex-file boot-check-cmd boot-check-image-ref boot-check-env boot-check-still-running boot-check-expect-log vulnix-scan vulnix-scan-app vulnix-scan-advisory-only grype-scan grype-scan-app grype-scan-advisory-only extraSubstituters extraTrustedPublicKeys requireSigs superCacheSaveEndpoint sbom-attest sbom-attest-app cosign-sign cosign-sign-app cartorio-attest cartorio-subject cartorio-closure-info-attr)
  :outputs   ()
  :secrets   (BOT_PAT GHCR_TOKEN ECR_TOKEN)
  :consumers 40)

(defworkflow gem-auto-bump
  :file      "gem-auto-bump.yml"
  :pattern   ruby-gem
  :inputs    (bump-type)
  :outputs   ()
  :secrets   (BOT_PAT)
  :consumers 38)

(defworkflow gem-ci
  :file      "gem-ci.yml"
  :pattern   ruby-gem
  :inputs    ()
  :outputs   ()
  :secrets   (BOT_PAT)
  :consumers 38)

(defworkflow gem-release
  :file      "gem-release.yml"
  :pattern   ruby-gem
  :inputs    (gem-name ruby-version runner)
  :outputs   ()
  :secrets   (RUBYGEMS_API_KEY)
  :consumers 38)

(defworkflow image-push
  :file      "image-push.yml"
  :pattern   container-image
  :inputs    (imageAttr tag registry imageName flakeRef additionalTags runner buildCores maxJobs extraSubstituters extraTrustedPublicKeys netrcFile requireSigs superCacheSaveEndpoint scanBeforePush scanFailOnSeverity scanIgnoreUnfixed scanIgnoreFile)
  :outputs   ()
  :secrets   (BOT_PAT GHCR_TOKEN ECR_TOKEN)
  :consumers 36)

(defworkflow vendor-image-mirror
  :file      "vendor-image-mirror.yml"
  :pattern   container-image
  :inputs    (ref zot-registry zot-repo zot-tag fail-on-severity ignore-file vex runner zot-username source-registry source-username)
  :outputs   (admitted severity result zot-digest)
  :secrets   (ZOT_PASSWORD SOURCE_PASSWORD CA_CERT_TOKEN)
  :consumers 35)

(defworkflow cargo-ci
  :file      "cargo-ci.yml"
  :pattern   rust-workspace
  :inputs    (flake-args devshell test-args build-targets fmt-check devshell-args)
  :outputs   ()
  :secrets   ()
  :consumers 24)

(defworkflow reusable-flakehub
  :file      "reusable-flakehub.yml"
  :pattern   other
  :inputs    (visibility rolling directory runner)
  :outputs   ()
  :secrets   ()
  :consumers 22)

(defworkflow cargo-publish-each-member-auto-release
  :file      "cargo-publish-each-member-auto-release.yml"
  :pattern   rust-workspace
  :inputs    (bump-type dry-run no-verify skip-when-no-source-changes)
  :outputs   ()
  :secrets   (CRATES_API_TOKEN BOT_PAT)
  :consumers 14)

(defworkflow cargo-gate-ci
  :file      "cargo-gate-ci.yml"
  :pattern   rust-workspace
  :inputs    (os-matrix fmt-args test-args clippy-advisory run-fmt rust-toolchain)
  :outputs   ()
  :secrets   ()
  :consumers 13)

(defworkflow crates-publish
  :file      "crates-publish.yml"
  :pattern   other
  :inputs    ()
  :outputs   ()
  :secrets   (CRATES_API_TOKEN)
  :consumers 10)

(defworkflow auto-release
  :file      "auto-release.yml"
  :pattern   other
  :inputs    (bump-type runner)
  :outputs   ()
  :secrets   (CRATES_API_TOKEN NPM_TOKEN PYPI_API_TOKEN BOT_PAT ANSIBLE_GALAXY_TOKEN)
  :consumers 8)

(defworkflow rust-binary-release
  :file      "rust-binary-release.yml"
  :pattern   rust
  :inputs    (binary-name features no-default-features system-deps app-bundle app-name bundle-id icon-svg desktop-categories min-system-version)
  :outputs   ()
  :secrets   ()
  :consumers 7)

(defworkflow cargo-release
  :file      "cargo-release.yml"
  :pattern   rust-workspace
  :inputs    (runner)
  :outputs   ()
  :secrets   (CRATES_API_TOKEN)
  :consumers 4)

(defworkflow caixa-validate
  :file      "caixa-validate.yml"
  :pattern   caixa-package
  :inputs    (runner strict build strictPalavra caixaPath)
  :outputs   ()
  :secrets   ()
  :consumers 3)

(defworkflow helm-monorepo-auto-release
  :file      "helm-monorepo-auto-release.yml"
  :pattern   helm-chart
  :inputs    (registry release-app runner)
  :outputs   ()
  :secrets   (BOT_PAT GHCR_TOKEN)
  :consumers 3)

(defworkflow retirada-ci-watch
  :file      "retirada-ci-watch.yml"
  :pattern   ops
  :inputs    (watch-repo watch-workflow dry-run loop-for-secs poll-interval-secs source-dir runner)
  :outputs   ()
  :secrets   ()
  :consumers 3)

(defworkflow ansible-collection-ansible-test
  :file      "ansible-collection-ansible-test.yml"
  :pattern   ansible-collection
  :inputs    (namespace name python-version)
  :outputs   ()
  :secrets   ()
  :consumers 2)

(defworkflow ansible-collection-auto-bump
  :file      "ansible-collection-auto-bump.yml"
  :pattern   ansible-collection
  :inputs    (bump-type)
  :outputs   ()
  :secrets   (BOT_PAT)
  :consumers 2)

(defworkflow ansible-collection-auto-merge
  :file      "ansible-collection-auto-merge.yml"
  :pattern   ansible-collection
  :inputs    ()
  :outputs   ()
  :secrets   ()
  :consumers 2)

(defworkflow ansible-collection-ci
  :file      "ansible-collection-ci.yml"
  :pattern   ansible-collection
  :inputs    (openapi-spec-url)
  :outputs   ()
  :secrets   ()
  :consumers 2)

(defworkflow ansible-collection-docs-lint
  :file      "ansible-collection-docs-lint.yml"
  :pattern   ansible-collection
  :inputs    (namespace name)
  :outputs   ()
  :secrets   ()
  :consumers 2)

(defworkflow ansible-collection-integration-live
  :file      "ansible-collection-integration-live.yml"
  :pattern   ansible-collection
  :inputs    ()
  :outputs   ()
  :secrets   ()
  :consumers 2)

(defworkflow ansible-collection-matrix
  :file      "ansible-collection-matrix.yml"
  :pattern   ansible-collection
  :inputs    (openapi-spec-url)
  :outputs   ()
  :secrets   ()
  :consumers 2)

(defworkflow ansible-collection-published-install
  :file      "ansible-collection-published-install.yml"
  :pattern   ansible-collection
  :inputs    (collection modules)
  :outputs   ()
  :secrets   ()
  :consumers 2)

(defworkflow ansible-collection-release
  :file      "ansible-collection-release.yml"
  :pattern   ansible-collection
  :inputs    ()
  :outputs   ()
  :secrets   (ANSIBLE_GALAXY_TOKEN)
  :consumers 2)

(defworkflow ansible-collection-upstream-watch
  :file      "ansible-collection-upstream-watch.yml"
  :pattern   ansible-collection
  :inputs    (upstream-spec-url spec-resources-repo)
  :outputs   ()
  :secrets   ()
  :consumers 2)

(defworkflow codeql-scan
  :file      "codeql-scan.yml"
  :pattern   gate
  :inputs    (languages runner)
  :outputs   ()
  :secrets   ()
  :consumers 2)

(defworkflow cve-suppression-gate
  :file      "cve-suppression-gate.yml"
  :pattern   gate
  :inputs    (fail-on-violation runner)
  :outputs   ()
  :secrets   ()
  :consumers 2)

(defworkflow helm-chart-release
  :file      "helm-chart-release.yml"
  :pattern   helm-chart
  :inputs    (chart-path oci-registry lib-chart-dir lib-chart-name runner)
  :outputs   ()
  :secrets   (GHCR_TOKEN)
  :consumers 2)

(defworkflow nix-devshell-cargo-test
  :file      "nix-devshell-cargo-test.yml"
  :pattern   nix
  :inputs    (runner devshell test-args fmt-check devshell-args)
  :outputs   ()
  :secrets   ()
  :consumers 2)

(defworkflow action-release
  :file      "action-release.yml"
  :pattern   action-release
  :inputs    (action-glob release-notes major-ref)
  :outputs   ()
  :secrets   ()
  :consumers 1)

(defworkflow caixa-publish
  :file      "caixa-publish.yml"
  :pattern   caixa-package
  :inputs    (caixaName registry runner tagPrefix pushLatest)
  :outputs   ()
  :secrets   (GHCR_TOKEN BOT_PAT)
  :consumers 1)

(defworkflow crossplane-function-auto-release
  :file      "crossplane-function-auto-release.yml"
  :pattern   iac-provider
  :inputs    (release-app tag registry-host runner extraSubstituters extraTrustedPublicKeys requireSigs)
  :outputs   ()
  :secrets   (GHCR_TOKEN BOT_PAT)
  :consumers 1)

(defworkflow mac-autobump-release
  :file      "mac-autobump-release.yml"
  :pattern   other
  :inputs    (package binary-name suffix target features no-default-features runner prerelease)
  :outputs   ()
  :secrets   (BOT_PAT)
  :consumers 1)

(defworkflow action-pipeline
  :file      "action-pipeline.yml"
  :pattern   universal-composer
  :inputs    (pipeline checkout-actions-ref runner)
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow ai-stack
  :file      "ai-stack.yml"
  :pattern   stack-composition
  :inputs    ()
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow auto-release-min
  :file      "auto-release-min.yml"
  :pattern   other
  :inputs    (bump-type)
  :outputs   ()
  :secrets   (BOT_PAT)
  :consumers 0)

(defworkflow auto-release-verify
  :file      "auto-release-verify.yml"
  :pattern   other
  :inputs    ()
  :outputs   ()
  :secrets   (CRATES_API_TOKEN NPM_TOKEN PYPI_API_TOKEN BOT_PAT)
  :consumers 0)

(defworkflow caixa-auto-release
  :file      "caixa-auto-release.yml"
  :pattern   caixa-package
  :inputs    (bump-type caixa-path)
  :outputs   ()
  :secrets   (BOT_PAT)
  :consumers 0)

(defworkflow caixa-forge
  :file      "caixa-forge.yml"
  :pattern   caixa-package
  :inputs    (spec outputs runner commitOnDrift branchPrefix)
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow caixa-publish-tlisp
  :file      "caixa-publish-tlisp.yml"
  :pattern   caixa-package
  :inputs    (caixaPath tagPrefix runner)
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow caixa-tlisp-auto-release
  :file      "caixa-tlisp-auto-release.yml"
  :pattern   caixa-package
  :inputs    (bump-type source-paths manifest-glob runner)
  :outputs   ()
  :secrets   (BOT_PAT)
  :consumers 0)

(defworkflow cd-stack
  :file      "cd-stack.yml"
  :pattern   stack-composition
  :inputs    (release chart namespace values-files reconcile-after reconcile-kind notify-slack)
  :outputs   ()
  :secrets   (KUBECONFIG_B64 SLACK_WEBHOOK_URL)
  :consumers 0)

(defworkflow comment-command-dispatch
  :file      "comment-command-dispatch.yml"
  :pattern   other
  :inputs    (catalog-path command trigger min-permission trust-pr-author allowlist target-label target-workflow target-workflow-ref target-repository-dispatch-event target-repository-dispatch-repo)
  :outputs   (dispatched outcome)
  :secrets   ()
  :consumers 0)

(defworkflow compliance-attest
  :file      "compliance-attest.yml"
  :pattern   attestation
  :inputs    ()
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow container-stack
  :file      "container-stack.yml"
  :pattern   stack-composition
  :inputs    (image tag platforms scan-fail-on sbom-format)
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow crossplane-provider-publish
  :file      "crossplane-provider-publish.yml"
  :pattern   iac-provider
  :inputs    (provider-name registry org package-dir runner)
  :outputs   ()
  :secrets   (UPBOUND_TOKEN GHCR_TOKEN BOT_PAT)
  :consumers 0)

(defworkflow cse-audit
  :file      "cse-audit.yml"
  :pattern   gate
  :inputs    (workspace_root strict only)
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow data-stack
  :file      "data-stack.yml"
  :pattern   stack-composition
  :inputs    ()
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow esteira-rio-bump
  :file      "esteira-rio-bump.yml"
  :pattern   esteira
  :inputs    (bump-type skip-paths runner)
  :outputs   ()
  :secrets   (BOT_PAT)
  :consumers 0)

(defworkflow esteira-rio-release
  :file      "esteira-rio-release.yml"
  :pattern   esteira
  :inputs    (release-app tag needs-tag runner)
  :outputs   ()
  :secrets   (GHCR_TOKEN)
  :consumers 0)

(defworkflow go-binary-release
  :file      "go-binary-release.yml"
  :pattern   go
  :inputs    (binary-name main-path go-version homebrew-tap homebrew-description homepage cosign)
  :outputs   ()
  :secrets   (HOMEBREW_TAP_TOKEN)
  :consumers 0)

(defworkflow go-gen-spec
  :file      "go-gen-spec.yml"
  :pattern   go
  :inputs    (gen-ref)
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow helm-auto-release
  :file      "helm-auto-release.yml"
  :pattern   helm-chart
  :inputs    (bump-type registry source-paths add-paths runner)
  :outputs   ()
  :secrets   (BOT_PAT)
  :consumers 0)

(defworkflow helm-publish
  :file      "helm-publish.yml"
  :pattern   helm-chart
  :inputs    (chartPath registry version libChartDir libChartName runner)
  :outputs   ()
  :secrets   (GHCR_TOKEN BOT_PAT)
  :consumers 0)

(defworkflow ios-game-ci
  :file      "ios-game-ci.yml"
  :pattern   other
  :inputs    (runner run-build-sim)
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow npm-auto-release
  :file      "npm-auto-release.yml"
  :pattern   node-package
  :inputs    (bump-type access source-paths add-paths runner)
  :outputs   ()
  :secrets   (NPM_TOKEN BOT_PAT)
  :consumers 0)

(defworkflow observability-deploy
  :file      "observability-deploy.yml"
  :pattern   other
  :inputs    ()
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow pleme-ansible
  :file      "pleme-ansible.yml"
  :pattern   family-composer
  :inputs    (target)
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow pleme-caixa
  :file      "pleme-caixa.yml"
  :pattern   family-composer
  :inputs    (target)
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow pleme-container
  :file      "pleme-container.yml"
  :pattern   family-composer
  :inputs    (target)
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow pleme-go
  :file      "pleme-go.yml"
  :pattern   family-composer
  :inputs    (target)
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow pleme-helm
  :file      "pleme-helm.yml"
  :pattern   family-composer
  :inputs    (target)
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow pleme-iac
  :file      "pleme-iac.yml"
  :pattern   family-composer
  :inputs    (target)
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow pleme-ops
  :file      "pleme-ops.yml"
  :pattern   family-composer
  :inputs    (target)
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow pleme-publish
  :file      "pleme-publish.yml"
  :pattern   family-composer
  :inputs    (target)
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow pleme-ruby
  :file      "pleme-ruby.yml"
  :pattern   family-composer
  :inputs    (target)
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow pleme-rust
  :file      "pleme-rust.yml"
  :pattern   family-composer
  :inputs    (target)
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow pleme-stack
  :file      "pleme-stack.yml"
  :pattern   stack-composition
  :inputs    (build-container image)
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow pleme
  :file      "pleme.yml"
  :pattern   universal-composer
  :inputs    (family target runner)
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow pulumi-provider-publish
  :file      "pulumi-provider-publish.yml"
  :pattern   iac-provider
  :inputs    (provider-name go-version python-version node-version runner)
  :outputs   ()
  :secrets   (PULUMI_ACCESS_TOKEN NPM_TOKEN PYPI_TOKEN)
  :consumers 0)

(defworkflow python-auto-release
  :file      "python-auto-release.yml"
  :pattern   python-package
  :inputs    (bump-type source-paths add-paths runner)
  :outputs   ()
  :secrets   (PYPI_API_TOKEN BOT_PAT)
  :consumers 0)

(defworkflow release-pipeline
  :file      "release-pipeline.yml"
  :pattern   other
  :inputs    (build-container image)
  :outputs   ()
  :secrets   ()
  :consumers 0)

(defworkflow rust-binary-auto-release
  :file      "rust-binary-auto-release.yml"
  :pattern   rust
  :inputs    (bump-type source-paths binary-name features no-default-features runner)
  :outputs   ()
  :secrets   (BOT_PAT)
  :consumers 0)

(defworkflow rust-release
  :file      "rust-release.yml"
  :pattern   rust
  :inputs    (crateName publishCrate bumpType runOnTag)
  :outputs   ()
  :secrets   (CRATES_API_TOKEN)
  :consumers 0)

(defworkflow steampipe-plugin-publish
  :file      "steampipe-plugin-publish.yml"
  :pattern   iac-provider
  :inputs    (plugin-name org go-version runner)
  :outputs   ()
  :secrets   (STEAMPIPE_REGISTRY_TOKEN)
  :consumers 0)

(defworkflow super-cache-ci-build-matrix
  :file      "super-cache-ci-build-matrix.yml"
  :pattern   build-cache
  :inputs    (flake-ref image-base arches services exclude eval-system matrix-max-parallel runner sui-mode lang registry fail-on-severity enforce-posture require-build discover-runner)
  :outputs   ()
  :secrets   (GHCR_TOKEN BOT_PAT)
  :consumers 0)

(defworkflow super-cache-ci-build
  :file      "super-cache-ci-build.yml"
  :pattern   build-cache
  :inputs    (svc arch runner sui-mode lang image-attr registry fail-on-severity enforce-posture require-build security-layers cosign-key-ref)
  :outputs   ()
  :secrets   (GHCR_TOKEN)
  :consumers 0)

(defworkflow terraform-provider-publish
  :file      "terraform-provider-publish.yml"
  :pattern   iac-provider
  :inputs    (provider-name namespace goreleaser-config runner)
  :outputs   ()
  :secrets   (TF_REGISTRY_GPG_PRIVATE_KEY TF_REGISTRY_GPG_PASSPHRASE)
  :consumers 0)

(defworkflow web3-stack
  :file      "web3-stack.yml"
  :pattern   stack-composition
  :inputs    ()
  :outputs   ()
  :secrets   ()
  :consumers 0)
