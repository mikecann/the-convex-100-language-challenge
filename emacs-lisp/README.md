# Convex from Emacs Lisp

This demonstration uses batch-mode GNU Emacs - the same Emacs Lisp a text
editor's own configuration is written in - to call Convex's documented JSON
HTTP endpoints and to keep a reactive query current through a native Emacs
Lisp WebSocket connection.

It is an educational, unofficial experiment. It is not a production SDK, an
officially sanctioned Convex client, or a package intended for publication.

## Start here

[`examples/basics/main.el`](examples/basics/main.el) is the canonical
example. It reads a new counter room over HTTP, starts Live before changing
it, applies an idempotent mutation, and proves the same `0 -> 1` journey
arrived through the subscription. The block below is generated from that
exact runnable file.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Badge earned | Query, mutation, action, bearer-token lifecycle, structured `FunctionError`/`ProtocolError`/`TransportError` classification, and logs pass a real loopback test suite in Docker and shared local and hosted black-box conformance (31/31 both profiles). The example-runtime and runtime Docker images were also run end to end against a real loopback deployment, not merely built. |
| Live | Badge earned | Subscribe, an initial value, an external update, `QueryFailed`, and the unsubscribe-before-acknowledgement barrier pass a real loopback test suite against the client directly, plus shared local and hosted black-box conformance (31/31 both profiles). `debugDisconnect`'s acknowledgement barrier and five consecutive real reconnect-and-resubscribe cycles, each required to deliver a genuine resubscribed value, are proven deterministically against a real second OS process. The shared harness drives the adapter over TCP; the TCP transport was independently confirmed end to end (subscribe, deliver a value) in the real runtime image, but the stdio transport has an unresolved intermittent crash under Live load that this run did not exercise - see Limitations. |

The shared evaluator awarded both badges from a clean exact-head build
(`e5e2b85`): 31 of 31 conformance checks against a local backend and 31 of
31 against the hosted deployment over real TLS.

## The basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.el -->
```emacs-lisp
;;; main.el --- the canonical Convex-from-Emacs-Lisp walkthrough: one HTTP
;;; query, a Live subscription, an idempotent mutation, and the resulting
;;; Live update. This is the exact source rendered in the README and on the
;;; project website, so every step is commented for a reader who has never
;;; seen this client before. It uses the same client/convex.el the
;;; conformance adapter does, so this is precisely what the README shows
;;; running.

(let ((here (file-name-directory (or load-file-name buffer-file-name))))
  (load (expand-file-name "../../client/convex.el" here) nil t))

(defun main--println (format-string &rest args)
  "Print one LF-terminated line to stdout. `message' is not usable here:
