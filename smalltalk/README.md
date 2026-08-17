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

### Keyword messages read like a sentence

Smalltalk methods that take more than one argument aren't called with a fixed
parameter list — they're a single message whose selector is spelled out in
pieces, each piece ending in a colon right before the value it takes.
`query:args:` is one selector, not two arguments bolted onto a function name,
and there is no other order to write it in. Reading a call aloud is close to
reading English, which was rather the point when Alan Kay's group settled on
this syntax in the 1970s.

```smalltalk
"query:args: is one two-part message; the colons belong to the selector."
current := client query: 'demo:state' args: (self roomArguments).

"Same shape for a mutation: one message, two keyword parts, no positional args."
mutation := client mutation: 'demo:increment' args: (ConvexJson objectWith: {
	'room' -> room.
	'language' -> 'smalltalk'.
	'runId' -> ConvexRandom hexIdentifier }).
"TypeScript: await client.mutation('demo:increment', { room, language, runId })"
```

### A Live subscription is an object you pull from

React's `useQuery` keeps its subscription behind the scenes and rerenders your
component whenever fresh data lands; you never touch the subscription itself.
This client's `subscribe:args:` hands it to you instead — you hold onto it,
ask for the next delivery with a deadline, and decide yourself whether what
comes back is an error or a value.

```smalltalk
"Subscribe before mutating, so the reactive update that follows can't be missed."
subscription := client subscribe: 'demo:state' args: (self roomArguments).

"Pulling a Live delivery, rather than being handed one by a rerender."
update := subscription nextWithinMilliseconds: 10000.
update ifNil: [ ^ (ConvexTransportError message: 'Live value timed out') signal ].
update error ifNotNil: [ :error | ^ error signal ].
^ update value
"TypeScript: const state = useQuery(api.demo.state, { room }); // pushed to you"
```

Closing it is explicit too: `subscription close` retires the delivery queue
before `client close` shuts the underlying WebSocket down.

### A cascade fires several messages at one receiver

The semicolon is Smalltalk's cascade operator: every message after the first
`;` in a cascade is sent to that same original receiver, not to whatever the
previous message happened to return. The client leans on this to write the
raw HTTP text that upgrades a Live connection into a WebSocket, one header
per cascaded send.

```smalltalk
"Five sends to 'out': the receiver is named once, then reused after each ';'."
request := String streamContents: [ :out |
	out nextPutAll: 'GET '; nextPutAll: self requestTarget; nextPutAll: ' HTTP/1.1'; nextPutAll: String crlf.
	out nextPutAll: 'Upgrade: websocket'; nextPutAll: String crlf.
	out nextPutAll: 'Sec-WebSocket-Key: '; nextPutAll: aKey; nextPutAll: String crlf.
	out nextPutAll: String crlf ].
"TypeScript: new WebSocket(url) does this whole handshake for you"
```

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
