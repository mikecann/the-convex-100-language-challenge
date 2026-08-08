# Live regressions: RFC 6455 framing and the Convex sync state machine.
#
# Every test drives a real socket. The client's own framer writes masked client
# frames, the fixture peer unmasks and asserts them, and the fixture writes
# unmasked server frames back. Nothing is stubbed, so a passing test means the
# bytes on the wire were right.

(import ./check :as check)
(import ./fixture :as fixture)
(import ../codec :as codec)
(import ../convex :as convex)
(import ../http :as http)
(import ../json :as json)
(import transport :as transport)
(import ../websocket :as ws)

#
# Direct framing
#

(defn- open-socket!
  "Open a client socket and its server-side peer through a real handshake."
  []
  (def [client-conn server-conn] (fixture/pair))
  (def peer (fixture/ws-peer server-conn))
  (def pending (ws/begin client-conn "ws://fixture.test" @[] (http/deadline-in 2000)))
  (fixture/ws-handshake! peer)
  [(ws/complete pending) peer])

(defn- poll-until!
  "Poll a socket until it yields an event or the timeout expires."
  [socket timeout-ms]
  (def deadline (http/deadline-in timeout-ms))
  (var event nil)
  (while (and (nil? event) (> (http/remaining-ms deadline) 0))
    (set event (ws/poll! socket 5)))
  event)

(def [probe-socket probe-peer] (open-socket!))
(check/check= (poll-until! probe-socket 50) nil "an idle socket yields no event")
(ws/send-text! probe-socket `{"type":"Ping"}` 1000)
(fixture/ws-step! probe-peer 50)
(check/check= (json/decode (fixture/ws-next-message! probe-peer)) @{"type" "Ping"}
              "a client message arrives masked and intact")
(ws/close-socket! probe-socket)
(fixture/ws-close! probe-peer)

# The handshake is validated, not merely completed.
(each [respond description]
  [[(fn [bad] (fixture/ws-reject! bad 403 "no")) "a non-101 upgrade response is refused"]
   [(fn [bad] (fixture/ws-bad-accept! bad)) "a wrong Sec-WebSocket-Accept is refused"]]
  (def [client-conn server-conn] (fixture/pair))
  (def bad-peer (fixture/ws-peer server-conn))
  (def pending (ws/begin client-conn "ws://fixture.test" @[] (http/deadline-in 2000)))
  (respond bad-peer)
  (check/check-raises "ProtocolError" (fn [] (ws/complete pending)) description)
  (transport/close client-conn)
  (fixture/ws-close! bad-peer))

# Hostile frames. Each of these is a shape a lenient framer would accept.
(each [bytes description]
  [[(string/from-bytes 0xC1 0x01 0x41) "a reserved bit is refused"]
   [(string/from-bytes 0x81 0x81 0x00 0x00 0x00 0x00 0x41) "a masked server frame is refused"]
   [(string/from-bytes 0x83 0x01 0x41) "an unknown opcode is refused"]
   [(string/from-bytes 0x80 0x01 0x41) "a continuation with no message is refused"]
   [(string/from-bytes 0x89 0x7E 0x00 0x7E) "an oversized control frame is refused"]
   [(string/from-bytes 0x09 0x01 0x41) "a fragmented control frame is refused"]
   [(string/from-bytes 0x81 0x7E 0x00 0x05 0x41 0x42 0x43 0x44 0x45)
    "a non-minimal 16-bit length is refused"]
   [(string/from-bytes 0x82 0x01 0x41) "a binary message is refused"]
   [(string/from-bytes 0x81 0x02 0xC3 0x28) "an invalid UTF-8 text message is refused"]
   [(string/from-bytes 0x88 0x01 0x03) "a one-byte close payload is refused"]
   [(string/from-bytes 0x88 0x02 0x03 0xEC) "a reserved close code is refused"]
   [(string (string/from-bytes 0x01 0x01 0x41) (string/from-bytes 0x81 0x01 0x42))
    "a data frame interrupting an unfinished message is refused"]]
  (def [hostile-socket hostile-peer] (open-socket!))
  (fixture/ws-send-raw! hostile-peer bytes)
  (check/check-raises "ProtocolError" (fn [] (poll-until! hostile-socket 500)) description)
  (ws/close-socket! hostile-socket)
  (fixture/ws-close! hostile-peer))

