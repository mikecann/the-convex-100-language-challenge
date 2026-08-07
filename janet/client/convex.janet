# A Convex client for Janet.
#
# This is the public library. It calls Convex functions over the documented
# JSON HTTP API and keeps queries current over the repository's pinned
# `/api/sync` WebSocket profile. Everything Convex-specific lives here: request
# envelopes, error classification, the sync handshake, query-set versioning,
# transition application, reconnect replay, and delivery bounds.
#
# ## The one-owner rule
#
# Live has exactly one owner: `step!`. Nothing else opens, reads, writes,
# retires, or reconnects the socket, and nothing else changes a query-set
# version. `subscribe!` and `unsubscribe!` record intent and queue a command;
# the owner performs the socket work on its next step. Janet's fibers make it
# tempting to let a subscription poll its own socket, and that is exactly the
# design that produces interleaved query-set versions and lost updates.
#
# `step!` is cooperative and non-blocking: it does a bounded amount of work and
# returns, so one thread can serve a controller and a Live socket at once
# without threads, locks, or an event loop.
#
# ## Delivery buffering
#
# The client owns the update queue, so it is bounded twice: at most 16 updates
# per subscription, and at most 4 MiB of encoded update payload across all
# subscriptions. A reactive query represents current state, so when a consumer
# falls behind the oldest value is dropped rather than the newest — and rather
# than letting a slow reader grow the process without limit.
#
# ## Why `transport` is imported by name
#
# Janet caches a module under the path it was imported by. The native transport
# is imported as a bare name from every file that needs it, so all of them share
# one loaded module: two copies would register two distinct abstract types, and
# a connection opened through one would be unrecognisable to the other. That
# means JANET_PATH has to point at this `client/` directory, which every image
# in this language's Dockerfile sets.

(import ./codec :as codec)
(import ./errors :as fail)
(import ./http :as http)
(import ./json :as json)
(import transport :as transport)
(import ./websocket :as ws)

(def client-version
  "The value sent in the Convex-Client header."
  "janet-0.1.0")

(def sync-profile
  "The inspected upstream profile this client targets."
  "convex-rs-0.10.4-unversioned-sync")

(def max-request-bytes (* 2 1024 1024))
(def max-subscriptions 64)
(def max-updates-per-subscription 16)
(def max-update-bytes (* 4 1024 1024))
(def http-timeout-ms 30000)
(def connect-timeout-ms 10000)
(def write-timeout-ms 5000)
(def server-inactivity-ms 30000)
(def initial-backoff-ms 100)
(def maximum-backoff-ms 15000)
# A transport failure is normally invisible: the owner reconnects and the
# subscription carries on. Only a persistently broken transport is worth
# telling a subscriber about, so this is how many consecutive failed attempts
# it takes before one structured TransportError is published.
(def transport-failure-threshold 3)

(def- initial-timestamp "AAAAAAAAAAA=")

(defn- shift!
  "Remove and return the first element. `array/pop` takes the last one."
  [items]
  (def item (get items 0))
  (array/remove items 0)
  item)

(defn- object? [value]
  (and (dictionary? value) (not (json/null? value))))

(defn- nonempty-string? [value]
  (and (string? value) (> (length value) 0) (codec/utf8-valid? value)))

(defn- valid-logs? [logs]
  (or (nil? logs)
      (and (indexed? logs) (all string? logs))))

(defn- log-lines [source]
  (def logs (get source "logLines"))
  (unless (valid-logs? logs) (fail/protocol "Convex response has invalid logLines"))
  (if (indexed? logs) (array/slice logs) @[]))

(defn- normalize-token
  "An empty token clears authentication; anything else must be header safe."
  [token]
  (if (or (nil? token) (= token ""))
    nil
    (do
      (unless (http/valid-header-value? token)
        (fail/protocol "auth token must be single-line UTF-8 text"))
      token)))

