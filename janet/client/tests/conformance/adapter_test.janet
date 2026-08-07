# Adapter protocol regressions.
#
# The shared controller validates every emitted event against
# `_shared/schemas/adapter.schema.json`, and a shape mismatch there costs a
# whole conformance run to diagnose. These tests pin the shapes locally instead:
# what is accepted, what is rejected, which keys appear, and which keys are
# absent rather than null.

(os/setenv "ADAPTER_LIBRARY_ONLY" "1")

(import ../check :as check)
(import ../fixture :as fixture)
(import ./adapter :as adapter)
(import ../../convex :as convex)
(import ../../http :as http)
(import ../../json :as json)
(import transport :as transport)
(import ../../websocket :as ws)

#
# Command validation
#

(def valid-commands
  [@{"id" "a" "op" "hello" "protocolVersion" 1}
   @{"id" "a" "op" "query" "path" "demo:state" "args" @{}}
   @{"id" "a" "op" "mutation" "path" "demo:increment" "args" @{"room" "r"}}
   @{"id" "a" "op" "action" "path" "demo:greet" "args" @{}}
   @{"id" "a" "op" "subscribe" "subscriptionId" "s" "path" "demo:state" "args" @{}}
   @{"id" "a" "op" "unsubscribe" "subscriptionId" "s"}
   @{"id" "a" "op" "setAuth" "token" ""}
   @{"id" "a" "op" "close"}
   @{"id" "a" "op" "debugDisconnect"}])

(each command valid-commands
  (check/check (adapter/strict-command command)
               (string "accepts a well formed " (get command "op") " command")))

(def invalid-commands
  [[@{"op" "hello" "protocolVersion" 1} "a command with no id"]
   [@{"id" 3 "op" "hello" "protocolVersion" 1} "an id that is not a string"]
   [@{"id" "" "op" "hello" "protocolVersion" 1} "an empty id"]
   [@{"id" (string/repeat "x" 129) "op" "hello" "protocolVersion" 1} "an id of 129 bytes"]
   [@{"id" "a" "op" "hello" "protocolVersion" 2} "an unsupported protocol version"]
   [@{"id" "a" "op" "hello"} "a hello with no protocol version"]
   [@{"id" "a" "op" "hello" "protocolVersion" 1 "extra" true} "an unexpected extra field"]
   [@{"id" "a" "op" "notAnOperation"} "an unknown operation"]
   [@{"id" "a" "op" "query" "path" "ab" "args" @{}} "a path shorter than three characters"]
   [@{"id" "a" "op" "query" "path" "demo:state" "args" @[]} "arguments that are not an object"]
   [@{"id" "a" "op" "query" "path" "demo:state"} "a query with no arguments"]
   [@{"id" "a" "op" "subscribe" "subscriptionId" @[] "path" "demo:state" "args" @{}}
    "a subscription id that is not a string"]
   [@{"id" "a" "op" "unsubscribe"} "an unsubscribe with no subscription id"]
   [@{"id" "a" "op" "setAuth" "token" 1} "a token that is not a string"]
   [@{"id" "a" "op" "close" "extra" true} "a close with an extra field"]])

(each [command description] invalid-commands
  (check/check-raises "ProtocolError" (fn [] (adapter/strict-command command))
                      (string "refuses " description)))

# Identifier length is measured in code points, because the shared schema's
# maxLength counts characters and a byte count would disagree on emoji.
(check/check (adapter/valid-id? (string/repeat "😀" 128)) "128 astral code points fit")
(check/check (not (adapter/valid-id? (string/repeat "😀" 129))) "129 astral code points do not")
(check/check (not (adapter/valid-id? (string/from-bytes 0xC0 0x80)))
             "an overlong UTF-8 id is refused")

#
# Event shapes
#

(def anonymous (adapter/error-event nil {:name "ProtocolError" :message "bad line"}))
(check/check (not (has-key? anonymous "id"))
             "an error for an unparseable line omits id rather than sending null")
(check/check= (json/encode anonymous)
              `{"error":{"message":"bad line","name":"ProtocolError"},"type":"error"}`
              "an anonymous error serializes without an id key")

(def identified (adapter/error-event "req-1" {:name "FunctionError"
                                              :message "nope"
                                              :data @{"code" "X"}
                                              :logs @["[LOG] a"]}))
(check/check= (get identified "id") "req-1" "an identified error keeps its id")
(check/check= (get-in identified ["error" "data" "code"]) "X"
              "structured error data is carried in the error object")
(check/check= (get identified "logs") @["[LOG] a"]
              "log lines sit beside the error rather than inside it")
(check/check (not (has-key? (get identified "error") "logs"))
             "log lines are not duplicated inside the error object")

(def bare (adapter/error-object {:name "TransportError" :message "gone"}))
(check/check (not (has-key? bare "data"))
             "an error with no data omits the key rather than sending null")

#
# A whole session over one stream
#

(defn- session []
  (def [control controller] (fixture/pair))
  [(adapter/adapter-new control) controller])

(defn- send-command! [controller command]
  (fixture/write-all! controller (string (json/encode command) "\n")))