# A text message may be fragmented anywhere, including inside a code point.
# Validating each fragment on its own is the classic way to get this wrong.
(def [fragment-socket fragment-peer] (open-socket!))
(fixture/ws-send-raw! fragment-peer (string/from-bytes 0x01 0x01 0xC3))
(check/check= (poll-until! fragment-socket 50) nil "an incomplete message yields nothing yet")
(check/check (get fragment-socket :partial-since)
             "an incomplete message starts its absolute deadline")
(fixture/ws-send-raw! fragment-peer (string/from-bytes 0x80 0x04 0xA9 0x6C 0x6C 0x6F))
(check/check= (poll-until! fragment-socket 500) [:text "éllo"]
              "fragments split inside a code point reassemble correctly")
(check/check= (get fragment-socket :partial-since) nil
              "a fully drained buffer clears the deadline")

# The frame deadline is absolute. Rewinding the recorded start proves the rule
# itself rather than waiting five seconds on a cooperative peer.
(fixture/ws-send-raw! fragment-peer (string/from-bytes 0x81 0x40 0x41))
(check/check= (poll-until! fragment-socket 50) nil "a stalled frame yields nothing")
(check/check (get fragment-socket :partial-since) "a stalled frame is holding the deadline")
(put fragment-socket :partial-since (- (http/now-ms) (+ ws/max-frame-deadline-ms 1000)))
(check/check-raises "TransportError" (fn [] (ws/poll! fragment-socket 5))
                    "a frame that outlives its absolute deadline fails the connection")
(check/check (get fragment-socket :partial-since)
             "the failed parser keeps its state instead of resynchronizing")
(ws/close-socket! fragment-socket)
(fixture/ws-close! fragment-peer)

# A ping is answered without disturbing the message stream.
(def [ping-socket ping-peer] (open-socket!))
(fixture/ws-send-ping! ping-peer "hi")
(fixture/ws-send-text! ping-peer `{"type":"Ping"}`)
(check/check= (poll-until! ping-socket 500) [:text `{"type":"Ping"}`]
              "a ping does not consume the message that follows it")
(fixture/ws-step! ping-peer 50)
(check/check= (get ping-peer :pongs) 1 "the client answered the ping with a pong")
(ws/close-socket! ping-socket)
(fixture/ws-close! ping-peer)

# Closing is bounded even when the peer never reads a byte. The buffers are
# filled first so the close frame genuinely cannot be written.
(def [stalled-socket stalled-peer] (open-socket!))
(var filled 0)
(var writing true)
(while (and writing (< filled 256))
  (def written (transport/write (get stalled-socket :conn)
                                (string/repeat "x" 16384) 0 20))
  (set writing (> written 0))
  (set filled (+ filled 1)))
(check/check (not writing) "the fixture peer's receive buffer was filled")
(def close-started (http/now-ms))
(ws/send-close! stalled-socket 1000 200)
(ws/close-socket! stalled-socket)
(def close-elapsed (- (http/now-ms) close-started))
(check/check (< close-elapsed 1500)
             (string "closing a stalled peer respected its deadline, took "
                     close-elapsed "ms"))
(fixture/ws-close! stalled-peer)

#
# Convex sync state machine
#

(def peer-state @{:peer nil :peers @[] :headers nil})

(defn- attach-peer!
  "The test seam: build a real socket over a loopback pair, remembering its peer."
  [client]
  (def [client-conn server-conn] (fixture/pair))
  (def peer (fixture/ws-peer server-conn))
  (def pending (ws/begin client-conn (convex/live-url client)
                         @[["Convex-Client" "janet-test"]]
                         (http/deadline-in 2000)))
  (put peer-state :headers (get (fixture/ws-handshake! peer) :headers))
  (def socket (ws/complete pending))
  (put peer-state :peer peer)
  (array/push (get peer-state :peers) peer)
  socket)

(defn- reset-peers! []
  (each peer (get peer-state :peers) (fixture/ws-close! peer))
  (put peer-state :peer nil)
  (put peer-state :peers @[]))

