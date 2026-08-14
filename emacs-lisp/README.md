<img src="logo.png" alt="GNU Emacs logo" width="128">
<!-- Logo source: https://git.savannah.gnu.org/cgit/emacs.git/plain/etc/images/icons/hicolor/128x128/apps/emacs.png -->

# Emacs Lisp

[Emacs Lisp](https://www.gnu.org/software/emacs/) is the Lisp dialect built
into GNU Emacs. It powers most Emacs commands and extensions, so its everyday
niche is editor configuration and packages rather than standalone services.
[GNU Emacs work began in 1984](https://www.gnu.org/gnu/the-gnu-project.html)
and had its [initial public release in
1985](https://www.gnu.org/software/emacs/history.html); today the same
interpreter can also run scripts in batch mode, which is how this client talks
to Convex.

This is an educational, unofficial demonstration. It is not a production SDK,
an officially sanctioned Convex client, or a package intended for publication.

## Getting Started

[`examples/basics/main.el`](examples/basics/main.el) is the canonical example.
It queries a fresh counter room, subscribes before changing it, applies an
idempotent mutation, and observes the reactive `0 -> 1` update.

From the repository root, run the exact example in its Docker runtime:

```sh
./run verify-example emacs-lisp
```

Docker supplies the pinned GNU Emacs 28.2 runtime and the verifier supplies a
unique room on an approved test deployment.

## Interesting Parts

### A quoted symbol picks how JSON keys compare

In Lisp, code and data share one syntax, and `'equal` is the tiny proof: a
symbol, quoted so it is passed along as a value instead of being evaluated,
telling the hash table to compare keys by string contents. Every JSON object
Convex returns is decoded into exactly this kind of table.

```emacs-lisp
(let ((args (make-hash-table :test 'equal))) ; 'equal compares keys by contents
  (puthash "room" "readme-room" args)
  (convex-configure (getenv "CONVEX_URL"))
  ;; TypeScript: await client.query("demo:state", { room })
  (let ((state (convex-query "demo:state" args)))
    (message "count: %s" (gethash "count" state))))
```

That quote mark is shorthand for `(quote equal)`, notation straight out of
McCarthy's 1960 Lisp paper, still on the job against a modern realtime
database.

### Failure is `nil`; the details are a plist

`convex-query` returns the decoded value, or `nil` on failure, and then the
full story waits in `convex--last-error` as a property list: alternating keys
and values, one of Lisp's oldest data structures. `plist-get` fishes out a
field by its keyword.

```emacs-lisp
(let ((state (convex-query "demo:state" args)))
  (unless state
    ;; convex--last-error looks like (:name ... :message ... :data ...)
    (error "query failed: %s" (plist-get convex--last-error :message)))
  (gethash "count" state))
```

### You hold the crank of the event loop

React's `useQuery` re-renders your component when the server pushes a new
value. Here the push arrives over a WebSocket this client implements itself
(Emacs models a network connection as a process object), and you pull:
`convex-live-pump` waits on the socket, `convex-live-next-event` dequeues the
next update.

```emacs-lisp
(convex-live-subscribe "demo:state" args)
;; TypeScript: useQuery(api.demo.state, { room }) re-renders for you
(while (not (convex-live-next-event))
  (convex-live-pump (+ (float-time) 0.2))) ; wait up to 200 ms for socket input
(gethash "count"
         (json-parse-string convex-live--event-payload :object-type 'hash-table))
```

When a mutation lands, the same loop wakes with the new count: Convex
reactivity, hand-pumped from a text editor whose lineage predates the web.

### `unwind-protect` was `finally` before `finally`

Lisp had guaranteed cleanup decades before mainstream languages picked up
`try/finally`. The canonical example wraps its whole Live session in
`unwind-protect`, so the subscription is dropped and the WebSocket closed no
matter how the body exits.

```emacs-lisp
(unwind-protect
    (progn
      (setq subscription (convex-live-subscribe "demo:state" args))
      ;; ... pump Live events, apply the mutation, pump again ...
      (message "verified count: 0 -> 1"))
  ;; Cleanup runs on success, error, or C-g.
  (when subscription (convex-live-unsubscribe subscription))
  (convex-live-close))
```

## Status

| Capability | Current state | Evidence-backed scope |
| --- | --- | --- |
| HTTP | Badge earned | Query, mutation, action, bearer-token lifecycle, logs, and structured function, protocol, and transport errors passed 31/31 shared checks on both local and hosted deployments. |
| Live | Badge earned | Subscription delivery, external updates, query failure and recovery, unsubscribe barriers, and five real reconnect-and-resubscribe cycles passed the same 31/31 local and 31/31 hosted checks. The shared harness uses the adapter's TCP transport; the separate stdio Live path still has the intermittent crash noted below. |

Both badges were awarded from the clean exact-head build at `e5e2b85`, with
hosted checks running over real TLS. This documentation update does not claim a
new verification run.

## Example

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

## Implementation Notes

This is a native Emacs Lisp implementation. HTTP uses Emacs's bundled
`url-retrieve-synchronously`, JSON uses `json-serialize` and
`json-parse-string`, and TLS uses `open-network-stream` with GnuTLS. The
[Emacs Lisp manual](https://www.gnu.org/software/emacs/manual/html_node/elisp/Processes.html)
describes those network connections as process objects, which is why Live can
wait for socket input through `accept-process-output` without another runtime.

Emacs does not bundle a WebSocket client in the pinned 28.2 image, so
[`client/convex.el`](client/convex.el) implements the RFC 6455 handshake,
masking, fragmentation, ping/pong, and framing over Emacs network processes.
It limits a frame to 2 MiB and gives a partially received frame eight seconds
to finish. Live events sit in a bounded client-owned queue of 64 events and
8 MiB, with the oldest event dropped first if either limit is exceeded.

The public API deliberately keeps one global client and returns decoded values
synchronously. Failed HTTP calls return `nil` and leave a structured error in
`convex--last-error`. Live uses explicit `convex-live-pump` and
`convex-live-next-event` calls even though Emacs supports asynchronous process
filters and callbacks. That choice keeps the batch example and conformance
adapter deterministic, but an editor package would probably wrap this core in
callbacks or promises of its own.

The test-only adapter supports both TCP and NDJSON over standard input. Its
small `stdin-poll.c` helper only checks whether inherited stdin is ready; it
does not implement any Convex behavior and is not part of the educational
client. HTTP pins the documented JSON endpoints. Live pins
`convex-rs-0.10.4-unversioned-sync` at
`6f1df8a8ba1665084ec001e307ca841ca17074d7` and `/api/sync`, so hosted
verification is important because that realtime protocol is not documented as
stable.

For the language-local Docker gate, run:

```sh
./run test emacs-lisp
```

That byte-compiles with warnings treated as errors, checks source style, and
runs the loopback HTTP, WebSocket, Live, queue, and adapter tests. The stronger
root-owned gates are `./run verify emacs-lisp`, `./run verify-hosted
emacs-lisp`, and `./run verify-all emacs-lisp`.

## Known Issues

1. Live authentication, optimistic updates, WebSocket mutations and actions,
   journals, and `TransitionChunk` assembly are not implemented. Mutations and
   actions go over HTTP.
2. Values are limited to JSON-safe objects, arrays, strings, booleans, null,
   and whole numbers in the supported range. Tagged Convex `Int64`, bytes, and
   special floats are outside this experiment.
3. The adapter's stdio transport has intermittently crashed under concurrent
   Live delivery and high-cadence stdin polling on a QEMU-emulated build host.
   The TCP adapter path used by shared conformance and the direct client Live
   tests are unaffected, but stdio Live remains unresolved.
4. A slow consumer can overflow the bounded Live queue. The client drops the
   oldest pending events rather than allowing memory use to grow without bound.
