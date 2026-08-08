# Test-only NDJSON adapter protocol v1 executable.
#
# This is conformance infrastructure, not part of the Janet client's public
# surface. The shared controller drives it either over stdin/stdout or over one
# TCP connection named by ADAPTER_LISTEN, and it must behave identically on
# both. Every operation calls the real client in ../../convex.janet; nothing
# here fakes a Convex result.
#
# ## Structure
#
# The adapter is a state machine with one bounded step rather than a blocking
# loop, for the same reason the client is: one thread has to serve a controller
# and a Live socket at the same time, and a blocking read of either one starves
# the other. `adapter-step!` does a slice of each and returns.
#
# ## One writer
#
# Every event — acknowledgement, result, error, relayed subscription value, and
# the final close — is appended to a single queue and written by a single
# writer in order. There is no second path to the output stream, so events can
# never interleave. The queue is bounded by count and by bytes, including the
# write currently in flight, so a controller that stops reading cannot make
# this process grow without limit.
#
# ## Staleness
#
# Relaying is split into a dequeue step and a publish step. The publish step
# re-checks that the update still belongs to the subscription the controller
# asked for, which is what makes an unsubscribe or a same-id replacement a real
# barrier: an update already taken off the queue still cannot cross it.

(import ../../convex :as convex)
(import ../../codec :as codec)
(import ../../errors :as fail)
(import ../../http :as http)
(import ../../json :as json)
(import transport :as transport)

(def protocol-version 1)
(def language-id "janet")

(def max-line-bytes
  "Largest single controller command."
  (* 2 1024 1024))

(def max-event-bytes
  "Largest single event this adapter will emit."
  (* 4 1024 1024))

(def max-output-bytes
  "Total queued output, including the write currently in flight."
  (* 4 1024 1024))

(def max-output-events
  "Largest number of queued events."
  16)

(def- read-slice-ms 5)
(def- step-slice-ms 5)
(def- write-slice-ms 5)

(defn runtime-version
  "Report the running Janet version.

  The dynamic binding is the runtime's own answer. JANET_VERSION is the version
  the image recorded when it built this interpreter from source, and exists so
  the reported value is never a guess on a runtime that publishes it elsewhere."
  []
  (string "Janet " (or (dyn :janet/version) (os/getenv "JANET_VERSION") "unknown")))

(defn implementation-string []
  (string "binding: Janet client over a local OpenSSL byte transport; "
          "HTTP/1.1, RFC 6455, JSON and the " convex/sync-profile
          " sync profile implemented in Janet"))

#
# Command validation
#

(defn valid-id?
  "Protocol ids are 1 to 128 code points of UTF-8, not 128 bytes."
  [value]
  (and (string? value)
       (let [points (codec/utf8-count value)]
         (and points (> points 0) (<= points 128)))))

(def- command-fields
  {"hello" ["protocolVersion" "id" "op"]
   "query" ["id" "op" "path" "args"]
   "mutation" ["id" "op" "path" "args"]
   "action" ["id" "op" "path" "args"]
   "subscribe" ["id" "op" "subscriptionId" "path" "args"]
   "unsubscribe" ["id" "op" "subscriptionId"]
   "setAuth" ["id" "op" "token"]
   "close" ["id" "op"]
   "debugDisconnect" ["id" "op"]})

(defn- call-shaped? [command]
  (and (string? (get command "path"))
       (>= (length (get command "path")) 3)
       (dictionary? (get command "args"))
       (not (json/null? (get command "args")))))

(defn strict-command
  "Validate one decoded command exactly, or raise a ProtocolError.

  Nothing is accepted loosely: an unknown operation, a missing field, an extra
  field, or a wrongly typed field is rejected before any client call happens."
  [command]
  (unless (and (dictionary? command) (not (json/null? command)))
    (fail/protocol "adapter command must be a JSON object"))
  (def operation (get command "op"))
  (unless (valid-id? (get command "id"))
    (fail/protocol "adapter command has a missing or invalid id"))
  (unless (string? operation) (fail/protocol "adapter command has no operation"))
  (def allowed (get command-fields operation))
  (unless allowed (fail/protocol "unknown adapter operation"))
  (unless (and (= (length command) (length allowed))
               (all (fn [key] (not (nil? (index-of key allowed)))) (keys command)))
    (fail/protocol "adapter command has missing or additional fields"))
  (case operation
    "hello"
    (unless (= protocol-version (get command "protocolVersion"))
      (fail/protocol "unsupported adapter protocol version"))

    "query" (unless (call-shaped? command) (fail/protocol "invalid query command"))
    "mutation" (unless (call-shaped? command) (fail/protocol "invalid mutation command"))
    "action" (unless (call-shaped? command) (fail/protocol "invalid action command"))

    "subscribe"
    (unless (and (valid-id? (get command "subscriptionId")) (call-shaped? command))
      (fail/protocol "invalid subscribe command"))

    "unsubscribe"
    (unless (valid-id? (get command "subscriptionId"))
      (fail/protocol "invalid unsubscribe command"))

    "setAuth"
    (unless (string? (get command "token"))
      (fail/protocol "invalid setAuth command"))

    nil)
  command)