(defn- pump-until!
  "Step the client and the current fixture peer until `predicate` holds."
  [client predicate timeout-ms]
  (def deadline (http/deadline-in timeout-ms))
  (var done (predicate))
  (while (and (not done) (> (http/remaining-ms deadline) 0))
    (convex/step! client 2)
    (when (get peer-state :peer) (fixture/ws-step! (get peer-state :peer) 2))
    (set done (predicate)))
  done)

(defn- next-server-message!
  "Wait for the client's next protocol message and decode it."
  [client timeout-ms]
  (pump-until! client
               (fn [] (and (get peer-state :peer)
                           (> (length (get (get peer-state :peer) :messages)) 0)))
               timeout-ms)
  (def raw (and (get peer-state :peer)
                (fixture/ws-next-message! (get peer-state :peer))))
  (if raw (json/decode raw) @{}))

(defn- wait-update! [client subscription timeout-ms]
  (var update nil)
  (pump-until! client
               (fn []
                 (set update (convex/poll-update! client subscription))
                 (not (nil? update)))
               timeout-ms)
  update)

(defn- timestamp-for
  "Encode `n` the way the sync profile does: little-endian uint64 in base64."
  [n]
  (def raw (buffer/new 8))
  (var value n)
  (repeat 8
    (buffer/push-byte raw (mod value 256))
    (set value (math/floor (/ value 256))))
  (codec/base64-encode raw))

(def ts0 (timestamp-for 0))
(check/check= ts0 "AAAAAAAAAAA=" "the initial timestamp encodes as the profile's constant")
(check/check= (timestamp-for 1) "AQAAAAAAAAA=" "timestamp one matches the profile's encoding")
(check/check= (timestamp-for 2) "AgAAAAAAAAA=" "timestamp two matches the profile's encoding")

(defn- version [query-set timestamp]
  {"querySet" query-set "identity" 0 "ts" timestamp})

# The server's version cursor, which every transition has to continue from.
(def cursor @{:remote (version 0 ts0) :tick 0})

(defn- reset-cursor! []
  # A retired connection resets both sides to the zero version.
  (put cursor :remote (version 0 ts0)))

(defn- push-transition!
  "Send one transition that continues from the cursor, and advance it."
  [query-set modifications]
  (put cursor :tick (+ 1 (get cursor :tick)))
  (def finish (version query-set (timestamp-for (get cursor :tick))))
  (fixture/ws-send-text!
    (get peer-state :peer)
    (json/encode {"type" "Transition"
                  "startVersion" (get cursor :remote)
                  "endVersion" finish
                  "modifications" modifications}))
  (put cursor :remote finish)
  finish)

# --- opening exchange, initial value, external update, and drift ---

(reset-peers!)
(reset-cursor!)
(def client (convex/new-client "http://fixture.test:1234"))
(with-dyns [convex/live-socket-dynamic attach-peer!]
  (def sub (convex/subscribe! client "demo:state" @{"room" "alpha"}))
  (def connect-message (next-server-message! client 3000))
  (check/check= (get connect-message "type") "Connect" "the session opens with Connect")
  (check/check= (length (or (get connect-message "sessionId") "")) 36
                "Connect carries a UUID session id")
  (check/check= (get connect-message "connectionCount") 0 "the first connection counts zero")
  (check/check= (get connect-message "lastCloseReason") "InitialConnect"
                "the first connection reports InitialConnect")
  (check/check (not (has-key? connect-message "maxObservedTimestamp"))
               "maxObservedTimestamp is omitted rather than sent as null")
  (check/check= (get (get peer-state :headers) "convex-client") "janet-test"
                "the upgrade request identifies the client version")

  (def add (next-server-message! client 3000))
  (check/check= (get add "type") "ModifyQuerySet" "the query set is modified next")
  (check/check= (get add "baseVersion") 0 "a fresh connection starts at version zero")
  (check/check= (get add "newVersion") 1 "the first modification advances to version one")
  (check/check= (get-in add ["modifications" 0 "type"]) "Add" "the query is added")
  (check/check= (get-in add ["modifications" 0 "udfPath"]) "demo:state"
                "the Add carries the function path")
  (check/check= (get-in add ["modifications" 0 "args" 0 "room"]) "alpha"
                "the Add carries one argument object inside an array")

  (push-transition! 1 [{"type" "QueryUpdated"
                        "queryId" (get sub :query-id)
                        "value" {"count" 0}
                        "logLines" ["[LOG] demo:state"]}])
  (def initial (wait-update! client sub 3000))
  (check/check= (get-in initial [:value "count"]) 0 "the initial Live value arrives")
  (check/check= (get initial :logs) @["[LOG] demo:state"] "log lines reach the subscriber")

  (push-transition! 1 [{"type" "QueryUpdated"
                        "queryId" (get sub :query-id)
                        "value" {"count" 1}}])
  (check/check= (get-in (wait-update! client sub 3000) [:value "count"]) 1
                "an external change arrives as a new Live value")
  (check/check= (get (convex/live-status client) :max-observed-timestamp)
                (timestamp-for 2)
                "the highest observed timestamp is tracked")

  # An update already taken off the queue must not survive an unsubscribe.
  (push-transition! 1 [{"type" "QueryUpdated"
                        "queryId" (get sub :query-id)
                        "value" {"count" 2}}])
  (def in-flight (wait-update! client sub 3000))
  (check/check (convex/subscription-current? sub in-flight)
               "a freshly dequeued update is current")
  (convex/unsubscribe! client sub)
  (check/check (not (convex/subscription-current? sub in-flight))
               "unsubscribing invalidates an update a relay already dequeued")
  (convex/close! client))