(defn new-client
  "Create a client for a Convex deployment URL.

  Nothing connects yet: HTTP calls open a connection each time, and Live opens
  one the first time a subscription needs it."
  [url &opt token]
  (def parts (http/parse-url url))
  @{:url-parts parts
    :token (normalize-token token)
    :version client-version
    :closed false
    :live
    @{:socket nil
      :socket-generation 0
      :subscriptions @{}
      :commands @[]
      :next-query-id 0
      # The local query-set version, which only the owner may advance.
      :query-set 0
      # The server's view, which every Transition must start from exactly.
      :remote-query-set 0
      :remote-identity 0
      :remote-ts initial-timestamp
      :max-observed-ts nil
      :connection-count 0
      :last-close-reason "InitialConnect"
      :last-server-response 0
      :next-connect-at 0
      :backoff-ms initial-backoff-ms
      :consecutive-failures 0
      :announced-failure false
      :queued-bytes 0
      :closed false}})

(defn json-null?
  "Is this decoded Convex value JSON null rather than an absent key?"
  [value]
  (json/null? value))

(defn random-hex
  "`count` cryptographically random bytes as lowercase hexadecimal text.

  Convex idempotency keys need to be unguessable and unique; this keeps that
  generation inside the client instead of shelling out to another program."
  [count]
  (codec/hex-encode (transport/random count)))

(defn describe-failure
  "A printable message for anything this client raised."
  [problem]
  (if (fail/client-error? problem)
    (string (fail/name-of problem) ": " (fail/message-of problem))
    (fail/message-of problem)))

(defn set-auth!
  "Replace the bearer token used by later HTTP calls. Live auth is deferred."
  [client token]
  (when (get client :closed) (fail/protocol "client is closed"))
  (put client :token (normalize-token token))
  client)

#
# HTTP
#

(defn- request-headers [client]
  (def headers @[["Content-Type" "application/json"]
                 ["Accept" "application/json"]
                 ["Convex-Client" (get client :version)]])
  (def token (get client :token))
  (when token (array/push headers ["Authorization" (string "Bearer " token)]))
  headers)

(defn classify-envelope
  "Turn one HTTP status and body into a result or a structured error.

  Convex reports a failed function with an `error` envelope, and does so under
  a non-2xx status such as 560. Status and envelope are therefore classified
  independently: a function failure must not be flattened into a transport
  failure, and a transport failure must never be mistaken for a value."
  [status body]
  (def ok? (and (>= status 200) (< status 300)))
  (var decoded nil)
  (var decode-problem nil)
  (try (set decoded (json/decode-object body "HTTP response"))
       ([problem] (set decode-problem problem)))
  (when decode-problem
    (if ok?
      (fail/rethrow decode-problem)
      (fail/transport (string "HTTP " status " did not return a Convex envelope"))))
  (def state (get decoded "status"))
  (cond
    (= state "success")
    (do
      (unless ok?
        (fail/transport (string "HTTP " status " returned a success-shaped envelope")))
      (unless (has-key? decoded "value")
        (fail/protocol "Convex success envelope omitted its value"))
      {:value (get decoded "value") :logs (log-lines decoded)})

    (= state "error")
    (do
      (def message (get decoded "errorMessage"))
      (unless (nonempty-string? message)
        (fail/protocol "Convex error envelope omitted errorMessage"))
      (fail/function message (get decoded "errorData") (log-lines decoded)))

    (if ok?
      (fail/protocol "Convex response has an unknown status")
      (fail/transport (string "HTTP " status " did not return a Convex envelope")))))

(defn- call [client operation path args]
  (when (get client :closed) (fail/protocol "client is closed"))
  (unless (nonempty-string? path) (fail/protocol "a Convex function path is required"))
  (unless (object? args) (fail/protocol "Convex arguments must be a named object"))
  (def body (json/encode {"path" path "args" args "format" "json"}))
  (when (> (length body) max-request-bytes)
    (fail/protocol "Convex request exceeds the 2 MiB limit"))
  (def response (http/post-json (get client :url-parts)
                                (string "/api/" operation)
                                (request-headers client)
                                body
                                http-timeout-ms))
  (classify-envelope (get response :status) (get response :body)))

(defn query
  "Call a public Convex query over HTTP. Returns {:value v :logs [...]}."
  [client path args]
  (call client "query" path args))

(defn mutation
  "Call a public Convex mutation over HTTP."
  [client path args]
  (call client "mutation" path args))

(defn action
  "Call a public Convex action over HTTP."
  [client path args]
  (call client "action" path args))

#
# Live: subscription intent
#

(defn- live-of [client] (get client :live))

(defn- active-subscriptions [live]
  (def ids (sort (keys (get live :subscriptions))))
  (filter (fn [id] (get (get (get live :subscriptions) id) :active)) ids))

