;; example-defaction.lisp — reference shape for the (defaction ...)
;; form that ACTION-AS-CAIXA M1+ will render mechanically into the
;; action.yml + run.tlisp + README.md triple.
;;
;; Reading this file, an operator should see EXACTLY how the next
;; 100+ primitives are authored after M2 cuts over.
;;
;; arch-synthesizer's Action domain (planned) consumes this shape.

(defaction cargo-bump
  :description "Bump a single-crate Rust repo's package.version field."
  :branding   { :icon "arrow-up-circle" :color "green" }
  :inputs     { :bump-type                   { :default "patch" :description "patch | minor | major" }
                :skip-when-no-source-changes { :default "true"  :description "Skip when no source changed since last tag" }
                :source-paths                { :default "src Cargo.toml Cargo.lock" } }
  :outputs    { :bumped      { :description "true if a bump happened" }
                :new-version { :description "new version after bump" }
                :old-version { :description "previous version" } }
  :installs   [ :rust-toolchain :cargo-edit :nix ]
  :body
    (define bump-type
      (config-resolve "BUMP_TYPE" "bump" "default-type" "patch"))
    (define skip-flag
      (config-resolve "SKIP_WHEN_NO_SOURCE_CHANGES" "bump" "skip-when-no-source-changes" "true"))
    (define source-paths
      (config-resolve "SOURCE_PATHS" "bump" "source-paths" "src Cargo.toml Cargo.lock"))
    ;; ... rest of body unchanged from current cargo-bump/run.tlisp
    ))

;; ─────────────────────────────────────────────────────────────────
;; Suite-level declaration: all 5 akeyless actions in ONE form.
;; M3 of the migration roadmap. Generates 5 action triples
;; mechanically + composes shared :installs / :auth-token-env /
;; etc. across the suite.
;; ─────────────────────────────────────────────────────────────────

(defaction-suite akeyless
  :description "Akeyless CLI primitives — every action in this suite
                shares OIDC auth + AKEYLESS_TOKEN env conventions."
  :shared     { :installs [ :jq :curl ]
                :auth-env "AKEYLESS_TOKEN" }
  :actions
    [ (defaction akeyless-auth
        :description "Login via OIDC JWT or access-key."
        :inputs     { :access-id { :required true }
                      :use-gh-jwt { :default "true" }
                      :api-url    { :default "https://api.akeyless.io" } }
        :outputs    { :token { :description "AKEYLESS_TOKEN" } }
        :body       (... auth flow body ...))

      (defaction akeyless-secret-fetch
        :description "Pull a secret value."
        :inputs     { :secret-name { :required true }
                      :output-env  { :default "" }
                      :api-url     { :default "https://api.akeyless.io" } }
        :outputs    { :value { :description "Secret value (auto-masked)" } }
        :body       (... fetch flow body ...))

      (defaction akeyless-rotate ...)
      (defaction akeyless-export-config ...)
      (defaction akeyless-injector-validate ...) ])

;; ─────────────────────────────────────────────────────────────────
;; Caixa-aware action: type-safe composition with Servico/Aplicacao.
;; M4 of the migration roadmap. The action declares which caixa
;; kinds it can operate on; the renderer validates inputs against
;; the matching caixa's M2/M3 slots at build-time.
;; ─────────────────────────────────────────────────────────────────

(defaction helm-deploy-caixa
  :description "Deploy a Servico/Aplicacao caixa to a target cluster."
  :expects-caixa-kind  [ :Servico :Aplicacao ]
  :inputs              { :caixa-name      { :required true }
                         :cluster-context { :required true } }
  :uses-caixa-slot     { :limits   :M2
                         :placement :M3 }   ;; pulls from caixa's typed slots
  :outputs             { :deployed { :description "true on success" }
                         :revision { :description "helm revision number" } }
  :body
    ;; Body has access to the resolved caixa value as `caixa`
    (define caixa (caixa-load (env-required "CAIXA_NAME")))
    (define limits (caixa-slot caixa :limits))   ;; typed access
    (define placement (caixa-slot caixa :placement))
    ;; Helm install with limits + placement from typed slots
    ;; (no string concatenation; no format!)
    ...)

;; ─────────────────────────────────────────────────────────────────
;; (defworkflow ...) — typed composition of actions into a reusable
;; workflow. M2 of the migration roadmap. Renders to substrate's
;; .github/workflows/<name>.yml. Sister of (defaction ...).
;;
;; Crucially: every :uses-action / :uses-workflow ref is TYPED.
;; The renderer validates against the action catalog at build time.
;; ─────────────────────────────────────────────────────────────────

