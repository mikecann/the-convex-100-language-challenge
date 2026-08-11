"""A small Hy Convex client, transpiled ahead of time for its Python runtime."""

(import base64 json os queue secrets threading time urllib.error urllib.parse urllib.request)
(import websockets.sync.client [connect])
(import websockets.exceptions [ConnectionClosed])

(defclass ConvexError [Exception])
(defclass ClosedError [ConvexError])
(defclass ProtocolError [ConvexError])
(defclass TransportError [ConvexError])

(defclass FunctionError [ConvexError]
  (defn __init__ [self message [data None] [logs None]]
    (setv self.args #(message))
    (setv self.data data self.logs (or logs []))))

(defclass Result []
  (defn __init__ [self value logs]
    (setv self.value value self.logs logs)))

(defclass Update []
  (defn __init__ [self [value None] [error None] [logs None]]
    (setv self.value value self.error error self.logs (or logs []))))

(defn _error-message [value]
  (if (isinstance value Exception) (str value) (str value)))

(defclass Subscription []
  (setv MAX-UPDATES 16)
  ;; A bounded item count and byte budget make a stopped adapter reader unable
  ;; to turn a noisy subscription into an unbounded Python queue.
  (setv MAX-BYTES (* 8 1024 1024))
  (defn __init__ [self manager query-id]
    (setv self.manager manager self.query-id query-id self.closed False
          self.updates (queue.Queue self.MAX-UPDATES) self.buffered-bytes 0
          self.lock (threading.Lock)))
  (defn _update-bytes [self update]
    ;; Count everything the adapter will retain and later encode, plus a small
    ;; allowance for Python object and queue overhead.
    (+ 512 (len (json.dumps {"value" update.value
                             "error" (if update.error (str update.error) None)
                             "logs" update.logs}
                            :default str))))
  (defn next-update [self [timeout None]]
    (try
      (setv update (.get self.updates :timeout timeout))
      (except [queue.Empty] (raise (TransportError "timed out waiting for Live update"))))
    (with [self.lock]
      (setv self.buffered-bytes (max 0 (- self.buffered-bytes (self._update-bytes update)))))
    (if (isinstance update.error ClosedError) (raise update.error) update))
  (defn deliver [self update]
    (if self.closed None
      (do
        (setv encoded (self._update-bytes update))
        (with [self.lock]
          (while (and (not (.empty self.updates))
                      (or (>= (.qsize self.updates) self.MAX-UPDATES)
                          (> (+ self.buffered-bytes encoded) self.MAX-BYTES)))
            (try
              (setv dropped (.get-nowait self.updates))
              (setv self.buffered-bytes (max 0 (- self.buffered-bytes (self._update-bytes dropped))))
              (except [queue.Empty] (break))))
          ;; One event larger than the entire budget is deliberately dropped.
          (when (<= encoded self.MAX-BYTES)
            (try
              (.put-nowait self.updates update)
              (setv self.buffered-bytes (+ self.buffered-bytes encoded))
              (except [queue.Full] None)))))))
  (defn close [self]
    (if (not self.closed)
      (do (setv self.closed True) (.unsubscribe self.manager self.query-id))
      None)))

(defclass LiveManager []
  (setv INITIAL-VERSION {"querySet" 0 "identity" 0 "ts" "AAAAAAAAAAA="})
  (defn __init__ [self deployment-url version [websocket-factory connect]]
    (setv parsed (urllib.parse.urlparse deployment-url)
          scheme (if (= parsed.scheme "https") "wss" "ws")
          self.url (urllib.parse.urlunparse [scheme parsed.netloc (+ (.rstrip parsed.path "/") "/api/sync") "" "" ""])
          self.version version self.subs {} self.commands (queue.Queue 64)
          self.closed False self.socket None self.connection-count 0
          self.handshaken False
          self.last-close-reason "InitialConnect" self.query-version 0
          self.backoff 0.05
          self.remote-version (dict self.INITIAL-VERSION)
          self.max-observed-timestamp None
          self.last-updates {} self.rehydrating (set)
          self.websocket-factory websocket-factory
          self.thread (threading.Thread :target self._run :daemon True))
    (.start self.thread))
  (defn _add [self query-id path args]
    {"type" "Add" "queryId" query-id "udfPath" path "args" [args]})
  (defn _send-modify [self modifications]
    (if modifications
      (do
        (.send self.socket (json.dumps {"type" "ModifyQuerySet" "baseVersion" self.query-version "newVersion" (+ self.query-version 1) "modifications" modifications} :separators ["," ":"]))
        (setv self.query-version (+ self.query-version 1)))
      None))
  (defn _connect [self]
    ;; This worker is the only owner of websocket reads, writes and version state.
    (setv self.handshaken False
          self.socket (self.websocket-factory self.url :additional_headers {"Convex-Client" self.version} :open_timeout 10 :close_timeout 1)
          self.query-version 0 self.remote-version (dict self.INITIAL-VERSION))
    (setv connect-message {"type" "Connect" "sessionId" (secrets.token_hex 16) "connectionCount" self.connection-count "lastCloseReason" self.last-close-reason "clientTs" 0})
    (when self.max-observed-timestamp
      (setv (get connect-message "maxObservedTimestamp") self.max-observed-timestamp))
    (.send self.socket (json.dumps connect-message :separators ["," ":"]))
    (self._send-modify (lfor [query-id entry] (.items self.subs) (self._add query-id (get entry 0) (get entry 1))))
    (setv self.handshaken True))
  (defn subscribe [self path args]
    (setv reply (queue.Queue 1))
    (.put self.commands ["add" path args reply])
    (setv answer (.get reply :timeout 5))
    (if (isinstance answer Exception) (raise answer) answer))
  (defn unsubscribe [self query-id]
    (setv reply (queue.Queue 1))
    (.put self.commands ["remove" query-id reply])
    (.get reply :timeout 2))
  (defn disconnect-for-adapter [self]
    (setv reply (queue.Queue 1))
    (.put self.commands ["disconnect" reply])
    (setv answer (.get reply :timeout 2))
    (if (isinstance answer Exception) (raise answer) None))
  (defn _retire [self reason]
    (if self.socket
      (do
        (try (.close self.socket) (except [Exception] None))
        (setv self.socket None self.handshaken False self.connection-count (+ self.connection-count 1) self.last-close-reason reason)
        (.clear self.rehydrating)
        (for [query-id (.keys self.subs)]
          (when (in query-id self.last-updates) (.add self.rehydrating query-id))))
      None))
  (defn _command [self command]
    (setv kind (get command 0))
      (if (= kind "add")
      (do
       (setv query-id (if self.subs (+ 1 (max (.keys self.subs))) 0))
       (setv subscription (Subscription self query-id))
       (setv (get self.subs query-id) [(get command 1) (get command 2) subscription])
       (if self.socket (self._send-modify [(self._add query-id (get command 1) (get command 2))]) None)
       (.put (get command 3) subscription))
      (if (= kind "remove")
       (do
       (if (in (get command 1) self.subs)
         (do (if self.socket (self._send-modify [{"type" "Remove" "queryId" (get command 1)}]) None)
             (del (get self.subs (get command 1)))
             (.pop self.last-updates (get command 1) None)
             (.discard self.rehydrating (get command 1)))
         None)
       (.put (get command 2) True))
       (if (= kind "disconnect")
         (do (self._retire "DebugDisconnect") (.put (get command 1) True))
         (if (= kind "close")
           (do
             (setv self.closed True)
             (self._retire "ClientClosed")
             (for [[_ entry] (.items self.subs)]
               (.deliver (get entry 2) (Update :error (ClosedError "Live subscription is closed"))))
             (.put (get command 1) True))
           None)))))
  (defn _transition [self message]
    (if (!= (.get message "startVersion") self.remote-version)
      (raise (ProtocolError "Transition start version does not match local version")) None)
    (setv modifications (.get message "modifications")
          end-version (.get message "endVersion")
          staged [])
    (if (or (not (isinstance modifications list)) (not (isinstance end-version dict)))
      (raise (ProtocolError "Transition versions and modifications were malformed")) None)
    ;; Validate the complete transition before publishing any part of it. A
    ;; malformed later modification must not leave subscribers on a half-
    ;; applied version.
    (for [mod modifications]
      (if (not (isinstance mod dict)) (raise (ProtocolError "Transition modification was not an object")) None)
      (setv query-id (.get mod "queryId")
            kind (.get mod "type")
            logs (.get mod "logLines" []))
      (if (not (isinstance logs list)) (raise (ProtocolError "Transition logLines was not an array")) None)
      (for [line logs]
        (if (not (isinstance line str)) (raise (ProtocolError "Transition logLines contained a non-string")) None))
      (setv update None signature None)
      (if (= kind "QueryUpdated")
        (do
          (if (not (in "value" mod)) (raise (ProtocolError "QueryUpdated omitted value")) None)
          (setv update (Update :value (get mod "value") :logs logs)
                signature ["value" (get mod "value")]))
        (if (= kind "QueryFailed")
          (do
            (setv error-message (.get mod "errorMessage"))
            (if (not (isinstance error-message str)) (raise (ProtocolError "QueryFailed omitted string errorMessage")) None)
            (setv update (Update :error (FunctionError error-message :data (.get mod "errorData") :logs logs) :logs logs)
                  signature ["error" error-message (.get mod "errorData")]))
          (if (!= kind "QueryRemoved")
            (raise (ProtocolError "unknown Transition modification"))
            None)))
      (setv entry (.get self.subs query-id))
      (when (and entry update) (.append staged [query-id entry update signature])))
    (setv timestamp (.get end-version "ts"))
    (if (not (isinstance timestamp str)) (raise (ProtocolError "Transition end timestamp was malformed")) None)
    (try
      (setv timestamp-bytes (base64.b64decode timestamp :validate True))
      (except [Exception] (raise (ProtocolError "Transition end timestamp was malformed"))))
    (if (!= (len timestamp-bytes) 8) (raise (ProtocolError "Transition end timestamp was malformed")) None)
    (for [[query-id entry update signature] staged]
      (setv replay (and (in query-id self.rehydrating)
                        (= signature (.get self.last-updates query-id))))
      (.discard self.rehydrating query-id)
      (setv (get self.last-updates query-id) signature)
      (if replay None (.deliver (get entry 2) update)))
    (setv self.remote-version end-version
          candidate (int.from_bytes timestamp-bytes "little")
          current (if self.max-observed-timestamp
                    (int.from_bytes (base64.b64decode self.max-observed-timestamp) "little")
                    -1))
    (when (> candidate current) (setv self.max-observed-timestamp timestamp))
    ;; A valid server transition proves the connection is healthy. Future
    ;; transport failures must start again at the minimum retry delay.
    (setv self.backoff 0.05))
  (defn _run [self]
    (while (not self.closed)
      (try
        (while True (self._command (.get-nowait self.commands)))
        (except [queue.Empty] None))
      (when self.closed (break))
      (if (not self.subs)
        (time.sleep 0.02)
        (do
          (try
            (if (not self.socket) (self._connect) None)
            (setv raw (.recv self.socket :timeout 0.1))
            (when raw
              (try
                (setv message (json.loads raw))
                (except [json.JSONDecodeError]
                  (raise (ProtocolError "Live message was not valid JSON"))))
              (if (= (.get message "type") "Transition")
                (self._transition message)
                (if (in (.get message "type") ["Ping" "MutationResponse" "ActionResponse"])
                  None
                  (raise (ProtocolError "unexpected Live message")))))
            (except [TimeoutError] None)
            (except [ConnectionClosed] (self._retire "ConnectionClosed"))
            (except [err Exception]
              (setv had-socket self.handshaken)
              (self._retire "Exception")
              ;; Failures after a handshake are visible but do not strand later
              ;; reconnects. Initial connection attempts remain retryable.
              (when had-socket
                (setv visible-error (if (isinstance err ProtocolError)
                                      err
                                      (TransportError (_error-message err))))
                (for [[_ entry] (.items self.subs)]
                  (.deliver (get entry 2) (Update :error visible-error))))
              (setv delay self.backoff
                    self.backoff (min 2.0 (* self.backoff 2)))
              (time.sleep delay)))))))
  (defn close [self]
    (when (not self.closed)
      (setv reply (queue.Queue 1))
      (.put self.commands ["close" reply])
      (.get reply :timeout 2)
      (.join self.thread :timeout 2))))

(defclass Client []
  (setv VERSION "hy-0.1.0")
  (defn __init__ [self deployment-url [bearer-token None]]
    (setv parsed (urllib.parse.urlparse deployment-url))
    (if (or (not (in parsed.scheme ["http" "https"])) (not parsed.hostname) parsed.username)
      (raise (ValueError "Convex deployment URL must be an http(s) URL with a host")) None)
    (setv self.url (.rstrip deployment-url "/") self.token (or bearer-token "") self.closed False self.live None))
  (defn _check [self] (if self.closed (raise (ClosedError "Convex client is closed")) None))
  (defn set-auth [self token] (self._check) (setv self.token (or token "")))
  (defn _call [self operation path args]
    (self._check)
    (if (or (not path) (not (isinstance args dict))) (raise (ValueError "Convex path and named object arguments are required")) None)
    (setv headers {"Content-Type" "application/json" "Accept" "application/json" "Convex-Client" self.VERSION})
    (if self.token (setv (get headers "Authorization") (+ "Bearer " self.token)) None)
    (setv request (urllib.request.Request (+ self.url "/api/" operation) :data (.encode (json.dumps {"path" path "args" args "format" "json"})) :headers headers :method "POST"))
    (try
      (setv response (urllib.request.urlopen request :timeout 30))
      (except [err Exception] (raise (TransportError (_error-message err)))))
    (try
      (try
        (setv decoded (json.load response))
        (except [json.JSONDecodeError]
          (raise (ProtocolError "Convex HTTP response was not valid JSON"))))
      (finally (.close response)))
    (if (and (= (.get decoded "status") "success") (in "value" decoded))
      (Result (.get decoded "value") (.get decoded "logLines" []))
      (if (= (.get decoded "status") "error")
        (raise (FunctionError (.get decoded "errorMessage" "Convex function failed") :data (.get decoded "errorData") :logs (.get decoded "logLines" [])))
        (raise (ProtocolError "unknown Convex HTTP response")))))
  (defn query [self path [args None]] (self._call "query" path (or args {})))
  (defn mutation [self path [args None]] (self._call "mutation" path (or args {})))
  (defn action [self path [args None]] (self._call "action" path (or args {})))
  (defn subscribe [self path [args None]]
    (self._check) (if (not self.live) (setv self.live (LiveManager self.url self.VERSION)) None) (.subscribe self.live path (or args {})))
  (defn debug-disconnect-for-adapter [self]
    (self._check)
    (if self.live (.disconnect-for-adapter self.live) (raise (TransportError "Live WebSocket is not connected"))))
  (defn close [self]
    (if (not self.closed) (do (setv self.closed True) (if self.live (.close self.live) None)) None)))
