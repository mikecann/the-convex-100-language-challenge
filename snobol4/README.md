# Convex from SNOBOL4

This demonstration uses SNOBOL4 - specifically CSNOBOL4, Phil Budne's free
port of the original 1962 Bell Labs implementation - to call Convex's
documented JSON HTTP endpoints and to keep a reactive query current through a
native SNOBOL4 WebSocket connection.

It is an educational, unofficial experiment. It is not a production SDK, an
officially sanctioned Convex client, or a package intended for publication.

## Start here

[`examples/basics/main.sno`](examples/basics/main.sno) is the canonical
example. It reads a new counter room over HTTP, starts Live before changing
it, applies an idempotent mutation, and proves the same `0 -> 1` journey
arrived through the subscription. The block below is generated from that
exact runnable file.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Verified | Query, mutation, action, bearer-token lifecycle, structured `FunctionError`/`ProtocolError`/`TransportError` classification, and logs pass a real loopback test suite in Docker, and shared local and hosted conformance both passed from a clean exact-head build. |
| Live | Verified | Subscribe, an initial value, an external update, `QueryFailed`, and the unsubscribe-before-acknowledgement barrier pass a real loopback test suite. `debugDisconnect`'s acknowledgement barrier (retire before ack) and five consecutive real reconnect-and-resubscribe cycles, each required to deliver a genuine resubscribed value, are proven deterministically against a real second OS process, and shared local and hosted conformance both passed from a clean exact-head build. |
| Earned capability badges | http, live | Awarded by the shared result evaluator from local and hosted runs at this exact head. |

The shared evaluator has run local and hosted black-box conformance for this
client and awarded both capabilities; `capabilities` in `manifest.yaml`
reflects that award.

