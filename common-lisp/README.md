<img src="logo.png" alt="Common Lisp logo" width="128">
<!-- Logo source: https://common-lisp.net/static/imgs/lisplogo_flag2_128.png -->

# Common Lisp

Common Lisp is the standardized, multi-paradigm member of the Lisp family. Work on the language began in 1981 by bringing several Lisp dialects together, and it became ANSI standard X3.226-1994. Its parenthesized forms are both code and ordinary list-shaped data, while the language also includes an object system, conditions, macros, native compilation, and interactive development. The [Common Lisp HyperSpec history](https://www.lispworks.com/documentation/HyperSpec/Front/Help.htm) explains that path from the wider Lisp family to the portable standard.

Today Common Lisp is a specialist language with an active ecosystem rather than a mainstream default. It is still used where interactive development, long-running processes, native performance, or building a language tailored to the problem are useful. This client runs on [SBCL](https://www.sbcl.org/), a native Common Lisp compiler with a debugger and profiler. [Common-Lisp.net](https://common-lisp.net/) is a community-maintained starting point for implementations, libraries, tools, and current events.

This repository's client is educational and unofficial. It is not a production SDK and is not intended for package publication.

## Getting Started

Start with [`examples/basics/main.lisp`](examples/basics/main.lisp). It queries a new counter, subscribes before changing it, applies one idempotent mutation, and checks that HTTP, the mutation result, and Live all agree on `0 -> 1`.

From the repository root, run the exact example in its Docker image against a unique test room:

```sh
./run verify-example common-lisp
```

No Common Lisp toolchain is installed on the host.

## Interesting Parts

### JSON needs one more false value than Lisp has

TypeScript receives a generated result type, so `applied` is a normal `boolean` and `state.count` is known to be a number. This Common Lisp client deliberately returns generic JSON values instead. Objects are string-keyed hash tables, and `+json-false+` and `+json-null+` are distinct sentinels because Common Lisp's `nil` already means both false and the empty list.

**TypeScript with React**

```tsx
import { useMutation } from "convex/react";
import { api } from "../convex/_generated/api";

export function IncrementButton() {
  const increment = useMutation(api.demo.increment);

  async function handleClick() {
    const result = await increment({
      room: "common-lisp-readme",
      language: "typescript",
      runId: crypto.randomUUID(),
    });

    console.log(result.applied); // Generated types make this boolean.
    console.log(result.state.count); // Generated types make this number.
  }

  return <button onClick={handleClick}>Increment</button>;
}
```

**Common Lisp**

```common-lisp
(load "/project/client/load.lisp")
(in-package #:convex)

(let* ((deployment (or (sb-ext:posix-getenv "CONVEX_URL")
                       (error "CONVEX_URL is required")))
       (client (make-client deployment)))
  (unwind-protect
       (let* (;; JSON-OBJECT builds the named Convex argument object.
              (arguments (json-object "room" "common-lisp-readme"
                                      "language" "common-lisp"
                                      "runId" (random-hex-id)))
              (result (client-mutation client "demo:increment" arguments))
              ;; RESULT-VALUE is generic JSON, so read object fields by name.
              (value (result-value result))
              (applied (json-get value "applied" +json-false+))
              (state (json-get value "state")))
         (format t "applied: ~:[false~;true~]~%" (eq applied t))
         (format t "count: ~D~%" (json-get state "count")))
    ;; UNWIND-PROTECT is Lisp's equivalent of finally for cleanup.
    (client-close client)))
```

The explicit decoding is a choice in this small client, not a Common Lisp restriction. A larger SDK could generate structs and accessors from Convex function types.

### React owns reactivity; this program owns a subscription

`useQuery` subscribes while the component is mounted and rerenders it when the value changes. The Common Lisp API exposes that lifecycle directly: create a subscription, block for its next delivery, inspect either its value or structured error, and close it. The blocking `subscription-next` call is this client's command-line-friendly API design, not a limitation of Common Lisp's concurrency model.

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function Counter() {
  const state = useQuery(api.demo.state, { room: "common-lisp-live" });

  if (state === undefined) return <p>Loading...</p>;
  return <p>Count: {state.count}</p>; // React rerenders on each Live value.
}
```

**Common Lisp**

```common-lisp
(load "/project/client/load.lisp")
(in-package #:convex)

(let* ((deployment (or (sb-ext:posix-getenv "CONVEX_URL")
                       (error "CONVEX_URL is required")))
       (client (make-client deployment))
       (subscription nil))
  (unwind-protect
       (progn
         ;; Starting the subscription opens Live and sends demo:state's args.
         (setf subscription
               (client-subscribe client "demo:state"
                                 (json-object "room" "common-lisp-live")))
         ;; A command-line program decides when to wait for each reactive value.
         (loop repeat 2
               for update = (subscription-next subscription :timeout 10.0)
               do (unless update (error "Timed out waiting for Live"))
                  (if (update-error update)
                      (error (update-error update))
                      (format t "Count: ~D~%"
                              (json-get (update-value update) "count")))))
    ;; The caller, rather than a React component, owns both lifetimes.
    (when subscription (subscription-close subscription))
    (client-close client)))
```

The first delivery hydrates the current query. A later delivery arrives after the data changes, without polling the HTTP endpoint. See the complete sequencing and validation in the [canonical example](examples/basics/main.lisp).

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions | Verified by shared local and hosted conformance |
| Bearer authentication and structured function errors | Verified by shared local and hosted conformance |
| Live initial values, updates, and query-error recovery | Verified by shared local and hosted conformance |
| Remove, five reconnects, generation barriers, and bounded delivery | Verified by shared local and hosted conformance |

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.lisp -->
```common-lisp
(in-package #:convex)

(defun example-count (value operation)
  "Accept Convex's integral decimal JSON numbers without accepting fractions."
  (let ((count (and (hash-table-p value) (json-get value "count"))))
    (unless (and (realp count)
                 (= count (truncate count))
                 (<= 0 count #x7fffffffffffffff))
      (error "~A returned a non-integral or out-of-range count" operation))
    (truncate count)))

(defun next-example-update (subscription operation)
  "Wait through recoverable transport events, but fail on query/protocol errors."
  (let ((deadline (deadline-after 10.0)))
    (loop
      for remaining = (- deadline (monotonic-seconds))
      do (when (<= remaining 0) (error "Timed out waiting for ~A" operation))
         (let ((update (subscription-next subscription :timeout remaining)))
           (unless update (error "Timed out waiting for ~A" operation))
           ;; Live reports a real socket retirement, then reconnects the same
           ;; subscription. The example waits for that recovery value.
           (when (and (update-error update)
                      (not (typep (update-error update) 'transport-error)))
             (error (update-error update)))
           (unless (update-error update) (return (update-value update)))))))

(defun example-main ()
  (handler-case
      (let ((deployment (sb-ext:posix-getenv "CONVEX_URL")))
        (unless (and deployment (plusp (length deployment)))
          (error "CONVEX_URL is required"))
        (let* ((arguments (rest sb-ext:*posix-argv*))
               (room (or (first arguments)
                         (sb-ext:posix-getenv "EXAMPLE_ROOM")
                         "common-lisp-example"))
               ;; Configure one client for the deployment supplied by Docker.
               (client (make-client deployment))
               (subscription nil))
          (unwind-protect
               (progn
                 ;; Query the room through Convex's documented HTTP endpoint.
                 (let* ((query (client-query client "demo:state"
                                             (json-object "room" room)))
                        ;; Decode the generic JSON object into the integer this
                        ;; counter program actually needs.
                        (current (example-count (result-value query) "current query")))
                   (format t "current count: ~D~%" current)

                   ;; Start Live before mutating so no reactive update is missed.
                   (setf subscription
                         (client-subscribe client "demo:state"
                                           (json-object "room" room)))

                   ;; The first Live value hydrates the same current query.
                   (let ((initial
                           (example-count
                            (next-example-update subscription "initial Live value")
                            "initial Live value")))
                     (unless (= initial current)
                       (error "Initial Live count disagreed with HTTP"))
                     (format t "live initial count: ~D~%" initial))

                   ;; A random runId is the mutation's idempotency key. Reusing
                   ;; it would return the prior result instead of incrementing twice.
                   (let* ((mutation
                            (client-mutation
                             client "demo:increment"
                             (json-object "room" room
                                          "language" "common-lisp"
                                          "runId" (random-hex-id))))
                          (mutation-value (result-value mutation))
                          (applied (json-get mutation-value "applied" +json-false+))
                          (mutation-count
                            (example-count (json-get mutation-value "state") "mutation"))
                          (expected (1+ current)))
                     (unless (eq applied t) (error "Mutation was not applied"))
                     (unless (= mutation-count expected)
                       (error "Mutation returned an unexpected count"))
                     (format t "mutation applied: true~%")
                     (format t "mutation count: ~D~%" mutation-count)

                     ;; Receive the mutation through Live, without polling HTTP.
                     (let ((updated
                             (example-count
                              (next-example-update subscription "updated Live value")
                              "updated Live value")))
                       (unless (= updated expected)
                         (error "Updated Live count disagreed with the mutation"))
                       (format t "live updated count: ~D~%" updated)

                       ;; All three operations agreed before this proof line prints.
                       (format t "verified count: ~D -> ~D~%" current updated)))))
            ;; Cleanup retires the subscription and bounds socket shutdown.
            (when subscription (ignore-errors (subscription-close subscription)))
            (ignore-errors (client-close client)))))
    (error (condition)
      (format *error-output* "Common Lisp example failed: ~A~%" condition)
      (finish-output *error-output*)
      (sb-ext:exit :code 1)))
  (sb-ext:exit :code 0))
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

The client is native Common Lisp running on SBCL 2.2.9. It implements Convex's documented JSON HTTP calls and the repository's pinned `/api/sync` Live profile itself. SBCL sockets provide TCP, while direct OpenSSL 3 calls provide TLS, certificate and hostname checks, hashing, and the WebSocket transport. It does not delegate Convex behavior to another SDK, the Convex CLI, `curl`, Node.js, or Python.

HTTP calls return a `result` containing a generic JSON value and log lines. Function failures, malformed protocol data, and transport failures are separate Common Lisp condition types, so callers can handle them differently. The JSON layer rejects excessive depth and structure, and it preserves JSON false and null with dedicated sentinels.

One owner thread has exclusive control of the Live socket. Other threads queue subscribe, unsubscribe, reconnect, and close requests to it. The client validates each complete transition before publishing any part of it, suppresses unchanged reconnect hydration with a fixed-size hash, and keeps delivery memory bounded. The public queue holds at most 16 newest updates within a conservative 20 MiB budget; active subscriptions have separate 64-item and 8 MiB bounds.

Docker saves the example and adapter as native `linux/amd64` SBCL executables. The minimal runtime keeps only their library closure, TLS material, and the shell tools required by the shared verifier. It runs as `65532:65532` and contains no `sbcl` command or package manager.

## Known Issues

1. Live authentication, optimistic updates, mutations and actions over Live, and journals are not implemented.
2. `TransitionChunk` assembly is not implemented. Receiving one produces a recoverable protocol error and reconnect.
3. Values cover Convex's JSON-safe subset. Tagged Convex encodings are not converted into richer Common Lisp types.
4. Very deep, highly structured, or oversized Live data is rejected at the documented bounds rather than allowed to grow memory without limit.