#
# Events
#

(defn error-object
  "The `error` member of an event: name, message, and data when it exists.

  `logs` is deliberately not folded in here; it is a sibling of `error` in the
  protocol, and duplicating it would make two sources of truth."
  [problem]
  (def out @{"name" (fail/name-of problem) "message" (fail/message-of problem)})
  (when (and (dictionary? problem) (has-key? problem :data))
    (put out "data" (get problem :data)))
  out)

(defn error-event [id problem]
  (def event @{"type" "error" "error" (error-object problem)})
  # An absent id is absent, never null: the shared schema constrains the type
  # of `id` whenever the key is present at all.
  (when id (put event "id" id))
  (when (and (dictionary? problem) (indexed? (get problem :logs)))
    (put event "logs" (get problem :logs)))
  event)

#
# Bounded, ordered output
#

(defn adapter-new
  "Create adapter state around one already-connected control stream."
  [control]
  @{:control control
    :inbuf (buffer/new 4096)
    :outbuf @[]
    :out-bytes 0
    :in-flight nil
    :in-flight-offset 0
    :client nil
    :subscriptions @{}
    :running true
    :dropped 0
    :failure nil})

(defn- drop-one-droppable!
  "Free room by discarding the oldest event that may be coalesced.

  A subscription value is droppable because it describes current state and a
  newer one is on the way. Acknowledgements, results, errors and the close
  event are not: losing one would silently desynchronize the controller."
  [state subscription-id]
  (def queue (get state :outbuf))
  # Prefer an older value for the same subscription, so pressure coalesces a
  # single busy query rather than starving the others.
  (var index (find-index (fn [entry]
                           (and (get entry :droppable)
                                (= subscription-id (get entry :subscription))))
                         queue))
  (when (nil? index)
    (set index (find-index (fn [entry] (get entry :droppable)) queue)))
  (when index
    (def entry (get queue index))
    (array/remove queue index)
    (put state :out-bytes (- (get state :out-bytes) (length (get entry :text))))
    (put state :dropped (+ 1 (get state :dropped)))
    true))

(defn enqueue-event!
  "Queue one event for the single writer.

  Returns true when the event was accepted. A droppable event may be refused
  under pressure; a mandatory event that cannot fit fails the connection,
  because pretending to have sent it would be worse."
  [state event &opt droppable subscription-id]
  (def text (string (json/encode event) "\n"))
  (def queue (get state :outbuf))
  (cond
    (> (length text) max-event-bytes)
    (if droppable
      (do (put state :dropped (+ 1 (get state :dropped))) false)
      (do (put state :failure "an adapter event exceeded the output size limit")
          (put state :running false)
          false))

    (do
      (var room true)
      (while (and room
                  (or (>= (length queue) max-output-events)
                      (> (+ (get state :out-bytes) (length text)) max-output-bytes)))
        (set room (drop-one-droppable! state subscription-id)))
      (cond
        room
        (do
          (array/push queue @{:text text
                              :droppable droppable
                              :subscription subscription-id})
          (put state :out-bytes (+ (get state :out-bytes) (length text)))
          true)

        droppable
        (do (put state :dropped (+ 1 (get state :dropped))) false)

        (do
          (put state :failure
               "the controller stopped reading and the output queue is full")
          (put state :running false)
          false)))))

(defn flush-output!
  "Write as much of the head of the queue as the stream will take right now."
  [state &opt slice-ms]
  (when (and (nil? (get state :in-flight)) (> (length (get state :outbuf)) 0))
    (def entry (get (get state :outbuf) 0))
    (array/remove (get state :outbuf) 0)
    (put state :in-flight (get entry :text))
    (put state :in-flight-offset 0))
  (when (get state :in-flight)
    (def text (get state :in-flight))
    (def written (transport/write (get state :control)
                                  text
                                  (get state :in-flight-offset)
                                  (or slice-ms write-slice-ms)))
    (put state :in-flight-offset (+ (get state :in-flight-offset) written))
    (when (>= (get state :in-flight-offset) (length text))
      # The in-flight write stays inside the byte budget until it completes,
      # which is what makes a stopped reader bounded rather than merely slow.
      (put state :out-bytes (- (get state :out-bytes) (length text)))
      (put state :in-flight nil)
      (put state :in-flight-offset 0)))
  state)