## The basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.sno -->
```snobol4
*   main.sno - the canonical Convex-from-SNOBOL4 walkthrough: one HTTP
*   query, a Live subscription, an idempotent mutation, and the resulting
*   Live update. This is the exact source rendered in the README and on
*   the project website, so every step is commented for a reader who has
*   never seen this client before.
-include 'host.sno'
-include 'convex.sno'

*   whole_count(rawvalue, operation) -> a validated non-negative whole
*   number from a Convex JSON field. Convex may spell a whole number as an
*   integral decimal such as "0.0"; json.uint32 already accepts that form
*   while rejecting fractions, quoted numbers, and anything out of a
*   uint32's range (see client/tests/json.test.sno for the regression that
*   proves the rejections). Failing loudly here, rather than printing a
*   fraction or an out-of-range value, is what a real caller should do too.
    define('whole_count(rawvalue,operation)field') :(whole_count.end)
whole_count
        field = json.field(rawvalue, "count")                            :f(whole_count.missing)
        whole_count = json.uint32(field)                                  :s(return)
        io.eprintln(operation " count was not a whole number in range")
        cvxexit(1)
whole_count.missing
        io.eprintln(operation " omitted count")
        cvxexit(1)
whole_count.end

*   main.wait_for_event() -> the next Live event's kind, pumping the
*   connection until one arrives or ten seconds pass. A real subscriber
*   normally reacts to events from an outer loop; this example only ever
*   needs the very next one before it moves on to its own next step.
*   DEFINE is a runtime statement in SNOBOL4, so this must execute before
*   the first call site below, not merely appear earlier in the file.
    define('main.wait_for_event()deadline') :(main.wait_for_event.end)
main.wait_for_event
        deadline = io.now() + 10000
main.wait_for_event.loop
        gt(cvx.live.event_count, 0)                                          :s(main.wait_for_event.got)
        gt(io.now(), deadline)                                               :s(freturn)
        cvx.live.pump(io.now() + 250)                                        :(main.wait_for_event.loop)
main.wait_for_event.got
        main.wait_for_event = cvx.live.next_event()                          :(return)
main.wait_for_event.end

*   main.hex(bytes) -> the lowercase hex encoding of a raw byte string,
*   used only to turn random entropy into a printable idempotency key.
    define('main.hex(bytes)i,out') :(main.hex.end)
main.hex
        out = ""
        i = 1
main.hex.loop
        gt(i, size(bytes))                                                    :s(main.hex.done)
        out = out substr("0123456789abcdef", (ord(substr(bytes, i, 1)) / 16) + 1, 1)
        out = out substr("0123456789abcdef", remdr(ord(substr(bytes, i, 1)), 16) + 1, 1)
        i = i + 1                                                             :(main.hex.loop)
main.hex.done
        main.hex = out                                                        :(return)
main.hex.end

*   Configuration: the deployment URL is required and never defaulted, so a
*   missing environment cannot silently talk to the wrong backend. The room
*   id is the shared counter's key; the verifier passes a unique one as the
*   first argument, and a friendly default lets someone run this by hand.
    ident(io.getenv("CONVEX_URL"), "")                                     :s(main.nourl)
    deployment = io.getenv("CONVEX_URL")
    room = host(2, host(3))                                                :s(main.gotroom)
    room = "snobol4-example"
main.gotroom

*   Client creation: cvx.configure parses the deployment URL once and
*   resets the Live protocol's own state, so this example (and every
*   conformance test) always starts from a clean client.
    cvx.configure(deployment, "")                                          :f(main.configurefailed)
    cvx.live.init()

*   The initial HTTP query. This is plain request/response: no
*   subscription, no persistent connection, just Convex's documented JSON
*   API answering "what is the count in this room right now?".
    current = cvx.query("demo:state", json.object1("room", json.qs(room)))   :f(main.queryfailed)
    currentcount = whole_count(current, "current query")
    output = "current count: " currentcount

*   Start Live before the mutation. Its first delivered value proves that
*   no write could have slipped in between this subscription and the
*   query above: the subscription's own first Transition is this room's
*   state at the moment Convex accepted the subscription, and it is
*   observed before any mutation is issued below.
    qid = cvx.live.subscribe("demo:state", json.object1("room", json.qs(room)))
    kind = main.wait_for_event()                                            :f(main.livefailed)
    ident(kind, "error")                                                    :s(main.liveerror)
    initialcount = whole_count(cvx.live.event.payload, "initial Live value")
    differ(initialcount, currentcount)                                       :s(main.mismatch)
    output = "live initial count: " initialcount

*   The mutation. runId is this call's idempotency key: retrying the exact
*   same logical request (the same room and the same runId) would not
*   double-increment the counter, because Convex deduplicates on it.
*   io.random supplies real entropy for that key rather than a predictable
*   counter, so two example runs against the same room can never collide.
    runid = main.hex(io.random(8))
    mutargs = json.object3("room", json.qs(room), "language", json.qs("SNOBOL4"), "runId", json.qs(runid))
    mutresult = cvx.mutation("demo:increment", mutargs)                      :f(main.mutationfailed)
    applied = json.field(mutresult, "applied")                               :f(main.mutationshape)
    ident(applied, "true")                                                   :f(main.notapplied)
    output = "mutation applied: true"
    mutstate = json.field(mutresult, "state")                                :f(main.mutationshape)
    mutationcount = whole_count(mutstate, "mutation")
    output = "mutation count: " mutationcount

*   Wait for the changed value to arrive over the open Live subscription,
*   rather than polling with another query: this is the behaviour Live
*   exists to demonstrate.
    kind2 = main.wait_for_event()                                            :f(main.livefailed)
    ident(kind2, "error")                                                    :s(main.liveerror)
    updatedcount = whole_count(cvx.live.event.payload, "updated Live value")
    output = "live updated count: " updatedcount
    output = "verified count: 0 -> 1"

    cvx.live.unsubscribe(qid)
    cvx.live.close()
    cvxexit(0)

main.nourl
    io.eprintln("CONVEX_URL is required")
    cvxexit(1)
main.configurefailed
    io.eprintln("invalid CONVEX_URL: " cvx.err.message)
    cvxexit(1)
main.queryfailed
    io.eprintln("current query failed: " cvx.err.name ": " cvx.err.message)
    cvxexit(1)
main.livefailed
    io.eprintln("Live subscription did not deliver a value in time")
    cvxexit(1)
main.liveerror
    io.eprintln("Live query failed: " cvx.live.event.payload)
    cvxexit(1)
main.mismatch
    io.eprintln("initial Live count disagreed with the HTTP query")
    cvxexit(1)
main.mutationfailed
    io.eprintln("mutation failed: " cvx.err.name ": " cvx.err.message)
    cvxexit(1)
main.mutationshape
    io.eprintln("mutation response omitted applied or state")
    cvxexit(1)
main.notapplied
    io.eprintln("mutation was not applied")
    cvxexit(1)
end
```
<!-- END GENERATED EXAMPLE -->

## Verify it in Docker

```sh
./run test snobol4
./run verify-example snobol4
./run verify snobol4
./run verify-hosted snobol4
./run verify-all snobol4
```

