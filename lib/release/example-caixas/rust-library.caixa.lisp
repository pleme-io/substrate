;; rust-library.caixa.lisp — typed source for a Rust library
;; (defcaixa). One file declares the full operator-facing
;; surface; the renderer emits Cargo.toml + .pleme-io-release.toml
;; + .github/workflows/{auto-release,pre-merge-gate,security-gate}.yml
;; mechanically.
;;
;; After ACTION-AS-CAIXA M3-M4: operator authors ONE caixa form.
;; Every downstream file (manifest, CI shims, config, docs)
;; renders from this source.

(defcaixa my-rust-lib
  :kind         :Biblioteca
  :ecosystem    :rust-single-crate

  ;; Cargo.toml [package] (rendered)
  :package      { :name        "my-rust-lib"
                  :version     "0.1.0"
                  :description "A typed pleme-io Rust library."
                  :license     "MIT"
                  :repository  "https://github.com/pleme-io/my-rust-lib"
                  :categories  [ "rust-patterns" "command-line-utilities" ]
                  :keywords    [ "pleme-io" "typed" ] }

  ;; .pleme-io-release.toml [bump] / [publish] / [security] (rendered)
  :ci-config    { :bump     { :default-type "patch"
                              :skip-when-no-source-changes true }
                  :publish  { :no-verify true }
                  :security { :fail-on-severity "high"
                              :check-license-headers true
                              :license "MIT" } }

  ;; .github/workflows/auto-release.yml (rendered — 3-line shim)
  ;; .github/workflows/pre-merge-gate.yml (rendered — 3-line shim)
  ;; .github/workflows/security-gate.yml (rendered — 5-line shim)
  :workflows    [ :auto-release :pre-merge-gate :security-gate ]

  ;; Optional: ship docs to gh-pages
  :docs         { :enabled true
                  :format  :cargo-doc
                  :branch  "gh-pages" }

  ;; Optional: post release events to Slack
  :notify       { :slack { :webhook-secret "SLACK_WEBHOOK_URL" } } )

;; Renderer:
;;   cd my-rust-lib/
;;   pleme-release render-caixa rust-library.caixa.lisp
;;
;; Output (committed to repo root):
;;   Cargo.toml
;;   .pleme-io-release.toml
;;   .github/workflows/auto-release.yml
;;   .github/workflows/pre-merge-gate.yml
;;   .github/workflows/security-gate.yml
;;
;; Operator never edits yaml. The caixa is the source of truth.