(defn- release-queued! [client subscription]
  (def live (live-of client))
  (put live :queued-bytes (- (get live :queued-bytes) (get subscription :queued-bytes)))
  (put subscription :queued-bytes 0)
  (array/clear (get subscription :updates)))

(defn subscribe!
  "Register a Live query and return its subscription handle.

  This never touches the socket. It records the query and queues an Add for the
  owner, so a caller can subscribe before Live has ever connected."
  [client path args]
  (when (get client :closed) (fail/protocol "client is closed"))
  (unless (nonempty-string? path) (fail/protocol "a Convex function path is required"))
  (unless (object? args) (fail/protocol "Convex arguments must be a named object"))
  (def live (live-of client))
  (when (>= (length (active-subscriptions live)) max-subscriptions)
    (fail/protocol "this client already holds the maximum number of subscriptions"))
  (def query-id (get live :next-query-id))
  (put live :next-query-id (+ query-id 1))
  (def subscription
    @{:query-id query-id
      :path path
      :args args
      :active true
      # Bumped whenever this subscription stops being the one a caller asked
      # for. Every queued update carries the generation it was created under,
      # so an update that was already dequeued can still be recognised as stale.
      :generation 0
      :add-pending true
      :awaiting-rehydration false
      :last-value nil
      :has-last false
      :last-succeeded false
      :updates @[]
      :queued-bytes 0})
  (put (get live :subscriptions) query-id subscription)
  (array/push (get live :commands) {:kind :add :query-id query-id})
  subscription)

(defn unsubscribe!
  "Stop a Live query.

  Invalidation is immediate and synchronous: the generation moves and the queue
  is dropped before this returns. An update a relay already dequeued therefore
  cannot cross the acknowledgement that follows. Sending the Remove is the
  owner's job and happens on its next step."
  [client subscription]
  (def live (live-of client))
  (when (get subscription :active)
    (put subscription :active false)
    (put subscription :generation (+ 1 (get subscription :generation)))
    (put subscription :awaiting-rehydration false)
    (put subscription :has-last false)
    (put subscription :last-value nil)
    (release-queued! client subscription)
    (array/push (get live :commands) {:kind :remove :query-id (get subscription :query-id)}))
  true)

(defn subscription-current?
  "Is `update` still the update the caller asked for?

  A relay that dequeues an update and is then paused must ask this before
  publishing, because an unsubscribe or a same-id replacement may have happened
  in between."
  [subscription update]
  (and (get subscription :active)
       (= (get subscription :generation) (get update :generation))))

#
# Live: bounded delivery
#

# Drop the oldest queued update held by any subscription. Returns true when one
# was dropped, false when every queue was already empty.
(defn- drop-oldest! [client]
  (def live (live-of client))
  (var dropped false)
  (each id (sort (keys (get live :subscriptions)))
    (def subscription (get (get live :subscriptions) id))
    (when (and (not dropped) (> (length (get subscription :updates)) 0))
      (def entry (shift! (get subscription :updates)))
      (put subscription :queued-bytes (- (get subscription :queued-bytes) (get entry :bytes)))
      (put live :queued-bytes (- (get live :queued-bytes) (get entry :bytes)))
      (set dropped true)))
  dropped)

(defn- enqueue! [client subscription payload]
  (def live (live-of client))
  # Measure what the payload actually costs on the wire. A fixed allowance
  # covers the record itself so a flood of tiny updates is bounded too.
  (def measured (if (has-key? payload :value)
                  (length (json/encode (get payload :value)))
                  (length (json/encode (get payload :error)))))
  (def size (+ 256 measured))
  (while (>= (length (get subscription :updates)) max-updates-per-subscription)
    (def entry (shift! (get subscription :updates)))
    (put subscription :queued-bytes (- (get subscription :queued-bytes) (get entry :bytes)))
    (put live :queued-bytes (- (get live :queued-bytes) (get entry :bytes))))
  # One frame is capped at 2 MiB and the aggregate budget is 4 MiB, so evicting
  # older state always makes room for the newest value. This deliberately never
  # raises: it runs while a transition is being applied and while a protocol
  # error is being published, and a failure to make room must not become a
  # second failure on top of the one already being reported.
  (var room true)
  (while (and room (> (+ (get live :queued-bytes) size) max-update-bytes))
    (set room (drop-oldest! client)))
  (def stamped (merge payload {:generation (get subscription :generation)}))
  (array/push (get subscription :updates) {:bytes size :payload stamped})
  (put subscription :queued-bytes (+ (get subscription :queued-bytes) size))
  (put live :queued-bytes (+ (get live :queued-bytes) size)))

