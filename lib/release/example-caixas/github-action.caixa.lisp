;; github-action.caixa.lisp — typed source for a pleme-io GH action.
;;
;; THE ULTIMATE REUSABILITY: an action is itself a caixa.
;;
;; Per ACTION-AS-CAIXA M4: each (defaction ...) form IS a (defcaixa)
;; specialized to the :GhAction kind. The same renderer that emits
;; rust-library caixas → Cargo.toml + ci shims emits action caixas
;; → action.yml + run.tlisp + README.md + patterns-full.nix entry.
;;
;; This file shows the unification: the same operator-facing shape
;; declares any artifact in the pleme-io substrate.

(defcaixa my-pleme-action
  :kind         :GhAction          ;; specialization of caixa
  :ecosystem    :github-action

  :action       { :name        "my-pleme-action"
                  :description "Do <one specific thing> per the pleme-io pattern."
                  :branding    { :icon "box" :color "green" }

                  :inputs      { :input-a { :required true
                                            :description "first input" }
                                 :input-b { :default  "patch"
                                            :description "second input" } }

                  :outputs     { :output-x { :type :bool
                                             :description "did it succeed" } }

                  :installs    [ :rust-toolchain ]
                  :wraps       "your-cli your-args"

                  :body        (... typed tlisp body — uses _tlisp-stdlib helpers ...) }

  :ci-config    { :validation { :run-tlisp-lint true
                                :enforce-no-shell true } }

  :workflows    [ :auto-release :pre-merge-gate ] )

;; Renders to (M2+ renderer):
;;   my-pleme-action/action.yml
;;   my-pleme-action/run.tlisp
;;   my-pleme-action/README.md
;;   substrate/lib/release/patterns-full.nix +1 entry (mechanical)
;;   .github/workflows/auto-release.yml (the actions-repo's auto-bump)
;;   .github/workflows/pre-merge-gate.yml
;;
;; ALL FROM ONE FILE. The 5-layer exposure stack is fully derived.

;; ─────────────────────────────────────────────────────────────────
;; THE ULTIMATE INTERLOCK
;;
;; - A new action = 1 (defcaixa :kind :GhAction) form
;; - The catalog regenerates (patterns-full.nix)
;; - Per-action README regenerates (pleme-doc-gen)
;; - Adoption-audit picks it up (next weekly cron)
;; - Substrate workflows can compose it via :uses-action :my-pleme-action
;; - Other caixas can declare :also-uses [:my-pleme-action] for opt-in
;;
;; Operator authors ONE TYPED LISP FILE. The fleet absorbs it.
;; ─────────────────────────────────────────────────────────────────
