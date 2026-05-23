;; rust-workspace.caixa.lisp — multi-crate Rust workspace.
;; Same shape as rust-library; :kind = :Supervisor for workspaces
;; that contain multiple Biblioteca/Binario children.

(defcaixa my-rust-workspace
  :kind         :Supervisor
  :ecosystem    :rust-workspace

  :workspace    { :version "0.1.0"
                  :members [ "crate-a" "crate-b" "crate-c" ]
                  :package { :license     "MIT"
                             :repository  "https://github.com/pleme-io/my-rust-workspace"
                             :categories  [ "rust-patterns" ] } }

  :ci-config    { :bump     { :default-type "patch" }
                  :publish  { :no-verify true
                              :rename-prefix "pleme-io-" } }

  :workflows    [ :auto-release :pre-merge-gate :security-gate ]

  ;; Multi-pass dep-order publish — substrate handles automatically
  ;; via the rust-workspace-publish action

  :children
    [ (defcaixa crate-a
        :kind :Biblioteca
        :package { :name "crate-a"
                   :description "Foundation types for the workspace." })
      (defcaixa crate-b
        :kind :Biblioteca
        :package { :name "crate-b"
                   :description "Helpers built on crate-a." })
      (defcaixa crate-c
        :kind :Binario
        :package { :name "crate-c"
                   :description "CLI binary consuming crate-a + crate-b." }) ])

;; Renders to:
;;   Cargo.toml (workspace)
;;   crate-a/Cargo.toml
;;   crate-b/Cargo.toml
;;   crate-c/Cargo.toml
;;   .pleme-io-release.toml
;;   .github/workflows/auto-release.yml  (dispatches to rust-workspace-auto-release)
;;   .github/workflows/pre-merge-gate.yml
;;   .github/workflows/security-gate.yml