(defn poll-update!
  "Dequeue one pending update, or nil. Never blocks and never reads the socket."
  [client subscription]
  (when (> (length (get subscription :updates)) 0)
    (def live (live-of client))
    (def entry (shift! (get subscription :updates)))
    (put subscription :queued-bytes (- (get subscription :queued-bytes) (get entry :bytes)))
    (put live :queued-bytes (- (get live :queued-bytes) (get entry :bytes)))
    (get entry :payload)))

#
# Live: the owner
#

(defn- publish-error! [client structured]
  (def live (live-of client))
  (each id (active-subscriptions live)
    (def subscription (get (get live :subscriptions) id))
    (enqueue! client subscription {:error structured :logs @[]})
    (put subscription :has-last false)
    (put subscription :last-value nil)
    (put subscription :last-succeeded false)))

(defn- retire-socket!
  "Close the current socket, reset per-connection state, and schedule a retry.

  Only the owner calls this. Resetting the query-set and remote versions here
  is what makes the next connection's `baseVersion 0` correct."
  [client reason &opt schedule?]
  (def live (live-of client))
  (when (get live :socket)
    # No closing handshake here on purpose. Retirement models a connection that
    # failed or was deliberately dropped, and waiting for a polite exchange with
    # a peer that may be gone is exactly the unbounded wait to avoid.
    (ws/close-socket! (get live :socket))
    (put live :connection-count (+ 1 (get live :connection-count))))
  (put live :socket nil)
  (put live :last-close-reason reason)
  (put live :query-set 0)
  (put live :remote-query-set 0)
  (put live :remote-identity 0)
  (put live :remote-ts initial-timestamp)
  (each id (active-subscriptions live)
    (put (get (get live :subscriptions) id) :add-pending true))
  (when (or (nil? schedule?) schedule?)
    (put live :next-connect-at (+ (http/now-ms) (get live :backoff-ms)))
    (put live :backoff-ms (min maximum-backoff-ms (* 2 (get live :backoff-ms))))))

(defn- session-id []
  # Convex identifies a logical client session with a version-4 UUID. It is
  # generated here rather than shelled out to a CLI or another runtime.
  (def raw (buffer (transport/random 16)))
  (put raw 6 (+ 0x40 (mod (get raw 6) 16)))
  (put raw 8 (+ 0x80 (mod (get raw 8) 64)))
  (def hex (codec/hex-encode raw))
  (string (string/slice hex 0 8) "-"
          (string/slice hex 8 12) "-"
          (string/slice hex 12 16) "-"
          (string/slice hex 16 20) "-"
          (string/slice hex 20 32)))

(defn- send-message! [client message]
  (def live (live-of client))
  (unless (get live :socket) (fail/transport "Live socket is not connected"))
  (ws/send-text! (get live :socket) (json/encode message) write-timeout-ms))

(defn- add-modification [subscription]
  {"type" "Add"
   "queryId" (get subscription :query-id)
   "udfPath" (get subscription :path)
   # The pinned profile carries exactly one JSON argument object in an array.
   "args" @[(get subscription :args)]})

(defn live-url
  "The `/api/sync` endpoint derived from the deployment URL."
  [client]
  (def parts (get client :url-parts))
  (string (if (get parts :tls) "wss://" "ws://")
          (get parts :authority)
          (get parts :path)))

(def live-socket-dynamic
  "Dynamic binding a test may set to supply an already-open Live socket.

  This is the one test seam in the client. It is inert by default, holds no
  state, and exists so language-local tests can drive a real RFC 6455 peer over
  a loopback connection they own both ends of. Nothing in the shipped code path
  ever sets it."
  :convex/test-live-socket)

(defn- open-live-socket [client]
  (def factory (dyn live-socket-dynamic))
  (if factory
    (factory client)
    (ws/connect (live-url client)
                @[["Convex-Client" (get client :version)]]
                connect-timeout-ms)))

