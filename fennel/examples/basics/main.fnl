#!/usr/local/bin/fennel
;; This canonical example demonstrates one complete Convex HTTP and Live journey.
(local Convex (require :convex))
(local Integer (require :integer))

(fn checked [result err]
  (if result result
      (error (.. (or (and err err.name) :Error) ": "
                 (or (and err err.message) "unknown failure")))))

(fn main []
  (let [deployment-url (assert (os.getenv :CONVEX_URL) "CONVEX_URL is required")
        ;; Create the Fennel client for the approved test deployment.
        client (checked (Convex.new deployment-url))
        ;; The verifier supplies a unique room so parallel runs never collide.
        room (or (. arg 1) :fennel-example)
        ;; Read the starting state through Convex's HTTP query API.
        current (checked (: client :query "demo:state" {: room}))
        initial (Integer.checked current.value.count "current query")]
    (print (.. "current count: " initial))
    ;; Subscribe before mutating so no reactive update can be missed.
    (let [subscription (checked (: client :subscribe "demo:state" {: room}))
          live-initial (checked (: subscription :next-update 10))
          live-initial-count (Integer.checked live-initial.value.count
                                             "initial Live value")]
      (assert (= live-initial-count initial)
              "initial Live value disagreed with HTTP")
      (print (.. "live initial count: " live-initial-count))
      ;; runId is the mutation's idempotency key.
      (let [run-id (table.concat [:fennel
                                  room
                                  (tostring (os.time))
                                  (tostring (math.random 1 2147483646))]
                                 ":")
            mutation (checked (: client :mutation "demo:increment"
                                 {: room :language :fennel :runId run-id}))
            changed (Integer.checked mutation.value.state.count :mutation)]
        (assert (= mutation.value.applied true) "mutation was not applied")
        (assert (= changed (+ initial 1))
                "mutation count did not advance by one")
        (print "mutation applied: true")
        (print (.. "mutation count: " changed))
        ;; Receive the resulting value from Live, without HTTP polling.
        (let [live-changed (checked (: subscription :next-update 10))
              live-changed-count (Integer.checked live-changed.value.count
                                                 "updated Live value")]
          (assert (= live-changed-count changed)
                  "updated Live value disagreed with mutation")
          (print (.. "live updated count: " live-changed-count))
          (print (.. "verified count: " initial " -> " live-changed-count))))
      ;; Unsubscribe before shutting down the single shared Live owner.
      (checked (: subscription :close))
      (: client :close))))

(main)
