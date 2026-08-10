;;/usr/local/bin/fennel
;; NDJSON adapter v1. One output writer owns stdout and every queued line is
;; bounded by both event count and retained bytes.
(local json (require :json))
(local socket (require :socket))
(local cqueues (require :cqueues))
(local cqueue-socket (require :cqueues.socket))
(local Convex (require :convex))
(local Events (require :adapter_events))
(local Output (require :adapter_output))

(fn new-state [output]
  {: output :client nil :subscriptions {} :closed false})

(fn ensure-client [state]
  (if state.client state.client
      (let [url (os.getenv :CONVEX_URL)]
        (if (or (= url nil) (= url ""))
            (values nil
                    {:name :TransportError :message "CONVEX_URL is required"})
            (let [(client err) (Convex.new url
                                           {:bearer-token (or (os.getenv :CONVEX_AUTH_TOKEN)
                                                              "")
                                            :client-version :fennel-0.1.0
                                            :cq state.cq})]
              (set state.client client)
              (values client err))))))

(fn enqueue-error [state id err]
  (: state.output :enqueue (Events.error id err)))

(fn process-line [state line]
  (let [(command decode-error) (json.decode line)]
    (if (not command)
        (enqueue-error state nil
                       {:name :ProtocolError
                        :message (.. "decode command: " (tostring decode-error))})
        (= command.op :hello)
        (if (= command.protocolVersion 1)
            (: state.output :enqueue
               {:protocolVersion 1
                :id command.id
                :type :ready
                :language :fennel
                :implementation :transpiled-fennel-1.6.1-lua-5.1
                :runtime _VERSION})
            (enqueue-error state command.id
                           {:name :ProtocolError
                            :message "unsupported adapter protocol version"}))
        (= command.op :close)
        (let [closing state.subscriptions]
          ;; Invalidate every relay before a close operation can yield.
          (set state.subscriptions {})
          (each [_ entry (pairs closing)] (: entry.subscription :close))
          (if state.client (: state.client :close))
          (: state.output :enqueue {:id command.id :type :closed})
          (set state.closed true)
          (: state.output :finish))
        (= command.op :subscribe)
        (let [(client client-error) (ensure-client state)]
          (if (not client)
              (enqueue-error state command.id client-error)
              (or (= command.subscriptionId nil) (= command.subscriptionId ""))
              (enqueue-error state command.id
                             {:name :ProtocolError
                              :message "subscriptionId is required"})
              (do
                (let [previous (. state.subscriptions command.subscriptionId)]
                  (when previous
                    ;; Replacement invalidates the old generation before close.
                    (set (. state.subscriptions command.subscriptionId) nil)
                    (: previous.subscription :close)))
                (let [(subscription err) (: client :subscribe command.path
                                            (or command.args {}))]
                  (if (not subscription)
                      (enqueue-error state command.id err)
                      (do
                        (set (. state.subscriptions command.subscriptionId)
                             {: subscription})
                        (: state.output :enqueue {:id command.id :type :ack})))))))
        (= command.op :unsubscribe)
        (let [entry (. state.subscriptions command.subscriptionId)]
          (set (. state.subscriptions command.subscriptionId) nil)
          (let [(ok err) (if entry (: entry.subscription :close)
                             (values true nil))]
            (if ok (: state.output :enqueue {:id command.id :type :ack})
                (enqueue-error state command.id err))))
        (= command.op :debugDisconnect)
        (let [(client client-error) (ensure-client state)
              (ok err) (if client (: client :debug-disconnect-for-adapter)
                           (values nil client-error))]
          (if ok (: state.output :enqueue {:id command.id :type :ack})
              (enqueue-error state command.id err)))
        (= command.op :setAuth)
        (let [(client client-error) (ensure-client state)]
          (if client
              (let [(ok err) (: client :set-auth (or command.token ""))]
                (if ok (: state.output :enqueue {:id command.id :type :ack})
                    (enqueue-error state command.id err)))
              (enqueue-error state command.id client-error)))
        (or (= command.op :query) (= command.op :mutation)
            (= command.op :action))
        (let [(client client-error) (ensure-client state)]
          (if (not client)
              (enqueue-error state command.id client-error)
              (let [(result err) (: client :call command.op command.path
                                    (or command.args {}))]
                (if result
                    (: state.output :enqueue (Events.result command.id result))
                    (enqueue-error state command.id err)))))
        (enqueue-error state command.id
                       {:name :ProtocolError
                        :message "unknown adapter operation"}))))

(fn drain-live [state step-owner]
  ;; Give the socket owner a bounded slice while a TCP controller is idle.
  (if (and step-owner state.client state.client.live)
      (: state.client.live.cq :step 0.1))
  (each [subscription-id entry (pairs state.subscriptions)]
    (var draining true)
    (while draining
      (let [update (: entry.subscription :try-next-update)]
        (if (not update)
            (set draining false)
            (let [event (if update.error
                            (let [failure-event (Events.error nil update.error)]
                              (set failure-event.type :subscription)
                              (set failure-event.subscriptionId subscription-id)
                              failure-event)
                            (Events.subscription subscription-id update))
                  delivered (: state.output :enqueue event state.subscriptions
                               subscription-id entry)]
              (if (not delivered) (set draining false))))))))

(fn cleanup [state]
  (let [closing state.subscriptions]
    (set state.subscriptions {})
    (each [_ entry (pairs closing)] (: entry.subscription :close)))
  (if state.client (: state.client :close))
  (set state.closed true)
  (: state.output :finish))

(fn run-stdio []
  (let [cq (cqueues.new)
        output (Output.new (assert (cqueue-socket.fdopen 1)))
        state (new-state output)
        input (assert (cqueue-socket.fdopen 0))]
    (set state.cq cq)
    (: cq :wrap (fn [] (: output :run-stdio)))
    (: cq :wrap
       (fn []
         (while (not state.closed)
           (let [line (: input :read :*l)]
             (if line (process-line state line) (cleanup state))))))
    (: cq :wrap (fn []
                  (while (not state.closed)
                    (drain-live state false)
                    (cqueues.sleep 0.005))))
    (assert (: cq :loop))))

(fn run-tcp [address]
  (let [(host port) (string.match address "^(.+):(%d+)$")]
    (assert (and host port) "ADAPTER_LISTEN must be host:port")
    (let [server (assert (socket.bind host (tonumber port)))
          peer (assert (: server :accept))
          output (Output.new peer)
          state (new-state output)]
      (: peer :settimeout 0)
      (set state.cq (cqueues.new))
      (var pending-fragment "")
      (while (not state.closed)
        (let [(line receive-error fragment) (: peer :receive :*l
                                               pending-fragment)]
          (set pending-fragment (or fragment ""))
          (if line (do
                     (set pending-fragment "")
                     (process-line state line))
              (not (= receive-error :timeout)) (cleanup state)))
        (drain-live state true)
        (let [(flushed flush-error) (: output :flush-tcp 5)]
          (assert flushed flush-error))
        (socket.sleep 0.005))
      (if (and state.client (not state.closed)) (: state.client :close))
      (: peer :close)
      (: server :close))))

(let [address (os.getenv :ADAPTER_LISTEN)]
  (if (and address (not (= address ""))) (run-tcp address) (run-stdio)))
