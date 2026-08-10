(local json (require :json))
(local Output (require :adapter_output))

(fn expect [condition message]
  (if (not condition) (error message)))

;; Generation invalidation wins before publication, so a stale relay can never
;; cross an unsubscribe or same-ID replacement acknowledgement.
(let [writer (Output.new {})
      entry {}
      subscriptions {:counter entry}]
  (set subscriptions.counter nil)
  (expect (not (: writer :enqueue {:type :subscription
                                   :subscriptionId :counter
                                   :value 1}
                  subscriptions :counter entry))
          "stale subscription generation entered the output queue")
  (: writer :enqueue {:id :unsubscribe :type :ack})
  (expect (= (length writer.queue) 1) "ack queue shape was wrong"))

;; Count and byte limits are independent. Both fail before retaining an event
;; beyond the configured budget and report structured transport metadata.
(let [writer (Output.new {} {:max-pending 2 :max-pending-bytes 4096})]
  (: writer :enqueue {:id :one :type :result :value 1})
  (: writer :enqueue {:id :two :type :result :value 2})
  (let [(ok err) (pcall (fn []
                          (: writer :enqueue
                             {:id :three :type :result :value 3})))]
    (expect (not ok) "event-count overflow was accepted")
    (expect (= err.name :TransportError) "event overflow was not structured")
    (expect (= err.data.pendingEvents 2) "event overflow exceeded its bound")))

(let [writer (Output.new {} {:max-pending 64 :max-pending-bytes 700})]
  (: writer :enqueue {:id :one :type :result :value (string.rep :x 200)})
  (let [(ok err) (pcall (fn []
                          (: writer :enqueue
                             {:id :two
                              :type :result
                              :value (string.rep :x 200)})))]
    (expect (not ok) "byte overflow was accepted")
    (expect (= err.name :TransportError) "byte overflow was not structured")
    (expect (string.match err.message "byte limit")
            "event limit fired before byte limit")
    (expect (<= writer.pending-bytes writer.max-pending-bytes)
            "byte budget was exceeded")))

;; Resume TCP sends at LuaSocket's exact last-byte index.
(let [tcp {:received "" :chunk 7}]
  (fn tcp.send [self data first]
    (let [last (math.min (+ first self.chunk -1) (length data))]
      (set self.received (.. self.received (string.sub data first last)))
      (if (< last (length data)) (values nil :timeout last) last)))

  (let [writer (Output.new tcp {:wait-writable (fn [] true)})
        event {:id :large :type :result :value (string.rep :x 128)}
        expected (.. (assert (json.encode event)) "\n")]
    (: writer :enqueue event)
    (assert (: writer :flush-tcp 1))
    (expect (= tcp.received expected)
            "partial TCP writes lost or duplicated bytes")))

(print "adapter output tests passed")