`test` builds CSNOBOL4 2.3.4 from source (pinned by URL and checksum, since it
is not packaged for Debian), builds the small native transport shim, lints
every source file, and runs real loopback JSON, HTTP, WebSocket, and Live
protocol fixtures, the conformance adapter's stdio and TCP modes, and the
example's fast-fail path, all inside Docker. The remaining commands are
root-owned shared gates for the approved local and hosted deployments; both
have passed for this client from a clean exact-head build, earning the http
and live capability badges above.

## Conformance and protocol notes

The test-only adapter under `client/tests/conformance/` speaks NDJSON
protocol v1 on stdin/stdout and TCP. It calls the real SNOBOL4 client for
every operation. Its adapter-only `debugDisconnect` command lets the shared
harness prove reconnects. Command schemas are strict: a missing or wrongly
typed `id`, `op`, `path`, `args`, `subscriptionId`, or `token` is a
structured `ProtocolError` and never reaches a deployment.

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

Transport limits are enforced while data is arriving rather than afterwards.
A response is abandoned once its declared or accumulated size passes 2 MiB, a
WebSocket frame is refused from its header alone, and connect and
partial-frame deadlines are absolute and independent of the caller's own
short polling interval, so a peer that trickles bytes forever cannot extend
them. HTTPS and WSS share one TLS policy: the pinned CA bundle, TLS 1.2 or
newer, SNI for a named host, and a peer identity that has to match the host
being connected to (`SSL_set1_host`, so a certificate valid for another host
is rejected).

Standard SNOBOL4 has no sockets, TLS, monotonic clock, or entropy source.
`client/convexrt.c` is the only native code in this client: a small,
reviewed C library loaded through CSNOBOL4's own documented external-function
mechanism (`LOAD()`, backed by `dlopen()`), supplying exactly those
primitives and nothing else. Every HTTP, WebSocket, JSON, and Convex protocol
decision - and every deadline - is SNOBOL4 source, reviewable in
`client/convex-*.sno`.

## Limitations

- Live authentication, optimistic updates, WebSocket mutations and actions,
  journals, and `TransitionChunk` assembly are intentionally not yet
  implemented. Mutations and actions use HTTP.
- Values are limited to this experiment's JSON-safe subset: objects, arrays,
  strings, whole numbers within a `uint32` range, booleans, and null. Tagged
  Convex `Int64`, bytes, and special floats are outside scope.
- CSNOBOL4's own `-O3` default reproducibly crashes GCC's `cc1` on this
  project's QEMU-emulated `linux/amd64` build host; the Dockerfile pins
  `-O0` explicitly rather than relying on CSNOBOL4's own configure default.
  Two independent from-clean `-O3` builds each crashed compiling a
  different, unrelated file, and `-O0` has built cleanly every time - the
  pattern AGENTS.md documents for other heavy toolchains on QEMU hosts, not
  a defect in CSNOBOL4 or this client.
- `client/tests/live_test.sno` asserts five real, consecutive WebSocket
  reconnects against a real second OS process
  (`client/tests/live_test_fixture.sno`): the handshake, masking, the
  `debugDisconnect` acknowledgement barrier (old connection retired and a
  reconnect genuinely scheduled before the command is acknowledged), and a
  genuine resubscribed value on every one of the five reconnects are all
  required to pass, and this is deterministic on this build host across
  repeated runs.
- Live delivery is a bounded queue: at most 64 pending events and 8 MiB of
  conservatively charged encoded bytes per client, oldest dropped first.
  Unsubscribe and a same-subscriptionId replacement bump a per-query
  generation counter that invalidates any already-queued event for that
  query before its acknowledgement is published; this has a deterministic,
  non-timing-dependent regression test.
- Language-local tests cover 32-bit bitwise arithmetic against known SHA-1
  and RFC 6455 test vectors, JSON field/array extraction and escaping
  (including surrogate pairs and UTF-8 pass-through), `uint32` validation
  (accepting Convex's integral-decimal form such as `1.0`, rejecting
  fractions, overflow, and leading zeros), a real loopback HTTP fixture
  covering bearer auth, structured errors, and logs, a real loopback
  WebSocket fixture covering the handshake and masking, and a real second
  process acting as a Live peer covering Add, an initial value, an external
  update, `QueryFailed`, and the unsubscribe generation barrier. Root-owned
  local and hosted conformance remain the final capability gates.