(defn- connect! [client]
  (def live (live-of client))
  (def socket (open-live-socket client))
  (put live :socket socket)
  (put live :socket-generation (+ 1 (get live :socket-generation)))
  (put live :query-set 0)
  (put live :remote-query-set 0)
  (put live :remote-identity 0)
  (put live :remote-ts initial-timestamp)
  (put live :last-server-response (http/now-ms))

  (def connect-message
    @{"type" "Connect"
      "sessionId" (session-id)
      "connectionCount" (get live :connection-count)
      "lastCloseReason" (get live :last-close-reason)
      "clientTs" 0})
  # The field is omitted rather than sent as null before any transition, which
  # is what the pinned profile does.
  (when (get live :max-observed-ts)
    (put connect-message "maxObservedTimestamp" (get live :max-observed-ts)))
  (send-message! client connect-message)

  # Replay every active query in one ModifyQuerySet, in numeric order, so the
  # version sequence after a reconnect is identical every time.
  (def ids (active-subscriptions live))
  (def modifications @[])
  (each id ids
    (def subscription (get (get live :subscriptions) id))
    # A subscription that already delivered a value expects the same value
    # back on reconnect; that rehydration is suppressed rather than replayed.
    (when (and (get subscription :has-last) (get subscription :last-succeeded))
      (put subscription :awaiting-rehydration true))
    (put subscription :add-pending false)
    (array/push modifications (add-modification subscription)))
  (when (> (length modifications) 0)
    (send-message! client
                   {"type" "ModifyQuerySet"
                    "baseVersion" 0
                    "newVersion" 1
                    "modifications" modifications})
    (put live :query-set 1))
  # A completed handshake is healthy transport evidence, so a later blip does
  # not inherit the previous maximum delay.
  (put live :backoff-ms initial-backoff-ms)
  (put live :consecutive-failures 0)
  (put live :announced-failure false)
  socket)

(defn- note-connect-failure! [client reason]
  (def live (live-of client))
  (put live :last-close-reason reason)
  (put live :connection-count (+ 1 (get live :connection-count)))
  (put live :consecutive-failures (+ 1 (get live :consecutive-failures)))
  (put live :next-connect-at (+ (http/now-ms) (get live :backoff-ms)))
  (put live :backoff-ms (min maximum-backoff-ms (* 2 (get live :backoff-ms))))
  # Keep quiet about a blip, but do not hide a transport that stays broken.
  (when (and (>= (get live :consecutive-failures) transport-failure-threshold)
             (not (get live :announced-failure)))
    (put live :announced-failure true)
    (publish-error! client (fail/make "TransportError" reason))))

(defn- ensure-socket! [client]
  (def live (live-of client))
  (when (and (nil? (get live :socket))
             (not (get live :closed))
             (> (length (active-subscriptions live)) 0)
             (>= (http/now-ms) (get live :next-connect-at)))
    (try (connect! client)
         ([problem]
          (when (get live :socket)
            (ws/close-socket! (get live :socket))
            (put live :socket nil))
          (note-connect-failure! client (fail/message-of problem))))))

(defn- run-command! [client command]
  (def live (live-of client))
  (def subscription (get (get live :subscriptions) (get command :query-id)))
  (case (get command :kind)
    :add
    (when (and subscription
               (get subscription :active)
               (get subscription :add-pending)
               (get live :socket))
      (send-message! client
                     {"type" "ModifyQuerySet"
                      "baseVersion" (get live :query-set)
                      "newVersion" (+ 1 (get live :query-set))
                      "modifications" @[(add-modification subscription)]})
      (put live :query-set (+ 1 (get live :query-set)))
      (put subscription :add-pending false))

    :remove
    (do
      (when (and subscription (get live :socket))
        (send-message! client
                       {"type" "ModifyQuerySet"
                        "baseVersion" (get live :query-set)
                        "newVersion" (+ 1 (get live :query-set))
                        "modifications" @[{"type" "Remove"
                                           "queryId" (get command :query-id)}]})
        (put live :query-set (+ 1 (get live :query-set))))
      (put (get live :subscriptions) (get command :query-id) nil))))

(defn- drain-commands! [client]
  (def live (live-of client))
  (var failure nil)
  (while (and (nil? failure) (> (length (get live :commands)) 0))
    (def command (shift! (get live :commands)))
    (try (run-command! client command)
         ([problem] (set failure problem))))
  (when failure
    # The socket is gone, but the intent is not: a queued Add is restored by
    # the reconnect replay, and a queued Remove already dropped its state.
    (retire-socket! client (fail/message-of failure))))