# --- a transition that does not continue from the local version is drift ---

(reset-peers!)
(reset-cursor!)
(def drift-client (convex/new-client "http://fixture.test:1234"))
(with-dyns [convex/live-socket-dynamic attach-peer!]
  (def sub (convex/subscribe! drift-client "demo:state" @{"room" "drift"}))
  (next-server-message! drift-client 3000)
  (next-server-message! drift-client 3000)
  (fixture/ws-send-text!
    (get peer-state :peer)
    (json/encode {"type" "Transition"
                  "startVersion" (version 9 (timestamp-for 40))
                  "endVersion" (version 9 (timestamp-for 41))
                  "modifications" [{"type" "QueryUpdated"
                                    "queryId" (get sub :query-id)
                                    "value" {"count" 99}}]}))
  (def drifted (wait-update! drift-client sub 3000))
  (check/check= (get-in drifted [:error :name]) "ProtocolError"
                "a mismatched start version is reported as protocol drift")
  (check/check= (get (convex/live-status drift-client) :connected) false
                "protocol drift retires the connection")
  (convex/close! drift-client))

# --- a whole transition is validated before any part of it is published ---

(reset-peers!)
(reset-cursor!)
(def atomic-client (convex/new-client "http://fixture.test:1234"))
(with-dyns [convex/live-socket-dynamic attach-peer!]
  (def sub (convex/subscribe! atomic-client "demo:state" @{"room" "atomic"}))
  (next-server-message! atomic-client 3000)
  (next-server-message! atomic-client 3000)
  # The first modification is perfectly valid; the second is not.
  (push-transition! 1 [{"type" "QueryUpdated"
                        "queryId" (get sub :query-id)
                        "value" {"count" 5}}
                       {"type" "QueryFailed" "queryId" (get sub :query-id)}])
  (def published (wait-update! atomic-client sub 3000))
  (check/check= (get-in published [:error :name]) "ProtocolError"
                "an invalid later modification rejects the whole transition")
  (check/check= (convex/poll-update! atomic-client sub) nil
                "the valid earlier modification was never published")
  (convex/close! atomic-client))

# --- a failed query recovers on the same subscription ---

(reset-peers!)
(reset-cursor!)
(def repair-client (convex/new-client "http://fixture.test:1234"))
(with-dyns [convex/live-socket-dynamic attach-peer!]
  (def sub (convex/subscribe! repair-client "demo:requiresNonzero" @{"room" "beta"}))
  (next-server-message! repair-client 3000)
  (next-server-message! repair-client 3000)
  (push-transition! 1 [{"type" "QueryFailed"
                        "queryId" (get sub :query-id)
                        "errorMessage" "room is empty"
                        "errorData" {"code" "ROOM_EMPTY"}}])
  (def failed (wait-update! repair-client sub 3000))
  (check/check= (get-in failed [:error :name]) "FunctionError"
                "a failing query is a function error, not a transport error")
  (check/check= (get-in failed [:error :data "code"]) "ROOM_EMPTY"
                "the structured error data reaches the subscriber")
  (push-transition! 1 [{"type" "QueryUpdated"
                        "queryId" (get sub :query-id)
                        "value" {"count" 1}}])
  (check/check= (get-in (wait-update! repair-client sub 3000) [:value "count"]) 1
                "the same subscription recovers with a later valid value")
  (convex/close! repair-client))

