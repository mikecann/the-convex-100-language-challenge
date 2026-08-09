# Convex from Smalltalk

This is a small Convex client written in Pharo 12 Smalltalk. It talks to a Convex
deployment two ways: ordinary HTTP function calls, and a live subscription over a
WebSocket that pushes new query results as soon as the data changes.

Everything Convex-specific is written in Smalltalk, including the RFC 6455
WebSocket framing, because Pharo 12 ships no WebSocket package at all. Zinc and
Zodiac, which come with the Pharo image, provide HTTP and TLS the way any Pharo
program would use them.

It is educational, unofficial, and not a production SDK. Nobody at Convex
supports it, the sync protocol it speaks is not a published stable interface, and
it exists to answer one question: can Smalltalk hold up its end of a modern
reactive backend?

## Start here

The canonical example is [`examples/basics/main.st`](examples/basics/main.st).

It follows one shared counter through a complete journey. It reads the current
count over HTTP, subscribes to the same query before changing anything, applies a
mutation carrying an idempotency key, and then waits for the new value to arrive
over the live subscription rather than polling again. Only when all three agree
does it print its final `verified count: 0 -> 1` line.

Starting the subscription *before* the mutation is the interesting part. That
ordering is what makes the update impossible to miss, and it is what a polling
client cannot promise.

## What works

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

The shared evaluator awarded the `http` and `live` badges from a clean
exact-head build: 31 of 31 conformance checks against a local backend and 31 of
31 against the hosted deployment over real TLS.

## The example

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

## Docker verification

```sh
./run test smalltalk
./run verify-example smalltalk
./run verify smalltalk
./run verify-hosted smalltalk
./run verify-all smalltalk
```

`./run test smalltalk` builds the image, loads every checked-in source file into
a scratch Pharo image, runs the whole SUnit suite, then builds the two saved
runtime images and probes their real entry points. It fails if a file does not
compile, if any test fails, if fewer tests run than expected, or if a saved image
still evaluates arbitrary Smalltalk.

`./run verify-example smalltalk` runs the exact program printed above, in the
minimal example image, against its own room on the approved deployment. It fails
on any unexpected value, not merely on a crash.

`./run verify smalltalk` adds the shared black-box conformance suite against the
approved local backend, and `./run verify-hosted smalltalk` repeats it against
the hosted drift target. `./run verify-all smalltalk` runs both profiles from one
build.

## Under the hood

**Pins.** The Pharo image is build 1258, commit `1645336`, and the headless
virtual machine is `v12.0.3-beta+33.23e5a5a`. Both are downloaded by immutable
URL and checked by SHA-256 in the Dockerfile. The Convex sync profile is pinned
in [`manifest.yaml`](manifest.yaml).

**Transports.** HTTPS goes through `ZnClient`, with redirects and retries turned
off, a bounded maximum entity size, and one addition: Zodiac completes a TLS
handshake without judging the certificate chain, so `ConvexHttpsClient` asserts a
zero verification state before any request body is written. The Live client does
the same after its own handshake.

**Framing.** `ConvexWebSocket` implements the client half of RFC 6455: masked
client frames, fragmentation with a byte budget, ping and pong, a bounded close
handshake, and rejection of masked server frames, reserved bits, unassigned
opcodes and non-minimal length encodings. Its reader is an explicit state machine
that consumes one byte at a time, so a deadline that expires halfway through a
frame leaves the parser exactly where it was instead of resynchronising at a
false boundary. There is a deterministic test for precisely that.
One absolute five-second deadline starts with the first byte and survives across
short owner polls, so a peer cannot keep a partial frame alive by dribbling one
byte before each poll expires.

**JSON.** Pharo ships STON, whose reader also accepts STON syntax and will
instantiate a class named in the document. Convex values arrive from the network,
so this client parses JSON with its own strict reader instead: RFC 8259 only,
bounded to 2 MiB, 128 levels of nesting and 8192 structural nodes, with surrogate
pairs joined and lone surrogates refused.

**Live ownership.** One process owns the socket, the query set version, every
reconnection and every publication. Subscribing, unsubscribing, the adapter-only
disconnect and closing are all commands sent to that owner and acknowledged by
it, so no other process ever touches the stream. Unsubscribe invalidates the
subscription before it acknowledges, which is what lets the conformance adapter
prove that a relay paused mid-publish cannot emit a stale value afterwards.

A whole `Transition` is validated before any part of it is published: the start
version must match local state, the timestamp must not move backwards, and every
modification must parse. Reconnection replays the full active `Add` set from
query set version zero and suppresses the unchanged rehydration the server sends,
so the observable sequence stays initial value, disconnect acknowledgement,
external mutation, new value.

**Buffering.** The Live owner keeps the newest 16 deliveries within a 20 MiB
budget charged from the encoded value, logs and structured error data plus a
per-entry overhead; consumers poll that queue rather than owning mailboxes of
their own, so a slow consumer cannot grow memory. The conformance adapter keeps
its own newest-16 output bound within 6 MiB including the line being written.
Subscription values there are newest-wins, while command responses are never
dropped, because a controller waiting for an acknowledgement would hang.

**Conformance executable.** [`client/tests/conformance/ConvexAdapter.st`](client/tests/conformance/ConvexAdapter.st)
speaks NDJSON adapter protocol v1 over stdin and stdout, or over TCP when
`ADAPTER_LISTEN` is set. It is test infrastructure, not client API: the
`debugDisconnect` hook it needs is compiled as an extension in that file alone,
so it never exists in the image the example runs in, and the example build fails
if it leaks.

**Runtime shape.** Each entry point is a separate saved Pharo image. Before the
snapshot, the build removes every interactive command handler: evaluate, file-in,
save, test, package loading and the rest. The Docker build then proves the saved
images refuse to evaluate `1 + 1`. The virtual machine is installed outside
`PATH`, so the only commands the runtime images offer are
`/usr/local/bin/convex-adapter` and `/usr/local/bin/convex-example`. Pharo's
compiler remains inside the image because a Smalltalk image needs it to boot;
that is documented rather than hidden.

## Limitations

- Live authentication, optimistic updates, WebSocket mutations and actions,
  journals, extended Convex value tags, and `TransitionChunk` assembly are all
  deferred. Only the JSON-safe Convex value subset is carried.
- Byte-at-a-time frame reading is what makes mid-frame timeouts safe, but it
  makes very large Live frames slower than a bulk reader would be.
- The certificate verification assertions are written but have not yet met a
  real bad certificate inside Docker.
- The saved images ship without a changes file. Docker entrypoint probes passed
  on a read-only filesystem without one.
- The shared site and README projection has no syntax-highlighting entry for
  `.st`, so the example above renders as plain text. Changing that belongs to
  shared infrastructure, not to this language directory.
