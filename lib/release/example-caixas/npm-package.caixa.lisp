;; npm-package.caixa.lisp — typed source for an npm package.

(defcaixa my-npm-pkg
  :kind         :Biblioteca
  :ecosystem    :npm

  :package      { :name        "@pleme-io/my-pkg"
                  :version     "0.1.0"
                  :description "A typed pleme-io npm package."
                  :license     "MIT"
                  :repository  "git+https://github.com/pleme-io/my-npm-pkg.git"
                  :keywords    [ "pleme-io" "typed" ] }

  :ci-config    { :bump    { :default-type "patch" }
                  :publish { :access "public" } }

  :workflows    [ :auto-release :pre-merge-gate :security-gate ]

  ;; Optional: render TypeDoc + deploy to gh-pages
  :docs         { :enabled true
                  :format  :typedoc } )

;; Renders to:
;;   package.json
;;   .pleme-io-release.toml
;;   .github/workflows/*.yml  (consumer shims)