# --- unsubscribe removes the query and closes the door behind it ---

(reset-peers!)
(reset-cursor!)
(def remove-client (convex/new-client "http://fixture.test:1234"))
(with-dyns [convex/live-socket-dynamic attach-peer!]
  (def sub (convex/subscribe! remove-client "demo:state" @{"room" "gamma"}))
  (next-server-message! remove-client 3000)
  (next-server-message! remove-client 3000)
  (push-transition! 1 [{"type" "QueryUpdated"
                        "queryId" (get sub :query-id)
                        "value" {"count" 0}}])
  (check/check= (get-in (wait-update! remove-client sub 3000) [:value "count"]) 0
                "the subscription is live before it is removed")

  (convex/unsubscribe! remove-client sub)
  (def removal (next-server-message! remove-client 3000))
  (check/check= (get-in removal ["modifications" 0 "type"]) "Remove"
                "unsubscribing sends a Remove")
  (check/check= (get removal "baseVersion") 1 "the Remove continues the version sequence")
  (check/check= (get removal "newVersion") 2 "the Remove advances the version")

  # A value the server was already sending must not reach a removed subscriber.
  (push-transition! 2 [{"type" "QueryUpdated"
                        "queryId" (get sub :query-id)
                        "value" {"count" 7}}])
  (pump-until! remove-client (fn [] false) 200)
  (check/check= (convex/poll-update! remove-client sub) nil
                "a removed subscription receives nothing further")
  (convex/close! remove-client))

# --- five real reconnects on one subscription ---

(reset-peers!)
(reset-cursor!)
(def reconnect-client (convex/new-client "http://fixture.test:1234"))
(with-dyns [convex/live-socket-dynamic attach-peer!]
  (var failures 0)
  (def expect (fn [condition] (unless condition (set failures (+ 1 failures)))))

  (def sub (convex/subscribe! reconnect-client "demo:state" @{"room" "delta"}))
  (next-server-message! reconnect-client 3000)
  (next-server-message! reconnect-client 3000)
  (push-transition! 1 [{"type" "QueryUpdated" "queryId" (get sub :query-id)
                        "value" {"count" 0}}])
  (check/check= (get-in (wait-update! reconnect-client sub 3000) [:value "count"]) 0
                "the reconnect subscription starts at zero")

  (var attempt 1)
  (while (<= attempt 5)
    (def before (get (convex/live-status reconnect-client) :connection-count))
    (convex/debug-disconnect! reconnect-client)
    (expect (= false (get (convex/live-status reconnect-client) :connected)))
    (expect (= (+ 1 before) (get (convex/live-status reconnect-client) :connection-count)))
    (reset-cursor!)

    (def opened (next-server-message! reconnect-client 5000))
    (expect (= "Connect" (get opened "type")))
    (expect (= attempt (get opened "connectionCount")))
    (expect (= "DebugDisconnect" (get opened "lastCloseReason")))
    # The client already saw a timestamp, so it must tell the server about it.
    (expect (string? (get opened "maxObservedTimestamp")))

    (def replay (next-server-message! reconnect-client 5000))
    (expect (= "Add" (get-in replay ["modifications" 0 "type"])))
    (expect (= (get sub :query-id) (get-in replay ["modifications" 0 "queryId"])))
    (expect (= 0 (get replay "baseVersion")))
    (expect (= 1 (get replay "newVersion")))

    # The rehydrated value is unchanged, so publishing it would make a
    # disconnect visible to the subscriber as a duplicate update.
    (push-transition! 1 [{"type" "QueryUpdated" "queryId" (get sub :query-id)
                          "value" {"count" (- attempt 1)}}])
    (pump-until! reconnect-client (fn [] false) 150)
    (expect (nil? (convex/poll-update! reconnect-client sub)))

    # The genuine change after the reconnect must be published.
    (push-transition! 1 [{"type" "QueryUpdated" "queryId" (get sub :query-id)
                          "value" {"count" attempt}}])
    (expect (= attempt (get-in (wait-update! reconnect-client sub 3000) [:value "count"])))

    # A healthy connection must not inherit the previous maximum delay.
    (expect (= convex/initial-backoff-ms
               (get (convex/live-status reconnect-client) :backoff-ms)))
    (set attempt (+ attempt 1)))

  (check/check= failures 0
                (string "five reconnects each replayed the Add, suppressed "
                        "rehydration, and delivered the change"))
  (check/check= (get (convex/live-status reconnect-client) :connection-count) 5
                "the client counted exactly five retired connections")
  (convex/close! reconnect-client))

