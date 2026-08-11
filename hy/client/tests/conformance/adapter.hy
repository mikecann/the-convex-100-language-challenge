(import json os socket sys threading time)
(sys.path.insert 0 (os.environ.get "CONVEX_CLIENT_PATH" "/opt/convex/client"))
(import convex [Client DeliveryBudget FunctionError Subscription Update])

(defn error-value [exc]
  (setv result {"name" exc.__class__.__name__ "message" (str exc)})
  ;; `data` is optional in Convex failures. Omit it instead of turning absence
  ;; into JSON null, because the adapter protocol preserves that distinction.
  (if (and (isinstance exc FunctionError) (is-not exc.data None))
    (setv (get result "data") exc.data)
    None)
  result)

(defn forward-updates [subscriptions lock writer subscription-id subscription [after-dequeue None]]
  (while True
    (try
      (setv update (.next-update subscription))
      ;; Tests pause here to prove replacement and unsubscribe can invalidate a
      ;; relay that has already dequeued a value but has not published it yet.
      (when after-dequeue (after-dequeue))
      (with [lock]
        (if (is-not (.get subscriptions subscription-id) subscription)
          (break)
          (do
            (.write writer (+ (json.dumps (if update.error
                                             {"type" "subscription" "subscriptionId" subscription-id "error" (error-value update.error) "logs" update.logs}
                                             {"type" "subscription" "subscriptionId" subscription-id "value" update.value "logs" update.logs})
                                          :separators ["," ":"]) "\n"))
            (.flush writer))))
      (except [Exception] (break)))))

(defn run [reader writer]
  (setv client None subscriptions {} lock (threading.Lock))
  (defn emit [event]
    (with [lock] (.write writer (+ (json.dumps event :separators ["," ":"]) "\n")) (.flush writer)))
  (for [line reader]
    (setv ident None)
    (try
      (setv command (json.loads line) ident (.get command "id") op (get command "op"))
      (if (= op "hello")
        (setv event {"protocolVersion" 1 "type" "ready" "language" "hy" "implementation" "transpiled-hy-python-3.13" "runtime" sys.version})
        (if (in op ["query" "mutation" "action"])
          (do
          (if (not client) (setv client (Client (.get os.environ "CONVEX_URL") :bearer-token (.get os.environ "CONVEX_AUTH_TOKEN"))) None)
          (setv result ((get {"query" client.query "mutation" client.mutation "action" client.action} op) (get command "path") (.get command "args" {})) event {"type" "result" "value" result.value "logs" result.logs}))
          (if (= op "setAuth")
            (do (if (not client) (setv client (Client (.get os.environ "CONVEX_URL"))) None) (.set-auth client (.get command "token" "")) (setv event {"type" "ack"}))
            (if (= op "subscribe")
              (do
                (if (not client) (setv client (Client (.get os.environ "CONVEX_URL"))) None)
                (setv subscription-id (get command "subscriptionId")
                      old-subscription None)
                ;; Close replacement state before the ACK so an old relay can
                ;; never emit through a reused subscription ID afterwards.
                (with [lock] (setv old-subscription (.pop subscriptions subscription-id None)))
                (if old-subscription (.close old-subscription) None)
                (setv subscription (.subscribe client (get command "path") (.get command "args" {})))
                (with [lock] (setv (get subscriptions subscription-id) subscription))
                (.start (threading.Thread :target forward-updates :args [subscriptions lock writer subscription-id subscription] :daemon True))
                (setv event {"type" "ack"}))
              (if (= op "unsubscribe")
                (do
                  (setv subscription None)
                  (with [lock] (setv subscription (.pop subscriptions (get command "subscriptionId") None)))
                  (if subscription (.close subscription) None)
                  (setv event {"type" "ack"}))
                (if (= op "debugDisconnect")
                  (do (.debug-disconnect-for-adapter client) (setv event {"type" "ack"}))
                  (if (= op "close")
                    (do
                      (with [lock]
                        (setv closing-subscriptions (list (.values subscriptions)))
                        (.clear subscriptions))
                      (for [subscription closing-subscriptions] (.close subscription))
                      (if client (.close client) None)
                      (emit {"type" "closed" "id" ident})
                      (return))
                    (raise (ValueError (+ "unknown adapter operation " (repr op)))))))))))
      (except [exc Exception]
        (setv event {"type" "error" "error" (error-value exc)})
        (when (isinstance exc FunctionError) (setv (get event "logs") exc.logs))))
    (if (is-not ident None) (setv (get event "id") ident) None)
    (emit event)))

(defn stopped-reader-memory-probe [writer]
  ;; This mode is only for the language-local Docker stress. It runs inside the
  ;; exact final adapter image, while a controller keeps the TCP connection open
  ;; without reading. Multiple relay writes become in-flight and every remaining
  ;; update is charged to one aggregate 16 MiB manager budget.
  (setv budget (DeliveryBudget (* 16 1024 1024))
        subscriptions {}
        lock (threading.Lock))
  (for [index (range 12)]
    (setv subscription (Subscription None index budget)
          (get subscriptions (str index)) subscription)
    (.deliver subscription (Update :value {"payload" (+ (str index) ":" (* "x" (- (* 1024 1024) 32)))}))
    (.start (threading.Thread :target forward-updates
                             :args [subscriptions lock writer (str index) subscription]
                             :daemon True)))
  (for [round (range 4)]
    (for [index (range 12)]
      (.deliver (get subscriptions (str index))
                (Update :value {"payload" (+ (str round) ":" (str index) ":" (* "y" (- (* 1024 1024) 40)))}))))
  ;; The external probe samples cgroup RSS while this exact process is held at
  ;; steady state. Exiting early would make a false low-memory result possible.
  (time.sleep 30))

(when (= __name__ "__main__")
  (if (os.environ.get "ADAPTER_LISTEN")
    (do (setv [host port] (.rsplit (os.environ.get "ADAPTER_LISTEN") ":" 1) server (socket.create_server #(host (int port))) [connection _] (.accept server) reader (.makefile connection "r") writer (.makefile connection "w"))
        (try
          (if (os.environ.get "HY_ADAPTER_STOPPED_READER_PROBE")
            (stopped-reader-memory-probe writer)
            (run reader writer))
          (finally (.close reader) (.close writer) (.close connection) (.close server))))
    (run sys.stdin sys.stdout)))
