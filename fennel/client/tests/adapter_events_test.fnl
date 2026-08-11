(local json (require :json))
(local Events (require :adapter_events))

(fn roundtrip [event]
  (assert (json.decode (assert (json.encode event)))))

(let [result (roundtrip (Events.result :query
                                      {:value false :logs (json.array [])}))]
  (assert (= result.id :query))
  (assert (= result.type :result))
  (assert (= result.value false))
  (assert (= result.logs nil)))

(let [failure (roundtrip
                (Events.error :mutation
                              {:name :FunctionError
                               :message "fixture failed"
                               :data {:code :FIXTURE}
                               :logs (json.array ["fixture log"])}))]
  (assert (= failure.id :mutation))
  (assert (= failure.type :error))
  (assert (= failure.error.name :FunctionError))
  (assert (= failure.error.data.code :FIXTURE))
  (assert (= (. failure.logs 1) "fixture log")))

(let [subscription (Events.error nil
                                 {:name :TransportError
                                  :message "fixture disconnected"})]
  (set subscription.type :subscription)
  (set subscription.subscriptionId :counter)
  (let [subscription (roundtrip subscription)]
    (assert (= subscription.id nil))
    (assert (= subscription.type :subscription))
    (assert (= subscription.subscriptionId :counter))
    (assert (= subscription.error.name :TransportError))))

(let [closed (roundtrip {:id :close :type :closed})]
  (assert (= closed.id :close))
  (assert (= closed.type :closed))
  (assert (= closed.value nil))
  (assert (= closed.error nil)))

(print "adapter event tests passed")
