;; npm-bump.lisp — sibling of cargo-bump.lisp. Proves the same
;; typed form generalizes across ecosystems with ZERO new
;; renderer code. The compounding scales linearly.

(defaction npm-bump
  :category    :bump
  :ecosystem   :npm
  :description "Bump an npm package's version field via npm version --no-git-tag-version."
  :branding    { :icon "arrow-up-circle" :color "green" }
  :inputs      { :bump-type                   { :default "patch" :description "patch | minor | major" }
                 :skip-when-no-source-changes { :default "true" }
                 :source-paths                { :default "src package.json package-lock.json" } }
  :outputs     { :bumped      { :type :bool   :description "true if a bump happened" }
                 :new-version { :type :string :description "new version after bump" }
                 :old-version { :type :string :description "previous version" } }
  :installs    [ :node ]
  :wraps       "npm version --no-git-tag-version <bump-type>"
  :body
    (let ((bump-type (config-resolve "BUMP_TYPE" "bump" "default-type" "patch"))
          (skip-flag (config-resolve "SKIP_WHEN_NO_SOURCE_CHANGES" "bump"
                                     "skip-when-no-source-changes" "true"))
          (source-paths (config-resolve "SOURCE_PATHS" "bump" "source-paths"
                                        "src package.json package-lock.json"))
          (old-version (npm-package-version)))
      (cond
        ((not (npm-should-bump? skip-flag source-paths))
         (emit-skip old-version))
        (else
          (let* ((bump-r (npm-version-bump bump-type))
                 (new-version (npm-package-version)))
            (cond
              ((not (= (status-of bump-r) 0))
               (emit-failure "npm version failed" old-version))
              ((equal? new-version old-version)
               (emit-failure (string-append "version unchanged: " old-version) old-version))
              (else
                (emit-success old-version new-version))))))))
