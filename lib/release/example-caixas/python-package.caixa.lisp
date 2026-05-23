;; python-package.caixa.lisp — typed source for a Python package.

(defcaixa my-python-pkg
  :kind         :Biblioteca
  :ecosystem    :python

  :package      { :name        "my-python-pkg"
                  :version     "0.1.0"
                  :description "A typed pleme-io Python package."
                  :license     "MIT"
                  :authors     [ "pleme-io" ]
                  :requires-python ">=3.10" }

  :ci-config    { :bump    { :default-type "patch" }
                  :publish { :dry-run false } }

  :workflows    [ :auto-release :pre-merge-gate :security-gate ]

  ;; Optional: ship mkdocs to gh-pages
  :docs         { :enabled true
                  :format  :mkdocs } )

;; Renders to:
;;   pyproject.toml
;;   .pleme-io-release.toml
;;   .github/workflows/*.yml
