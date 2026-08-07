# Convex from COBOL

A small Convex client written in GnuCOBOL. It reads a shared counter over
Convex's HTTP API, subscribes to the same query over a WebSocket, increments
the counter once, and watches the new value arrive on the subscription.

This is an educational demonstration, not an official Convex SDK and not a
package intended for use in production. It exists to answer one question:
can a language from 1959 hold up its end of a modern reactive protocol?

Mostly, yes. JSON, HTTP/1.1, the RFC 6455 framing, and every piece of Convex
behaviour are written in COBOL. A small reviewed C file supplies only the four
things the COBOL runtime genuinely cannot: a monotonic clock, a cryptographic
random source, a SHA-1 digest, and byte movement over TCP and TLS.

## Start here

[`examples/basics/main.cbl`](examples/basics/main.cbl) is the whole journey in
one program. It queries the counter, subscribes *before* mutating so the
increment cannot slip past unobserved, applies the mutation with an
idempotency key, and prints its verification line only once HTTP and Live
agree on the same `0 -> 1` story.

## What works

Nothing is proven yet. The source is complete; it has never been compiled.

| Capability | Status |
| --- | --- |
| HTTP query, mutation, action | Written, never executed |
| Live subscriptions over WebSocket | Written, never executed |
| TLS with certificate verification | Written, never executed |
| NDJSON adapter protocol v1 | Written, never executed |
| Parser-level unit tests | Written, never executed |
| Socket-level hostile-peer tests | Written, never executed |
| Stopped-reader memory accounting | Written, never executed |
| Earned capability badges | None |

