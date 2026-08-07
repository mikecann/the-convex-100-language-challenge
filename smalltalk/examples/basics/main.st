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
