;; Deterministic protocol fixtures exercise the transitions before a hosted
;; service is involved. The socket owner is not started because these tests
;; feed transitions directly into the same manager method it calls.
(local Live (require :live))
(local json (require :json))

(fn expect [condition message]
  (if (not condition) (error message)))

(fn transition [start end modifications]
  {:type :Transition
   :startVersion start
   :endVersion end
   :modifications (json.array modifications)})

(let [manager (Live.Manager.new "https://example.invalid" :fennel-fixture
                                {:cq {:wrap (fn [_ _])}})
      subscription (Live.Subscription.new manager 0)
      start {:querySet 0 :identity 0 :ts :AAAAAAAAAAA=}
      first {:querySet 0 :identity 0 :ts :AQAAAAAAAAA=}
      second {:querySet 0 :identity 0 :ts :AgAAAAAAAAA=}
      third {:querySet 0 :identity 0 :ts :AwAAAAAAAAA=}
      fourth {:querySet 0 :identity 0 :ts :BAAAAAAAAAA=}
      fifth {:querySet 0 :identity 0 :ts :BQAAAAAAAAA=}]
  ;; Add state just as the owner does before it sends ModifyQuerySet.
  (set (. manager.subscriptions 0)
       {:path "demo:state" :args {} : subscription :last-delivered nil})
  (let [(ok err) (: manager :transition
                    (transition start first
                                [{:type :QueryUpdated
                                  :queryId 0
                                  :value 0
                                  :logLines (json.array [])}]))]
    (expect ok (or (and err err.message) "initial QueryUpdated failed")))
  (let [update (: subscription :try-next-update)]
    (expect (= update.value 0) "initial value was not delivered"))
  ;; An external update must reach the same subscription after the initial Add.
  (let [(ok err) (: manager :transition
                    (transition first second
                                [{:type :QueryUpdated
                                  :queryId 0
                                  :value 1
                                  :logLines (json.array [])}]))]
    (expect ok (or (and err err.message) "external QueryUpdated failed")))
  (let [update (: subscription :try-next-update)]
    (expect (= update.value 1) "external value was not delivered"))
  ;; QueryFailed is structured and a later QueryUpdated proves recovery.
  (let [(ok err) (: manager :transition
                    (transition second third
                                [{:type :QueryFailed
                                  :queryId 0
                                  :errorMessage "fixture failure"
                                  :errorData {:kind :fixture}
                                  :logLines (json.array [])}]))]
    (expect ok (or (and err err.message) "QueryFailed transition rejected")))
  (let [failed (: subscription :try-next-update)]
    (expect (= failed.error.name :FunctionError)
            "QueryFailed was not structured"))
  (let [(ok err) (: manager :transition
                    (transition third fourth
                                [{:type :QueryUpdated
                                  :queryId 0
                                  :value 2
                                  :logLines (json.array [])}]))]
    (expect ok (or (and err err.message) "QueryUpdated recovery failed")))
  (let [update (: subscription :try-next-update)]
    (expect (= update.value 2) "subscription did not recover"))
  ;; Reject the complete malformed transition atomically, then accept the
  ;; canonical QueryRemoved shape and advance without a stale delivery.
  (let [(ok err) (: manager :transition
                    (transition fourth fifth
                                [{:type :QueryUpdated
                                  :queryId 0
                                  :value 99
                                  :logLines (json.object {})}]))]
    (expect (= ok nil) "object-shaped logLines were accepted")
    (expect (= err.name :ProtocolError)
            "malformed Transition was not structured")
    (expect (= manager.remote-version.ts fourth.ts)
            "rejected Transition advanced state")
    (expect (= (: subscription :try-next-update) nil)
            "rejected Transition delivered a value"))
  (let [(ok err) (: manager :transition
                    (transition fourth fifth [{:type :QueryRemoved :queryId 0}]))]
    (expect ok (or (and err err.message) "canonical QueryRemoved failed"))
    (expect (= manager.remote-version.ts fifth.ts)
            "QueryRemoved did not advance version")
    (expect (= (. manager.remote-results 0) nil)
            "QueryRemoved retained cached state")
    (expect (= (: subscription :try-next-update) nil)
            "QueryRemoved delivered stale data"))
  ;; Remove invalidates the subscription before an acknowledgement can be sent.
  (: subscription :finish)
  (expect (= (: subscription :try-next-update) nil)
          "Remove did not invalidate queued delivery"))

(print "live fixture tests passed")
