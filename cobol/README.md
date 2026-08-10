# COBOL

COBOL is an English-like compiled language designed for business data
processing. CODASYL created it in 1959, drawing partly on Grace Hopper's
FLOW-MATIC. It became a standard language and is still maintained as
[ISO/IEC 1989:2023](https://www.iso.org/standard/74527.html). Its present-day
niche is the long-lived transaction and administrative software used by banks,
insurers, governments, and other large organisations. This implementation uses
[GnuCOBOL](https://gnucobol.sourceforge.io/), which compiles COBOL through C to
a native executable. [IBM's COBOL overview](https://www.ibm.com/think/topics/cobol)
has a concise history and a current view of where the language is used.

This is an educational demonstration, not an official Convex SDK and not a
package intended for production use.

## Getting Started

Start with [`examples/basics/main.cbl`](examples/basics/main.cbl). It reads a
room's counter, starts a Live subscription before changing the value, performs
one idempotent increment, and waits for Live to deliver the result.

From the repository root, run the canonical program in its Docker image against
a unique room on the approved test deployment:

```sh
./run verify-example cobol
```

## Interesting Parts

### Objects become fixed records and explicit JSON text

In React, generated bindings give the argument and result their TypeScript
shapes. This COBOL client instead accepts JSON in a fixed buffer and returns a
raw JSON span. The program tracks every meaningful length, then asks its own
JSON reader for the `count` member.

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function Counter() {
  const state = useQuery(api.demo.state, { room: "interesting-parts" });
  // api.demo.state is generated, so state.count is type-safe here.
  return <p>{state?.count ?? "Loading..."}</p>;
}
```

**COBOL**

```cobol
DATA DIVISION.
WORKING-STORAGE SECTION.
COPY "cvx-limits.cpy".
COPY "cvx-client.cpy".
01 URL-BUFFER       PIC X(1024).
01 URL-LENGTH       BINARY-LONG.
01 CLIENT-VERSION   PIC X(64) VALUE "cobol-readme".
01 CLIENT-V-LENGTH  BINARY-LONG VALUE 12.
01 FUNCTION-PATH    PIC X(256) VALUE "demo:state".
01 PATH-LENGTH      BINARY-LONG VALUE 10.
*> The Convex argument object is JSON text plus its used length.
01 ARGUMENTS-JSON   PIC X(8192) VALUE '{"room":"interesting-parts"}'.
01 ARGUMENTS-LENGTH BINARY-LONG VALUE 28.
01 OPERATION        BINARY-LONG VALUE 1. *> 1 means HTTP query.
01 STATUS-CODE      BINARY-LONG.
01 JSON-SLOT        BINARY-LONG VALUE 1.
01 ROOT-NODE        BINARY-LONG.
01 COUNT-NODE       BINARY-LONG.
01 MEMBER-NAME      PIC X(64) VALUE "count".
01 MEMBER-LENGTH    BINARY-LONG VALUE 5.
01 COUNT-VALUE      BINARY-DOUBLE.

PROCEDURE DIVISION.
    ACCEPT URL-BUFFER FROM ENVIRONMENT "CONVEX_URL"
    COMPUTE URL-LENGTH = FUNCTION LENGTH(FUNCTION TRIM(URL-BUFFER))

    *> Configure the HTTP endpoint and Live socket owned by this client.
    CALL "cvx-client-init" USING URL-BUFFER URL-LENGTH CLIENT-VERSION
        CLIENT-V-LENGTH CVX-ERROR STATUS-CODE

    *> The result comes back as a raw JSON span in CVX-RESULT.
    CALL "cvx-client-call" USING OPERATION FUNCTION-PATH PATH-LENGTH
        ARGUMENTS-JSON ARGUMENTS-LENGTH CVX-RESULT CVX-ERROR STATUS-CODE

    *> Decode the same state.count value that TypeScript exposes directly.
    CALL "cvx-json-parse" USING JSON-SLOT CVX-R-VALUE CVX-R-VALUE-LEN
        STATUS-CODE
    CALL "cvx-json-root" USING JSON-SLOT ROOT-NODE
    CALL "cvx-json-member" USING JSON-SLOT ROOT-NODE MEMBER-NAME
        MEMBER-LENGTH COUNT-NODE
    CALL "cvx-json-int" USING JSON-SLOT COUNT-NODE COUNT-VALUE STATUS-CODE
    DISPLAY "count: " COUNT-VALUE
```

The two snippets read the same `api.demo.state` result, but they do not have
the same lifecycle. `useQuery` remains subscribed and rerenders the component.
`cvx-client-call` is deliberately a one-off HTTP request.

### React owns reactivity; the COBOL caller pumps it

React subscribes and unsubscribes as the component mounts, changes arguments,
or unmounts. This command-line API makes that ownership visible. The caller
registers a query, checks the bounded delivery queue, and drives the one socket
owner with `cvx-live-pump` until a value arrives.

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function LiveCounter() {
  // React keeps this query subscribed and rerenders after any increment.
  const state = useQuery(api.demo.state, { room: "live-room" });
  return <output>{state?.count ?? "Connecting..."}</output>;
}
```

**COBOL**

```cobol
DATA DIVISION.
WORKING-STORAGE SECTION.
COPY "cvx-limits.cpy".
COPY "cvx-client.cpy".
01 URL-BUFFER       PIC X(1024).
01 URL-LENGTH       BINARY-LONG.
01 CLIENT-VERSION   PIC X(64) VALUE "cobol-readme".
01 CLIENT-V-LENGTH  BINARY-LONG VALUE 12.
01 FUNCTION-PATH    PIC X(256) VALUE "demo:state".
01 PATH-LENGTH      BINARY-LONG VALUE 10.
01 ARGUMENTS-JSON   PIC X(8192) VALUE '{"room":"live-room"}'.
01 ARGUMENTS-LENGTH BINARY-LONG VALUE 20.
01 SUBSCRIPTION-ID  BINARY-LONG.
01 STATUS-CODE      BINARY-LONG.
01 PUMP-TIMEOUT-MS  BINARY-LONG VALUE 200.
01 DELIVERY-READY   BINARY-LONG VALUE 0.
PROCEDURE DIVISION.
    ACCEPT URL-BUFFER FROM ENVIRONMENT "CONVEX_URL"
    COMPUTE URL-LENGTH = FUNCTION LENGTH(FUNCTION TRIM(URL-BUFFER))
    CALL "cvx-client-init" USING URL-BUFFER URL-LENGTH CLIENT-VERSION
        CLIENT-V-LENGTH CVX-ERROR STATUS-CODE

    *> Register demo:state. The returned number identifies this subscription.
    CALL "cvx-live-subscribe" USING FUNCTION-PATH PATH-LENGTH
        ARGUMENTS-JSON ARGUMENTS-LENGTH SUBSCRIPTION-ID CVX-ERROR STATUS-CODE

    PERFORM UNTIL DELIVERY-READY = 1
        *> First take any value already waiting in the bounded queue.
        CALL "cvx-live-next" USING SUBSCRIPTION-ID CVX-RESULT CVX-ERROR
            STATUS-CODE
        IF STATUS-CODE = CVX-OK
            MOVE 1 TO DELIVERY-READY
        ELSE
            *> No delivery yet, so let the sole socket owner do one step.
            CALL "cvx-live-pump" USING PUMP-TIMEOUT-MS STATUS-CODE
        END-IF
    END-PERFORM

    *> CVX-R-VALUE now contains the latest demo:state object as JSON.
    DISPLAY CVX-R-VALUE(1:CVX-R-VALUE-LEN)
    CALL "cvx-live-unsubscribe" USING SUBSCRIPTION-ID CVX-ERROR STATUS-CODE
    CALL "cvx-live-close" USING STATUS-CODE
```

The blocking `next` plus explicit `pump` loop is this client's API choice, not
a general restriction on every COBOL program. It keeps this small client
single-owner and makes cleanup explicit. The complete example also subscribes
before its mutation so it cannot miss the resulting update.

## Status

| Capability | Status |
| --- | --- |
| HTTP query, mutation, action | Earned (`http`) |
| Live subscriptions over WebSocket | Earned (`live`) |
| TLS with certificate verification | Passing, exercised against both backends |
| NDJSON adapter protocol v1 | Passing |
| Parser-level unit tests | Passing |
| Socket-level hostile-peer tests | Passing |
| Stopped-reader memory accounting | Passing |
| Earned capability badges | `http`, `live` |

`http` and `live` were awarded by the shared result evaluator from a clean,
exact-head run of `./run verify-all cobol`: 31/31 conformance checks passed
against both the local self-hosted backend and the dedicated hosted drift
target from the same built image at parent commit `305e9a4`.

## Example

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

## Implementation Notes

This is a native GnuCOBOL client. `convex.cbl` owns the public calls and the
cooperative Live state machine. Separate COBOL modules implement bounded JSON,
HTTP/1.1 framing, WebSocket framing, base64, UTF-8 validation, and Convex
timestamp conversion. Convex-specific behaviour remains in COBOL.

A small reviewed C extension supplies only facilities unavailable from the
GnuCOBOL runtime: monotonic time, cryptographic random bytes, SHA-1, and
deadline-aware TCP and TLS byte movement. GnuCOBOL itself translates the source
through C and links a native executable. The pinned build uses GnuCOBOL
`4.0~early~20200606-6+b1` for `linux/amd64`.

Every substantial buffer is fixed in `WORKING-STORAGE`. The client shares
scratch regions whose lifetimes do not overlap, bounds-checks declared network
lengths before copying data, and holds at most 16 Live deliveries under a byte
budget. When the queue fills, it drops the oldest delivery. A stopped adapter
reader instead applies backpressure through the kernel pipe because the adapter
writes events synchronously and owns no output queue.

COBOL code has no hidden background task here. `cvx-live-pump` alone opens,
reads, writes, reconnects, and changes the query set. Tests exercise fragmented
frames, stalled peers, five reconnects, error recovery, and stale-delivery
barriers. The adapter's `debugDisconnect` hook exists only for those shared
tests and is not part of the educational client API.

You can inspect the language-local Docker checks without running shared
conformance:

```sh
./run test cobol
```

The historical capability evidence came from these separate shared gates:

```sh
./run verify cobol
./run verify-hosted cobol
./run verify-all cobol
```

Only the shared result evaluator awards capabilities.

### Source map

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

Live targets the pinned `convex-rs-0.10.4-unversioned-sync` profile at
`/api/sync`. That realtime protocol is internal and undocumented, so this
client treats unexpected transition shapes as protocol drift rather than
claiming general compatibility.

## Known Issues

1. Live authentication, WebSocket mutations and actions, optimistic updates,
   and mutation replay are deferred. HTTP authentication and HTTP query,
   mutation, and action calls are separate supported paths.
2. `TransitionChunk` assembly is deferred. Receiving one retires the
   connection as profile drift and starts recovery.
3. Live values support the JSON-safe subset, not tagged Convex value types.
4. JSON numbers written with an exponent round-trip as text but are not reduced
   to integers, so the example cannot accept them as counter values.
5. A slow Live consumer retains only the newest 16 queued deliveries within the
   byte budget. Older deliveries are dropped deliberately.
6. IPv6 literal deployment hosts are not parsed.