(defn- send-raw! [controller line]
  (fixture/write-all! controller (string line "\n")))

(defn- run-session!
  "Step the adapter until it stops, collecting everything it wrote."
  [state controller timeout-ms]
  (def collected (buffer/new 1024))
  (def deadline (http/deadline-in timeout-ms))
  (var running true)
  (while (and running (> (http/remaining-ms deadline) 0))
    (set running (adapter/adapter-step! state))
    (fixture/read-available! controller collected 2))
  (adapter/drain-output! state 500)
  (repeat 10 (fixture/read-available! controller collected 5))
  (def lines (filter (fn [line] (> (length line) 0))
                     (string/split "\n" (string collected))))
  (map json/decode lines))

(def [hello-state hello-controller] (session))
(send-command! hello-controller @{"id" "h1" "op" "hello" "protocolVersion" 1})
(send-raw! hello-controller "{not json")
(send-command! hello-controller @{"id" "u1" "op" "notAnOperation"})
(send-command! hello-controller @{"id" "c1" "op" "close"})
(def events (run-session! hello-state hello-controller 5000))

(check/check= (length events) 4 "every command produced exactly one event")
(def ready (get events 0))
(check/check= (get ready "type") "ready" "hello is answered with ready")
(check/check= (get ready "id") "h1" "ready carries the request id")
(check/check= (get ready "protocolVersion") 1 "ready reports adapter protocol v1")
(check/check= (get ready "language") "janet" "ready reports the language id")
(check/check (> (length (or (get ready "implementation") "")) 0)
             "ready reports its implementation provenance")
(check/check (string/has-prefix? "Janet " (or (get ready "runtime") ""))
             "ready reports the Janet runtime version")

(def malformed (get events 1))
(check/check= (get malformed "type") "error" "an unparseable line produces an error")
(check/check (not (has-key? malformed "id")) "an unparseable line has no id to report")

(def unknown (get events 2))
(check/check= (get unknown "type") "error" "an unknown operation produces an error")
(check/check= (get unknown "id") "u1" "an unknown operation still correlates by id")
(check/check= (get-in unknown ["error" "name"]) "ProtocolError"
              "an unknown operation is a protocol error")

(def closed (get events 3))
(check/check= (get closed "type") "closed" "close is answered with closed")
(check/check= (get closed "id") "c1" "closed carries the request id")
(check/check= (adapter/adapter-step! hello-state) false "the adapter stops after close")

# A command split across two writes must still be handled as one command, and
# a CRLF line ending is still NDJSON.
(def [split-state split-controller] (session))
(fixture/write-all! split-controller `{"id": "h2", "op"`)
(adapter/adapter-step! split-state)
(fixture/write-all! split-controller (string `: "hello", "protocolVersion": 1}` "\r\n"))
(send-command! split-controller @{"id" "c2" "op" "close"})
(def split-events (run-session! split-state split-controller 5000))
(check/check= (get (get split-events 0) "type") "ready"
              "a command split across writes is reassembled")
(check/check= (get (get split-events 1) "type") "closed" "the split session closes cleanly")

#
# Bounded output
#

(def [pressure-state pressure-controller] (session))
# Nothing ever reads `pressure-controller`, so the queue is the only place
# these events can go.
(var accepted 0)
(var index 0)
(while (< index (+ 2 adapter/max-output-events))
  (when (adapter/enqueue-event! pressure-state @{"type" "ack" "id" (string "a" index)})
    (set accepted (+ 1 accepted)))
  (set index (+ index 1)))
(check/check= accepted adapter/max-output-events
              "exactly the queue's worth of mandatory events were accepted")
(check/check (<= (length (get pressure-state :outbuf)) adapter/max-output-events)
             "the output queue never exceeds its event limit")
(check/check= (get pressure-state :running) false
             "a mandatory event that cannot be queued fails the connection")
(check/check (get pressure-state :failure)
             "the failure is recorded rather than silently dropped")
(transport/close pressure-controller)

#
# The relay barrier
#

(os/setenv "CONVEX_URL" "http://fixture.test:1234")

(def peer-state @{:peer nil})

(defn- attach-peer! [client]
  (def [client-conn server-conn] (fixture/pair))
  (def peer (fixture/ws-peer server-conn))
  (def pending (ws/begin client-conn (convex/live-url client) @[] (http/deadline-in 2000)))
  (fixture/ws-handshake! peer)
  (def socket (ws/complete pending))
  (put peer-state :peer peer)
  socket)

(defn- pump! [state timeout-ms]
  (def deadline (http/deadline-in timeout-ms))
  (while (> (http/remaining-ms deadline) 0)
    (when (get state :client) (convex/step! (get state :client) 2))
    (when (get peer-state :peer) (fixture/ws-step! (get peer-state :peer) 2))))

(defn- await-message! [state timeout-ms]
  (def deadline (http/deadline-in timeout-ms))
  (var raw nil)
  (while (and (nil? raw) (> (http/remaining-ms deadline) 0))
    (when (get state :client) (convex/step! (get state :client) 2))
    (when (get peer-state :peer)
      (fixture/ws-step! (get peer-state :peer) 2)
      (set raw (fixture/ws-next-message! (get peer-state :peer)))))
  (when raw (json/decode raw)))

