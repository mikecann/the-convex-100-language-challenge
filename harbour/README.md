# Convex from Harbour

This demonstration uses Harbour, a free modern compiler for the xBase
(Clipper/dBase) language family, to call Convex's documented JSON HTTP
functions and to keep a reactive query current through a native Harbour
WebSocket connection.

It is an educational, unofficial experiment. It is not a production SDK, an
officially sanctioned Convex client, or a package intended for publication.

## Start here

[`examples/basics/main.prg`](examples/basics/main.prg) is the canonical
example. It reads a new counter room over HTTP, starts Live before changing
it, applies an idempotent mutation, and proves the same `0 -> 1` journey
arrived through the subscription. The block below is generated from that
exact runnable file.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Badge earned | Query, mutation, action, bearer-token lifecycle, logs, and structured errors are implemented and pass shared local and hosted black-box conformance. |
| Live | Badge earned | Subscribe/unsubscribe, five-reconnect-capable backoff, reactive error recovery, and clean close are implemented and pass shared local and hosted black-box conformance, including a debugDisconnect-triggered reconnect and a QueryFailed-then-recovery cycle. |

The shared evaluator awarded both badges from a clean exact-head build: 31 of
31 checks against a local backend and 31 of 31 against the hosted deployment
over real TLS.

## The basic example

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

## Verify it in Docker

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

## Conformance and protocol notes

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

## Limitations

- When a certificate carries no `subjectAltName` at all, hostname
  verification falls back to pattern-matching the Subject CN (via
  `X509_name_oneline()`), and a certificate with neither is a best-effort
  skip of the name check specifically, rather than being rejected
  outright. Chain verification itself (`SSL_get_verify_result()` against
  the system trust store or `$SSL_CERT_FILE`) is always full strength and
  rejects an untrusted or self-signed peer regardless of this narrowing.
- A WebSocket control frame (close/ping/pong) arriving while a data message
  is still being reassembled from continuation frames is treated as a
  protocol failure that triggers a reconnect, rather than being returned to
  the caller mid-reassembly and resumed afterward. Convex's own sync
  protocol never fragments an application message, so this can only be
  reached by a broken or hostile peer.
- Live authentication, optimistic updates, WebSocket-issued mutations,
  WebSocket actions, and `TransitionChunk` assembly are deferred; a
  `TransitionChunk` is reported as protocol drift and the connection
  reconnects.
- Live values cover Convex's JSON-safe subset; tagged Convex value
  conversions are deferred.
- The client keeps no in-memory Live delivery queue: `convexlive.prg`'s
  `DeliverValue()`/`DeliverError()` call the caller's event codeblock
  directly from the Live worker thread, with no intermediate buffer. The
  adapter's own codeblock writes straight to stdout (or the
  `ADAPTER_LISTEN` TCP socket) under one mutex; a slow or stopped consumer
  therefore blocks that single write against the OS pipe or socket buffer
  rather than growing process memory.
- JSON numbers are accepted only when mathematically integral and within a
  signed 64-bit range; fractional and out-of-range values are rejected at
  the point of use.
