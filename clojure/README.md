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

### Immutable maps make mutation arguments explicit

**TypeScript with React**

```tsx
import { useState } from "react";
import { useMutation } from "convex/react";
import { api } from "./convex/_generated/api";

function IncrementButton() {
  const increment = useMutation(api.demo.increment);
  const [room] = useState(() => `clojure-${crypto.randomUUID()}`);

  async function addOne() {
    const args = {
      room,
      language: "typescript",
      runId: crypto.randomUUID(),
    };
    const result = await increment(args);
    console.log(result.state.count); // The generated API makes this number type-safe.
  }

  return <button onClick={addOne}>Increment</button>;
}
```

**Clojure**

```clojure
(require '[convex.client :as convex])
(import '[java.util UUID])

(let [url (or (System/getenv "CONVEX_URL")
              (throw (ex-info "CONVEX_URL is required" {})))
      room-args {"room" (str "clojure-" (UUID/randomUUID))}
      ;; assoc returns a new map. room-args still contains only the room.
      mutation-args (assoc room-args
                           "language" "clojure"
                           "runId" (str (UUID/randomUUID)))]
  (with-open [client (convex/client url)]
    (let [result (:value (convex/mutation client "demo:increment" mutation-args))]
      ;; JSON map keys and count are checked at runtime, not by generated types.
      (println (get-in result ["state" "count"])))))
```

Clojure's maps are [immutable and persistent](https://clojure.org/reference/data_structures), so adding the mutation fields does not alter the reusable query arguments. The trade-off here is type safety: the React client gets generated function and result types, while this small Clojure client accepts dynamic string-keyed JSON maps and relies on runtime validation.

### A command-line subscription has a lifecycle you can see

**TypeScript with React**

```tsx
import { useState } from "react";
import { useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

function Counter() {
  const [room] = useState(() => `clojure-${crypto.randomUUID()}`);
  const state = useQuery(api.demo.state, { room });

  if (state === undefined) return <p>Loading...</p>;
  return <p>{state.count}</p>; // state.count is type-safe and rerenders reactively.
}
```

**Clojure**

```clojure
(require '[convex.client :as convex])
(import '[java.util UUID])

(let [url (or (System/getenv "CONVEX_URL")
              (throw (ex-info "CONVEX_URL is required" {})))
      room-args {"room" (str "clojure-" (UUID/randomUUID))}]
  ;; This CLI owns the HTTP client, Live client, and subscription explicitly.
  (with-open [http (convex/client url)
              live (convex/live-client url)
              subscription (convex/subscribe live "demo:state" room-args)]
    (let [initial (:value (convex/next-update subscription 10000))]
      (println (get initial "count")) ; Initial Live value.
      (convex/mutation http "demo:increment"
                       (assoc room-args
                              "language" "clojure"
                              "runId" (str (UUID/randomUUID))))
      (let [updated (:value (convex/next-update subscription 10000))]
        ;; This is the reactive update from the same subscription.
        (println (get updated "count"))))))
```

React starts, updates, and disposes the `useQuery` subscription with the component. This command-line client instead returns a subscription that the caller consumes and closes. Its blocking `next-update` operation is a deliberate client API choice for a readable example, not a limitation of Clojure's concurrency tools.

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
