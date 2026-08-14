<img src="logo.png" alt="Clojure logo" width="128">
<!-- Logo source: https://clojure.org/images/clojure-logo-icon-256.png -->

# Clojure

[Clojure](https://clojure.org/) is a functional Lisp created by Rich Hickey and [first presented publicly in 2007](https://clojure.org/about/documentary). It [compiles to JVM bytecode](https://clojure.org/about/jvm_hosted), works directly with Java libraries, and favours immutable data over mutable objects. It remains a focused modern language rather than a mainstream one, with the [2025 community survey](https://clojure.org/news/2026/02/18/state-of-clojure-2025) showing especially visible use in financial services, enterprise software, and healthcare.

This repository's client is an educational demonstration. It is unofficial and is not a production Convex SDK.

## Getting Started

Start with the [canonical basic example](examples/basics/main.clj). It creates a client from `CONVEX_URL`, gives the run its own room, reads the counter over HTTP, opens a Live subscription, performs an idempotent mutation, and observes the reactive `0 -> 1` update.

From the repository root, Docker builds the example and runs that exact source against an approved test deployment:

```sh
./run verify-example clojure
```

## Interesting Parts

### The reply is just a map, and a keyword can read it

Clojure keywords such as `:value` are not mere constants — each one is a function that looks itself up in a map. Add the thread-first macro `->`, which feeds each result into the next form, and drilling into a Convex response reads top-to-bottom instead of inside-out.

```clojure
;; TypeScript: const { count } = await client.query("demo:state", { room });
(-> (convex/query client "demo:state" {"room" room})
    :value              ; the keyword extracts its own entry from the reply map
    (get "count"))
```

### `assoc` returns a new map, so argument-building cannot backfire

Clojure's collections are [persistent data structures](https://clojure.org/reference/data_structures), built on the hash array mapped tries Rich Hickey adapted from Phil Bagwell's research. "Updating" a map returns a fresh map that shares structure with the old one, so the basics example grows its query arguments into mutation arguments with no defensive copying.

```clojure
(let [room-args {"room" room}
      ;; A brand-new map; room-args itself is untouched, forever.
      mutation-args (assoc room-args
                           "language" "clojure"
                           "runId" (str (UUID/randomUUID)))]
  (convex/mutation client "demo:increment" mutation-args)
  (convex/query client "demo:state" room-args))  ; still exactly {"room" room}
```

### `with-open` gives a Live subscription the lifetime of a block

The HTTP client, the Live client, and every subscription implement Java's `AutoCloseable`, so `with-open` — in Clojure years before Java 7 grew try-with-resources — plays the role the component lifecycle plays for `useQuery`: leaving the block unsubscribes and closes the WebSocket, even when an exception escapes.

```clojure
;; TypeScript: const state = useQuery(api.demo.state, { room });
(with-open [client (convex/client url)
            live (convex/live-client url)
            subscription (convex/subscribe live "demo:state" room-args)]
  (println (get (:value (convex/next-update subscription 10000)) "count"))
  (convex/mutation client "demo:increment" mutation-args)
  ;; The same open subscription now delivers the reactive update: 0 -> 1.
  (println (get (:value (convex/next-update subscription 10000)) "count")))
```

### A failed Convex function throws data, not just a string

Since Clojure 1.4, `ex-info` has built exceptions that carry an arbitrary map, and `ex-data` gets the map back. This client wraps every Convex function failure that way, so the server's structured error payload arrives as ordinary data you can destructure — no exception-class hierarchy to learn.

```clojure
(try
  (convex/query client "demo:state" {})  ; oops — forgot the room argument
  (catch clojure.lang.ExceptionInfo error
    ;; TypeScript: if (e instanceof ConvexError) console.log(e.data)
    (let [{:keys [kind data]} (ex-data error)]
      (println kind "-" (ex-message error))
      data)))
```

## Status

| Capability | Status |
| --- | --- |
| HTTP query, mutation, action, auth, logs, and structured errors | Verified by shared local and hosted conformance |
| Live initial values, changes, query-error recovery, and reconnects | Verified by shared local and hosted conformance |
| Bounded delivery and lifecycle barriers | Implemented and covered by deterministic fixtures |

## Example

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

## Implementation Notes

This is a native Clojure implementation. Convex-specific HTTP and Live behavior lives in Clojure, while JDK 21 supplies HTTP, TLS, and WebSocket transport and `clojure.data.json` 2.5.1 handles JSON. The demonstration is pinned to Clojure 1.12.0 and the experimental `convex-rs-0.10.4-unversioned-sync` profile at backend commit `6f1df8a8ba1665084ec001e307ca841ca17074d7`.

HTTP calls are synchronous and return `{:value ... :logs ...}` maps. Function failures become `ExceptionInfo` values with structured data instead of being mistaken for successful results. For Live queries, one dedicated owner thread controls the WebSocket, query versions, reconnects, and writes. The JDK WebSocket admits one callback at a time, and the owner queue is capped at 64 events. That is an implementation design, not a Clojure Agent.

`./run test clojure` checks formatting, exercises the HTTP, raw WebSocket, lifecycle, pressure, example, and adapter tests, then ahead-of-time compiles the canonical example and conformance adapter. `./run build clojure` creates the minimal non-root runtime. The runtime retains the Clojure compiler classes needed while core namespaces load, but exposes no Clojure or Java compiler command, package manager, source tree, or build metadata.

The test-only adapter speaks protocol v1 over standard input/output or `ADAPTER_LISTEN` TCP. It validates command shapes, keeps protocol output separate from diagnostics, preserves structured errors, and uses lifecycle barriers so an old subscription cannot publish after replacement or unsubscribe has been acknowledged.

## Known Issues

1. Live uses an experimental pinned sync profile. Live authentication, optimistic updates, transition chunks, journals, and replay are deferred.
2. The client has no generated Clojure API types. Function paths and decoded JSON values are checked at runtime, so application code should validate the fields it depends on as the canonical example does for `count`.
3. All subscriptions share a newest-16, 4 MiB encoded delivery budget. Under pressure, stale snapshots can be dropped to retain newer ones. Incoming Live messages are capped at 2 MiB.
4. The minimal AOT runtime still contains `clojure.lang.Compiler` classes because Clojure core namespace loading references them, although no compiler command is available.