(defworkflow auto-release
  :description "Polymorphic dispatcher — push to main → per-language bump+publish."
  :triggers    [ (:push :branches [ "main" ])
                 (:workflow-dispatch
                   :inputs { :bump-type { :default "patch" } }) ]
  :permissions { :contents :write
                 :packages :write }
  :secrets     [ :CRATES_API_TOKEN :NPM_TOKEN :PYPI_API_TOKEN :BOT_PAT ]
  :jobs
    [ (:job detect
        :uses-action :detect-repo-type
        :outputs     [ :repo-type ])
      (:job rust-workspace
        :needs detect
        :when (= (output detect :repo-type) "rust-workspace")
        :uses-workflow :rust-auto-release
        :with { :bump-type (input :bump-type) })
      (:job rust-single-crate
        :needs detect
        :when (= (output detect :repo-type) "rust-single-crate")
        :uses-workflow :cargo-auto-release)
      (:job npm
        :needs detect
        :when (= (output detect :repo-type) "npm")
        :uses-workflow :npm-auto-release)
      (:job python
        :needs detect
        :when (= (output detect :repo-type) "python")
        :uses-workflow :python-auto-release)
      (:job helm
        :needs detect
        :when (= (output detect :repo-type) "helm")
        :uses-workflow :helm-auto-release)
      (:job caixa
        :needs detect
        :when (= (output detect :repo-type) "caixa")
        :uses-workflow :caixa-auto-release) ])

;; ─────────────────────────────────────────────────────────────────
;; (defworkflow ...) with COMPOSED jobs — pre-merge-gate.yml
;; Demonstrates how :uses-action / :uses-workflow / direct :run
;; tlisp bodies compose in one form.
;; ─────────────────────────────────────────────────────────────────

(defworkflow pre-merge-gate
  :description "PR-time quality + security gate (polymorphic by repo type)."
  :triggers    [ (:pull-request :branches [ "main" ]) ]
  :jobs
    [ (:job detect          :uses-action :detect-repo-type)
      (:job rust-quality
        :when (or (= (output detect :repo-type) "rust-workspace")
                  (= (output detect :repo-type) "rust-single-crate"))
        :uses-action :rust-gate)
      (:job npm-quality
        :when (= (output detect :repo-type) "npm")
        :uses-action :npm-gate)
      (:job python-quality
        :when (= (output detect :repo-type) "python")
        :uses-action :python-gate)
      (:job tlisp-balance   :uses-action :tlisp-lint)
      (:job action-shell-ban
        :when (= (output detect :repo-type) "github-action")
        :uses-action :action-shell-lint
        :with { :threshold "15" :fail-on-violation "true" })
      (:job publish-dry-run
        :when (!= (output detect :repo-type) "unknown")
        :uses-workflow :auto-release-verify) ])

;; ─────────────────────────────────────────────────────────────────
;; (defworkflow ...) for caixa-aware actions
;; The renderer validates that :uses-action refs exist in the
;; action catalog + that their :expects-caixa-kind matches the
;; caixa context.
;; ─────────────────────────────────────────────────────────────────

(defworkflow cd-stack
  :description "Turnkey CD pipeline: helm-deploy + flux-reconcile + slack-notify."
  :triggers    [ (:workflow-call
                   :inputs { :release   { :type :string :required true }
                             :chart     { :type :string :required true }
                             :namespace { :type :string :default  "default" } }
                   :secrets [ :KUBECONFIG_B64 :SLACK_WEBHOOK_URL ]) ]
  :jobs
    [ (:job deploy
        :uses-action :helm-deploy
        :with { :release (input :release)
                :chart   (input :chart)
                :namespace (input :namespace) }
        :outputs [ :deployed :revision ])
      (:job reconcile
        :needs deploy
        :when (= (input :reconcile-after) "true")
        :uses-action :flux-reconcile
        :with { :kind :helmrelease :name (input :release) :namespace (input :namespace) })
      (:job notify
        :needs [ deploy reconcile ]
        :when (always)
        :uses-action :slack-notify
        :with { :webhook-url (secret :SLACK_WEBHOOK_URL)
                :title (format "CD: {} → {}" (input :release)
                          (if (= (output deploy :deployed) "true") "deployed" "FAILED"))
                :body  (format "chart={} ns={} revision={}" (input :chart)
                          (input :namespace) (output deploy :revision))
                :color (if (= (output deploy :deployed) "true") "good" "danger") }) ])

;; ─────────────────────────────────────────────────────────────────
;; Renderer summary:
;;
;;   (defaction X)            → pleme-io/actions/X/{action.yml, run.tlisp, README.md}
;;                              + patterns.nix entry
;;                              + skill table row
;;                              + example-config.toml schema
;;
;;   (defaction-suite X)      → N action triples + shared :installs
;;
;;   (defworkflow X)          → pleme-io/substrate/.github/workflows/X.yml
;;                              + patterns.nix workflows entry
;;
;;   (defcaixa X)             → adopting-repo .github/workflows/{auto-release,
;;                                pre-merge-gate, security-gate}.yml
;;                              + .pleme-io-release.toml
;;
;; The renderer is one binary: arch-synthesizer render --in <X>.lisp --out <dir>
;; Per the prime directive: hand-authoring is the FALLBACK. Every
;; downstream artifact is mechanically derived from typed Lisp.
;; ─────────────────────────────────────────────────────────────────
