# Convex from Janet: the shared counter, start to finish.
#
# This program is the canonical example. It is what the README shows, what the
# website shows, and what the `example-runtime` image runs against a real
# deployment. It follows one room's counter from 0 to 1 and proves that the
# HTTP query, the mutation's own result, and the Live subscription all agree.
#
# The order matters. Live is started before the mutation, because a reactive
# subscription that begins after a change cannot prove it saw the change.

(import ../../client/convex :as convex)

(defn example-failed
  "Report on stderr and stop.

  Stdout is the shared happy-path transcript that every language in this
  repository must produce byte for byte, so nothing diagnostic may go there."
  [message]
  (flush)
  (eprint (string "Janet example failed: " message))
  (eflush)
  (os/exit 1))

(defn whole-count
  "Read a non-negative whole `count` out of a Convex value.

  Convex JSON may spell a whole number as `0` or as `0.0`, and both are the
  same number in Janet. What this has to reject is everything that is *not* a
  count: a fraction, a quoted number, a missing field, or a value so large it
  could not be a counter."
  [value label]
  (unless (and (dictionary? value) (not (convex/json-null? value)))
    (example-failed (string label " did not return an object")))
  (def count (get value "count"))
  (unless (and (number? count)
               (not (nan? count))
               (not= count math/inf)
               (not= count math/-inf)
               (= count (math/floor count))
               (>= count 0)
               (<= count 9007199254740992))
    (example-failed (string label " returned a value that is not a whole count")))
  count)

(defn run-id
  "A fresh idempotency key for the mutation.

  Convex uses this to make a retry safe: sending the same `runId` twice applies
  the increment once. It is generated from the local CSPRNG rather than by
  shelling out to another program."
  []
  (convex/random-hex 16))

(defn next-live-value
  "Wait for the subscription's next update and unwrap it.

  A Live update carries either a value or a structured error. Treating an error
  as data is the mistake this guard exists to prevent."
  [client subscription label]
  (def update (convex/next-update! client subscription 15000))
  (unless update (example-failed (string label " did not arrive in time")))
  (when (has-key? update :error)
    (example-failed (string label " failed: " (get-in update [:error :message]))))
  (get update :value))

(defn example-room
  "The room to use: the verifier's unique id, an environment override, or a default.

  Janet reports the script path alongside the arguments, so the first real
  argument is whatever follows the last `.janet` entry."
  []
  (def arguments (or (dyn :args) @[]))
  (var start 0)
  (var index 0)
  (while (< index (length arguments))
    (when (string/has-suffix? ".janet" (get arguments index))
      (set start (+ index 1)))
    (set index (+ index 1)))
  (or (get arguments start)
      (os/getenv "EXAMPLE_ROOM")
      "janet-basic-example"))

(defn run-example []
  # The deployment URL is supplied by the container that runs this image.
  (def deployment (os/getenv "CONVEX_URL"))
  (unless (and deployment (> (length deployment) 0))
    (example-failed "CONVEX_URL is required"))
  (def room (example-room))

  # One client serves both the HTTP calls and the Live subscription. Nothing
  # connects yet; the first call opens what it needs.
  (def client (convex/new-client deployment (os/getenv "CONVEX_AUTH_TOKEN")))
  (var subscription nil)
  (defer (do
           # Cleanup is bounded: unsubscribing is local state plus one queued
           # owner command, and closing never waits for the peer to answer.
           (when subscription (convex/unsubscribe! client subscription))
           (convex/close! client))

    # Read the room's current state through Convex's documented HTTP API.
    (def current (whole-count (get (convex/query client "demo:state" @{"room" room})
                                   :value)
                              "the initial query"))
    (unless (= current 0)
      (example-failed "this room was expected to be a fresh, empty counter"))
    (print (string/format "current count: %d" current))

    # Subscribe before changing anything. The Live socket opens on the next
    # client step, replays this query, and delivers the current value first.
    (set subscription (convex/subscribe! client "demo:state" @{"room" room}))
    (def initial (whole-count (next-live-value client subscription "the initial Live value")
                              "the initial Live value"))
    (unless (= initial current)
      (example-failed "the initial Live value disagreed with the HTTP query"))
    (print (string/format "live initial count: %d" initial))

    # Apply exactly one increment. `runId` is the idempotency key: replaying
    # this same mutation returns the previous result instead of counting twice.
    (def result (convex/mutation client "demo:increment"
                                 @{"room" room "language" "Janet" "runId" (run-id)}))
    (def applied (get-in result [:value "applied"]))
    (unless (= applied true)
      (example-failed "the mutation reported that it was not applied"))
    (def mutated (whole-count (get-in result [:value "state"]) "the mutation"))
    (unless (= mutated (+ current 1))
      (example-failed "the mutation did not move the counter by exactly one"))
    (print "mutation applied: true")
    (print (string/format "mutation count: %d" mutated))

    # The same change now has to arrive over Live, without polling HTTP again.
    (def updated (whole-count (next-live-value client subscription "the updated Live value")
                              "the updated Live value"))
    (unless (= updated mutated)
      (example-failed "the Live value disagreed with the mutation's own result"))
    (print (string/format "live updated count: %d" updated))

    # Only now, with HTTP, the mutation, and Live all agreeing, is the journey
    # proven. This final line is the shared cross-language transcript.
    (print (string/format "verified count: %d -> %d" current updated))
    (flush)))

(try
  (run-example)
  ([problem] (example-failed (convex/describe-failure problem))))
