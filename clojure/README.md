# Convex from Clojure

This Clojure client calls Convex functions over HTTP, then keeps a query current over the experimental pinned Live sync profile.

It is educational, unofficial, and not a production Convex SDK.

## Start here

The [canonical basic example](examples/basics/main.clj) performs a unique room's `0 -> 1` counter journey: HTTP query, initial Live value, idempotent mutation, then its Live update.

## What works

| Capability | Status |
| --- | --- |
| HTTP query, mutation, action, auth, logs, and structured errors | Implemented, awaiting shared evidence |
| Live initial values, changes, query-error recovery, and reconnects | Implemented for the pinned profile, awaiting shared evidence |
| Bounded delivery and lifecycle barriers | Implemented and covered by deterministic fixtures |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.clj -->
```clojure
(ns main
  (:gen-class)
  (:require [convex.client :as convex])
  (:import [java.math BigDecimal]
           [java.util UUID]))

(defn- count-of [state operation]
  (let [count (get state "count")]
    ;; Convex JSON may encode a whole count as 0 or 0.0. Validate before
    ;; normalising so a fractional or non-finite value cannot be hidden.
    (when-not (number? count)
      (throw (ex-info (str operation " did not return a numeric count") {})))
    (let [decimal (try
                    (bigdec count)
                    (catch NumberFormatException _ nil))]
      (when-not (and decimal
                     (<= (.scale (.stripTrailingZeros ^BigDecimal decimal)) 0)
                     (<= (bigdec Long/MIN_VALUE) decimal (bigdec Long/MAX_VALUE)))
        (throw (ex-info (str operation " did not return an in-range whole count") {})))
      (.longValueExact ^BigDecimal decimal))))

(defn- print-transcript [before initial applied mutation updated]
  (println (str "current count: " before))
  (println (str "live initial count: " initial))
  (println (str "mutation applied: " applied))
  (println (str "mutation count: " mutation))
  (println (str "live updated count: " updated))
  (println (str "verified count: " before " -> " updated)))

(defn -main [& args]
  ;; Read configuration from the verifier rather than baking a deployment into the image.
  (let [url (or (System/getenv "CONVEX_URL") (throw (ex-info "CONVEX_URL is required" {})))
        ;; A unique room keeps this demonstration independent from every other run.
        room (or (first args) "clojure-example")
        room-args {"room" room}]
    ;; The native Clojure HTTP client and Live worker are always closed, including on failure.
    (with-open [client (convex/client url) live (convex/live-client url)]
      ;; Ask Convex's HTTP query endpoint for the counter before subscribing.
      (let [before (count-of (:value (convex/query client "demo:state" room-args)) "current query")
            ;; Start Live before the mutation, so its first value is our observation point.
            subscription (convex/subscribe live "demo:state" room-args)
            initial (count-of (:value (convex/next-update subscription 10000)) "initial Live value")]
        (when-not (= before initial) (throw (ex-info "Live initial value disagreed" {})))
        ;; runId is the mutation's idempotency key, preventing a retry from incrementing twice.
        (let [mutation (:value (convex/mutation client "demo:increment" (assoc room-args "language" "clojure" "runId" (str (UUID/randomUUID)))))]
          (when-not (true? (get mutation "applied")) (throw (ex-info "mutation was not applied" {})))
          (let [after (count-of (get mutation "state") "mutation")
                ;; Consume the update from the existing subscription rather than polling HTTP again.
                updated (count-of (:value (convex/next-update subscription 10000)) "updated Live value")]
            (when-not (= after updated) (throw (ex-info "Live update disagreed" {})))
            (print-transcript before initial true after updated)))))))
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

`./run test clojure` checks standard formatting, runs the language-local HTTP, raw WebSocket, lifecycle, and adapter tests, then AOT-compiles the exact example and adapter. `./run build clojure` creates the minimal non-root runtime. Its BusyBox is built from source with only the shell and inspection applets the verifier needs, so network and package-management applets are absent even when callers forge `argv[0]`. Root owns the serial shared example and conformance evidence.

## Protocol notes

The client uses the documented JSON HTTP endpoints and the pinned `convex-rs-0.10.4-unversioned-sync` profile. One Clojure actor owns every WebSocket, query-set version, reconnect, and serialized write. The JDK WebSocket is demand-driven: at most one callback is admitted at a time, and the owner's executor has a fixed 64-event queue as a second safety boundary. Reconnect metadata survives generations, backoff resets after a successful WebSocket handshake, and unchanged hydration is suppressed.

The adapter supports partial NDJSON over stdin/stdout and `ADAPTER_LISTEN` TCP, flushes each correlated event, and continues after request errors. It rejects an encoded command line above 1 MiB before allocating the whole line. Its asynchronous writer has one newest-16, 4 MiB encoded budget across queued and in-flight output, so a stopped reader cannot block Live relays or grow memory without limit. Replacement, unsubscribe, and the test-only `debugDisconnect` acknowledge only after their generation/relay barriers; replacement and unsubscribe also await the corresponding WebSocket send completion.

## Limitations

The Live profile is experimental and deliberately earns no badge until the shared controller passes locally and against the hosted drift target. Authentication, optimistic updates, transition chunks, journals, and replay are deferred. All subscriptions share one newest-16, 4 MiB encoded delivery budget, and each inbound WebSocket message is limited to 2 MiB. The AOT runtime still includes Clojure's `clojure.lang.Compiler` classes because core namespace loading references them, but it exposes no Clojure or Java compiler command and contains no source or build metadata.
