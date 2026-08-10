;; Deterministic fake WebSockets exercise the same single-owner command and
;; receive loop used by the final client, including real reconnect scheduling.
(local json (require :json))
(local cqueues (require :cqueues))
(local errno (require :cqueues.errno))
(local Live (require :live))

(fn expect [condition message]
  (if (not condition) (error message)))

(fn expect-equal [actual expected label]
  (expect (= actual expected)
          (string.format "%s: expected %s, got %s" label (tostring expected)
                         (tostring actual))))

(fn transition [start-query-set end-query-set start-ts end-ts modification]
  {:type :Transition
   :startVersion {:querySet start-query-set :identity 0 :ts start-ts}
   :endVersion {:querySet end-query-set :identity 0 :ts end-ts}
   :modifications (json.array [modification])})

(local FakeSocket {})
(set FakeSocket.__index FakeSocket)
(fn FakeSocket.new [server]
  (let [instance (setmetatable {: server
                                :incoming []
                                :closed false
                                :request {:headers {:append (fn [])}}}
                               FakeSocket)]
    (set instance.socket
         {:shutdown (fn [])
          :close (fn [] (set instance.closed true)
                   (set instance.forced-closed true))})
    instance))

(fn FakeSocket.connect [self]
  (if (and self.server.connect-failures (> self.server.connect-failures 0))
      (do
        (set self.server.connect-failures (- self.server.connect-failures 1))
        (values nil "fixture handshake failure"))
      (do
        (table.insert self.server.connections self) true)))

(fn FakeSocket.send [self payload]
  (let [message (assert (json.decode payload))]
    (table.insert self.server.sent message)
    (if (= message.type :ModifyQuerySet)
        (let [first-modification (. message.modifications 1)
              kind (and first-modification first-modification.type)]
          (if (= self.server.fail-next-modify kind)
              (do
                (set self.server.fail-next-modify nil)
                (values nil "fixture query-set write failure"))
              (: self.server :on-modify self message))))
    true))

(fn FakeSocket.receive [self]
  (if self.closed (values nil :closed 0) self.fail-receive
      (do
        (set self.fail-receive false)
        (values nil "fixture transport cut" 0))
      (= (length self.incoming) 0)
      (do
        (cqueues.sleep 0.001) (values nil :timeout errno.ETIMEDOUT))
      (values (assert (json.encode (table.remove self.incoming 1))) :text)))

(fn FakeSocket.close [self _ reason]
  (expect (<= (length reason) 123) "close reason exceeded RFC6455 limit")
  (set self.close-reason reason)
  (if self.server.fail-next-close
      (do
        (set self.server.fail-next-close false)
        (error "fixture close failure"))
      (do
        (set self.closed true) true)))

(fn server-for-updates []
  (let [server {:connections [] :sent []}]
    (fn server.new-socket [self] (FakeSocket.new self))

    (fn server.on-modify [self socket message]
      (let [change (. message.modifications 1)]
        (if (and (= change.type :Add) (not self.suppress-add-update))
            (table.insert socket.incoming
                          (transition 0 message.newVersion :AAAAAAAAAAA=
                                      :AQAAAAAAAAA=
                                      {:type :QueryUpdated
                                       :queryId change.queryId
                                       :value {:count 0}
                                       :logLines (json.array [])})))))

    server))