Every row above stays unproven until the Docker gates in
[Verifying](#verifying) run. Compilation alone would not change the table
either; only the shared example and conformance runs can.

## The canonical example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.cbl -->
```cobol
>>SOURCE FORMAT IS FREE
*> ==================================================================
*> Convex from COBOL: the shared counter journey, 0 -> 1.
*>
*> The program queries a room's counter over HTTP, subscribes to the
*> same query over Live, increments it once, and proves that Live
*> delivered the new value. It prints the verification line only after
*> every operation agrees.
*> ==================================================================
IDENTIFICATION DIVISION.
PROGRAM-ID. CONVEX-EXAMPLE.

DATA DIVISION.
WORKING-STORAGE SECTION.
COPY "cvx-limits.cpy".
COPY "cvx-client.cpy".

01 WS-URL                   PIC X(1024).
01 WS-URL-LEN               BINARY-LONG.
01 WS-ROOM                  PIC X(256).
01 WS-ROOM-LEN              BINARY-LONG.
01 WS-CLIENTV               PIC X(64) VALUE "cobol-0.1.0".
01 WS-CLIENTV-LEN           BINARY-LONG VALUE 11.

01 WS-PATH                  PIC X(256).
01 WS-PATH-LEN              BINARY-LONG.
01 WS-ARGS                  PIC X(8192).
01 WS-ARGS-LEN              BINARY-LONG.
01 WS-ROOM-JSON             PIC X(1024).
01 WS-ROOM-JSON-LEN         BINARY-LONG.
01 WS-RUNID-JSON            PIC X(128).
01 WS-RUNID-JSON-LEN        BINARY-LONG.

01 WS-RUNID-RAW             PIC X(16).
01 WS-RUNID-HEX             PIC X(32).
01 WS-RUNID-HEX-LEN         BINARY-LONG.

01 WS-SUBIX                 BINARY-LONG.
01 WS-STATUS                BINARY-LONG.
01 WS-RC                    BINARY-LONG.
01 WS-OP                    BINARY-LONG.
01 WS-TIMEOUT               BINARY-LONG VALUE 200.
01 WS-NOW                   BINARY-DOUBLE.
01 WS-DEADLINE              BINARY-DOUBLE.
01 WS-SIXTEEN               BINARY-LONG VALUE 16.

*> Every call this example makes into the client (query, subscribe,
*> mutate, and each Live pump) has already returned by the time this
*> program parses CVX-R-VALUE on its own behalf, so reusing slot 1
*> (WS-SLOT-HTTP in convex.cbl) here cannot collide with anything the
*> client itself still has in flight.
01 WS-SLOT                  BINARY-LONG VALUE 1.
01 WS-NODE                  BINARY-LONG.
01 WS-CHILD                 BINARY-LONG.
01 WS-KEY                   PIC X(64).
01 WS-KEY-LEN               BINARY-LONG.
01 WS-BOOLVAL               BINARY-DOUBLE.

01 WS-CURRENT               BINARY-DOUBLE.
01 WS-INITIAL               BINARY-DOUBLE.
01 WS-MUTCOUNT              BINARY-DOUBLE.
01 WS-UPDATED               BINARY-DOUBLE.
01 WS-EXPECTED              BINARY-DOUBLE.
01 WS-NUM                   BINARY-DOUBLE.
01 WS-NUMTEXT               PIC -(18)9.
01 WS-FROMTEXT              PIC -(18)9.
01 WS-TOTEXT                PIC -(18)9.
01 WS-STAGE                 PIC X(64).

PROCEDURE DIVISION.
MAIN-PARAGRAPH.
    *> ---------------------------------------------------------------
    *> Configuration comes from the container, never from a literal.
    *> The verifier passes a unique room as the first argument so
    *> concurrent runs cannot collide on one counter.
    *> ---------------------------------------------------------------
    MOVE SPACES TO WS-URL
    ACCEPT WS-URL FROM ENVIRONMENT "CONVEX_URL"
    COMPUTE WS-URL-LEN = FUNCTION LENGTH(FUNCTION TRIM(WS-URL))
    IF WS-URL = SPACES
        MOVE "CONVEX_URL is required" TO WS-STAGE
        PERFORM FAIL-AND-STOP
    END-IF

    MOVE SPACES TO WS-ROOM
    DISPLAY 1 UPON ARGUMENT-NUMBER
    ACCEPT WS-ROOM FROM ARGUMENT-VALUE
        ON EXCEPTION MOVE "cobol-example" TO WS-ROOM
    END-ACCEPT
    IF WS-ROOM = SPACES
        MOVE "cobol-example" TO WS-ROOM
    END-IF
    COMPUTE WS-ROOM-LEN = FUNCTION LENGTH(FUNCTION TRIM(WS-ROOM))

    *> Create one client for the deployment. It owns both the HTTP
    *> endpoint and, later, the Live WebSocket.
    CALL "cvx-client-init" USING WS-URL WS-URL-LEN WS-CLIENTV
        WS-CLIENTV-LEN CVX-ERROR WS-STATUS
    IF WS-STATUS NOT = CVX-OK
        MOVE "client configuration" TO WS-STAGE
        PERFORM FAIL-AND-STOP
    END-IF

    *> The room name is JSON encoded once and reused as the argument
    *> object for both the query and the subscription.
    CALL "cvx-json-esc-string" USING WS-ROOM WS-ROOM-LEN
        WS-ROOM-JSON WS-ROOM-JSON-LEN
    MOVE SPACES TO WS-ARGS
    MOVE 1 TO WS-ARGS-LEN
    STRING
        '{"room":' DELIMITED SIZE
        WS-ROOM-JSON(1:WS-ROOM-JSON-LEN) DELIMITED SIZE
        '}' DELIMITED SIZE
        INTO WS-ARGS
        WITH POINTER WS-ARGS-LEN
    END-STRING
    SUBTRACT 1 FROM WS-ARGS-LEN

    *> ---------------------------------------------------------------
    *> Read the current counter over Convex's HTTP query endpoint.
    *> ---------------------------------------------------------------
    MOVE "demo:state" TO WS-PATH
    MOVE 10 TO WS-PATH-LEN
    MOVE 1 TO WS-OP
    CALL "cvx-client-call" USING WS-OP WS-PATH WS-PATH-LEN
        WS-ARGS WS-ARGS-LEN CVX-RESULT CVX-ERROR WS-STATUS
    IF WS-STATUS NOT = CVX-OK
        MOVE "initial query" TO WS-STAGE
        PERFORM FAIL-AND-STOP
    END-IF
    PERFORM DECODE-COUNT
    MOVE WS-NUM TO WS-CURRENT
    MOVE WS-CURRENT TO WS-NUMTEXT
    DISPLAY "current count: " FUNCTION TRIM(WS-NUMTEXT)

    *> ---------------------------------------------------------------
    *> Subscribe before mutating. Starting Live first is what
    *> guarantees the increment cannot slip past unobserved.
    *> ---------------------------------------------------------------
    CALL "cvx-live-subscribe" USING WS-PATH WS-PATH-LEN
        WS-ARGS WS-ARGS-LEN WS-SUBIX CVX-ERROR WS-STATUS
    IF WS-STATUS NOT = CVX-OK
        MOVE "subscribe" TO WS-STAGE
        PERFORM FAIL-AND-STOP
    END-IF

    *> The first Live delivery hydrates the same value the query just
    *> returned, which is how the two views are shown to agree.
    MOVE "initial Live value" TO WS-STAGE
    PERFORM WAIT-FOR-DELIVERY
    PERFORM DECODE-COUNT
    MOVE WS-NUM TO WS-INITIAL
    IF WS-INITIAL NOT = WS-CURRENT
        MOVE "initial Live value disagreed with HTTP" TO WS-STAGE
        PERFORM FAIL-AND-STOP
    END-IF
    MOVE WS-INITIAL TO WS-NUMTEXT
    DISPLAY "live initial count: " FUNCTION TRIM(WS-NUMTEXT)

    *> ---------------------------------------------------------------
    *> Increment once. runId is the mutation's idempotency key: a
    *> retry with the same value returns the first result instead of
    *> counting twice, which is why it is generated per run rather
    *> than per attempt.
    *> ---------------------------------------------------------------
    CALL "cvx_random_bytes" USING
        BY REFERENCE WS-RUNID-RAW
        BY VALUE WS-SIXTEEN
        RETURNING WS-RC
    IF WS-RC NOT = CVX-OK
        MOVE "could not generate a run identifier" TO WS-STAGE
        PERFORM FAIL-AND-STOP
    END-IF
    CALL "cvx-hex-encode" USING WS-RUNID-RAW WS-SIXTEEN
        WS-RUNID-HEX WS-RUNID-HEX-LEN
    CALL "cvx-json-esc-string" USING WS-RUNID-HEX WS-RUNID-HEX-LEN
        WS-RUNID-JSON WS-RUNID-JSON-LEN
    MOVE SPACES TO WS-ARGS
    MOVE 1 TO WS-ARGS-LEN
    STRING
        '{"room":' DELIMITED SIZE
        WS-ROOM-JSON(1:WS-ROOM-JSON-LEN) DELIMITED SIZE
        ',"language":"COBOL","runId":' DELIMITED SIZE
        WS-RUNID-JSON(1:WS-RUNID-JSON-LEN) DELIMITED SIZE
        '}' DELIMITED SIZE
        INTO WS-ARGS
        WITH POINTER WS-ARGS-LEN
    END-STRING
    SUBTRACT 1 FROM WS-ARGS-LEN

    MOVE "demo:increment" TO WS-PATH
    MOVE 14 TO WS-PATH-LEN
    MOVE 2 TO WS-OP
    CALL "cvx-client-call" USING WS-OP WS-PATH WS-PATH-LEN
        WS-ARGS WS-ARGS-LEN CVX-RESULT CVX-ERROR WS-STATUS
    IF WS-STATUS NOT = CVX-OK
        MOVE "mutation" TO WS-STAGE
        PERFORM FAIL-AND-STOP
    END-IF

    *> The mutation reports whether it applied and echoes the new
    *> state. Both are checked before anything is printed.
    CALL "cvx-json-parse" USING WS-SLOT CVX-R-VALUE CVX-R-VALUE-LEN
        WS-STATUS
    IF WS-STATUS NOT = CVX-OK
        MOVE "mutation result was not JSON" TO WS-STAGE
        PERFORM FAIL-AND-STOP
    END-IF
    CALL "cvx-json-root" USING WS-SLOT WS-NODE
    MOVE "applied" TO WS-KEY
    MOVE 7 TO WS-KEY-LEN
    CALL "cvx-json-member" USING WS-SLOT WS-NODE WS-KEY WS-KEY-LEN
        WS-CHILD
    CALL "cvx-json-bool" USING WS-SLOT WS-CHILD WS-BOOLVAL WS-STATUS
    IF WS-STATUS NOT = CVX-OK OR WS-BOOLVAL NOT = 1
        MOVE "mutation was not applied" TO WS-STAGE
        PERFORM FAIL-AND-STOP
    END-IF
    MOVE "state" TO WS-KEY
    MOVE 5 TO WS-KEY-LEN
    CALL "cvx-json-member" USING WS-SLOT WS-NODE WS-KEY WS-KEY-LEN
        WS-CHILD
    PERFORM DECODE-COUNT-AT-NODE
    MOVE WS-NUM TO WS-MUTCOUNT
    COMPUTE WS-EXPECTED = WS-CURRENT + 1
    IF WS-MUTCOUNT NOT = WS-EXPECTED
        MOVE "mutation returned an unexpected count" TO WS-STAGE
        PERFORM FAIL-AND-STOP
    END-IF
    DISPLAY "mutation applied: true"
    MOVE WS-MUTCOUNT TO WS-NUMTEXT
    DISPLAY "mutation count: " FUNCTION TRIM(WS-NUMTEXT)

    *> ---------------------------------------------------------------
    *> Receive the increment through Live rather than polling HTTP.
    *> ---------------------------------------------------------------
    MOVE "updated Live value" TO WS-STAGE
    PERFORM WAIT-FOR-DELIVERY
    PERFORM DECODE-COUNT
    MOVE WS-NUM TO WS-UPDATED
    IF WS-UPDATED NOT = WS-EXPECTED
        MOVE "updated Live value disagreed with the mutation"
            TO WS-STAGE
        PERFORM FAIL-AND-STOP
    END-IF
    MOVE WS-UPDATED TO WS-NUMTEXT
    DISPLAY "live updated count: " FUNCTION TRIM(WS-NUMTEXT)

    *> Remove the subscription and hang up the socket politely.
    CALL "cvx-live-unsubscribe" USING WS-SUBIX CVX-ERROR WS-STATUS
    CALL "cvx-live-close" USING WS-STATUS

    *> Printed last, and only because HTTP, the mutation, and both
    *> Live deliveries agreed on the same journey.
    MOVE WS-CURRENT TO WS-FROMTEXT
    MOVE WS-UPDATED TO WS-TOTEXT
    DISPLAY "verified count: " FUNCTION TRIM(WS-FROMTEXT)
        " -> " FUNCTION TRIM(WS-TOTEXT)
    STOP RUN.

*> Pump the Live owner until a delivery for this subscription arrives.
*> COBOL has no threads, so the caller drives the transport; the pump
*> is the only routine that touches the socket.
WAIT-FOR-DELIVERY.
    CALL "cvx_now_ms" USING BY REFERENCE WS-NOW RETURNING WS-RC
    COMPUTE WS-DEADLINE = WS-NOW + 20000
    PERFORM UNTIL 1 = 2
        CALL "cvx-live-next" USING WS-SUBIX CVX-RESULT CVX-ERROR
            WS-STATUS
        IF WS-STATUS = CVX-OK
            IF CVX-R-IS-ERROR = 1
                PERFORM FAIL-AND-STOP
            END-IF
            EXIT PERFORM
        END-IF
        CALL "cvx-live-pump" USING WS-TIMEOUT WS-STATUS
        CALL "cvx_now_ms" USING BY REFERENCE WS-NOW RETURNING WS-RC
        IF WS-NOW > WS-DEADLINE
            PERFORM FAIL-AND-STOP
        END-IF
    END-PERFORM.

*> Convex may encode a whole count as 0 or 0.0. cvx-json-int accepts
*> both and refuses anything genuinely fractional or out of range, so
*> a surprising value fails the example instead of being truncated.
DECODE-COUNT.
    CALL "cvx-json-parse" USING WS-SLOT CVX-R-VALUE CVX-R-VALUE-LEN
        WS-STATUS
    IF WS-STATUS NOT = CVX-OK
        PERFORM FAIL-AND-STOP
    END-IF
    CALL "cvx-json-root" USING WS-SLOT WS-NODE
    MOVE WS-NODE TO WS-CHILD
    PERFORM DECODE-COUNT-AT-NODE.

DECODE-COUNT-AT-NODE.
    MOVE "count" TO WS-KEY
    MOVE 5 TO WS-KEY-LEN
    CALL "cvx-json-member" USING WS-SLOT WS-CHILD WS-KEY WS-KEY-LEN
        WS-NODE
    IF WS-NODE = 0
        PERFORM FAIL-AND-STOP
    END-IF
    CALL "cvx-json-int" USING WS-SLOT WS-NODE WS-NUM WS-STATUS
    IF WS-STATUS NOT = CVX-OK OR WS-NUM < 0
        PERFORM FAIL-AND-STOP
    END-IF.

*> Diagnostics go to stderr. Stdout carries only the six verified
*> lines, because the shared verifier compares it byte for byte.
FAIL-AND-STOP.
    DISPLAY "COBOL example failed at " FUNCTION TRIM(WS-STAGE)
        UPON SYSERR
    IF CVX-E-MSG-LEN > 0
        DISPLAY "  " CVX-E-MSG(1:CVX-E-MSG-LEN) UPON SYSERR
    END-IF
    CALL "cvx-live-close" USING WS-STATUS
    MOVE 1 TO RETURN-CODE
    STOP RUN.

END PROGRAM CONVEX-EXAMPLE.
```
<!-- END GENERATED EXAMPLE -->

## Verifying

```sh
./run test cobol             # lint, unit tests, both executables, amd64
./run verify-example cobol   # the example above, against a unique room
./run verify cobol           # example plus shared black-box conformance
./run verify-hosted cobol    # the same, against the hosted drift target
./run verify-all cobol       # both deployment profiles, one built image
```

`test` proves the source compiles and that the parser-level tests pass inside
a genuine `linux/amd64` image. `verify-example` proves the example actually
talks to Convex and produces the expected values. `verify` adds the shared
conformance suite. Only the shared result evaluator awards badges.

## How it fits together

| File | Responsibility |
| --- | --- |
| `client/convex.cbl` | Client API, HTTP calls, the Live owner state machine |
| `client/convex-json.cbl` | Bounded JSON reader and writer |
| `client/convex-http.cbl` | HTTP/1.1 request and response framing |
| `client/convex-ws.cbl` | RFC 6455 handshake, framing, and masking |
| `client/convex-util.cbl` | base64, hex, UTF-8, Convex timestamp codec |
| `client/convex-native.c` | Clock, CSPRNG, SHA-1, TCP and TLS byte movement |
| `client/tests/conformance/adapter.cbl` | Test-only NDJSON adapter |
| `client/tests/fixtures/convex-fixture.c` | Test-only hostile peers |

### One owner, no threads

COBOL has no threads, so this client is a cooperative single owner rather than
a worker with mutexes. Exactly one routine, `cvx-live-pump`, ever touches the
socket: it drains queued work, reads at most one message, and returns. Callers
reach the transport only by pumping. The "one worker owns the socket" rule the
Live design needs therefore holds by construction rather than by discipline.

The cost is that the caller must pump. The example and the adapter both do
this in their main loops, and it is why the adapter can interleave controller
input, the Live owner, and delivery forwarding without any locking.

### Memory is decided at link time

Every buffer lives in `WORKING-STORAGE`. The client never allocates, so its
memory ceiling is a property of the binary rather than of what a peer sends.
The Docker test stage reads `.bss` out of the linked adapter and fails if it
approaches the shared 128 MiB limit. Declared lengths — `Content-Length`, a
chunk size, a WebSocket payload length — are all range-checked while they are
still just numbers, before any byte they describe is accepted.

### Live delivery buffering

The client owns a bounded queue, deliberately, rather than relying on a
runtime mailbox. It is capped by both entry count (16) and a byte budget, and
the oldest delivery is dropped when a slow consumer lets it fill. An
unchanged rehydration after a reconnect is suppressed by a per-subscription
content signature, so a reconnect that re-delivers the same value stays
invisible to the consumer.

### Testing against a hostile peer

Framing bugs do not show up on a well-behaved connection, so the tests
drive the real client through real sockets with a peer that misbehaves
on purpose.

Two fixture shapes, chosen deliberately:

- A **socketpair preloaded with exact bytes**. The client reads through
  its normal code path while the test controls precisely how much is
  available at each moment. No timing is involved, so these cases are
  perfectly reproducible. This covers chunked and oversized bodies,
  conflicting framing headers, truncated responses, header floods, and
  every malformed WebSocket frame.
- A **forked loopback peer** replaying a byte script, used only where
  timing is the subject: dribbling one byte at a time, and stalling
  mid-message past the client's deadline.

The resumability case deserves a mention because it is the one that
catches the bug this parser design exists to prevent. A partial frame
is made readable, the poll is allowed to time out, the remainder is
pushed, and the next poll must return the complete message. A parser
that restarted at a guessed frame boundary would fail it.

For Live, a scripted peer completes a real RFC 6455 handshake, reads
the client's `Connect` and `ModifyQuerySet` frames, and answers session
N with count N. Five forced reconnects therefore produce five distinct
values, so a genuine rehydration is distinguishable from a suppressed
unchanged one. The peer counts how many sessions saw the client resend
its `Add` and reports that as its exit status, which is how the
query-set rebuild is proven rather than assumed.

The fixture translation unit is linked only into test binaries. The
build asserts that no `cvx_fixture_` symbol survives into the shipped
`convex-example` or `convex-adapter`.

## Protocol notes

Live targets the pinned `convex-rs-0.10.4-unversioned-sync` profile at
`/api/sync`, described in [`docs/protocol-profiles.md`](../docs/protocol-profiles.md).
Convex's realtime protocol is internal and undocumented; this client tracks
one inspected revision and treats anything else as drift.

The WebSocket parser is resumable by construction. Raw bytes accumulate in a
buffer and a frame is decoded only once it is entirely present, so a read that
times out halfway through a frame simply leaves the bytes where they are.
Parser state is never rewound to a guessed frame boundary.

`debugDisconnect` is an adapter-only command used by the shared controller to
force real reconnects. It is not part of the client API.

## Limitations

- **Never compiled or executed.** The GnuCOBOL package pin in the Dockerfile
  is unverified, and no Docker gate has run.
- A stopped controller stalls the adapter. Events are written
  synchronously with no output queue, so backpressure lands in the
  kernel pipe rather than in the process.
- Live authentication, WebSocket mutations and actions, optimistic updates,
  and mutation replay are out of scope.
- `TransitionChunk` assembly is deferred; receiving one retires the
  connection as profile drift.
- Live values cover the JSON-safe subset. Tagged Convex value types are
  deferred.
- JSON numbers in exponent form round-trip verbatim but are not reduced to
  integers, so they cannot be read as counts.
- IPv6 literal hosts in the deployment URL are not parsed.