(defn- wire-counter? [value]
  # The profile's version counters are unsigned 32-bit integers, and Convex may
  # encode one as 1 or 1.0. Both are the same Janet number; a fraction is not.
  (and (number? value)
       (not (nan? value))
       (= value (math/floor value))
       (>= value 0)
       (<= value 4294967295)))

(defn- state-version? [version]
  (and (object? version)
       (wire-counter? (get version "querySet"))
       (wire-counter? (get version "identity"))
       (codec/valid-timestamp? (get version "ts"))))

(defn- apply-transition! [client message]
  (def live (live-of client))
  (def start (get message "startVersion"))
  (def finish (get message "endVersion"))
  (def modifications (get message "modifications"))
  (unless (and (state-version? start) (state-version? finish) (indexed? modifications))
    (fail/protocol "Transition is missing its versions or modifications"))
  (unless (and (= (get start "querySet") (get live :remote-query-set))
               (= (get start "identity") (get live :remote-identity))
               (= (get start "ts") (get live :remote-ts)))
    (fail/protocol "Transition does not start from the local sync version"))

  # Validate the whole transition before publishing any part of it. A partly
  # applied transition would leave subscribers holding state the server never
  # agreed to.
  (each modification modifications
    (unless (and (object? modification) (wire-counter? (get modification "queryId")))
      (fail/protocol "Transition modification is malformed"))
    (unless (valid-logs? (get modification "logLines"))
      (fail/protocol "Transition modification has invalid logLines"))
    (case (get modification "type")
      "QueryUpdated"
      (unless (has-key? modification "value")
        (fail/protocol "QueryUpdated omitted its value"))
      "QueryFailed"
      (unless (nonempty-string? (get modification "errorMessage"))
        (fail/protocol "QueryFailed omitted its errorMessage"))
      "QueryRemoved" nil
      (fail/protocol "Transition contains an unknown modification")))

  # Commit the version before delivering, so a subscriber that reacts inside
  # its own callback sees a consistent client.
  (put live :remote-query-set (get finish "querySet"))
  (put live :remote-identity (get finish "identity"))
  (put live :remote-ts (get finish "ts"))
  (when (or (nil? (get live :max-observed-ts))
            (> (codec/compare-timestamps (get finish "ts") (get live :max-observed-ts)) 0))
    (put live :max-observed-ts (get finish "ts")))

  (each modification modifications
    (def subscription (get (get live :subscriptions) (get modification "queryId")))
    (when (and subscription (get subscription :active))
      (case (get modification "type")
        "QueryUpdated"
        (do
          (def value (get modification "value"))
          (def unchanged (and (get subscription :has-last)
                              (get subscription :last-succeeded)
                              (deep= (get subscription :last-value) value)))
          (def rehydration (get subscription :awaiting-rehydration))
          (put subscription :awaiting-rehydration false)
          (put subscription :last-value value)
          (put subscription :has-last true)
          (put subscription :last-succeeded true)
          # After a reconnect the server resends the value the subscriber
          # already has. Publishing it again would make a disconnect visible as
          # a duplicate update, so only a genuine change is delivered.
          (unless (and rehydration unchanged)
            (enqueue! client subscription
                      {:value value :logs (log-lines modification)})))

        "QueryFailed"
        (do
          (put subscription :awaiting-rehydration false)
          (put subscription :last-value nil)
          (put subscription :has-last false)
          (put subscription :last-succeeded false)
          (enqueue! client subscription
                    {:error (fail/make "FunctionError"
                                       (get modification "errorMessage")
                                       (get modification "errorData"))
                     :logs (log-lines modification)}))

        "QueryRemoved"
        (do
          (put subscription :awaiting-rehydration false)
          (put subscription :last-value nil)
          (put subscription :has-last false)
          (put subscription :last-succeeded false)))))
  # A valid transition is also healthy transport evidence.
  (put live :backoff-ms initial-backoff-ms)
  (put live :consecutive-failures 0)
  (put live :announced-failure false))