in --batch mode it writes to stderr, and this transcript must be
byte-identical, on stdout, to _shared/examples/basics.expected.txt."
  (princ (apply #'format format-string args))
  (princ "\n"))

(defun main--whole-count (value operation)
  "VALUE is the decoded `count' field of a Convex query, mutation, or Live
result. Convex JSON can spell a whole number as 0.0; accept that
mathematical integer, but reject fractions, strings, and non-finite
values, matching every other client's example in this project."
  (unless (numberp value)
    (error "%s omitted a numeric count" operation))
  (unless (= value (truncate value))
    (error "%s count was not a finite whole number" operation))
  (truncate value))

(defun main--wait-for-live-event (deadline-seconds)
  "Pump Live until an event is ready, or DEADLINE-SECONDS elapses. Returns
the event kind (\"value\"/\"error\"), or nil on timeout."
  (let ((deadline (+ (float-time) deadline-seconds)) kind)
    (while (and (not (setq kind (convex-live-next-event)))
                (< (float-time) deadline))
      (convex-live-pump (+ (float-time) 0.2)))
    kind))

(defun main ()
  (let ((deployment (getenv "CONVEX_URL")))
    (when (or (null deployment) (string-empty-p deployment))
      (error "CONVEX_URL is required"))
    (let* ((room (or (car command-line-args-left) "emacs-lisp-example"))
           (args (make-hash-table :test 'equal))
           (subscription nil))
      (puthash "room" room args)
      (convex-configure deployment)
      (unwind-protect
          (progn
            ;; Ask Convex once over HTTP before opening Live, to establish
            ;; the fresh room.
            (let* ((current (convex-query "demo:state" args)))
              (unless current
                (error "current query failed: %s" (plist-get convex--last-error :message)))
              (let ((current-count (main--whole-count (gethash "count" current) "current query")))
                (unless (= current-count 0)
                  (error "current count was %d, expected 0" current-count))
                (main--println "current count: %d" current-count)))

            ;; Start Live first. Its initial value proves no mutation can
            ;; slip between subscription setup and the later idempotent
            ;; write.
            (setq subscription (convex-live-subscribe "demo:state" args))
            (let ((kind (main--wait-for-live-event 20)))
              (unless (equal kind "value")
                (error "initial Live value: %s" (if kind "delivered an error" "timed out")))
              (let ((initial-count (main--whole-count
                                     (gethash "count"
                                              (json-parse-string convex-live--event-payload
                                                                  :object-type 'hash-table))
                                     "initial Live value")))
                (unless (= initial-count 0)
                  (error "initial Live count was %d, expected 0" initial-count))
                (main--println "live initial count: %d" initial-count)))

            ;; A unique runId is the mutation's idempotency key, so retrying
            ;; this logical request would not double-increment the room.
            (let* ((mutation-args (make-hash-table :test 'equal))
                   (mutation nil))
              (puthash "room" room mutation-args)
              (puthash "language" "emacs-lisp" mutation-args)
              (puthash "runId" (format "%x" (truncate (* (float-time) 1000000))) mutation-args)
              (setq mutation (convex-mutation "demo:increment" mutation-args))
              (unless mutation
                (error "mutation failed: %s" (plist-get convex--last-error :message)))
              (unless (eq (gethash "applied" mutation) t)
                (error "mutation was not applied"))
              (main--println "mutation applied: true")
              (let ((mutation-count (main--whole-count
                                      (gethash "count" (gethash "state" mutation))
                                      "mutation")))
                (unless (= mutation-count 1)
                  (error "mutation count was %d, expected 1" mutation-count))
                (main--println "mutation count: %d" mutation-count)))

            ;; Wait for the changed value from Live rather than issuing
            ;; another query.
            (let ((kind (main--wait-for-live-event 20)))
              (unless (equal kind "value")
                (error "updated Live value: %s" (if kind "delivered an error" "timed out")))
              (let ((updated-count (main--whole-count
                                     (gethash "count"
                                              (json-parse-string convex-live--event-payload
                                                                  :object-type 'hash-table))
                                     "updated Live value")))
                (unless (= updated-count 1)
                  (error "updated Live count was %d, expected 1" updated-count))
                (main--println "live updated count: %d" updated-count)))
            (main--println "verified count: 0 -> 1"))
        (when subscription (convex-live-unsubscribe subscription))
        (convex-live-close)))))

;; An uncaught Lisp error in --batch mode prints a full debugger backtrace
;; to stderr and exits 255, not the clean single-line message and exit
;; status 1 this project's Docker test stages assert on. Catch it here
;; instead: stdout stays untouched on failure (nothing above ever fails
;; after printing a line, only before), and stderr gets exactly the
;; message, not a backtrace.
(condition-case err
    (main)
  (error
   (princ (error-message-string err) #'external-debugging-output)
   (princ "\n" #'external-debugging-output)
   (kill-emacs 1)))
```
<!-- END GENERATED EXAMPLE -->

## Verify it in Docker

```sh
./run test emacs-lisp
./run verify-example emacs-lisp
./run verify emacs-lisp
./run verify-hosted emacs-lisp
./run verify-all emacs-lisp
```

`test` installs `emacs-nox` 28.2, byte-compiles the client and the adapter
with warnings treated as errors, lints every source file, and runs real
loopback JSON, HTTP, WebSocket, and Live protocol fixtures, the conformance
adapter's stdio and TCP modes, and the example's fast-fail path, all inside
Docker. The remaining commands are root-owned shared gates for the approved
local and hosted deployments; `./run verify-all emacs-lisp` has passed both,
earning the http and live badges above.

## Conformance and protocol notes

The test-only adapter under `client/tests/conformance/` speaks NDJSON
protocol v1 on stdin/stdout and TCP. It calls the real Emacs Lisp client
(`client/convex.el`) for every operation. Its adapter-only `debugDisconnect`
command lets the shared harness prove reconnects. Command schemas are
strict: a missing or wrongly typed `id`, `op`, `path`, `args`,
`subscriptionId`, or `token` is a structured `ProtocolError` and never
reaches a deployment.

HTTP uses Convex's documented `format: "json"` endpoints. Live pins
`convex-rs-0.10.4-unversioned-sync` at
`6f1df8a8ba1665084ec001e307ca841ca17074d7` and `/api/sync`. That realtime
protocol is not documented as stable, so hosted verification remains
required before any Live claim.

Responses are classified by what the deployment actually said, not only by
the status line:

| Response | Result | Why |
| --- | --- | --- |
| `200` with `status: "success"` | value and logs | the documented success envelope |
| `200` with `status: "error"`, or `560` | `FunctionError` | the function ran and failed, so the caller can act on it |
| `408`, `429`, `5xx` | `TransportError` | this attempt was not answered and may be retried |
| any other non-`200` | `ProtocolError` | the deployment refused the request and would refuse it again |

A single WebSocket frame is bounded to 2 MiB, and once any byte of a frame
has been consumed, an 8-second partial-frame deadline governs completing it,
tracked independently of the caller's own polling deadline so a slow peer
cannot hold the connection open with repeated short polls.

Emacs has genuine network primitives, so `client/convex.el` is native end to
end and has no C in it at all: HTTP goes through `url.el`
(`url-retrieve-synchronously`), JSON through the built-in
`json-parse-string`/`json-serialize`, SHA-1 through `secure-hash`, base64
through `base64-encode-string`/`base64-decode-string`, and TLS through
`open-network-stream`'s own `:type 'tls` (GnuTLS - confirmed with a real
HTTPS connection, not merely `gnutls-available-p`). Emacs has no WebSocket
library, so the RFC 6455 handshake and frame format for Live are
hand-written Emacs Lisp over `make-network-process`/`open-network-stream`,
the same way several other clients in this project implement WebSockets by
hand over a raw socket. The one piece of native code anywhere in this
client, `client/tests/conformance/stdin-poll.c`, exists solely for the
test-only adapter's stdio transport - see Limitations for exactly why.

## Limitations

- Live authentication, optimistic updates, WebSocket mutations and actions,
  journals, and `TransitionChunk` assembly are intentionally not yet
  implemented. Mutations and actions use HTTP.
- Values are limited to this experiment's JSON-safe subset: objects, arrays,
  strings, whole numbers within a `uint32` range, booleans, and null. Tagged
  Convex `Int64`, bytes, and special floats are outside scope.
- `client/tests/conformance/stdin-poll.c` is the only native code anywhere
  in this client, and it exists solely for the test-only NDJSON adapter,
  never for `client/convex.el`. The adapter's own loop must multiplex two
  independent readiness conditions - the next NDJSON command arriving on
  stdin, and the next Live delivery becoming available from the WebSocket
  the client already owns - without either one blocking the other
  indefinitely. Emacs's own network processes support exactly this via
  `accept-process-output` with a timeout (used natively for the TCP
  transport, with no helper at all), but batch-mode Emacs Lisp has no
  equivalent for its own inherited stdin: `read-from-minibuffer` (the only
  primitive that reads piped, non-tty stdin at all in `--batch` mode) is an
  uninterruptible blocking read with no timeout,
  `read-event`/`read-char`/`sit-for` never observe piped stdin data even
  when it is already available, Lisp threads do not run concurrently with a
  blocking read (confirmed empirically in both directions), and a spawned
  subprocess does not inherit this process's own external stdin (Emacs
  redirects a child's stdin to a pipe it controls). Several other
  single-threaded languages in this project hit the identical wall for the
  identical reason and solve it the identical way: a `poll(2)` readiness
  check on stdin, callable with a timeout. `stdin-poll.c` never reads or
  forwards a byte of stdin itself - only `convex.el`'s own
  `read-from-minibuffer` call ever consumes adapter input.
- The stdio transport's multiplexing loop was observed during testing to
  crash the whole Emacs process, without a Lisp-level error or backtrace,
  on some runs where a Live subscription became active while the adapter
  was simultaneously polling stdin at a high cadence on this QEMU-emulated
  build host; other runs of the identical scenario completed without
  incident, and it was not root-caused in the time available. The TCP
  transport is unaffected - proven reliably and repeatedly, including a
  full subscribe-and-deliver-a-value exchange against a real loopback
  fixture in the actual runtime image - because it never uses `stdin-poll`
  or a subprocess at all. `client/tests/live_test.el` proves the complete
  Live acceptance list against `client/convex.el` directly, not through the
  adapter, so that suite is unaffected; the specific, unresolved risk is
  stdio-transported Live delivery through the adapter.
- Live delivery is a bounded queue owned entirely by `convex.el`: at most 64
  pending events and 8 MiB of conservatively charged encoded bytes per
  client, oldest dropped first. The adapter adds no second queue on top of
  it - it drains whatever is available and writes it out immediately, so a
  stalled reader applies ordinary OS pipe or socket backpressure to the
  adapter's own loop rather than an adapter-private buffer growing without
  bound. Unsubscribe and a same-subscriptionId replacement bump a per-query
  generation counter that invalidates any already-queued event for that
  query before its acknowledgement is published; this has a deterministic,
  non-timing-dependent regression test.
- Language-local tests cover WebSocket frame encode/round-trip (short and
  extended-length payloads), the Convex timestamp/version comparison Live's
  reconnect and out-of-order guard depend on, HTTP envelope message
  classification, the delivery queue's 64-event bound and oldest-dropped
  ordering, generation-based stale-event invalidation, a real loopback HTTP
  fixture covering bearer auth, structured errors, and logs, a real loopback
  WebSocket fixture covering the handshake and masking, and a real second
  process acting as a Live peer covering Add, an initial value, an external
  update, five real reconnects, `QueryFailed` with structured `errorData`,
  and the unsubscribe generation barrier. Root-owned local and hosted
  conformance have since passed 31/31 on both profiles, earning the http
  and live badges above; the stdio-transport Live risk noted earlier in
  this list is unaffected by that result, since the shared harness drives
  the adapter over TCP and never exercises the stdio transport.
