"Test-only NDJSON adapter for the shared conformance controller.

 This file is loaded into the adapter image only. It calls the real client for
 every operation, reserves stdout for protocol events and sends diagnostics to
 stderr. It is not part of the educational client API, which is why the
 adapter-only debugDisconnect hook is added here as an extension rather than
 living in Convex.st.

 The exclamation mark separates chunks in this format, so it never appears in
 this file."

Object subclass: #ConvexAdapterChannel
	instanceVariableNames: 'maximumLineBytes'
	classVariableNames: ''
	package: 'Convex-Conformance'!

ConvexAdapterChannel subclass: #ConvexAdapterStdioChannel
	instanceVariableNames: 'input output'
	classVariableNames: ''
	package: 'Convex-Conformance'!

ConvexAdapterChannel subclass: #ConvexAdapterSocketChannel
	instanceVariableNames: 'listener socket stream'
	classVariableNames: ''
	package: 'Convex-Conformance'!

Object subclass: #ConvexAdapterPublisher
	instanceVariableNames: 'channel queue queuedBytes inFlightBytes lock ready writer stopped droppedCount failure'
	classVariableNames: ''
	package: 'Convex-Conformance'!

Object subclass: #ConvexAdapter
	instanceVariableNames: 'client subscriptions relays publisher lock finished'
	classVariableNames: ''
	package: 'Convex-Conformance'!

CommandLineHandler subclass: #ConvexAdapterCommandLineHandler
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'Convex-Conformance'!