(defn pending-output?
  [state]
  (or (get state :in-flight) (> (length (get state :outbuf)) 0)))

(defn drain-output!
  "Flush the queue, giving up at an absolute deadline."
  [state timeout-ms]
  (def deadline (http/deadline-in timeout-ms))
  (while (and (pending-output? state) (> (http/remaining-ms deadline) 0))
    (try (flush-output! state (min 50 (http/remaining-ms deadline)))
         ([_] (break))))
  state)

#
# Commands
#

(defn- ensure-client [state]
  (unless (get state :client)
    (def url (os/getenv "CONVEX_URL"))
    (unless (and url (> (length url) 0))
      (fail/protocol "CONVEX_URL is required"))
    (put state :client (convex/new-client url (os/getenv "CONVEX_AUTH_TOKEN"))))
  (get state :client))

(defn- result-event [id result]
  @{"type" "result" "id" id "value" (get result :value) "logs" (get result :logs)})

(defn- run-command! [state command]
  (def id (get command "id"))
  (case (get command "op")
    "hello"
    (enqueue-event! state @{"type" "ready"
                            "id" id
                            "protocolVersion" protocol-version
                            "language" language-id
                            "implementation" (implementation-string)
                            "runtime" (runtime-version)})

    "setAuth"
    (do
      (convex/set-auth! (ensure-client state) (get command "token"))
      (enqueue-event! state @{"type" "ack" "id" id}))

    "query"
    (enqueue-event! state (result-event id (convex/query (ensure-client state)
                                                         (get command "path")
                                                         (get command "args"))))

    "mutation"
    (enqueue-event! state (result-event id (convex/mutation (ensure-client state)
                                                            (get command "path")
                                                            (get command "args"))))

    "action"
    (enqueue-event! state (result-event id (convex/action (ensure-client state)
                                                          (get command "path")
                                                          (get command "args"))))

    "subscribe"
    (do
      (def subscription-id (get command "subscriptionId"))
      (def client (ensure-client state))
      (def existing (get (get state :subscriptions) subscription-id))
      # Replacing an id invalidates the previous subscription first, so its
      # already-dequeued updates cannot be published after this acknowledgement.
      (when existing (convex/unsubscribe! client existing))
      (put (get state :subscriptions) subscription-id
           (convex/subscribe! client (get command "path") (get command "args")))
      (enqueue-event! state @{"type" "ack" "id" id}))

    "unsubscribe"
    (do
      (def subscription-id (get command "subscriptionId"))
      (def existing (get (get state :subscriptions) subscription-id))
      (when existing
        (convex/unsubscribe! (ensure-client state) existing)
        (put (get state :subscriptions) subscription-id nil))
      (enqueue-event! state @{"type" "ack" "id" id}))

    "debugDisconnect"
    (do
      (convex/debug-disconnect! (ensure-client state))
      (enqueue-event! state @{"type" "ack" "id" id}))

    "close"
    (do
      (when (get state :client) (convex/close! (get state :client)))
      (each key (keys (get state :subscriptions))
        (put (get state :subscriptions) key nil))
      (enqueue-event! state @{"type" "closed" "id" id})
      (put state :running false))))

(defn process-line!
  "Decode, validate, and run one controller line, reporting any failure."
  [state line]
  # Recover the id before validation so a rejected command can still be
  # correlated by the controller that sent it.
  (def preview (try (json/decode line) ([_] nil)))
  (def safe-id (when (and (dictionary? preview) (valid-id? (get preview "id")))
                 (get preview "id")))
  (try
    (run-command! state (strict-command (json/decode-object line "adapter command")))
    ([problem] (enqueue-event! state (error-event safe-id problem))))
  state)

#
# Subscription relay
#

(defn relay-dequeue!
  "Take one pending update off any registered subscription.

  Returns [subscription-id subscription update] or nil. Splitting this from
  publication is what lets a test pause a relay mid-flight."
  [state]
  (def client (get state :client))
  (var found nil)
  (when client
    (each subscription-id (sort (keys (get state :subscriptions)) compare<)
      (when (nil? found)
        (def subscription (get (get state :subscriptions) subscription-id))
        (def update (convex/poll-update! client subscription))
        (when update (set found [subscription-id subscription update])))))
  found)

(defn relay-publish!
  "Publish a dequeued update, unless it stopped being current in the meantime."
  [state subscription-id subscription update]
  (def registered (get (get state :subscriptions) subscription-id))
  (if (or (not= registered subscription)
          (not (convex/subscription-current? subscription update)))
    false
    (do
      (def event @{"type" "subscription" "subscriptionId" subscription-id})
      (if (has-key? update :error)
        (put event "error" (error-object (get update :error)))
        (put event "value" (get update :value)))
      (when (indexed? (get update :logs)) (put event "logs" (get update :logs)))
      # Only a value may be coalesced under pressure. A subscription error is
      # the reason a controller would stop trusting the stream, so it is kept.
      (enqueue-event! state event (not (has-key? update :error)) subscription-id))))

