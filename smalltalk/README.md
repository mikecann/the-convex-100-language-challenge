<img src="logo.png" alt="Pharo logo" width="240">
<!-- Logo source: https://pharo.org/files/pharo.png -->

# Smalltalk

Smalltalk is the family of languages that made objects and message sending the
centre of the programming model. This client uses [Pharo](https://pharo.org/),
a modern open-source Smalltalk environment that began in 2008 as a fork of
Squeak. Pharo combines a dynamic language, an object image and its development
tools, so it feels more like a live system than a compiler pointed at loose
source files.

Pharo remains a specialist language rather than a mainstream application stack,
but it has an active community and is used for web applications, teaching,
research and commercial systems. This repository's client is educational,
unofficial and not a production SDK. It is not supported by Convex, and its Live
implementation relies on an unpublished sync protocol that may change.

## Getting Started

The canonical [`examples/basics/main.st`](examples/basics/main.st) program reads
a shared counter, subscribes before changing it, applies one mutation and waits
for Live to deliver the new value. From the repository root, run it entirely in
Docker with:

```sh
./run verify-example smalltalk
```

The verifier supplies a fresh room, runs the exact source shown below in its
minimal runtime image and checks the expected `0 -> 1` journey. It proves the
example, not the wider conformance suite.

## Interesting Parts

### Keyword messages make calls read differently

React's generated API gives the query result a static TypeScript type. This
Smalltalk client instead builds an ordered JSON object and returns the decoded
result as a dictionary. The colons in `query:args:` mark the two parts of one
keyword message, not named arguments to a conventional function.

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

export function Counter() {
  const state = useQuery(api.demo.state, { room: "readme-room" });
  if (state === undefined) return <p>Loading...</p>;

  return <p>{state.count}</p>; // state and count are type-safe here.
}
```

**Smalltalk**

```smalltalk
| deployment client arguments state |
"Read the deployment URL supplied to this process by the verifier or operator."
deployment := OSEnvironment current at: 'CONVEX_URL' ifAbsent: [ nil ].
(deployment isNil or: [ deployment isEmpty ]) ifTrue: [
	(ConvexTransportError message: 'CONVEX_URL is required') signal ].

"Create an ordered dictionary that will become the query's JSON args object."
arguments := ConvexJson objectWith: { 'room' -> 'readme-room' }.
client := ConvexClient deployment: deployment.

[
	"Send the keyword message query:args: and decode the one-off HTTP result."
	state := client query: 'demo:state' args: arguments.
	Transcript show: (state at: 'count') printString
] ensure: [ client close ]. "Release any client-owned resources even on error."
```

`useQuery` keeps a React component subscribed and rerenders it. The Smalltalk
call above is deliberately a one-off HTTP read, so another call is needed to see
later data. That is a client API difference, not a limitation of Smalltalk.

### A Live subscription is an object you own

React owns the query subscription for as long as the component needs it. The
command-line Smalltalk API exposes that lifecycle directly: subscribe, pull the
next delivery with a deadline, inspect either its error or value, then close it.

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

export function LiveCounter() {
  const room = "readme-live-room";
  const state = useQuery(api.demo.state, { room }); // React owns the subscription.
  const increment = useMutation(api.demo.increment);

  const addOne = () =>
    increment({ room, language: "typescript", runId: crypto.randomUUID() });

  return <button onClick={addOne}>Count: {state?.count ?? "loading"}</button>;
  // A Live update rerenders this component with the mutation's new count.
}
```

**Smalltalk**

```smalltalk
| deployment client room arguments subscription initial mutation update |
"Use the same required deployment setting as the canonical example."
deployment := OSEnvironment current at: 'CONVEX_URL' ifAbsent: [ nil ].
(deployment isNil or: [ deployment isEmpty ]) ifTrue: [
	(ConvexTransportError message: 'CONVEX_URL is required') signal ].

room := 'readme-live-room'.
arguments := ConvexJson objectWith: { 'room' -> room }.
client := ConvexClient deployment: deployment.

[
	"Subscribe before mutating so the resulting update cannot be missed."
	subscription := client subscribe: 'demo:state' args: arguments.
	initial := subscription nextWithinMilliseconds: 10000.
	initial error ifNotNil: [ :error | error signal ].

	"The runId makes this increment idempotent if the operation is retried."
	mutation := client mutation: 'demo:increment' args: (ConvexJson objectWith: {
		'room' -> room.
		'language' -> 'smalltalk'.
		'runId' -> ConvexRandom hexIdentifier }).
	Transcript show: ((mutation at: 'state') at: 'count') printString.

	"Pull the reactive delivery and decode its dictionary value."
	update := subscription nextWithinMilliseconds: 10000.
	update error ifNotNil: [ :error | error signal ].
	Transcript show: (update value at: 'count') printString
] ensure: [
	subscription ifNotNil: [ subscription close ].
	client close ].
```

Pharo supports blocks, callbacks and concurrent processes. Returning a
`ConvexUpdate` from blocking `nextWithinMilliseconds:` is this client's API
choice for a small command-line example, not the language's only reactive style.

## Status

| Capability | State |
| --- | --- |
| HTTP query, mutation, action | Implemented; verified |
| Structured Convex function errors | Implemented; verified |
| Bearer token for HTTP calls | Implemented; verified |
| Live subscriptions over WebSocket | Implemented; verified |
| Reconnect, replay and recovery | Implemented; verified |
| Live authentication | Not implemented |
| Optimistic updates, WebSocket mutations and actions | Not implemented |
| Extended Convex value tags, journals, transition chunks | Not implemented |

The evidence recorded for the current implementation earned the `http` and
`live` capabilities: 31 of 31 shared checks passed against the local backend and
31 of 31 against the hosted deployment over real TLS. This README-only change
does not claim a fresh verification run.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.st -->
```smalltalk
"Convex from Smalltalk: the shared counter journey, start to finish.

 The room identifier arrives as the first command line argument so each
 verification run gets its own counter. Everything printed on stdout is part of
 the check; anything diagnostic goes to stderr."

Object subclass: #ConvexBasicExample
	instanceVariableNames: 'client room subscription'
	classVariableNames: ''
	package: 'Convex-Example'!

CommandLineHandler subclass: #ConvexExampleCommandLineHandler
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'Convex-Example'!


!ConvexBasicExample class methodsFor: 'decoding'!
countFrom: aValue operation: anOperation
	"Convex sends JSON numbers, and an integral value may arrive as 0.0 rather
	 than 0. Accept anything mathematically integral and in range, and refuse
	 fractional, quoted, non-finite or overflowing counts."
	| count |
	(aValue isDictionary and: [ aValue includesKey: 'count' ]) ifFalse: [
		^ (ConvexProtocolError message: anOperation, ' did not return a count') signal ].
	count := aValue at: 'count'.
	^ ConvexJson
		integerFrom: count
		named: anOperation, ' count'
		between: 0
		and: 9223372036854775807
! !

!ConvexBasicExample class methodsFor: 'running'!
runForRoom: aRoom
	^ self new setRoom: aRoom; run
! !

!ConvexBasicExample methodsFor: 'running'!
setRoom: aRoom
	room := aRoom
!
run
	| deployment current initial mutation applied mutationCount updated |
	deployment := OSEnvironment current at: 'CONVEX_URL' ifAbsent: [ nil ].
	(deployment isNil or: [ deployment isEmpty ]) ifTrue: [
		^ (ConvexTransportError message: 'CONVEX_URL is required') signal ].

	"One client is configured from the deployment URL the container supplies.
	 A bearer token is optional and this demonstration does not use one."
	client := ConvexClient deployment: deployment.
	^ [
		"Read the counter over Convex's HTTP function endpoint first."
		current := self class
			countFrom: (client query: 'demo:state' args: (self roomArguments))
			operation: 'current query'.
		self writeLine: 'current count: ', current printString.

		"Subscribe before mutating. Starting Live first is what makes the update
		 below impossible to miss between two polling calls."
		subscription := client subscribe: 'demo:state' args: (self roomArguments).

		"The first Live value hydrates the same query the HTTP call just read."
		initial := self class
			countFrom: (self nextLiveValueNamed: 'initial Live value')
			operation: 'initial Live value'.
		initial = current ifFalse: [
			^ (ConvexProtocolError message: 'initial Live count disagreed with HTTP') signal ].
		self writeLine: 'live initial count: ', initial printString.

		"runId is the mutation's idempotency key. A retried run with the same
		 runId returns the earlier result instead of incrementing twice."
		mutation := client mutation: 'demo:increment' args: (ConvexJson objectWith: {
			'room' -> room.
			'language' -> 'smalltalk'.
			'runId' -> ConvexRandom hexIdentifier }).
		applied := (mutation isDictionary and: [ (mutation at: 'applied' ifAbsent: [ nil ]) = true ]).
		applied ifFalse: [
			^ (ConvexProtocolError message: 'mutation was not applied') signal ].
		mutationCount := self class
			countFrom: (mutation at: 'state' ifAbsent: [ nil ])
			operation: 'mutation'.
		mutationCount = (current + 1) ifFalse: [
			^ (ConvexProtocolError message: 'mutation returned an unexpected count') signal ].
		self writeLine: 'mutation applied: true'.
		self writeLine: 'mutation count: ', mutationCount printString.

		"Take the result from Live rather than polling HTTP a second time."
		updated := self class
			countFrom: (self nextLiveValueNamed: 'updated Live value')
			operation: 'updated Live value'.
		updated = mutationCount ifFalse: [
			^ (ConvexProtocolError message: 'updated Live count disagreed with the mutation') signal ].
		self writeLine: 'live updated count: ', updated printString.

		"Every operation agreed before this proof line is printed."
		self writeLine: 'verified count: ', current printString, ' -> ', updated printString
	] ensure: [ self cleanUp ]
!
roomArguments
	"Each Convex call names the room, so parallel verification runs of different
	 languages never share a counter."
	^ ConvexJson objectWith: { 'room' -> room }
!
nextLiveValueNamed: anOperation
	"A Live update carries either a value or a structured error. Neither a
	 timeout nor a query failure may be quietly turned into a value."
	| update |
	update := subscription nextWithinMilliseconds: 10000.
	update ifNil: [
		^ (ConvexTransportError message: anOperation, ' timed out') signal ].
	update error ifNotNil: [ :error | ^ error signal ].
	^ update value
!
writeLine: aString
	"Stdout is the shared happy-path test surface for every language, so it stays
	 byte for byte identical and carries nothing else."
	Stdio stdout
		nextPutAll: (ZnUTF8Encoder new encodeString: aString, String lf);
		flush
!
cleanUp
	"Closing the subscription retires it inside the Live owner, and closing the
	 client shuts that owner and its WebSocket down before the image exits."
	subscription ifNotNil: [ [ subscription close ] on: Error do: [ :ignored | nil ] ].
	client ifNotNil: [ [ client close ] on: Error do: [ :ignored | nil ] ]
! !


!ConvexExampleCommandLineHandler class methodsFor: 'accessing'!
commandName
	"Pharo runs a saved image by selecting a command handler, so this is how the
	 image becomes the convex-example program."
	^ 'convex-example'
!
description
	^ 'Run the canonical Convex basic example against one room'
! !

!ConvexExampleCommandLineHandler methodsFor: 'activation'!
activate
	| room |
	room := self arguments
		ifEmpty: [ OSEnvironment current at: 'EXAMPLE_ROOM' ifAbsent: [ 'smalltalk-example' ] ]
		ifNotEmpty: [ :arguments | arguments first ].
	[ ConvexBasicExample runForRoom: room ]
		on: Error
		do: [ :error |
			[ Stdio stderr
				nextPutAll: (ZnUTF8Encoder new encodeString:
					'Smalltalk example failed: ', (error messageText ifNil: [ error class name ]), String lf);
				flush ] on: Error do: [ :ignored | nil ].
			^ self exitFailure ].
	^ self exitSuccess
! !
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

This is a native Pharo 12 implementation. The pinned image is build 1258 at
commit `1645336`, and the headless VM is `v12.0.3-beta+33.23e5a5a`. The
[Dockerfile](Dockerfile) downloads both from immutable URLs and verifies their
SHA-256 hashes. Zinc and Zodiac, which ship in the image, provide HTTP and TLS.
All Convex-specific behaviour lives in
[`client/Convex.st`](client/Convex.st).

Pharo 12 has no bundled WebSocket package, so `ConvexWebSocket` implements the
RFC 6455 client framing used by Live. One owner process alone reads and writes
the socket, manages subscriptions and reconnects, and replays active
subscriptions after reconnecting. The newest 16 deliveries are retained within
a 20 MiB byte budget, which keeps a stalled consumer from growing memory without
bound.

The client also avoids using Pharo's general STON reader for network JSON.
STON accepts more than JSON and can instantiate a named class, so `ConvexJson`
parses only the expected JSON grammar and caps input at 2 MiB, 128 nesting
levels and 8192 structural nodes. HTTP response bodies and Live frames use the
same 2 MiB ceiling.

Docker produces separate saved images for the example and conformance adapter.
The build removes interactive command handlers and proves the runtime images
cannot evaluate arbitrary Smalltalk. The VM remains outside `PATH`; Pharo's
compiler stays inside the saved object image because the runtime needs that
image to boot.

## Known Issues

1. Live authentication, optimistic updates, WebSocket mutations and actions,
   journals, extended Convex value tags and `TransitionChunk` assembly are not
   implemented. Only JSON-safe Convex values are carried.
2. The WebSocket parser reads one byte at a time because Zodiac loses bytes from
   a bulk read that times out. This preserves parser state but slows very large
   Live frames.
3. Both TLS paths assert Zodiac's certificate verification state after the
   handshake, but that check has not yet been exercised against a real invalid
   certificate in Docker.
4. The saved images intentionally omit a changes file. Their entry points passed
   the recorded read-only-filesystem probes without one.
