# SNOBOL4

SNOBOL began at Bell Labs in 1962 as a language for string and symbolic
processing. SNOBOL4 followed from a major redesign begun in 1966, adding the
pattern language, tables, arrays, structures, and numeric types that define it
today. Its statement-level success and failure branches will look unusual to a
TypeScript, C#, Java, or C developer. The [official history](https://www.regressive.org/snobol4/history.html)
and [SNOBOL4 tutorial](https://www.regressive.org/snobol4/docs/burks/tutorial/contents.htm)
are good introductions.

This demonstration uses [CSNOBOL4](https://www.regressive.org/snobol4/csnobol4/),
Phil Budne's open source C port of the original Bell Labs Macro SNOBOL4. The
project remains a small, specialist ecosystem centred on text processing and
pattern matching, but CSNOBOL4 2.3.4 makes the full language practical on a
modern Unix-like system. This client is an educational, unofficial experiment,
not a production SDK, an officially sanctioned Convex client, or a package
intended for publication.

## Getting Started

Start with [`examples/basics/main.sno`](examples/basics/main.sno). It queries a
fresh counter room, subscribes before changing it, applies an idempotent
mutation, and observes the resulting Live update.

From the repository root, run the exact canonical example in its Docker image:

```sh
./run verify-example snobol4
```

Docker supplies the pinned CSNOBOL4 toolchain and an approved test deployment,
so nothing needs to be installed on the host.

## Interesting Parts

### A failed call branches to a label, not a catch block

SNOBOL4 predates exceptions by decades. Every statement can succeed or fail,
and the arrow at the end of a line — `:S(label)` for success, `:F(label)` for
failure — sends control straight to a label on that outcome. There is no
`try`/`catch`; failure is just another kind of goto, wired into the grammar
since the 1966 redesign.

```snobol4
*   TypeScript: try { await client.query(...) } catch (e) { ... }
    cvx.configure(deployment, "")                              :f(configure.failed)
    current = cvx.query("demo:state", args)                    :f(query.failed)
    output = "current count: " current
                                                                :(done)
configure.failed
    output = "invalid deployment configuration"                :(done)
query.failed
    output = cvx.err.name ": " cvx.err.message
done
```

### A pattern match doubles as a type check

Pattern matching is SNOBOL4's signature idea: `SPAN` builds a pattern that
consumes a run of characters from a fixed alphabet, and `RPOS(0)` requires
that run to reach the end of the string. Chained together, they reject
anything that isn't a clean run of digits — no separate type system needed.
This is lifted straight from [`client/convex-json.sno`](client/convex-json.sno),
where it turns a raw JSON number into a validated Convex `uint32`.

```snobol4
json.uint32
        trimmed = json.trim(rawvalue)
*       ... (split off and reject any fractional part first) ...
*   TypeScript: typeof value === "number" && Number.isInteger(value)
        whole span("0123456789") rpos(0)                      :f(freturn)
        eq(size(whole), 1)                                     :s(json.uint32.value)
        differ(substr(whole, 1, 1), "0")                       :f(freturn)
json.uint32.value
        json.uint32 = whole + 0
        le(json.uint32, 4294967295)                            :s(return)
```

A malformed number simply fails the match, which fails the function, which
the caller was already set up to branch on.

### A Live value waits in a queue until you pump for it

This client earns Convex's Live capability, but there's no React runtime
quietly polling on its behalf. `cvx.live.subscribe` opens the subscription
and events queue up in silence until the caller explicitly drives the
connection forward.

```snobol4
*   TypeScript: useQuery(api.demo.state, { room }) reruns your component.
    qid = cvx.live.subscribe("demo:state", args)
wait.loop
        gt(cvx.live.event_count, 0)                            :s(wait.ready)
        cvx.live.pump(io.now() + 250)                          :(wait.loop)
wait.ready
        kind = cvx.live.next_event()
        ident(kind, "value")                                   :f(live.failed)
        count = json.uint32(json.field(cvx.live.event.payload, "count"))
        output = count
```

Reactivity here is a queue you own, not a hook that owns you.

## Status

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Verified | Query, mutation, action, bearer-token lifecycle, structured `FunctionError`/`ProtocolError`/`TransportError` classification, and logs pass a real loopback test suite in Docker, and shared local and hosted conformance both passed from a clean exact-head build. |
| Live | Verified | Subscribe, an initial value, an external update, `QueryFailed`, and the unsubscribe-before-acknowledgement barrier pass a real loopback test suite. `debugDisconnect`'s acknowledgement barrier (retire before ack) and five consecutive real reconnect-and-resubscribe cycles, each required to deliver a genuine resubscribed value, are proven deterministically against a real second OS process, and shared local and hosted conformance both passed from a clean exact-head build. |
| Earned capability badges | http, live | Awarded by the shared result evaluator from local and hosted runs at this exact head. |

The shared evaluator has run local and hosted black-box conformance for this
client and awarded both capabilities; `capabilities` in `manifest.yaml`
reflects that award.

## Example

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

## Implementation Notes

The implementation is native SNOBOL4 for all Convex-specific behaviour. It
builds JSON, HTTP/1.1, RFC 6455 WebSocket frames, SHA-1, base64, and the pinned
Convex Live messages in the `.sno` files under [`client/`](client/). Standard
SNOBOL4 does not provide sockets, verified TLS, a monotonic clock, or operating
system entropy, so [`client/convexrt.c`](client/convexrt.c) supplies only those
low-level primitives through CSNOBOL4's documented `LOAD()` mechanism. It does
not implement HTTP, WebSockets, JSON, or Convex behaviour.

HTTP query, mutation, and action calls use Convex's documented JSON endpoints.
They return the raw JSON value and classify failures as `FunctionError`,
`ProtocolError`, or `TransportError`. Live uses `/api/sync` with the pinned
`convex-rs-0.10.4-unversioned-sync` profile at commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7`. That realtime protocol is not
documented as stable, which is why hosted conformance is part of the evidence.

The Live client has a bounded queue of 64 events and 8 MiB, dropping the oldest
event first when either limit is reached. It also invalidates queued events
before acknowledging an unsubscribe or replacement. Reconnect behaviour is
covered by five consecutive disconnect, reconnect, resubscribe, and delivery
cycles against a separate fixture process.

The repository provides these Docker-only gates:

```sh
./run test snobol4
./run verify-example snobol4
./run verify snobol4
./run verify-hosted snobol4
./run verify-all snobol4
```

`test` builds CSNOBOL4 2.3.4 from source (pinned by URL and checksum, since it
is not packaged for Debian), builds the native transport shim, checks source
style, and runs language-local JSON, HTTP, WebSocket, Live, adapter, and example
tests. The remaining commands are the repository's local, hosted, and combined
shared gates. They have passed for this exact client revision and earned the
HTTP and Live capabilities shown above.

## Known Issues

1. Live authentication, optimistic updates, WebSocket mutations and actions,
   journals, and `TransitionChunk` assembly are not implemented. Mutations and
   actions use HTTP.
2. Values are limited to JSON-safe objects, arrays, strings, `uint32` whole
   numbers, booleans, and null. Tagged Convex `Int64`, bytes, and special floats
   are outside this experiment.
3. CSNOBOL4's default `-O3` build reproducibly crashes GCC's `cc1` on this
   project's QEMU-emulated `linux/amd64` host. The Dockerfile pins `-O0`; the
   observed failures happened in unrelated CSNOBOL4 files before this client's
   source was involved.
4. HTTP responses and individual WebSocket frames are capped at 2 MiB. The
   client also uses absolute connection and partial-frame deadlines, so slow or
   oversized peers fail instead of growing memory use indefinitely.
