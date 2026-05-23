;; cargo-bump.lisp — typed source for the cargo-bump action.
;; This 22-line file renders to:
;;   pleme-io/actions/cargo-bump/action.yml   (~50 lines)
;;   pleme-io/actions/cargo-bump/run.tlisp    (~40 lines)
;;   pleme-io/actions/cargo-bump/README.md    (~35 lines)
;;   pleme-io/substrate/lib/release/patterns.nix +1 entry
;; Total downstream: ~130 lines of generated artifacts.
;; Compounding ratio: 22 → 130, ~6×. After M2 the source-only file
;; is the operator-edited surface; the 130 lines are CI-generated.

(defaction cargo-bump
  :category    :bump
  :ecosystem   :rust-single-crate
  :description "Bump a single-crate Rust repo's package.version field."
  :branding    { :icon "arrow-up-circle" :color "green" }
  :inputs      { :bump-type                   { :default "patch" :description "patch | minor | major" }
                 :skip-when-no-source-changes { :default "true"  :description "Skip when no source changed since last tag" }
                 :source-paths                { :default "src Cargo.toml Cargo.lock" } }
  :outputs     { :bumped      { :type :bool   :description "true if a bump happened" }
                 :new-version { :type :string :description "new version after bump" }
                 :old-version { :type :string :description "previous version" } }
  :installs    [ :rust-toolchain :cargo-edit :nix ]
  :wraps       "cargo set-version --bump <bump-type>"
  :body
    ;; Inputs read via config-resolve (env > .pleme-io-release.toml > default)
    (let ((bump-type   (config-resolve "BUMP_TYPE" "bump" "default-type" "patch"))
          (skip-flag   (config-resolve "SKIP_WHEN_NO_SOURCE_CHANGES" "bump"
                                       "skip-when-no-source-changes" "true"))
          (source-paths (config-resolve "SOURCE_PATHS" "bump" "source-paths"
                                        "src Cargo.toml Cargo.lock"))
          (old-version (cargo-package-version)))
      (cond
        ((not (cargo-should-bump? skip-flag source-paths))
         (emit-skip old-version))
        (else
          (let* ((bump-r (cargo-set-version-bump bump-type))
                 (new-version (cargo-package-version)))
            (cond
              ((not (= (status-of bump-r) 0))
               (emit-failure "cargo set-version failed" old-version))
              ((equal? new-version old-version)
               (emit-failure (string-append "version unchanged: " old-version) old-version))
              (else
                (emit-success old-version new-version))))))))
