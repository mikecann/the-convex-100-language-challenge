<img src="logo.png" alt="BlitzMax" width="248">
<!-- Logo source: https://blitzmax.org/img/blitzmax.svg -->

# BlitzMax

[BlitzMax NG](https://blitzmax.org/) is a strongly typed, garbage-collected, open-source language in the Blitz BASIC family. It keeps BASIC's readable, statement-oriented feel while adding objects, modules, native compilation, and cross-platform libraries. It is best known for apps and games, with built-in graphics, sound, UI, and community modules.

BlitzMax is a niche language today, but its compiler, documentation, and module ecosystem are still maintained. This Convex client is an educational, unofficial demonstration, not a production SDK or a package intended for publication.

## Getting Started

Start with [`examples/basics/main.bmx`](examples/basics/main.bmx). It queries a fresh room, subscribes before changing it, increments the counter once, and checks that HTTP and Live both see `0 -> 1`.

From the repository root, run the canonical example in its Docker image:

```sh
./run verify-example blitzmax
```

## Interesting Parts

### `SuperStrict` types stop where JSON begins

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function QueryCount() {
  const room = "readme-blitzmax-query";
  const state = useQuery(api.demo.state, { room });

  if (state === undefined) return <span>Loading...</span>;
  return <span>{state.count}</span>; // The generated Convex API makes state.count type-safe.
}
```

**BlitzMax**

```blitzmax
SuperStrict

Import "../../client/transport.bmx"
Import "../../client/jsonvalue.bmx"
Import "../../client/convex.bmx"

Local room:String = "readme-blitzmax-query"
' ~q is BlitzMax's escape for a quote inside a string literal.
Local args:TJSONObject = ConvexParseJsonObject("{~qroom~q:" + ConvexQuote(room) + "}", "arguments")
Local client:TConvexClient = TConvexClient.Create(ConvexEnv("CONVEX_URL"))

' Query is an HTTP call here, not a reactive hook.
Local value:TJSON = client.Query("demo:state", args).value
Local state:TJSONObject = TJSONObject(value)
If Not state Then Throw TConvexError.Protocol("demo:state did not return an object")
Local count:Long = ConvexIntegralValue(state.Get("count"), "state count")
Print count ' count is a checked 64-bit integer here.

client.Close()
```

`SuperStrict` requires every variable and return type to be declared, so `room`, `state`, and `count` cannot silently change type. Unlike the generated TypeScript API, BlitzMax does not know the Convex function's return shape at compile time. This client therefore casts `TJSON` nodes and validates each important field at runtime.

### A Live query is an object you drive and retire

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function RoomCount() {
  const room = "readme-blitzmax-live";
  const state = useQuery(api.demo.state, { room });

  if (state === undefined) return <p>Loading...</p>;
  return <p>{state.count}</p>; // React rerenders when the subscribed value changes.
}
```

**BlitzMax**

```blitzmax
SuperStrict

Import "../../client/transport.bmx"
Import "../../client/jsonvalue.bmx"
Import "../../client/convex.bmx"

' Type declares an object; Extends supplies the callback BlitzMax must override.
Type TCountObserver Extends TConvexObserver
    Field received:Int ' Each observer instance remembers whether a value arrived.

    Method OnUpdate(subscription:TConvexSubscription, value:TJSON, problem:TConvexFunctionError) Override
        If problem Then Throw TConvexError.Protocol(problem.message)

        Local state:TJSONObject = TJSONObject(value)
        If Not state Then Throw TConvexError.Protocol("demo:state did not return an object")
        Local count:Long = ConvexIntegralValue(state.Get("count"), "Live count")
        Print count ' The callback receives each initial or changed value.
        received = True
    End Method
End Type

Local room:String = "readme-blitzmax-live"
Local args:TJSONObject = ConvexParseJsonObject("{~qroom~q:" + ConvexQuote(room) + "}", "arguments")
Local client:TConvexClient = TConvexClient.Create(ConvexEnv("CONVEX_URL"))
Local observer:TCountObserver = New TCountObserver
Local subscription:TConvexSubscription = client.Subscribe("demo:state", args, observer)

Local deadline:TConvexDeadline = TConvexDeadline.Create(5000)
While Not observer.received And Not deadline.Expired()
    client.Pump(50) ' The command-line app explicitly drives Live progress.
Wend
If Not observer.received Then Throw TConvexError.Transport("timed out waiting for Live")
client.Unsubscribe(subscription) ' Explicitly retire this query.
client.Close() ' Explicitly close its transport too.
```

React owns the `useQuery` subscription while the component is mounted. This command-line client instead exposes an observer plus `Pump`, `Unsubscribe`, and `Close`. That explicit lifecycle is a client API choice suited to the single-owner event loop in this implementation, not a limitation of BlitzMax objects or callbacks.

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, actions, and structured function errors | Verified by shared local and hosted conformance |
| Live initial values, external updates, failure recovery, and reconnection | Verified by shared local and hosted conformance |
| Full HTTP and Live conformance against the shared harness | Passed locally and hosted; HTTP and Live earned |
| Live authentication, optimistic updates, WebSocket mutations and actions | Deferred |

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.bmx -->
```blitzmax
SuperStrict

Framework BRL.StandardIO

Import "../../client/transport.bmx"
Import "../../client/jsonvalue.bmx"
Import "../../client/convex.bmx"

Extern
	Function convex_example_exit(code:Int) = "exit"
End Extern

' The harness compares this example's stdout byte-for-byte against
' _shared/examples/basics.expected.txt, which is LF-only, so the transcript
' is written straight to the file descriptor with ConvexEncodeLine's bare LF
' terminator rather than through Print; see that function's comment in
' transport.bmx for why Print itself cannot be used here.
Function WriteStdoutLine(text:String)
	Local line:TConvexBuffer = ConvexEncodeLine(text)
	Local offset:Int = 0
	While offset < line.length
		Local written:Long = convex_write(1, Varptr line.data[offset], Size_T(line.length - offset))
		If written <= 0 Then
			Throw TConvexError.Transport("could not write the example transcript to stdout")
		End If
		offset :+ Int(written)
	Wend
End Function

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
		WriteStdoutLine("live initial count: " + observed)
		sawInitial = True

		' Only now is it safe to change the room: the subscription is live, so
		' the resulting update cannot be missed.
		Local mutation:TConvexResult = client.Mutation("demo:increment", IncrementArguments(room, ConvexNewUuid()))
		Local applied:Long = AppliedCountFrom(mutation.value)
		If applied <> startingCount + 1 Then
			Throw TConvexError.Protocol("the mutation returned an unexpected count")
		End If
		WriteStdoutLine("mutation applied: true")
		WriteStdoutLine("mutation count: " + applied)
	End Method

	' The second Live value is the reactive proof: Convex pushed the new count
	' without the example asking for it again.
	Method OnUpdatedValue(value:TJSON)
		Local observed:Long = CountFrom(value, "updated Live value")
		If observed <> startingCount + 1 Then
			Throw TConvexError.Protocol("the updated Live count disagreed with the mutation")
		End If
		WriteStdoutLine("live updated count: " + observed)
		WriteStdoutLine("verified count: " + startingCount + " -> " + observed)
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
	WriteStdoutLine("current count: " + current)

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

## Implementation Notes

This is a native BlitzMax NG client built with the pinned `0.165.3.61.202608020404` toolchain. Stock `Net.mbedtls` handles TCP and TLS, and stock `Text.Json` supplies jansson JSON nodes. The Convex HTTP envelopes, HTTP response framing, WebSocket handshake and frames, and pinned Live query protocol are implemented in BlitzMax rather than delegated to another Convex client.

HTTP queries, mutations, and actions are separate request-response calls. Live uses one socket owner driven by `Pump`, and subscriptions receive values through `TConvexObserver` objects. Delivery is non-reentrant and bounded, unsubscribe is a barrier against stale queued values, and reconnects replay active subscriptions while suppressing the one unchanged rehydration snapshot.

The client validates complete HTTP body framing before treating bytes as a result, preserves structured Convex function errors, and applies one absolute deadline after the initial DNS and TCP connect. It scans untrusted JSON before jansson allocates a tree, rejecting values above an estimated 8 MiB retained-memory budget or 64 nesting levels. Language-local Docker tests cover these bounds, malformed peers, reconnects, and both adapter transports.

The final runtime images contain the compiled BlitzMax executables, their native library closure, CA certificates, and the small POSIX shell surface required by the shared verifier. They run as user `65532:65532` without a compiler, package manager, Convex CLI, Node.js, or Python.

## Known Issues

1. Live authentication lifecycle, optimistic updates, WebSocket mutations and actions, journals, and `TransitionChunk` assembly are deferred.
2. DNS resolution and TCP connect use mbed TLS's blocking call, so the operating system controls those timeouts. The client's absolute deadline covers every later handshake, request, frame, and close step.
3. Values use Convex's JSON-safe subset. A wire-valid JSON value is rejected with `ProtocolError` if its estimated retained tree exceeds 8 MiB or nests more than 64 levels.
4. The shared site generator has no BlitzMax syntax mapping yet, so the canonical `blitzmax` code fence renders without syntax highlighting.