# --- bounded delivery ---

(reset-peers!)
(reset-cursor!)
(def bounded-client (convex/new-client "http://fixture.test:1234"))
(with-dyns [convex/live-socket-dynamic attach-peer!]
  (def sub (convex/subscribe! bounded-client "demo:state" @{"room" "bounds"}))
  (next-server-message! bounded-client 3000)
  (next-server-message! bounded-client 3000)
  (var index 0)
  (while (< index 40)
    (push-transition! 1 [{"type" "QueryUpdated" "queryId" (get sub :query-id)
                          "value" {"count" index}}])
    (pump-until! bounded-client (fn [] false) 20)
    (set index (+ index 1)))
  (check/check (<= (length (get sub :updates)) convex/max-updates-per-subscription)
               (string "a slow consumer keeps at most "
                       convex/max-updates-per-subscription " updates, kept "
                       (length (get sub :updates))))
  # The newest value is the one that matters: it is the current state.
  (def newest (get (get sub :updates) (- (length (get sub :updates)) 1)))
  (check/check= (get-in newest [:payload :value "count"]) 39
                "the newest value survives a full queue")
  (convex/close! bounded-client))

# A byte budget is not the same as a count budget: sixteen large values would
# still be far more memory than this process may hold.
(reset-peers!)
(reset-cursor!)
(def byte-client (convex/new-client "http://fixture.test:1234"))
(with-dyns [convex/live-socket-dynamic attach-peer!]
  (def sub (convex/subscribe! byte-client "demo:state" @{"room" "bytes"}))
  (next-server-message! byte-client 3000)
  (next-server-message! byte-client 3000)
  (def filler (string/repeat "x" 800000))
  (var index 0)
  (while (< index 6)
    (put cursor :tick (+ 1 (get cursor :tick)))
    (def finish (version 1 (timestamp-for (get cursor :tick))))
    (def frame
      (fixture/server-frame
        0x1
        (json/encode {"type" "Transition"
                      "startVersion" (get cursor :remote)
                      "endVersion" finish
                      "modifications" [{"type" "QueryUpdated"
                                        "queryId" (get sub :query-id)
                                        "value" {"count" index "filler" filler}}]})))
    (put cursor :remote finish)
    # Interleave writing with stepping, because nobody else is draining the
    # socket while this test writes several megabytes into it.
    (var offset 0)
    (def deadline (http/deadline-in 10000))
    (while (and (< offset (length frame)) (> (http/remaining-ms deadline) 0))
      (set offset (+ offset (transport/write (get (get peer-state :peer) :conn)
                                             frame offset 5)))
      (convex/step! byte-client 1))
    (pump-until! byte-client (fn [] false) 300)
    (set index (+ index 1)))
  (pump-until! byte-client (fn [] false) 500)
  (check/check (<= (get (convex/live-status byte-client) :queued-bytes)
                   convex/max-update-bytes)
               (string "the aggregate byte budget holds, at "
                       (get (convex/live-status byte-client) :queued-bytes) " bytes"))
  (check/check (< (length (get sub :updates)) 6)
               "the byte budget dropped older values before the count budget could")
  (def newest (get (get sub :updates) (- (length (get sub :updates)) 1)))
  (check/check= (get-in newest [:payload :value "count"]) 5
                "the newest large value survives the byte budget")
  (convex/close! byte-client))

(reset-peers!)
(check/report "janet live")
