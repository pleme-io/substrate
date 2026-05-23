;; auto-release-workflow.lisp — demonstrates the (defworkflow ...)
;; form that the M3 renderer turns into substrate's
;; .github/workflows/auto-release.yml.
;;
;; This 30-line file replaces the current 80-line yaml workflow.
;; The compounding ratio at the workflow layer is similar to
;; the action layer (~3×).

(defworkflow auto-release
  :description "Polymorphic dispatcher — push to main → per-language bump+publish."
  :triggers    [ (:push :branches [ "main" ])
                 (:workflow-dispatch
                   :inputs { :bump-type { :default "patch" :description "patch | minor | major" } }) ]
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
        :uses-workflow :cargo-auto-release
        :with { :bump-type (input :bump-type) })
      (:job npm
        :needs detect
        :when (= (output detect :repo-type) "npm")
        :uses-workflow :npm-auto-release
        :with { :bump-type (input :bump-type) })
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
