;; slack-notify.lisp — demonstrates a "leaf" action (no detect,
;; no language coupling, just typed inputs + curl POST).

(defaction slack-notify
  :category    :comms
  :description "Post a typed release event to a Slack incoming webhook."
  :branding    { :icon "message-square" :color "purple" }
  :inputs      { :webhook-url { :required true :description "Slack incoming-webhook URL (from secrets)" }
                 :title       { :required true }
                 :body        { :default "" }
                 :color       { :default "good" :description "good | warning | danger | <hex>" }
                 :fields      { :default "[]" :description "JSON array of {title, value, short} field objects" } }
  :outputs     { :delivered { :type :bool :description "'true' on 2xx, 'false' on error" } }
  :installs    [ ]
  :wraps       "curl -X POST <webhook>"
  :body
    (let ((webhook (env-required "WEBHOOK_URL"))
          (title (env-required "TITLE"))
          (body (env-get "BODY" ""))
          (color (env-get "COLOR" "good"))
          (fields (env-get "FIELDS" "[]")))
      (let* ((payload (build-slack-payload title body color fields))
             (code (http-post-status webhook payload)))
        (cond
          ((or (equal? code "200") (equal? code "204"))
           (append-output "delivered=true") (exit 0))
          (else
           (log-error (string-append "Slack returned HTTP " code))
           (append-output "delivered=false") (exit 1))))))