!ConvexClient methodsFor: 'conformance only'!
convexAdapterDebugDisconnect
	"Adapter-only. It is compiled into the conformance image and nowhere else, so
	 the educational client API never offers a way to drop a healthy connection.
	 The Live owner acknowledges only after the old socket is retired and the
	 reconnect is scheduled."
	self assertOpen.
	^ (self liveManager submit: 'debugDisconnect' arguments: #()) waitMilliseconds: 10000
! !


!ConvexAdapterChannel methodsFor: 'accessing'!
maximumLineBytes
	^ maximumLineBytes ifNil: [ maximumLineBytes := 1024 * 1024 ]
!
readLine
	^ self subclassResponsibility
!
writeBytes: aByteArray
	^ self subclassResponsibility
!
close
	^ self subclassResponsibility
!
lineFrom: aWriteStream
	"CRLF is accepted but never preserved, so a controller on either convention
	 produces the same command bytes."
	| bytes |
	bytes := aWriteStream contents.
	(bytes isEmpty not and: [ bytes last = 13 ]) ifTrue: [
		bytes := bytes copyFrom: 1 to: bytes size - 1 ].
	^ bytes
! !


!ConvexAdapterStdioChannel class methodsFor: 'instance creation'!
new
	^ super new setInput: Stdio stdin output: Stdio stdout
! !

!ConvexAdapterStdioChannel methodsFor: 'accessing'!
setInput: anInput output: anOutput
	input := anInput.
	output := anOutput
!
readLine
	"Read a byte at a time so a hostile controller cannot make the adapter
	 allocate an unbounded String before the limit is checked. waitForData parks
	 only this process, so the Live owner keeps running while stdin is idle."
	| out chunk |
	out := WriteStream on: (ByteArray new: 256).
	[
		chunk := input next: 1.
		chunk isEmpty
			ifTrue: [
				input waitForData.
				chunk := input next: 1.
				chunk isEmpty ifTrue: [
					^ out contents isEmpty ifTrue: [ nil ] ifFalse: [ self lineFrom: out ] ] ].
		chunk first = 10
			ifTrue: [ ^ self lineFrom: out ]
			ifFalse: [
				out nextPut: chunk first.
				out position > self maximumLineBytes ifTrue: [
					^ (ConvexProtocolError message: 'adapter input line exceeds 1 MiB') signal ] ]
	] repeat
!
writeBytes: aByteArray
	output nextPutAll: aByteArray; flush
!
close
	[ output flush ] on: Error do: [ :ignored | nil ].
	[ input releaseSemaphores ] on: Error do: [ :ignored | nil ]
! !


!ConvexAdapterSocketChannel class methodsFor: 'instance creation'!
listeningOn: anAddressString
	^ self new listenOn: anAddressString
! !

!ConvexAdapterSocketChannel methodsFor: 'accessing'!
listenOn: anAddressString
	"ADAPTER_LISTEN carries one host:port address. Exactly one controller
	 connection is accepted, then the same bounded NDJSON stream runs over it."
	| colon port accepted |
	colon := anAddressString lastIndexOf: $:.
	colon = 0 ifTrue: [
		^ (ConvexProtocolError message: 'ADAPTER_LISTEN must be host:port') signal ].
	port := [ (anAddressString copyFrom: colon + 1 to: anAddressString size) asInteger ]
		on: Error
		do: [ :error | nil ].
	(port notNil and: [ port between: 1 and: 65535 ]) ifFalse: [
		^ (ConvexProtocolError message: 'ADAPTER_LISTEN port is invalid') signal ].
	listener := Socket newTCP.
	listener listenOn: port backlogSize: 1.
	accepted := listener waitForAcceptFor: 60.
	accepted ifNil: [
		[ listener closeAndDestroy ] on: Error do: [ :ignored | nil ].
		^ (ConvexTransportError message: 'timed out waiting for the adapter controller') signal ].
	socket := accepted.
	stream := ZnNetworkingUtils default socketStreamOn: socket.
	stream
		binary;
		timeout: 1.
	^ self
!
readLine
	"Zodiac raises on a read timeout rather than answering a short count, so an
	 idle controller shows up here as a timeout and simply means keep waiting."
	| out byte |
	out := WriteStream on: (ByteArray new: 256).
	[
		byte := [ stream next ]
			on: Error
			do: [ :error |
				(error isKindOf: ConnectionTimedOut)
					ifTrue: [ 0 - 1 ]
					ifFalse: [ (ConvexTransportError message: 'adapter socket read failed: ', (error messageText ifNil: [ error class name ])) signal ] ].
		byte
			ifNil: [ ^ out contents isEmpty ifTrue: [ nil ] ifFalse: [ self lineFrom: out ] ]
			ifNotNil: [
				byte >= 0 ifTrue: [
					byte = 10
						ifTrue: [ ^ self lineFrom: out ]
						ifFalse: [
							out nextPut: byte.
							out position > self maximumLineBytes ifTrue: [
								^ (ConvexProtocolError message: 'adapter input line exceeds 1 MiB') signal ] ] ] ]
	] repeat
!
writeBytes: aByteArray
	stream nextPutAll: aByteArray; flush
!
close
	[ stream ifNotNil: [ stream close ] ] on: Error do: [ :ignored | nil ].
	[ listener ifNotNil: [ listener closeAndDestroy ] ] on: Error do: [ :ignored | nil ]
! !


!ConvexAdapterPublisher class methodsFor: 'limits'!
maximumEventBytes
	"The client accepts a 2 MiB Convex response. Its adapter envelope adds a small
	 amount, so the output line limit must not reject a value the real client has
	 already accepted. The independent 6 MiB queue budget remains the tighter
	 stopped-reader bound."
	^ 3 * 1024 * 1024
!
maximumQueuedEvents
	^ 16
!
maximumQueuedBytes
	"Encoded output plus the line currently being written. Sixteen near-maximum
	 events stay far below the shared 128 MiB adapter limit even with the
	 controller stopped."
	^ 6 * 1024 * 1024
! !

!ConvexAdapterPublisher class methodsFor: 'instance creation'!
on: aChannel
	^ self new setChannel: aChannel
! !

!ConvexAdapterPublisher methodsFor: 'publishing'!
setChannel: aChannel
	channel := aChannel.
	queue := OrderedCollection new.
	queuedBytes := 0.
	inFlightBytes := 0.
	droppedCount := 0.
	failure := nil.
	stopped := false.
	lock := Semaphore forMutualExclusion.
	ready := Semaphore new.
	writer := [ self writerLoop ] forkAt: Processor userBackgroundPriority.
	^ self
!
emit: anEvent droppable: aBoolean
	"One writer process owns publication, so subscription relays and the command
	 loop can never interleave halves of two NDJSON lines."
	| line |
	stopped ifTrue: [
		^ (failure
			ifNil: [ ConvexTransportError message: 'adapter publisher is stopped' ]
			ifNotNil: [ failure ]) signal ].
	line := ConvexJson renderToBytes: anEvent.
	line size + 1 > self class maximumEventBytes ifTrue: [
		^ (ConvexProtocolError message: 'adapter event exceeds 3 MiB') signal ].
	lock critical: [
		self makeRoomFor: line size + 1 droppable: aBoolean.
		queue addLast: (Array with: line with: aBoolean).
		queuedBytes := queuedBytes + line size + 1 ].
	ready signal
!
makeRoomFor: aByteCount droppable: aBoolean
	"Bounded newest-wins for subscription values. Command responses are never
	 dropped, because a controller waiting for an acknowledgement would hang."
	| victim |
	[ (queue size >= self class maximumQueuedEvents)
		or: [ queuedBytes + inFlightBytes + aByteCount > self class maximumQueuedBytes ] ] whileTrue: [
		victim := queue detect: [ :each | each second ] ifNone: [ nil ].
		victim ifNil: [
			^ (ConvexTransportError message: 'adapter output is blocked and the queue is full of command responses') signal ].
		queue remove: victim.
		queuedBytes := queuedBytes - victim first size - 1.
		droppedCount := droppedCount + 1 ]
!
writerLoop
	| item |
	[ stopped ] whileFalse: [
		ready wait.
		[
			item := lock critical: [
				queue isEmpty
					ifTrue: [ nil ]
					ifFalse: [ | first |
						first := queue removeFirst.
						queuedBytes := queuedBytes - first first size - 1.
						inFlightBytes := first first size + 1.
						first ] ].
			item ifNotNil: [
				[ channel writeBytes: (item first copyWith: 10) ]
					ensure: [ lock critical: [ inFlightBytes := 0 ] ] ]
		] on: Error do: [ :error | self reportWriteFailure: error ] ]
!
reportWriteFailure: anError
	"The controller is gone. Record the failure and close the read side too, so
	 the command loop wakes and the adapter exits non-zero instead of remaining
	 alive with a dead publisher."
	failure := (anError isKindOf: ConvexError)
		ifTrue: [ anError ]
		ifFalse: [ ConvexTransportError message: (anError messageText ifNil: [ 'adapter output failed' ]) ].
	stopped := true.
	[ Stdio stderr nextPutAll: (ZnUTF8Encoder new encodeString: 'adapter output failed: ', (anError messageText ifNil: [ 'unknown' ]), String lf); flush ]
		on: Error
		do: [ :ignored | nil ].
	self closeChannel
!
raiseIfFailed
	failure ifNotNil: [ ^ failure signal ]
!
droppedCount
	^ lock critical: [ droppedCount ]
!
queuedBytes
	^ lock critical: [ queuedBytes ]
!
flushWithin: milliseconds
	| deadline |
	deadline := ConvexDeadline afterMilliseconds: milliseconds.
	[ (lock critical: [ queue isEmpty and: [ inFlightBytes = 0 ] ]) or: [ deadline isExpired ] ]
		whileFalse: [ (Delay forMilliseconds: 5) wait ]
!
stop
	stopped := true.
	ready signal.
	[ writer isTerminated ifFalse: [ writer terminate ] ] on: Error do: [ :ignored | nil ]
! !


!ConvexAdapter class methodsFor: 'running'!
run
	"Entry point of the adapter image. CONVEX_URL is required, ADAPTER_LISTEN
	 selects the TCP mode the shared harness uses."
	| environment deployment listen channel adapter |
	environment := OSEnvironment current.
	deployment := environment at: 'CONVEX_URL' ifAbsent: [ nil ].
	deployment ifNil: [
		^ (ConvexTransportError message: 'CONVEX_URL is required') signal ].
	listen := environment at: 'ADAPTER_LISTEN' ifAbsent: [ nil ].
	channel := (listen isNil or: [ listen isEmpty ])
		ifTrue: [ ConvexAdapterStdioChannel new ]
		ifFalse: [ ConvexAdapterSocketChannel listeningOn: listen ].
	adapter := self
		client: (ConvexClient
			deployment: deployment
			bearerToken: (environment at: 'CONVEX_AUTH_TOKEN' ifAbsent: [ nil ]))
		channel: channel.
	^ adapter runLoop
!
client: aClient channel: aChannel
	^ self new setClient: aClient channel: aChannel
! !

!ConvexAdapter methodsFor: 'initialization'!
setClient: aClient channel: aChannel
	client := aClient.
	subscriptions := Dictionary new.
	relays := Dictionary new.
	lock := Semaphore forMutualExclusion.
	finished := false.
	publisher := ConvexAdapterPublisher on: aChannel.
	^ self
!
publisher
	^ publisher
!
subscriptionAt: anIdentifier
	^ lock critical: [ subscriptions at: anIdentifier ifAbsent: [ nil ] ]
! !

!ConvexAdapter methodsFor: 'running'!
runLoop
	| line command |
	^ [
		[ finished ] whileFalse: [
			line := publisher channelReadLine.
			line ifNil: [ publisher raiseIfFailed. ^ self shutDown ].
			line isEmpty ifFalse: [
				command := [ self parseCommand: line ]
					on: ConvexError
					do: [ :error | self emitErrorEvent: error id: nil. nil ].
				command ifNotNil: [ self dispatch: command ] ] ]
	] ensure: [ self shutDown ]
!
shutDown
	finished := true.
	self terminateAllRelays.
	[ client close ] on: Error do: [ :ignored | nil ].
	publisher flushWithin: 2000.
	publisher stop.
	publisher closeChannel
! !

!ConvexAdapter methodsFor: 'parsing'!
parseCommand: aLine
	| parsed |
	parsed := ConvexJson parseBytes: aLine.
	self validateCommand: parsed.
	^ parsed
!
validateCommand: aCommand
	"Reject anything the shared schema would reject, before the value reaches the
	 client and before any part of it is echoed back."
	| operation allowed |
	ConvexJson assertObject: aCommand named: 'adapter command'.
	operation := ConvexJson assertString: (aCommand at: 'op' ifAbsent: [ nil ]) named: 'adapter op'.
	allowed := self allowedFieldsFor: operation.
	(aCommand keys allSatisfy: [ :key | allowed includes: key ]) ifFalse: [
		^ (ConvexProtocolError message: 'adapter command has an unknown field') signal ].
	self validateIdentifier: (aCommand at: 'id' ifAbsent: [ nil ]) named: 'id'.
	operation = 'hello' ifTrue: [
		(aCommand at: 'protocolVersion' ifAbsent: [ nil ]) = 1 ifFalse: [
			^ (ConvexProtocolError message: 'unsupported adapter protocol version') signal ] ].
	(#('query' 'mutation' 'action') includes: operation) ifTrue: [
		self validatePath: (aCommand at: 'path' ifAbsent: [ nil ]).
		ConvexJson assertObject: (aCommand at: 'args' ifAbsent: [ nil ]) named: 'args' ].
	(#('subscribe' 'unsubscribe') includes: operation) ifTrue: [
		self validateIdentifier: (aCommand at: 'subscriptionId' ifAbsent: [ nil ]) named: 'subscriptionId'.
		operation = 'subscribe' ifTrue: [
			self validatePath: (aCommand at: 'path' ifAbsent: [ nil ]).
			ConvexJson assertObject: (aCommand at: 'args' ifAbsent: [ nil ]) named: 'args' ] ].
	operation = 'setAuth' ifTrue: [
		ConvexJson assertString: (aCommand at: 'token' ifAbsent: [ nil ]) named: 'token' ].
	^ aCommand
!
allowedFieldsFor: anOperation
	anOperation = 'hello' ifTrue: [ ^ #('protocolVersion' 'id' 'op') ].
	(#('query' 'mutation' 'action') includes: anOperation) ifTrue: [ ^ #('id' 'op' 'path' 'args') ].
	anOperation = 'subscribe' ifTrue: [ ^ #('id' 'op' 'subscriptionId' 'path' 'args') ].
	anOperation = 'unsubscribe' ifTrue: [ ^ #('id' 'op' 'subscriptionId') ].
	anOperation = 'setAuth' ifTrue: [ ^ #('id' 'op' 'token') ].
	(#('close' 'debugDisconnect') includes: anOperation) ifTrue: [ ^ #('id' 'op') ].
	^ (ConvexProtocolError message: 'unknown adapter operation: ', anOperation) signal
!
validateIdentifier: aValue named: aName
	((aValue isString and: [ aValue isEmpty not ]) and: [ aValue size <= 128 ]) ifFalse: [
		^ (ConvexProtocolError message: aName, ' must be a string of one to 128 characters') signal ].
	^ aValue
!
validatePath: aValue
	((aValue isString and: [ aValue size >= 3 ])
		and: [ ((aValue includes: Character cr) or: [ aValue includes: Character lf ]) not ]) ifFalse: [
		^ (ConvexProtocolError message: 'function path is invalid') signal ].
	^ aValue
! !

!ConvexAdapter methodsFor: 'dispatching'!
dispatch: aCommand
	| operation identifier |
	operation := aCommand at: 'op'.
	identifier := aCommand at: 'id'.
	^ [
		operation = 'hello' ifTrue: [ ^ self emitReady: identifier ].
		(#('query' 'mutation' 'action') includes: operation) ifTrue: [
			^ self runCall: operation command: aCommand id: identifier ].
		operation = 'setAuth' ifTrue: [
			client setBearerToken: (aCommand at: 'token').
			^ self emitAck: identifier ].
		operation = 'subscribe' ifTrue: [ ^ self runSubscribe: aCommand id: identifier ].
		operation = 'unsubscribe' ifTrue: [ ^ self runUnsubscribe: aCommand id: identifier ].
		operation = 'debugDisconnect' ifTrue: [
			client convexAdapterDebugDisconnect.
			^ self emitAck: identifier ].
		operation = 'close' ifTrue: [
			finished := true.
			self terminateAllRelays.
			client close.
			^ self emitClosed: identifier ].
		(ConvexProtocolError message: 'unknown adapter operation: ', operation) signal
	] on: Error do: [ :error | self emitErrorEvent: error id: identifier ]
!
runCall: anOperation command: aCommand id: anIdentifier
	| result |
	result := client call: anOperation path: (aCommand at: 'path') args: (aCommand at: 'args').
	^ self emit: (ConvexJson objectWith: {
		'id' -> anIdentifier.
		'type' -> 'result'.
		'value' -> result value.
		'logs' -> result logs }) droppable: false
!
runSubscribe: aCommand id: anIdentifier
	"A same-identifier subscribe replaces the old one. The replacement is
	 installed and the old relay invalidated before the acknowledgement, so a
	 value queued for the old subscription can never cross this ack."
	| subscriptionId subscription |
	subscriptionId := aCommand at: 'subscriptionId'.
	self retireSubscriptionNamed: subscriptionId.
	subscription := client subscribe: (aCommand at: 'path') args: (aCommand at: 'args').
	lock critical: [ subscriptions at: subscriptionId put: subscription ].
	self startRelayFor: subscription named: subscriptionId.
	^ self emitAck: anIdentifier
!
runUnsubscribe: aCommand id: anIdentifier
	self retireSubscriptionNamed: (aCommand at: 'subscriptionId').
	^ self emitAck: anIdentifier
!
retireSubscriptionNamed: anIdentifier
	"Remove the mapping first, then close the subscription in the Live owner, then
	 stop the relay. After this returns, the relay identity check below fails for
	 the retired subscription no matter where it was paused."
	| previous relay |
	previous := lock critical: [ subscriptions removeKey: anIdentifier ifAbsent: [ nil ] ].
	relay := lock critical: [ relays removeKey: anIdentifier ifAbsent: [ nil ] ].
	previous ifNotNil: [ [ previous close ] on: Error do: [ :ignored | nil ] ].
	relay ifNotNil: [ [ relay isTerminated ifFalse: [ relay terminate ] ] on: Error do: [ :ignored | nil ] ].
	^ previous
!
terminateAllRelays
	| current |
	current := lock critical: [ | copy | copy := relays values asArray. relays := Dictionary new. copy ].
	current do: [ :relay |
		[ relay isTerminated ifFalse: [ relay terminate ] ] on: Error do: [ :ignored | nil ] ]
! !

!ConvexAdapter methodsFor: 'relaying'!
startRelayFor: aSubscription named: anIdentifier
	| relay |
	relay := [ self relayLoopFor: aSubscription named: anIdentifier ]
		forkAt: Processor userBackgroundPriority.
	lock critical: [ relays at: anIdentifier put: relay ]
!
relayLoopFor: aSubscription named: anIdentifier
	"The relay never touches a socket. It only moves owner-created updates into
	 the bounded publisher, and it re-checks the subscription identity after the
	 dequeue rather than before it."
	| update |
	[ finished ] whileFalse: [
		update := [ aSubscription nextWithinMilliseconds: 250 ]
			on: Error
			do: [ :ignored | nil ].
		update ifNotNil: [
			self publishRelayUpdate: update for: aSubscription named: anIdentifier ] ]
!
publishRelayUpdate: anUpdate for: aSubscription named: anIdentifier
	| current |
	current := self subscriptionAt: anIdentifier.
	(current == aSubscription and: [ aSubscription isActive ]) ifFalse: [ ^ self ].
	anUpdate error
		ifNil: [
			^ self emit: (ConvexJson objectWith: {
				'type' -> 'subscription'.
				'subscriptionId' -> anIdentifier.
				'value' -> anUpdate value.
				'logs' -> anUpdate logs }) droppable: true ]
		ifNotNil: [ :error |
			^ self emit: (ConvexJson objectWith: {
				'type' -> 'subscription'.
				'subscriptionId' -> anIdentifier.
				'error' -> (self errorObjectFor: error) }) droppable: true ]
! !

!ConvexAdapter methodsFor: 'emitting'!
emit: anEvent droppable: aBoolean
	^ publisher emit: anEvent droppable: aBoolean
!
emitReady: anIdentifier
	^ self emit: (ConvexJson objectWith: {
		'protocolVersion' -> 1.
		'id' -> anIdentifier.
		'type' -> 'ready'.
		'language' -> 'smalltalk'.
		'implementation' -> 'native-pharo12-zinc-zodiac-rfc6455'.
		'runtime' -> ('Pharo ', SystemVersion current dottedMajorMinorPatch) }) droppable: false
!
emitAck: anIdentifier
	^ self emit: (ConvexJson objectWith: {
		'id' -> anIdentifier.
		'type' -> 'ack' }) droppable: false
!
emitClosed: anIdentifier
	^ self emit: (ConvexJson objectWith: {
		'id' -> anIdentifier.
		'type' -> 'closed' }) droppable: false
!
emitErrorEvent: anError id: anIdentifier
	"An absent id is omitted rather than serialised as null, because the shared
	 schema does not permit a null identifier."
	| event |
	event := ConvexJson object.
	anIdentifier ifNotNil: [ event at: 'id' put: anIdentifier ].
	event at: 'type' put: 'error'.
	event at: 'error' put: (self errorObjectFor: anError).
	^ [ self emit: event droppable: false ]
		on: Error
		do: [ :ignored | nil ]
!
errorObjectFor: anError
	| kind detail |
	kind := (anError isKindOf: ConvexError) ifTrue: [ anError kind ] ifFalse: [ 'TransportError' ].
	detail := ConvexJson objectWith: {
		'name' -> kind.
		'kind' -> kind.
		'message' -> (anError messageText ifNil: [ anError class name ]) }.
	(anError isKindOf: ConvexError) ifTrue: [
		anError data ifNotNil: [ :value | detail at: 'data' put: value ] ].
	^ detail
! !


!ConvexAdapterPublisher methodsFor: 'channel'!
channelReadLine
	^ channel readLine
!
closeChannel
	[ channel close ] on: Error do: [ :ignored | nil ]
! !


!ConvexAdapterCommandLineHandler class methodsFor: 'accessing'!
commandName
	^ 'convex-adapter'
!
description
	^ 'Run the test-only Convex NDJSON conformance adapter'
! !

!ConvexAdapterCommandLineHandler methodsFor: 'activation'!
activate
	[ ConvexAdapter run ]
		on: Error
		do: [ :error |
			[ Stdio stderr
				nextPutAll: (ZnUTF8Encoder new encodeString: (error messageText ifNil: [ error class name ]), String lf);
				flush ] on: Error do: [ :ignored | nil ].
			^ self exitFailure ].
	^ self exitSuccess
! !
