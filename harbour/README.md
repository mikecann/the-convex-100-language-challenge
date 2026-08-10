<img src="logo.png" alt="Harbour logo" width="180">
<!-- Logo source: https://harbour.github.io/images/harbour.svg -->

# Harbour

[Harbour](https://harbour.github.io/about) is a free, cross-platform compiler
for the xBase language family, compatible with the Clipper language that grew
out of dBase-style database programming. The project
[began in 1999](https://harbour.github.io/faq) as an open source Clipper
compiler and now adds objects, threads, portable UI and database backends, and
a large runtime library.

Its present-day niche is practical: maintaining and extending xBase business
software while targeting current operating systems. The
[official project repository](https://github.com/harbour/core) describes it as
multi-platform, multi-threaded, object-oriented, and scriptable.

This is an educational, unofficial Convex client. It is not a production SDK,
an officially sanctioned Convex client, or a package intended for publication.

## Getting Started

Start with [`examples/basics/main.prg`](examples/basics/main.prg). It reads a
fresh counter over HTTP, subscribes before changing it, performs an idempotent
mutation, and receives the resulting `0 -> 1` change through Live.

From the repository root, run the exact example in its minimal Docker image
against a unique room on the approved local backend:

```sh
./run verify-example harbour
```

## Interesting Parts

### JSON objects are Harbour hashes

A generated Convex TypeScript API gives React code typed arguments and return
values. Harbour's `{ "key" => value }` syntax is a hash table, so it maps neatly
to a JSON object, but this client decodes the result dynamically and must check
its shape at runtime.

**TypeScript with React**

```tsx
import { useState } from "react";
import { useMutation } from "convex/react";
import { api } from "./convex/_generated/api";

export function IncrementButton() {
  const increment = useMutation(api.demo.increment);
  const [room] = useState(() => `harbour-readme-${crypto.randomUUID()}`);

  async function handleClick() {
    const result = await increment({
      room,
      language: "TypeScript",
      runId: crypto.randomUUID(),
    });
    console.log(result.state.count); // result.state.count is a typed number.
  }

  return <button onClick={handleClick}>Increment</button>;
}
```

**Harbour**

```harbour
PROCEDURE Main()
   LOCAL cUrl, cRoom, oClient, hArgs, hResult, hValue

   cUrl := GetEnv( "CONVEX_URL" )
   IF Empty( cUrl )
      OutErr( "CONVEX_URL is required" + hb_eol() )
      RETURN
   ENDIF
   cRoom := "harbour-readme-" + ConvexUuid4()
   oClient := TConvexClient():New( cUrl, NIL )

   /* A Harbour hash becomes the JSON argument object sent to Convex. */
   hArgs := { "room" => cRoom, ;
      "language" => "Harbour", "runId" => ConvexUuid4() }
   hResult := oClient:Call( "mutation", "demo:increment", hArgs, 10000 )

   /* Unlike generated TypeScript, the decoded hash needs runtime checks. */
   IF hResult[ "ok" ] .AND. ValType( hResult[ "value" ] ) == "H"
      hValue := hResult[ "value" ]
      IF hb_HHasKey( hValue, "state" ) .AND. ;
         hb_HHasKey( hValue[ "state" ], "count" )
         ? hValue[ "state" ][ "count" ]
      ENDIF
   ENDIF

   oClient:Close()
   RETURN
```

`Call()` is a one-off HTTP mutation. The hashes are pleasantly close to the
wire-shaped data, but they do not provide the compile-time argument and result
checks that `api.demo.increment` does.

### A codeblock receives Live updates

React owns a `useQuery` subscription for the component's lifetime. This
Harbour client instead invokes a callback, called a codeblock, on its Live
worker thread. The example uses a Harbour mutex as a channel so its main thread
can wait for the value and then clean up explicitly.

**TypeScript with React**

```tsx
import { useState } from "react";
import { useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

export function Counter() {
  const [room] = useState(() => `harbour-live-${crypto.randomUUID()}`);
  const state = useQuery(api.demo.state, { room });

  // React starts, updates, and disposes the subscription for this component.
  if (state === undefined) return <p>Loading</p>;
  return <p>{state.count}</p>; // state.count is a typed number.
}
```

**Harbour**

```harbour
PROCEDURE Main()
   LOCAL cUrl, cRoom, hArgs, cUpdates, bOnEvent, oClient, hUpdate

   cUrl := GetEnv( "CONVEX_URL" )
   IF Empty( cUrl )
      OutErr( "CONVEX_URL is required" + hb_eol() )
      RETURN
   ENDIF
   cRoom := "harbour-live-" + ConvexUuid4()
   /* This hash is the complete query argument object. */
   hArgs := { "room" => cRoom }
   /* This mutex is used here as a one-value channel. */
   cUpdates := hb_mutexCreate()

   /* {| ... | ... } is a codeblock. The Live worker calls it per update. */
   bOnEvent := {| cSubId, xValue, hError, xLogs | ;
      hb_mutexNotify( cUpdates, { "value" => xValue, "error" => hError } ) }
   oClient := TConvexClient():New( cUrl, bOnEvent )

   oClient:Subscribe( "counter", "demo:state", hArgs )
   /* Wait up to ten seconds for the initial state, then read its count. */
   hb_mutexSubscribe( cUpdates, 10, @hUpdate )
   /* The returned hash and its count are dynamically decoded. */
   ? hUpdate[ "value" ][ "count" ]

   /* This command-line API owns the lifecycle that React normally hides. */
   oClient:Unsubscribe( "counter" )
   oClient:Close()
   RETURN
```

Codeblocks and threads are Harbour features. The direct callback and explicit
`Subscribe()`/`Unsubscribe()` lifecycle are choices made by this small client,
not limitations of the language.

## Status

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Badge earned | Query, mutation, action, bearer-token lifecycle, logs, and structured errors are implemented and pass shared local and hosted black-box conformance. |
| Live | Badge earned | Subscribe/unsubscribe, five-reconnect-capable backoff, reactive error recovery, and clean close are implemented and pass shared local and hosted black-box conformance, including a debugDisconnect-triggered reconnect and a QueryFailed-then-recovery cycle. |

The shared evaluator awarded both badges from a clean exact-head build: 31 of
31 checks against a local backend and 31 of 31 against the hosted deployment
over real TLS.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.prg -->
```harbour
/*
 * Convex from Harbour: follow the shared demo counter from 0 to 1 using
 * one HTTP query, a Live subscription started before the mutation, and
 * one idempotent mutation.
 */

#include "hbclass.ch"

REQUEST HB_MT

/* Convex represents a whole count as either 1 or 1.0 in JSON; accept both
 * without silently truncating a fractional value that should not exist. */
FUNCTION CountOf( xValue )
   IF ValType( xValue ) != "H" .OR. !hb_HHasKey( xValue, "count" ) .OR. ;
      !ConvexWholeNumber( xValue[ "count" ] )
      RETURN -1
   ENDIF
   RETURN xValue[ "count" ]

/* Every failure path prints to stderr only, and stops before anything
 * touches stdout -- stdout is reserved for the six-line transcript this
 * example is graded against byte for byte. */
PROCEDURE Die( cMessage )
   OutErr( cMessage + hb_eol() )
   ErrorLevel( 1 )
   QUIT

PROCEDURE Main( cRoomArg )
   LOCAL cUrl, cRoom, oClient, cUpdateChan, bOnEvent
   LOCAL hResult, xValue, hUpdate, cRunId, hMutationArgs, hQueryArgs

   /* Configuration: every native client in this project reads its
    * deployment from CONVEX_URL. */
   cUrl := GetEnv( "CONVEX_URL" )
   IF Empty( cUrl )
      Die( "CONVEX_URL is required" )
   ENDIF
   cRoom := cRoomArg
   IF Empty( cRoom )
      cRoom := GetEnv( "EXAMPLE_ROOM" )
   ENDIF
   IF Empty( cRoom )
      cRoom := "harbour-basic-example"
   ENDIF

   /* Client creation: one object owns the parsed deployment URL, the
    * current bearer token, and the Live worker thread's subscription
    * pump. Every delivered Live value or error for this example's one
    * subscription arrives on cUpdateChan, notified from the worker
    * thread, because only one thread here ever calls OutStd(). Harbour's
    * "?" command is QOut(), which writes the line terminator before the
    * expression rather than after it, so this example calls OutStd()
    * directly with an explicit trailing hb_eol() to keep stdout in the
    * ordinary content-then-newline order the transcript check expects. */
   cUpdateChan := hb_mutexCreate()
   bOnEvent := {| cSubId, xVal, hErr, xLogs | ;
      hb_mutexNotify( cUpdateChan, { "value" => xVal, "error" => hErr } ) }
   oClient := TConvexClient():New( cUrl, bOnEvent )
   IF oClient:oUrl == NIL
      Die( "invalid CONVEX_URL" )
   ENDIF

   /* The HTTP query: ask Convex for the room's current state through its
    * documented JSON HTTP endpoint, /api/query. Decoding stops at the
    * one field this example promises to check. */
   hQueryArgs := { "room" => cRoom }
   hResult := oClient:Call( "query", "demo:state", hQueryArgs, 10000 )
   IF !hResult[ "ok" ] .OR. CountOf( hResult[ "value" ] ) != 0
      Die( "unexpected initial query value" )
   ENDIF
   OutStd( "current count: 0" + hb_eol() )

   /* Starting Live before the mutation: subscribing first means no
    * reactive update, including the one the mutation below is about to
    * cause, can fall into the gap between reading and watching. */
   oClient:Subscribe( "state", "demo:state", hQueryArgs )

   /* The initial Live value: the first delivery on a fresh subscription
    * hydrates the same state the HTTP query above just read, over the
    * WebSocket sync protocol rather than a second HTTP request. */
   IF !hb_mutexSubscribe( cUpdateChan, 10, @hUpdate ) .OR. ;
      hUpdate[ "error" ] != NIL .OR. CountOf( hUpdate[ "value" ] ) != 0
      Die( "unexpected initial Live value" )
   ENDIF
   OutStd( "live initial count: 0" + hb_eol() )

   /* The mutation and its idempotency key: runId is deterministic per
    * room, so re-running this example against a room it already touched
    * replays the earlier result instead of incrementing a second time. */
   cRunId := cRoom + "-once"
   hMutationArgs := ;
      { "room" => cRoom, "language" => "Harbour", "runId" => cRunId }
   hResult := oClient:Call( "mutation", "demo:increment", hMutationArgs, 10000 )
   xValue := hResult[ "value" ]
   IF !hResult[ "ok" ] .OR. !hb_HHasKey( xValue, "applied" ) .OR. ;
      xValue[ "applied" ] != .T. .OR. !hb_HHasKey( xValue, "state" ) .OR. ;
      CountOf( xValue[ "state" ] ) != 1
      Die( "unexpected mutation result" )
   ENDIF
   OutStd( "mutation applied: true" + hb_eol() )
   OutStd( "mutation count: 1" + hb_eol() )

   /* Receiving the same change reactively: the Live subscription
    * delivers the mutation's result with no second HTTP request at
    * all. */
   IF !hb_mutexSubscribe( cUpdateChan, 10, @hUpdate ) .OR. ;
      hUpdate[ "error" ] != NIL .OR. CountOf( hUpdate[ "value" ] ) != 1
      Die( "unexpected updated Live value" )
   ENDIF
   OutStd( "live updated count: 1" + hb_eol() )

   /* Only now, with the HTTP query, the initial Live value, the mutation
    * and the updated Live value all agreeing, print the proof line. */
   OutStd( "verified count: 0 -> 1" + hb_eol() )

   /* Cleanup: unsubscribe and close before the process exits. */
   oClient:Unsubscribe( "state" )
   oClient:Close()

   RETURN
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

```sh
./run test harbour           # builds Harbour 3.2.0 from source, lints the
                              # source style, compiles every client and test
                              # program, and runs the language-local suites
./run verify-example harbour # runs the exact block above against a unique
                              # room on the local self-hosted backend
./run verify harbour         # verify-example plus shared black-box conformance
```

`./run test harbour` clones and builds Harbour 3.2.0 at a pinned upstream
commit, compiles `client/tests/client_test.prg` and `client/tests/
tls_test.prg` and runs them, then builds `convex-adapter` and
`convex-example` themselves and probes both the stdin/stdout and
`ADAPTER_LISTEN` TCP modes of the adapter. `client/tests/tls_test.prg` runs
against a real local TLS server it starts, in trusted, untrusted, and
wrong-hostname configurations, so certificate verification is exercised
against actual peers rather than mocked.

### How it works

- The client speaks the pinned `convex-rs@6f1df8a8` sync profile at
  `/api/sync`, matching every other client in this project.
- `hb_jsonEncode()`/`hb_jsonDecode()` are part of Harbour's own core
  runtime library, not a third-party contrib, so JSON encoding and decoding
  is native Harbour. `contrib/hbssl` binds OpenSSL directly onto Harbour's
  own `hb_inet*` socket layer for TCP and TLS. HTTP/1.1 request and
  response framing and RFC 6455 WebSocket handshake and frame encode/decode
  are hand-written in Harbour (`client/convexhttp.prg`, `client/
  convexws.prg`) on top of that socket boundary, because neither has a
  standard Harbour library of its own.
- The Live sync protocol runs on a dedicated `hb_threadStart()` worker
  thread that exclusively owns the WebSocket connection, coordinated with
  the controller thread and any subscribers through `hb_mutexNotify()`/
  `hb_mutexSubscribe()` channels -- real OS threads via Harbour's `-mt`
  runtime, not a cooperative poll loop.
- `client/tests/conformance/adapter.prg` implements NDJSON adapter
  protocol v1 over both stdin/stdout and the `ADAPTER_LISTEN` TCP mode, and
  declares `debugDisconnect` as its one adapter-only command. Its TCP mode
  reads with `hb_inetRecv()` into its own bare-`\n` line buffer rather than
  Harbour's `hb_inetRecvLine()`, which only recognises `\r\n` and would
  block forever against a controller that never sends a trailing `\r`.
- Every `hbmk2` link in the Dockerfile shares `-static -gtcgi -mt`:
  `-static` links Harbour's own runtime so the minimal runtime image needs
  no `libharbour.so`; `-gtcgi` selects Harbour's non-interactive console
  driver, because the default GTSTD driver writes ANSI cursor-positioning
  escape codes to stdout even when stdout is a pipe, which would corrupt
  both the NDJSON adapter protocol and the byte-exact example transcript;
  `-mt` links the multithread-capable runtime the Live worker thread needs.
- Harbour's `?` command is `QOut()`, which writes the line terminator
  before the expression rather than after it. The canonical example calls
  `OutStd()` directly with an explicit trailing `hb_eol()` instead, so its
  six-line stdout transcript matches `_shared/examples/basics.expected.txt`
  exactly rather than opening with a spurious blank line.
- TLS hostname verification follows RFC 6125's ordering: a certificate's
  `subjectAltName` DNS entries are checked first, and the legacy Subject
  CN is only consulted when a certificate has no `subjectAltName` at all.
  `contrib/hbssl` exposes no accessor for X.509 extensions, so
  `client/convextls_native.c` (about 65 lines) reaches libssl's own
  `X509_get_ext_d2i()`/`GENERAL_NAME` API directly for that one missing
  accessor -- the same OpenSSL library `contrib/hbssl` already links, and
  no Convex-specific logic, just the generic TLS primitive `contrib/hbssl`
  itself forgot to wrap. This is not a cosmetic improvement over CN-only
  matching: the hosted Convex deployment's own certificate has Subject CN
  `convex.cloud` but `subjectAltName` `convex.cloud` and `*.convex.cloud`,
  so a CN-only client cannot complete a hosted handshake at all.

## Known Issues

1. When a certificate has no `subjectAltName`, hostname verification falls
   back to its Subject CN. If it has neither, this client skips the hostname
   check, although certificate-chain verification still rejects an untrusted
   or self-signed peer.
2. A WebSocket control frame received midway through a fragmented data message
   triggers a reconnect instead of pausing and resuming message reassembly.
3. Live authentication, optimistic updates, WebSocket mutations and actions,
   and `TransitionChunk` assembly are deferred.
4. Live values cover the JSON-safe Convex subset. Tagged Convex value
   conversions are deferred.
5. The client deliberately has no in-memory Live delivery queue. A slow event
   codeblock blocks the worker on the OS pipe, socket buffer, or caller's
   channel instead of allowing process memory to grow.
6. Code that expects an integer accepts mathematically integral JSON numbers
   within signed 64-bit range and rejects fractional or overflowing values.