;; Add, initial/external updates, QueryFailed recovery, and Remove all pass
;; through one owner and one subscription.
(let [server (server-for-updates)
      manager (Live.Manager.new "http://unit.test" :fennel-test
                                {:websocket-factory (fn []
                                                      (: server :new-socket))})
      subscription (assert (: manager :subscribe "demo:state" {:room :unit}))]
  (let [update (assert (: subscription :next-update 1))]
    (expect-equal update.value.count 0 "initial value"))
  (let [socket (. server.connections 1)]
    (table.insert socket.incoming
                  (transition 1 1 :AQAAAAAAAAA= :AgAAAAAAAAA=
                              {:type :QueryUpdated
                               :queryId subscription.query-id
                               :value {:count 1}
                               :logLines (json.array [])}))
    (let [update (assert (: subscription :next-update 1))]
      (expect-equal update.value.count 1 "external value"))
    (table.insert socket.incoming
                  (transition 1 1 :AgAAAAAAAAA= :AwAAAAAAAAA=
                              {:type :QueryFailed
                               :queryId subscription.query-id
                               :errorMessage "fixture failure"
                               :errorData {:code :TEST}
                               :logLines (json.array ["fixture log"])}))
    (let [update (assert (: subscription :next-update 1))]
      (expect-equal update.error.name :FunctionError "query failure"))
    (table.insert socket.incoming
                  (transition 1 1 :AwAAAAAAAAA= :BAAAAAAAAAA=
                              {:type :QueryUpdated
                               :queryId subscription.query-id
                               :value {:count 2}
                               :logLines (json.array [])}))
    (let [update (assert (: subscription :next-update 1))]
      (expect-equal update.value.count 2 "query recovery")))
  (assert (: subscription :close))
  (let [last-message (. server.sent (length server.sent))]
    (expect-equal (. (. last-message.modifications 1) :type) :Remove
                  "Remove command"))
  (assert (: manager :close)))

;; Five debug disconnects retire the old socket before ack, reconnect, replay
;; Add, and suppress unchanged hydration on the same subscription.
(let [server (server-for-updates)
      manager (Live.Manager.new "http://unit.test" :fennel-test
                                {:websocket-factory (fn []
                                                      (: server :new-socket))})
      subscription (assert (: manager :subscribe "demo:state"
                              {:room :reconnect}))]
  (let [update (assert (: subscription :next-update 1))]
    (expect-equal update.value.count 0 "reconnect hydration"))
  (for [expected 1 5]
    (assert (: manager :debug-disconnect))
    (let [deadline (+ (cqueues.monotime) 2)]
      (while (and (< (length server.connections) (+ expected 1))
                  (< (cqueues.monotime) deadline))
        (: manager.cq :step 0.2)))
    (expect-equal (length server.connections) (+ expected 1) "reconnect count")
    (expect (= (: subscription :try-next-update) nil)
            "unchanged reconnect hydration leaked"))
  (var connects 0)
  (var adds 0)
  (each [_ message (ipairs server.sent)]
    (if (= message.type :Connect)
        (do
          (expect-equal message.connectionCount connects :connectionCount)
          (set connects (+ connects 1)))
        (and (= message.type :ModifyQuerySet)
             (= (. (. message.modifications 1) :type) :Add))
        (set adds (+ adds 1))))
  (expect-equal connects 6 "Connect count")
  (expect-equal adds 6 "Add replay count")
  (assert (: manager :close)))

;; Transport failure is structured, reconnects, and does not strand later data.
(let [server (server-for-updates)
      manager (Live.Manager.new "http://unit.test" :fennel-test
                                {:websocket-factory (fn []
                                                      (: server :new-socket))})
      subscription (assert (: manager :subscribe "demo:state" {:room :recover}))]
  (assert (: subscription :next-update 1))
  (let [first-socket (. server.connections 1)]
    (set first-socket.fail-receive true))
  (let [update (assert (: subscription :next-update 1))]
    (expect-equal update.error.name :TransportError "transport failure"))
  (let [deadline (+ (cqueues.monotime) 2)]
    (while (and (< (length server.connections) 2)
                (< (cqueues.monotime) deadline))
      (: manager.cq :step 0.2)))
  (expect-equal (length server.connections) 2 "transport reconnect")
  (let [second-socket (. server.connections 2)]
    (table.insert second-socket.incoming
                  (transition 1 1 :AQAAAAAAAAA= :AgAAAAAAAAA=
                              {:type :QueryUpdated
                               :queryId subscription.query-id
                               :value {:count 3}
                               :logLines (json.array [])})))
  (let [update (assert (: subscription :next-update 1))]
    (expect-equal update.value.count 3 "post-reconnect value"))
  (assert (: manager :close)))

;; The subscription queue has a deliberate newest-16 count bound.
(let [manager {:unsubscribe (fn [] true)}
      subscription (Live.Subscription.new manager 0)]
  (for [value 1 20]
    (: subscription :deliver {: value :logs (json.array [])}))
  (expect-equal (length subscription.updates) 16 "subscription queue bound")
  (let [update (assert (: subscription :try-next-update))]
    (expect-equal update.value 5 "oldest retained update")))

(print "live owner tests passed")
