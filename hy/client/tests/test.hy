"""Deterministic HTTP and Live regressions for the Hy client."""

(import http.server json os queue subprocess sys threading time)
(setv client-path (os.environ.get "CONVEX_CLIENT_PATH" "/work/client"))
(sys.path.insert 0 client-path)
(import convex [Client ClosedError FunctionError LiveManager ProtocolError Subscription TransportError Update])

(defn eventually [predicate [seconds 2]]
  (setv deadline (+ (time.monotonic) seconds))
  (while (and (not (predicate)) (< (time.monotonic) deadline))
    (time.sleep 0.01))
  (assert (predicate)))

(defclass Handler [http.server.BaseHTTPRequestHandler]
  (defn do-POST [self]
    (setv length (int (.get self.headers "Content-Length"))
          request-body (json.loads (.read self.rfile length))
          self.server.seen [self.path self.headers request-body]
          response-body (.encode (json.dumps self.server.reply :separators ["," ":"])))
    (.send-response self 200)
    (.send-header self "Content-Length" (str (len response-body)))
    (.end-headers self)
    (.write self.wfile response-body))
  (defn log-message [self #* args] None))

(defn test-http []
  (setv server (http.server.ThreadingHTTPServer #( "127.0.0.1" 0) Handler)
        server.reply {"status" "success" "value" {"ok" True} "logLines" ["log"]}
        server-thread (threading.Thread :target server.serve_forever :daemon True)
        client (Client f"http://127.0.0.1:{server.server_port}" "token"))
  (.start server-thread)
  (try
    (setv result (.query client "demo:state" {"room" "hy-test"}))
    (assert (= result.value {"ok" True}))
    (assert (= (get server.seen 0) "/api/query"))
    (assert (= (get (get server.seen 2) "format") "json"))
    (assert (= (get (get server.seen 1) "Authorization") "Bearer token"))
    (setv server.reply {"status" "error" "errorMessage" "expected" "errorData" {"code" "X"} "logLines" ["before"]})
    (try
      (.action client "demo:fail" {})
      (raise (AssertionError "expected FunctionError"))
      (except [error FunctionError]
        (assert (= error.data {"code" "X"}))
        (assert (= error.logs ["before"]))))
    (setv server.reply {"unexpected" True})
    (try
      (.query client "demo:state" {})
      (raise (AssertionError "expected ProtocolError"))
      (except [ProtocolError] None))
    (setv unreachable (Client "http://127.0.0.1:1"))
    (try
      (.query unreachable "demo:state" {})
      (raise (AssertionError "expected TransportError"))
      (except [TransportError] None)
      (finally (.close unreachable)))
    (.close client)
    (try
      (.query client "demo:state" {})
      (raise (AssertionError "expected ClosedError"))
      (except [ClosedError] None))
    (finally
      (.shutdown server)
      (.server-close server)
      (.join server-thread :timeout 2))))

(defclass FakeSocket []
  (defn __init__ [self]
    (setv self.sent [] self.incoming (queue.Queue) self.closed False))
  (defn send [self raw]
    (.append self.sent (json.loads raw)))
  (defn recv [self [timeout None]]
    (if self.closed (raise EOFError) None)
    (try
      (setv incoming (.get self.incoming :timeout timeout))
      (except [queue.Empty] (raise TimeoutError)))
    (if (isinstance incoming Exception) (raise incoming) incoming))
  (defn close [self]
    (setv self.closed True)))

(defn transition [query-id start end modification]
  {"type" "Transition"
   "startVersion" start
   "endVersion" end
   "modifications" [(dict {"queryId" query-id} #** modification)]})

(defn test-live []
  (setv sockets [])
  (defn factory [#* args #** kwargs]
    (setv socket (FakeSocket))
    (.append sockets socket)
    socket)
  (setv manager (LiveManager "http://example.test" "hy-test" factory)
        subscription (.subscribe manager "demo:state" {"room" "one"})
        initial (dict manager.INITIAL-VERSION)
        version-1 {"querySet" 1 "identity" 0 "ts" "AQAAAAAAAAA="}
        version-2 {"querySet" 1 "identity" 0 "ts" "AgAAAAAAAAA="}
        version-3 {"querySet" 1 "identity" 0 "ts" "AwAAAAAAAAA="}
        version-4 {"querySet" 1 "identity" 0 "ts" "BAAAAAAAAAA="})
  (try
    (eventually (fn [] (and (>= (len sockets) 1) (. (get sockets 0) sent))))
    (assert (= (get (get (. (get sockets 0) sent) 0) "connectionCount") 0))
    (assert (not (in "maxObservedTimestamp" (get (. (get sockets 0) sent) 0))))
    (.put (. (get sockets 0) incoming)
          (json.dumps (transition subscription.query-id initial version-1
                                  {"type" "QueryUpdated" "value" {"count" 0} "logLines" []})))
    (setv update (.next-update subscription 1))
    (assert (= update.value {"count" 0}))

    ;; Reconnect acknowledgement is published only after the old socket is
    ;; retired. The unchanged replay must not cross that acknowledgement.
    (.disconnect-for-adapter manager)
    (eventually (fn [] (and (>= (len sockets) 2) (. (get sockets 1) sent))))
    (assert (= (get (get (. (get sockets 1) sent) 0) "connectionCount") 1))
    (assert (= (get (get (. (get sockets 1) sent) 0) "lastCloseReason") "DebugDisconnect"))
    (assert (= (get (get (. (get sockets 1) sent) 0) "maxObservedTimestamp") "AQAAAAAAAAA="))
    (.put (. (get sockets 1) incoming)
          (json.dumps (transition subscription.query-id initial version-1
                                  {"type" "QueryUpdated" "value" {"count" 0} "logLines" []})))
    (time.sleep 0.2)
    (assert (.empty subscription.updates))
    (.put (. (get sockets 1) incoming)
          (json.dumps (transition subscription.query-id version-1 version-2
                                  {"type" "QueryUpdated" "value" {"count" 1} "logLines" ["updated"]})))
    (setv update (.next-update subscription 1))
    (assert (= update.value {"count" 1}))
    (assert (= update.logs ["updated"]))

    ;; A genuine function failure remains structured and the same subscription
    ;; can recover with a later valid transition.
    (.put (. (get sockets 1) incoming)
          (json.dumps (transition subscription.query-id version-2 version-3
                                  {"type" "QueryFailed" "errorMessage" "empty" "errorData" {"code" "ROOM_EMPTY"} "logLines" []})))
    (setv failed (.next-update subscription 1))
    (assert (isinstance failed.error FunctionError))
    (assert (= failed.error.data {"code" "ROOM_EMPTY"}))
    (.put (. (get sockets 1) incoming)
          (json.dumps (transition subscription.query-id version-3 version-4
                                  {"type" "QueryUpdated" "value" {"count" 2} "logLines" ["recovered"]})))
    (setv recovered (.next-update subscription 1))
    (assert (= recovered.value {"count" 2}))
    (assert (= recovered.logs ["recovered"]))

    ;; Invalid protocol data is reported, then a fresh connection can recover.
    (.put (. (get sockets 1) incoming) "not JSON")
    (setv protocol-failure (.next-update subscription 1))
    (assert (isinstance protocol-failure.error ProtocolError))
    (eventually (fn [] (and (>= (len sockets) 3) (. (get sockets 2) sent))))
    (.put (. (get sockets 2) incoming)
          (json.dumps (transition subscription.query-id initial version-1
                                  {"type" "QueryUpdated" "value" {"count" 3} "logLines" []})))
    (assert (= (. (.next-update subscription 1) value) {"count" 3}))

    ;; A post-handshake transport failure is structured and also recoverable.
    (.put (. (get sockets 2) incoming) (OSError "wire failed"))
    (setv transport-failure (.next-update subscription 1))
    (assert (isinstance transport-failure.error TransportError))
    (eventually (fn [] (and (>= (len sockets) 4) (. (get sockets 3) sent))))
    (.put (. (get sockets 3) incoming)
          (json.dumps (transition subscription.query-id initial version-1
                                  {"type" "QueryUpdated" "value" {"count" 4} "logLines" []})))
    (assert (= (. (.next-update subscription 1) value) {"count" 4}))
    (finally
      (.close subscription)
      (.close manager))))

(defn test-adapter []
  (setv environment (dict os.environ)
        adapter-path (os.environ.get "CONVEX_ADAPTER_PATH" "/work/client/tests/conformance/adapter.hy")
        python-command (os.environ.get "PYTHON_COMMAND" "/usr/local/bin/python3")
        (get environment "CONVEX_CLIENT_PATH") client-path
        ;; `python -m hy` rewrites sys.executable to Hy's own module path, so
        ;; invoke the known interpreter when this fixture launches the adapter.
        adapter-command (if (.endswith adapter-path ".hy")
                          [python-command "-m" "hy" adapter-path]
                          [python-command adapter-path])
        process (subprocess.run adapter-command
                               :input (+ "{bad json}\n"
                                         "{\"protocolVersion\":1,\"op\":\"hello\"}\n"
                                         "{\"id\":\"bye\",\"op\":\"close\"}\n")
                               :text True :capture_output True :env environment :timeout 5)
        events (list (map json.loads (.splitlines process.stdout))))
  (when (!= process.returncode 0)
    (print "adapter subprocess return" process.returncode
           "stdout" (repr process.stdout) "stderr" (repr process.stderr) :file sys.stderr))
  (assert (= process.returncode 0) process.stderr)
  (assert (= (len events) 3))
  (assert (not (in "id" (get events 0))))
  (assert (= (get (get events 0) "type") "error"))
  (assert (not (in "id" (get events 1))))
  (assert (= (get (get events 1) "language") "hy"))
  (assert (= (get events 2) {"id" "bye" "type" "closed"})))

(defn test-buffer-budget []
  (setv subscription (Subscription None 0)
        megabyte (* "x" 1024 1024))
  (for [_ (range 20)] (.deliver subscription (Update :value {"payload" megabyte})))
  (assert (<= subscription.buffered-bytes subscription.MAX-BYTES))
  (assert (<= (.qsize subscription.updates) subscription.MAX-UPDATES))
  ;; A single value cannot bypass the byte cap after older entries are evicted.
  (.deliver subscription (Update :value {"payload" (* "x" (* 9 1024 1024))}))
  (assert (= subscription.buffered-bytes 0))
  (assert (.empty subscription.updates)))

(test-http)
(test-live)
(test-adapter)
(test-buffer-budget)
(print "PASS Hy HTTP, Live reconnect, recovery, buffer, and adapter fixtures")
