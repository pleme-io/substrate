;; helm-chart.caixa.lisp — typed source for a Helm chart.

(defcaixa my-helm-chart
  :kind         :Aplicacao
  :ecosystem    :helm

  :chart        { :name        "my-helm-chart"
                  :version     "0.1.0"
                  :appVersion  "0.1.0"
                  :description "A typed pleme-io Helm chart."
                  :type        "application" }

  :ci-config    { :bump    { :default-type "patch" }
                  :publish { :registry "ghcr.io/pleme-io/helm" } }

  :workflows    [ :auto-release :pre-merge-gate :security-gate ]

  ;; Optional: cluster integration
  :deploy       { :enabled false  ;; flip to true to opt into cd-stack.yml
                  :release  "my-helm-chart"
                  :namespace "default"
                  :reconcile-after-publish true } )

;; Renders to:
;;   Chart.yaml
;;   values.yaml (skeleton)
;;   templates/ (empty)
;;   .pleme-io-release.toml
;;   .github/workflows/*.yml
;;   (optional) .github/workflows/cd-stack.yml