(defn- subscription-events [state]
  (filter (fn [entry] (string/find `"type":"subscription"` (get entry :text)))
          (get state :outbuf)))

(def [relay-state relay-controller] (session))
(with-dyns [convex/live-socket-dynamic attach-peer!]
  (adapter/process-line!
    relay-state
    (json/encode @{"id" "s1" "op" "subscribe" "subscriptionId" "sub-a"
                   "path" "demo:state" "args" @{"room" "barrier"}}))
  (def connect-message (await-message! relay-state 3000))
  (check/check= (get connect-message "type") "Connect" "the relay test opened a session")
  (def add (await-message! relay-state 3000))
  (def query-id (get-in add ["modifications" 0 "queryId"]))
  (fixture/ws-send-text!
    (get peer-state :peer)
    (json/encode {"type" "Transition"
                  "startVersion" {"querySet" 0 "identity" 0 "ts" "AAAAAAAAAAA="}
                  "endVersion" {"querySet" 1 "identity" 0 "ts" "AQAAAAAAAAA="}
                  "modifications" [{"type" "QueryUpdated" "queryId" query-id
                                    "value" {"count" 0}}]}))
  (pump! relay-state 500)

  # Take an update off the queue but do not publish it yet: this is the moment
  # a real relay can be paused.
  (def taken (adapter/relay-dequeue! relay-state))
  (check/check (not (nil? taken)) "an update was dequeued for the relay")

  # Now the controller unsubscribes. The acknowledgement is about to go out.
  (adapter/process-line!
    relay-state
    (json/encode @{"id" "u1" "op" "unsubscribe" "subscriptionId" "sub-a"}))

  (check/check= (adapter/relay-publish! relay-state (get taken 0) (get taken 1) (get taken 2))
                false
                "an update dequeued before an unsubscribe cannot cross its acknowledgement")
  (check/check= (length (subscription-events relay-state)) 0
                "no subscription event was queued after the barrier")
  (convex/close! (get relay-state :client)))
(transport/close relay-controller)

# The same barrier has to hold when an id is reused rather than removed.
(def [replace-state replace-controller] (session))
(with-dyns [convex/live-socket-dynamic attach-peer!]
  (adapter/process-line!
    replace-state
    (json/encode @{"id" "s1" "op" "subscribe" "subscriptionId" "sub-b"
                   "path" "demo:state" "args" @{"room" "replace"}}))
  (await-message! replace-state 3000)
  (def add (await-message! replace-state 3000))
  (def query-id (get-in add ["modifications" 0 "queryId"]))
  (fixture/ws-send-text!
    (get peer-state :peer)
    (json/encode {"type" "Transition"
                  "startVersion" {"querySet" 0 "identity" 0 "ts" "AAAAAAAAAAA="}
                  "endVersion" {"querySet" 1 "identity" 0 "ts" "AQAAAAAAAAA="}
                  "modifications" [{"type" "QueryUpdated" "queryId" query-id
                                    "value" {"count" 0}}]}))
  (pump! replace-state 500)
  (def taken (adapter/relay-dequeue! replace-state))
  (check/check (not (nil? taken)) "an update was dequeued before the replacement")
  (adapter/process-line!
    replace-state
    (json/encode @{"id" "s2" "op" "subscribe" "subscriptionId" "sub-b"
                   "path" "demo:state" "args" @{"room" "replace-again"}}))
  (check/check= (adapter/relay-publish! replace-state
                                        (get taken 0) (get taken 1) (get taken 2))
                false
                "an update from a replaced subscription cannot reach the new one")
  (check/check= (length (subscription-events replace-state)) 0
                "no subscription event survived the replacement")
  (convex/close! (get replace-state :client)))
(transport/close replace-controller)

# debugDisconnect must retire the socket before its acknowledgement is queued.
(def [disconnect-state disconnect-controller] (session))
(with-dyns [convex/live-socket-dynamic attach-peer!]
  (adapter/process-line!
    disconnect-state
    (json/encode @{"id" "s1" "op" "subscribe" "subscriptionId" "sub-c"
                   "path" "demo:state" "args" @{"room" "disconnect"}}))
  (await-message! disconnect-state 3000)
  (await-message! disconnect-state 3000)
  (check/check= (get (convex/live-status (get disconnect-state :client)) :connected) true
                "the disconnect test has a live socket")
  (adapter/process-line!
    disconnect-state
    (json/encode @{"id" "d1" "op" "debugDisconnect"}))
  (check/check= (get (convex/live-status (get disconnect-state :client)) :connected) false
                "the socket is already retired when the acknowledgement is queued")
  (def last-event (json/decode (get (last (get disconnect-state :outbuf)) :text)))
  (check/check= (get last-event "type") "ack" "debugDisconnect is acknowledged")
  (check/check= (get last-event "id") "d1" "the acknowledgement carries the request id")
  (convex/close! (get disconnect-state :client)))
(transport/close disconnect-controller)

(check/report "janet adapter")