(defn relay-once! [state]
  (def taken (relay-dequeue! state))
  (when taken
    (relay-publish! state (get taken 0) (get taken 1) (get taken 2))
    true))

(def- max-relays-per-step 8)

(defn relay-pending!
  "Relay a bounded number of updates so one busy query cannot starve a step."
  [state]
  (var count 0)
  (while (and (< count max-relays-per-step) (relay-once! state))
    (set count (+ count 1)))
  count)

#
# Reading and stepping
#

(defn- take-line! [state]
  (def buffer (get state :inbuf))
  (def newline (string/find "\n" buffer))
  (if newline
    (do
      (def line (string (buffer/slice buffer 0 newline)))
      (def rest (buffer/slice buffer (+ newline 1)))
      (buffer/clear buffer)
      (buffer/push-string buffer rest)
      # A controller that ends lines with CRLF is still speaking NDJSON.
      (string/trimr line "\r"))
    (do
      (when (> (length buffer) max-line-bytes)
        (put state :failure "a controller command exceeded the 2 MiB line limit")
        (put state :running false))
      nil)))

(def- max-writes-per-step 16)

(defn- flush-some!
  "Write until the stream stops accepting bytes or the slice budget is spent."
  [state]
  (var attempts 0)
  (var progressing true)
  (while (and progressing (< attempts max-writes-per-step) (pending-output? state))
    (def before (get state :in-flight-offset))
    (def queued (length (get state :outbuf)))
    (flush-output! state)
    (set progressing (or (not= before (get state :in-flight-offset))
                         (not= queued (length (get state :outbuf)))))
    (set attempts (+ attempts 1)))
  state)

(defn- step-once! [state]
  (flush-some! state)
  (when (get state :running)
    (def buffer (get state :inbuf))
    (def got (transport/read (get state :control) buffer 65536 read-slice-ms))
    # End of stream is a clean end of session, but only once every command that
    # already arrived has been answered. A controller that writes its whole
    # script and closes immediately — which is exactly what a shell pipeline
    # does — must still get every reply.
    (when (and (nil? got) (nil? (string/find "\n" buffer)))
      (put state :running false))
    (def line (take-line! state))
    (when line (process-line! state line)))
  (when (and (get state :running) (get state :client))
    (convex/step! (get state :client) step-slice-ms)
    (relay-pending! state)))

(defn adapter-step!
  "Do one bounded slice of adapter work. Returns true while the adapter runs.

  A failure of the control stream itself — the controller vanishing mid-write,
  for instance — ends the session with a recorded reason rather than killing
  the process, so the exit is still something a controller can interpret."
  [state]
  (try
    (step-once! state)
    ([problem]
     (put state :failure (fail/message-of problem))
     (put state :running false)))
  (get state :running))

(defn adapter-run!
  "Run until the controller closes or sends `close`, then flush and report."
  [state]
  (while (adapter-step! state) nil)
  (drain-output! state 2000)
  (when (get state :client) (convex/close! (get state :client)))
  (when (get state :failure)
    (eprint (string "janet adapter stopped: " (get state :failure))))
  (not (get state :failure)))

#
# Entry point
#

(defn parse-listen-address
  "Split ADAPTER_LISTEN into a host and port, allowing IPv6 literals."
  [value]
  (def separator (last (string/find-all ":" value)))
  (unless separator (fail/protocol "ADAPTER_LISTEN must be host:port"))
  (def host (string/slice value 0 separator))
  (def port (scan-number (string/slice value (+ 1 separator))))
  (unless (and (> (length host) 0)
               (number? port)
               (= port (math/floor port))
               (> port 0)
               (< port 65536))
    (fail/protocol "ADAPTER_LISTEN has an invalid host or port"))
  [host port])

(defn open-control-stream
  "Accept the controller connection, or borrow stdin and stdout."
  []
  (def address (os/getenv "ADAPTER_LISTEN"))
  (if (nil? address)
    (transport/stdio)
    (do
      (def [host port] (parse-listen-address address))
      (def listener (transport/listen host port))
      (defer (transport/close listener)
        (def control (transport/accept listener 60000))
        (unless control (fail/transport "no controller connected within 60 seconds"))
        control))))

(defn main-entry []
  (def control (open-control-stream))
  (def state (adapter-new control))
  (def ok (adapter-run! state))
  (transport/close control)
  (os/exit (if ok 0 1)))

# Importing this file for a unit test must not start a session.
(when (nil? (os/getenv "ADAPTER_LIBRARY_ONLY"))
  (main-entry))
