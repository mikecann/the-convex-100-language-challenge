# Convex from BlitzMax

This client calls Convex from BlitzMax NG. It reads a shared counter over Convex's documented JSON HTTP endpoints and then keeps that counter current over a WebSocket, so a change made anywhere shows up without asking again.

It is educational and unofficial. It is not a production SDK, and it is not intended for package publication.

## Start here

Read [`examples/basics/main.bmx`](examples/basics/main.bmx). It queries a fresh room's counter, starts a Live subscription **before** anything changes, applies one idempotent mutation from inside the subscription, and then proves that HTTP and Live agree on the journey `0 -> 1`.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, actions, and structured function errors | Implemented, no earned badge |
| Live initial values, external updates, failure recovery, and reconnection | Implemented, no earned badge |
| Full HTTP and Live conformance against the shared harness | Not yet earned |
| Live authentication, optimistic updates, WebSocket mutations and actions | Deferred |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.bmx -->
```text
SuperStrict

Framework BRL.StandardIO

Import "../../client/transport.bmx"
Import "../../client/jsonvalue.bmx"
Import "../../client/convex.bmx"

Extern
	Function convex_example_exit(code:Int) = "exit"
End Extern

' Convex's demo counter lives in a room. Every argument object the example
' sends is built here so the room name is quoted once, correctly, in one place.
Function RoomArguments:TJSONObject(room:String)
	Return ConvexParseJsonObject("{~qroom~q:" + ConvexQuote(room) + "}", "arguments")
End Function

' The mutation also carries a language label and an idempotency key. Convex
' uses that key to make a retried increment count once, so it is generated per
' attempt rather than derived from the room.
Function IncrementArguments:TJSONObject(room:String, idempotencyKey:String)
	Return ConvexParseJsonObject("{~qroom~q:" + ConvexQuote(room) + ",~qlanguage~q:~qBlitzMax~q,~qrunId~q:" + ..
		ConvexQuote(idempotencyKey) + "}", "arguments")
End Function

' Convex may encode an integral JSON number as either 1 or 1.0 depending on how
' it travelled. Accept both spellings of the same integer while refusing a
' fractional, quoted, or out-of-range count, so a wrong value fails loudly
' instead of being rounded into something plausible.
Function CountFrom:Long(value:TJSON, operation:String)
	Local state:TJSONObject = TJSONObject(value)
	If Not state Then
		Throw TConvexError.Protocol(operation + " did not return an object")
	End If
	Local count:Long = ConvexIntegralValue(state.Get("count"), operation + " count")
	If count < 0 Then
		Throw TConvexError.Protocol(operation + " returned a negative count")
	End If
	Return count
End Function

' Reads the mutation's envelope. Both fields are checked before either is used,
' because a mutation that reported success without applying anything would
' otherwise look identical to one that worked.
Function AppliedCountFrom:Long(value:TJSON)
	Local envelope:TJSONObject = TJSONObject(value)
	If Not envelope Then
		Throw TConvexError.Protocol("the mutation did not return an object")
	End If
	Local applied:TJSONBool = TJSONBool(envelope.Get("applied"))
	If Not applied Then
		Throw TConvexError.Protocol("the mutation did not report whether it applied")
	End If
	If Not applied.isTrue Then
		Throw TConvexError.Protocol("the mutation was not applied")
	End If
	Return CountFrom(envelope.Get("state"), "mutation")
End Function

' Live updates arrive here. The example is a small state machine: the first
' update is the initial value Convex already had, and the second is the one the
' mutation caused. Keeping the mutation inside this observer is what proves the
' subscription was established before the value changed.
Type TCounterObserver Extends TConvexObserver

	Field client:TConvexClient
	Field room:String
	Field startingCount:Long
	Field sawInitial:Int
	Field finished:Int
	Field failure:String

	Method OnUpdate(subscription:TConvexSubscription, value:TJSON, problem:TConvexFunctionError) Override
		If finished Or failure.length > 0 Then
			Return
		End If
		Try
			If problem Then
				Throw TConvexError.Protocol(problem.name + ": " + problem.message)
			End If
			If Not sawInitial Then
				OnInitialValue(value)
			Else
				OnUpdatedValue(value)
			End If
		Catch stopped:TConvexError
			failure = stopped.message
		End Try
	End Method

	' The first Live value must agree with what the HTTP query already reported.
	Method OnInitialValue(value:TJSON)
		Local observed:Long = CountFrom(value, "initial Live value")
		If observed <> startingCount Then
			Throw TConvexError.Protocol("the initial Live count disagreed with the HTTP query")
		End If
		Print "live initial count: " + observed
		sawInitial = True

		' Only now is it safe to change the room: the subscription is live, so
		' the resulting update cannot be missed.
		Local mutation:TConvexResult = client.Mutation("demo:increment", IncrementArguments(room, ConvexNewUuid()))
		Local applied:Long = AppliedCountFrom(mutation.value)
		If applied <> startingCount + 1 Then
			Throw TConvexError.Protocol("the mutation returned an unexpected count")
		End If
		Print "mutation applied: true"
		Print "mutation count: " + applied
	End Method

	' The second Live value is the reactive proof: Convex pushed the new count
	' without the example asking for it again.
	Method OnUpdatedValue(value:TJSON)
		Local observed:Long = CountFrom(value, "updated Live value")
		If observed <> startingCount + 1 Then
			Throw TConvexError.Protocol("the updated Live count disagreed with the mutation")
		End If
		Print "live updated count: " + observed
		Print "verified count: " + startingCount + " -> " + observed
		finished = True
	End Method

End Type

Function Run:Int()
	Local url:String = ConvexEnv("CONVEX_URL")
	If url.length = 0 Then
		Throw TConvexError.Protocol("CONVEX_URL is required")
	End If
	' The verifier passes a unique room as the first argument; the environment
	' variable and the literal below only make the image pleasant to run by hand.
	Local room:String = ConvexEnv("EXAMPLE_ROOM")
	If AppArgs.length > 1 And AppArgs[1].length > 0 Then
		room = AppArgs[1]
	End If
	If room.length = 0 Then
		room = "blitzmax-example"
	End If

	' One client serves both transports for this deployment.
	Local client:TConvexClient = TConvexClient.Create(url)

	' Read the room over Convex's documented HTTP query endpoint.
	Local current:Long = CountFrom(client.Query("demo:state", RoomArguments(room)).value, "current query")
	Print "current count: " + current

	' Start Live before anything changes the room.
	Local observer:TCounterObserver = New TCounterObserver
	observer.client = client
	observer.room = room
	observer.startingCount = current
	Local subscription:TConvexSubscription = client.Subscribe("demo:state", RoomArguments(room), observer)

	' Drive the Live connection until the journey completes. The deadline exists
	' so a viewer sees a clear failure rather than an example that hangs.
	Local deadline:TConvexDeadline = TConvexDeadline.Create(20000)
	While Not observer.finished And observer.failure.length = 0
		If deadline.Expired() Then
			Throw TConvexError.Transport("the example timed out waiting for a Live update")
		End If
		client.Pump(50)
	Wend

	' Retire the Live query and its transport once the proof is complete.
	client.Unsubscribe(subscription)
	client.Close()
	If observer.failure.length > 0 Then
		Throw TConvexError.Protocol(observer.failure)
	End If
	Return 0
End Function

Local status:Int = 1
Try
	status = Run()
Catch problem:TConvexError
	ErrPrint("BlitzMax example failed: " + problem.message)
Catch other:Object
	ErrPrint("BlitzMax example failed: " + other.ToString())
End Try
convex_example_exit(status)
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

```sh
./run sync-examples
./run validate
./run test blitzmax
./run verify-example blitzmax
```

`test` builds every BlitzMax executable inside Docker and runs the language-local suites: unit checks, a hostile HTTP peer, a hostile WebSocket peer, and adapter serialisation. It then exercises the real adapter over both stdin/stdout and TCP, and asserts that the minimal runtime images contain no compiler, package manager, or delegated runtime. `verify-example` runs the exact canonical example from its minimal image against a unique room and compares its stdout with the shared transcript. Neither earns a capability: only the root-owned shared conformance run can do that.

## Conformance and protocol notes

BlitzMax NG supplies the byte transport and the JSON codec. `Net.mbedtls` provides the TCP socket and a verified TLS session — the client sets the server name itself, because the module's wrapper exposes no binding for SNI and a certificate that is never checked against the name you asked for is not a check. `Text.Json` (jansson) parses and serialises values. Everything Convex-specific is BlitzMax: the `/api/query`, `/api/mutation`, and `/api/action` envelopes; HTTP/1.1 response framing; the RFC 6455 upgrade, masking, and incremental frame parser; and the pinned `/api/sync` query-set protocol with its `Connect`, `ModifyQuerySet`, and `Transition` handling.

One owner holds the Live socket. Subscribing, unsubscribing, reading, writing, retiring a connection, and changing the query-set version all happen there, driven from a single `Pump`. A `Transition` is fully validated — start version, query-set bounds, and a numerically monotonic little-endian timestamp — and every piece of connection state is committed before a subscriber can observe the update that produced it. Retiring a connection bumps a generation and restarts the query-set version, so a late frame from a retired socket cannot be mistaken for a valid continuation on its replacement. A reconnection replays the active `Add` operations and suppresses exactly one unchanged rehydration snapshot, so the sequence a viewer sees is the real journey rather than a repeat.

HTTP responses are parsed before they are classified. A complete Convex function-error envelope keeps its `errorMessage`, `errorData`, and `logLines` on any status, while a non-2xx reply that is not a Convex envelope stays a transport failure rather than being promoted into an application error. A body that never satisfied its `Content-Length`, or a chunked body missing its terminal zero chunk, is a transport failure — not the value that its truncated bytes happen to spell.

Memory bounds measure what is retained, not what was serialised. A parsed jansson tree costs roughly a hundred bytes per value, so a dense array can retain far more than it weighs on the wire while staying inside every byte-count limit. Untrusted JSON is therefore scanned before it is parsed and refused if its tree would exceed eight MiB retained or nest deeper than sixty-four levels. Each Live relay is generation-tagged and bounded to sixteen reserved queued or in-flight events and to that same eight-MiB retained bound plus a fixed allowance, so one value accepted at the maximum can be held exactly once, with the event currently in a subscriber's hands still charged. Adapter output has a two-MiB event cap and a one-second default absolute write deadline, so a stopped controller cannot pin the process.

Deadlines are absolute, not inactivity timeouts. Each operation creates one monotonic expiry and every wait inside it shrinks against that same expiry, so a peer that drips one byte at a time cannot hold a call open. Closing is bounded by construction: the close frame is attempted once and the peer's echo is never awaited.

The test-only adapter under `client/tests/conformance/` speaks strict NDJSON v1 on stdin/stdout, or over one `ADAPTER_LISTEN` TCP controller connection. It reserves stdout for protocol events, sends diagnostics to stderr, rejects unknown fields rather than ignoring them, and never serialises an absent `id`, value, or error as `null`. `debugDisconnect` is adapter-only and exists so the shared harness can prove real reconnections; it is not part of the educational client API.

## Limitations

The language-local peers are cooperative rather than threaded: the peer is serviced from the client's own idle hook, so each hostile sequence replays byte for byte on every run. They cover truncated `Content-Length` and unterminated chunked bodies, function-error envelopes on non-2xx statuses, malformed-body recovery, continuously dripping and silent peers against an absolute deadline, a forged `Sec-WebSocket-Accept`, an unoffered extension, a masked server frame, invalid UTF-8, an over-declared frame length, a rewound sync timestamp, a mismatched start version, a fragmented message with an interleaved ping, a frame that stalls halfway and resumes, five real reconnects with `Add` replay and suppressed rehydration, a bounded close against a stalled peer, and relay count, byte, and invalidation barriers. They do not replace fresh independent review or the root-owned shared conformance runs.

Name resolution and the TCP connect are the one step outside the absolute deadline. mbed TLS performs both inside a single blocking call, so those two phases are bounded by the operating system's resolver and connect timeouts. Everything after them — the TLS handshake, every request, every frame, and every close — is bounded by the client.

A Convex value whose parsed tree would exceed the retained bound is reported as a `ProtocolError` rather than delivered, and a Live frame carrying one retires that connection instead of being parsed. That is a deliberate trade: a wire-legal but node-dense payload is refused rather than allowed to exhaust the container's memory limit. Live authentication lifecycle, optimistic updates, mutations and actions over the WebSocket, journals, and `TransitionChunk` assembly are all deferred. The shared README and site generator has no BlitzMax fence mapping yet, so the example below renders as plain text rather than highlighted source; that mapping lives in shared infrastructure. The manifest deliberately declares no earned badges.