(defn- handle-message! [client text]
  (def message (json/decode-object text "Live message"))
  (case (get message "type")
    "Transition" (apply-transition! client message)
    "Ping" nil
    # The pinned profile never sends mutations or actions over the socket, but
    # a server that answers one is not broken, only ahead of this client.
    "MutationResponse" nil
    "ActionResponse" nil
    "FatalError" (fail/protocol (string "Live server reported a fatal error: "
                                        (or (get message "error") "unknown")))
    "AuthError" (fail/protocol (string "Live server rejected authentication: "
                                       (or (get message "error") "unknown")))
    # Chunk assembly is outside the pinned profile. Treating a chunk as drift
    # and reconnecting is honest; guessing at the reassembly would not be.
    "TransitionChunk" (fail/protocol "TransitionChunk assembly is not implemented")
    (fail/protocol "Live server sent an unknown message type")))

(defn- pump-socket! [client budget-ms]
  (def live (live-of client))
  (def socket (get live :socket))
  (when socket
    (try
      (do
        (def event (ws/poll! socket budget-ms))
        (cond
          (nil? event)
          # Silence only counts while no partial frame is in flight; a partial
          # frame has its own, shorter, absolute deadline.
          (when (and (nil? (get socket :partial-since))
                     (> (- (http/now-ms) (get live :last-server-response))
                        server-inactivity-ms))
            (fail/transport "Live server passed the inactivity deadline"))

          (= (get event 0) :close)
          (do
            (put live :last-server-response (http/now-ms))
            (fail/transport (string "Live peer closed with status "
                                    (or (get event 1) "none"))))

          (do
            (put live :last-server-response (http/now-ms))
            (handle-message! client (get event 1)))))
      ([problem]
       # A protocol failure means the local view is no longer trustworthy, so
       # subscribers hear about it. A transport failure is handled by
       # reconnecting; the subscription stays alive and delivers again.
       (when (= "ProtocolError" (fail/name-of problem))
         (publish-error! client (fail/make "ProtocolError" (fail/message-of problem))))
       (retire-socket! client (fail/message-of problem))))))

(defn step!
  "Advance Live by a bounded amount of work. This is the only socket owner.

  `budget-ms` is how long the socket read may wait for bytes; zero polls."
  [client &opt budget-ms]
  (def live (live-of client))
  (unless (get live :closed)
    (ensure-socket! client)
    (drain-commands! client)
    (pump-socket! client (or budget-ms 0)))
  client)

(defn next-update!
  "Step until this subscription has an update or `timeout-ms` elapses."
  [client subscription timeout-ms]
  (def deadline (http/deadline-in timeout-ms))
  (var result (poll-update! client subscription))
  (while (and (nil? result)
              (get subscription :active)
              (> (http/remaining-ms deadline) 0))
    (step! client (min 25 (http/remaining-ms deadline)))
    (set result (poll-update! client subscription)))
  result)

(defn debug-disconnect!
  "Retire the current Live socket as if the network had dropped it.

  This exists only so a test can prove a real reconnect. It is deliberately
  absent from the documented client surface. Draining queued commands first
  keeps the owner's ordering intact, and the socket is retired and the retry
  scheduled before this returns, so a caller may acknowledge immediately
  without racing a stale read."
  [client]
  (def live (live-of client))
  (drain-commands! client)
  (unless (get live :socket)
    (fail/transport "there is no connected Live socket to disconnect"))
  (retire-socket! client "DebugDisconnect")
  true)

(defn live-status
  "Connection bookkeeping, exposed for tests and diagnostics."
  [client]
  (def live (live-of client))
  {:connection-count (get live :connection-count)
   :last-close-reason (get live :last-close-reason)
   :max-observed-timestamp (get live :max-observed-ts)
   :backoff-ms (get live :backoff-ms)
   :query-set (get live :query-set)
   :queued-bytes (get live :queued-bytes)
   :connected (not (nil? (get live :socket)))})

(defn close!
  "Close the client. Bounded even against a peer that never answers."
  [client]
  (def live (live-of client))
  (put client :closed true)
  (put live :closed true)
  (when (get live :socket)
    (ws/send-close! (get live :socket) 1000 250)
    (ws/close-socket! (get live :socket))
    (put live :socket nil))
  (each id (keys (get live :subscriptions))
    (def subscription (get (get live :subscriptions) id))
    (put subscription :active false)
    (put subscription :generation (+ 1 (get subscription :generation)))
    (release-queued! client subscription))
  (array/clear (get live :commands))
  (put live :queued-bytes 0)
  true)
