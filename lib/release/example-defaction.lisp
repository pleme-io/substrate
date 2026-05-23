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
;; The renderer produces 3 files per (defaction ...):
;;   <name>/action.yml   — 5 canonical sections from the typed Action
;;   <name>/run.tlisp    — stdlib loader + :body content
;;   <name>/README.md    — auto-generated table from :inputs/:outputs
;;
;; The renderer produces N file-triples per (defaction-suite ...).
;;
;; The renderer validates caixa-aware actions against the typed
;; caixa schema at build-time; mismatches are compile-time errors,
;; not runtime errors at action invocation.
;; ─────────────────────────────────────────────────────────────────
