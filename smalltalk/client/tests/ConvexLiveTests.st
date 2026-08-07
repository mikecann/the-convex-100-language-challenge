"Deterministic coverage for Live ownership and the conformance adapter.

 The Live owner is driven through a scripted WebSocket so every ordering claim
 is reproducible: Add and Remove, an initial value, an external update, a
 QueryFailed followed by recovery, five real reconnects with replay and
 suppressed rehydration, backoff reset, and a bounded delivery queue with a
 stopped consumer.

 The adapter is driven through a scripted channel, including a relay paused
 after dequeue, which is the only way to prove that no stale event crosses an
 unsubscribe or a same-identifier replacement.

 The exclamation mark separates chunks in this format, so it never appears in
 this file."

Object subclass: #ConvexFakeWebSocket
	instanceVariableNames: 'sent queued closed lock'
	classVariableNames: ''
	package: 'Convex-Tests'!

ConvexLiveManager subclass: #ConvexScriptedLiveManager
	instanceVariableNames: 'pendingSockets openedSockets socketLock'
	classVariableNames: ''
	package: 'Convex-Tests'!

Object subclass: #ConvexFakeSubscription
	instanceVariableNames: 'updates active closeCount'
	classVariableNames: ''
	package: 'Convex-Tests'!

Object subclass: #ConvexFakeClient
	instanceVariableNames: 'subscriptionsMade results closed disconnects'
	classVariableNames: ''
	package: 'Convex-Tests'!

ConvexAdapterChannel subclass: #ConvexFakeAdapterChannel
	instanceVariableNames: 'lines written closed blocked failWrites'
	classVariableNames: ''
	package: 'Convex-Tests'!

TestCase subclass: #ConvexLiveTests
	instanceVariableNames: 'manager'
	classVariableNames: ''
	package: 'Convex-Tests'!

TestCase subclass: #ConvexAdapterTests
	instanceVariableNames: 'channel adapter client'
	classVariableNames: ''
	package: 'Convex-Tests'!


!ConvexFakeWebSocket class methodsFor: 'instance creation'!
new
	^ super new initializeFake
! !

!ConvexFakeWebSocket methodsFor: 'testing support'!
initializeFake
	sent := OrderedCollection new.
	queued := OrderedCollection new.
	closed := false.
	lock := Semaphore forMutualExclusion
!
queueText: aString
	lock critical: [
		queued addLast: (ConvexWebSocketFrame
			final: true
			opcode: ConvexWebSocket opcodeText
			payload: (ZnUTF8Encoder new encodeString: aString)) ]
!
sentMessages
	^ lock critical: [ sent asArray ]
!
lastSentOfType: aType
	| matches |
	matches := self sentMessages select: [ :each |
		((ConvexJson parseString: each) at: 'type' ifAbsent: [ nil ]) = aType ].
	^ matches isEmpty ifTrue: [ nil ] ifFalse: [ ConvexJson parseString: matches last ]
! !

!ConvexFakeWebSocket methodsFor: 'socket protocol'!
sendText: aString
	closed ifTrue: [ ^ (ConvexTransportError message: 'fake socket is closed') signal ].
	lock critical: [ sent addLast: aString ]
!
sendPongWith: aByteArray
	^ self
!
readFrameWithin: milliseconds
	| frame |
	frame := lock critical: [ queued isEmpty ifTrue: [ nil ] ifFalse: [ queued removeFirst ] ].
	frame ifNil: [ (Delay forMilliseconds: (milliseconds min: 5)) wait ].
	^ frame
!
closeWithin: milliseconds
	closed := true
!
abandon
	closed := true
!
isClosed
	^ closed
! !


!ConvexScriptedLiveManager methodsFor: 'testing support'!
setDeployment: aUrlString clientVersion: aVersion
	"Prepare the socket script before super forks the owner process."
	pendingSockets := OrderedCollection new.
	openedSockets := OrderedCollection new.
	socketLock := Semaphore forMutualExclusion.
	^ super setDeployment: aUrlString clientVersion: aVersion
!
provideSocket: aSocket
	socketLock critical: [ pendingSockets addLast: aSocket ]
!
openSocket
	| next |
	next := socketLock critical: [
		pendingSockets isEmpty ifTrue: [ nil ] ifFalse: [ pendingSockets removeFirst ] ].
	next ifNil: [
		^ (ConvexTransportError message: 'no scripted socket is available') signal ].
	socketLock critical: [ openedSockets addLast: next ].
	^ next
!
openedSockets
	^ socketLock critical: [ openedSockets asArray ]
! !


!ConvexFakeSubscription class methodsFor: 'instance creation'!
new
	^ super new initializeFake
! !

!ConvexFakeSubscription methodsFor: 'testing support'!
initializeFake
	updates := OrderedCollection new.
	active := true.
	closeCount := 0
!
queueUpdate: anUpdate
	updates addLast: anUpdate
!
closeCount
	^ closeCount
! !

!ConvexFakeSubscription methodsFor: 'subscription protocol'!
nextWithinMilliseconds: milliseconds
	updates isEmpty ifTrue: [
		(Delay forMilliseconds: (milliseconds min: 5)) wait.
		^ nil ].
	^ updates removeFirst
!
isActive
	^ active
!
close
	closeCount := closeCount + 1.
	active := false
! !


!ConvexFakeClient class methodsFor: 'instance creation'!
new
	^ super new initializeFake
! !

!ConvexFakeClient methodsFor: 'testing support'!
initializeFake
	subscriptionsMade := OrderedCollection new.
	results := OrderedCollection new.
	disconnects := 0.
	closed := false
!
queueResult: aResult
	results addLast: aResult
!
subscriptionsMade
	^ subscriptionsMade asArray
!
disconnects
	^ disconnects
!
isClosed
	^ closed
! !

!ConvexFakeClient methodsFor: 'client protocol'!
call: anOperation path: aPath args: someArguments
	results isEmpty ifTrue: [
		^ (ConvexFunctionError message: 'no scripted result' data: nil logs: #() operation: anOperation) signal ].
	^ results removeFirst
!
subscribe: aPath args: someArguments
	| subscription |
	subscription := ConvexFakeSubscription new.
	subscriptionsMade addLast: subscription.
	^ subscription
!
setBearerToken: aToken
	^ self
!
convexAdapterDebugDisconnect
	disconnects := disconnects + 1.
	^ true
!
close
	closed := true
! !


!ConvexFakeAdapterChannel class methodsFor: 'instance creation'!
new
	^ super new initializeFake
! !

!ConvexFakeAdapterChannel methodsFor: 'testing support'!
initializeFake
	lines := OrderedCollection new.
	written := WriteStream on: (ByteArray new: 256).
	closed := false.
	blocked := false.
	failWrites := false
!
scriptLine: aString
	lines addLast: (ZnUTF8Encoder new encodeString: aString)
!
emittedLines
	^ (ZnUTF8Encoder new decodeBytes: written contents) lines
!
blockWrites
	"Stand in for a controller that has stopped reading its end of the pipe."
	blocked := true
!
failWrites
	failWrites := true
!
isClosed
	^ closed
! !

!ConvexFakeAdapterChannel methodsFor: 'channel protocol'!
readLine
	^ lines isEmpty ifTrue: [ nil ] ifFalse: [ lines removeFirst ]
!
writeBytes: aByteArray
	failWrites ifTrue: [ ^ (ConvexTransportError message: 'scripted write failure') signal ].
	[ blocked ] whileTrue: [ (Delay forMilliseconds: 10) wait ].
	written nextPutAll: aByteArray
!
close
	closed := true
! !


!ConvexLiveTests methodsFor: 'helpers'!
tearDown
	manager ifNotNil: [ [ manager close ] on: Error do: [ :ignored | nil ] ].
	manager := nil.
	super tearDown
!
newManager
	manager := ConvexScriptedLiveManager
		deployment: 'https://example.convex.cloud'
		clientVersion: 'smalltalk-0.1.0'.
	^ manager
!
waitUntil: aBlock
	| deadline |
	deadline := ConvexDeadline afterMilliseconds: 5000.
	[ aBlock value or: [ deadline isExpired ] ] whileFalse: [ (Delay forMilliseconds: 5) wait ].
	^ aBlock value
!
versionWithQuerySet: aQuerySet timestamp: aTimestamp
	^ ConvexJson objectWith: {
		'querySet' -> aQuerySet.
		'identity' -> 0.
		'ts' -> (ConvexTimestamp encode: aTimestamp) }
!
transitionFrom: aStartTimestamp to: anEndTimestamp querySet: aQuerySet modifications: someModifications
	^ ConvexJson renderToString: (ConvexJson objectWith: {
		'type' -> 'Transition'.
		'startVersion' -> (self versionWithQuerySet: aQuerySet timestamp: aStartTimestamp).
		'endVersion' -> (self versionWithQuerySet: aQuerySet timestamp: anEndTimestamp).
		'modifications' -> someModifications })
!
queryUpdatedFor: aQueryId count: aCount
	^ ConvexJson objectWith: {
		'type' -> 'QueryUpdated'.
		'queryId' -> aQueryId.
		'value' -> (ConvexJson objectWith: { 'count' -> aCount }).
		'logLines' -> #() }
!
queryFailedFor: aQueryId message: aMessage
	^ ConvexJson objectWith: {
		'type' -> 'QueryFailed'.
		'queryId' -> aQueryId.
		'errorMessage' -> aMessage.
		'logLines' -> #() }
! !

!ConvexLiveTests methodsFor: 'tests - query set'!
testFirstConnectionSendsConnectThenTheActiveAddSet
	| socket subscription connect modify |
	socket := ConvexFakeWebSocket new.
	self newManager provideSocket: socket.
	self assert: (self waitUntil: [ socket sentMessages size >= 1 ]).
	connect := socket lastSentOfType: 'Connect'.
	self assert: (connect at: 'connectionCount') equals: 0.
	self assert: (connect at: 'lastCloseReason') equals: 'InitialConnect'.
	self assert: (connect at: 'sessionId') size equals: 32.
	subscription := manager subscribe: 'demo:state' args: (ConvexJson objectWith: { 'room' -> 'r' }).
	self assert: (self waitUntil: [ (socket lastSentOfType: 'ModifyQuerySet') notNil ]).
	modify := socket lastSentOfType: 'ModifyQuerySet'.
	self assert: (modify at: 'baseVersion') equals: 0.
	self assert: (modify at: 'newVersion') equals: 1.
	self assert: ((modify at: 'modifications') first at: 'type') equals: 'Add'.
	self assert: ((modify at: 'modifications') first at: 'udfPath') equals: 'demo:state'.
	self assert: ((modify at: 'modifications') first at: 'queryId') equals: subscription queryId.
	self assert: (((modify at: 'modifications') first at: 'args') first at: 'room') equals: 'r'
!
testUnsubscribeSendsRemoveAndInvalidatesBeforeItAcknowledges
	| socket subscription modify |
	socket := ConvexFakeWebSocket new.
	self newManager provideSocket: socket.
	subscription := manager subscribe: 'demo:state' args: ConvexJson object.
	self assert: (self waitUntil: [ (socket lastSentOfType: 'ModifyQuerySet') notNil ]).
	manager unsubscribe: subscription.
	"These hold at the instant the acknowledgement returned, not eventually."
	self deny: subscription isActive.
	self assert: manager activeSubscriptions isEmpty.
	modify := socket lastSentOfType: 'ModifyQuerySet'.
	self assert: ((modify at: 'modifications') first at: 'type') equals: 'Remove'.
	self assert: (modify at: 'newVersion') equals: 2
! !

!ConvexLiveTests methodsFor: 'tests - updates'!
testInitialValueAndExternalUpdateAreBothDelivered
	| socket subscription first second |
	socket := ConvexFakeWebSocket new.
	self newManager provideSocket: socket.
	subscription := manager subscribe: 'demo:state' args: ConvexJson object.
	self assert: (self waitUntil: [ (socket lastSentOfType: 'ModifyQuerySet') notNil ]).
	socket queueText: (self
		transitionFrom: 0 to: 100 querySet: 0
		modifications: (Array with: (self queryUpdatedFor: subscription queryId count: 0))).
	first := subscription nextWithinMilliseconds: 3000.
	self assert: first notNil.
	self assert: (first value at: 'count') equals: 0.
	socket queueText: (self
		transitionFrom: 100 to: 200 querySet: 0
		modifications: (Array with: (self queryUpdatedFor: subscription queryId count: 1))).
	second := subscription nextWithinMilliseconds: 3000.
	self assert: second notNil.
	self assert: (second value at: 'count') equals: 1.
	self assert: manager maxObservedTimestamp equals: 200
!
testQueryFailedIsStructuredAndTheSameSubscriptionRecovers
	| socket subscription failure recovery |
	socket := ConvexFakeWebSocket new.
	self newManager provideSocket: socket.
	subscription := manager subscribe: 'demo:state' args: ConvexJson object.
	self assert: (self waitUntil: [ (socket lastSentOfType: 'ModifyQuerySet') notNil ]).
	socket queueText: (self
		transitionFrom: 0 to: 100 querySet: 0
		modifications: (Array with: (self queryFailedFor: subscription queryId message: 'boom'))).
	failure := subscription nextWithinMilliseconds: 3000.
	self assert: failure notNil.
	self assert: failure error class equals: ConvexFunctionError.
	self assert: failure error kind equals: 'FunctionError'.
	self assert: failure error messageText equals: 'boom'.
	socket queueText: (self
		transitionFrom: 100 to: 200 querySet: 0
		modifications: (Array with: (self queryUpdatedFor: subscription queryId count: 4))).
	recovery := subscription nextWithinMilliseconds: 3000.
	self assert: recovery notNil.
	self assert: recovery error isNil.
	self assert: (recovery value at: 'count') equals: 4
!
testInvalidTransitionRetiresTheConnectionWithoutStrandingTheSubscription
	| first second subscription failure recovery |
	first := ConvexFakeWebSocket new.
	second := ConvexFakeWebSocket new.
	self newManager provideSocket: first.
	subscription := manager subscribe: 'demo:state' args: ConvexJson object.
	self assert: (self waitUntil: [ (first lastSentOfType: 'ModifyQuerySet') notNil ]).
	manager provideSocket: second.
	"A transition whose start version does not match local state is a protocol
	 failure, not a value."
	first queueText: (self
		transitionFrom: 500 to: 600 querySet: 0
		modifications: (Array with: (self queryUpdatedFor: subscription queryId count: 9))).
	failure := subscription nextWithinMilliseconds: 3000.
	self assert: failure notNil.
	self assert: failure error notNil.
	self assert: (self waitUntil: [ (second lastSentOfType: 'ModifyQuerySet') notNil ]).
	second queueText: (self
		transitionFrom: 0 to: 100 querySet: 0
		modifications: (Array with: (self queryUpdatedFor: subscription queryId count: 3))).
	recovery := subscription nextWithinMilliseconds: 3000.
	self assert: recovery notNil.
	self assert: recovery error isNil.
	self assert: (recovery value at: 'count') equals: 3
!
testTransitionCannotRepeatAQueryIdentifier
	| socket subscription failure |
	socket := ConvexFakeWebSocket new.
	self newManager provideSocket: socket.
	subscription := manager subscribe: 'demo:state' args: ConvexJson object.
	self assert: (self waitUntil: [ (socket lastSentOfType: 'ModifyQuerySet') notNil ]).
	socket queueText: (self
		transitionFrom: 0 to: 100 querySet: 0
		modifications: (Array
			with: (self queryUpdatedFor: subscription queryId count: 1)
			with: (self queryUpdatedFor: subscription queryId count: 2))).
	failure := subscription nextWithinMilliseconds: 3000.
	self assert: failure notNil.
	self assert: failure error class equals: ConvexProtocolError
! !

!ConvexLiveTests methodsFor: 'tests - reconnection'!
testFiveDebugDisconnectsReplayAddsAndSuppressUnchangedRehydration
	"This is the exact shape the shared controller checks: initial value, the
	 disconnect acknowledgement, an external mutation, then the new value. The
	 unchanged rehydration each reconnection produces must not appear as an
	 update."
	| socket subscription value timestamp |
	socket := ConvexFakeWebSocket new.
	self newManager provideSocket: socket.
	subscription := manager subscribe: 'demo:state' args: ConvexJson object.
	self assert: (self waitUntil: [ (socket lastSentOfType: 'ModifyQuerySet') notNil ]).
	timestamp := 100.
	socket queueText: (self
		transitionFrom: 0 to: timestamp querySet: 0
		modifications: (Array with: (self queryUpdatedFor: subscription queryId count: 0))).
	value := subscription nextWithinMilliseconds: 3000.
	self assert: (value value at: 'count') equals: 0.
	1 to: 5 do: [ :round |
		| replacement modify |
		replacement := ConvexFakeWebSocket new.
		manager provideSocket: replacement.
		(manager submit: 'debugDisconnect' arguments: #()) waitMilliseconds: 5000.
		self assert: (self waitUntil: [ (replacement lastSentOfType: 'ModifyQuerySet') notNil ]).
		modify := replacement lastSentOfType: 'ModifyQuerySet'.
		self assert: ((modify at: 'modifications') first at: 'type') equals: 'Add'.
		self assert: ((modify at: 'modifications') first at: 'queryId') equals: subscription queryId.
		self assert: manager connectionCount equals: round + 1.
		self assert: manager lastCloseReason equals: 'debugDisconnect'.
		"Every reconnection rehydrates the query with the value the consumer
		 already has. That repetition must not surface as an update."
		replacement queueText: (self
			transitionFrom: 0 to: timestamp querySet: 0
			modifications: (Array with: (self queryUpdatedFor: subscription queryId count: round - 1))).
		self assert: (subscription nextWithinMilliseconds: 300) isNil.
		"Then an external mutation produces a genuinely new value."
		replacement queueText: (self
			transitionFrom: timestamp to: timestamp + 100 querySet: 0
			modifications: (Array with: (self queryUpdatedFor: subscription queryId count: round))).
		timestamp := timestamp + 100.
		value := subscription nextWithinMilliseconds: 3000.
		self assert: value notNil.
		self assert: (value value at: 'count') equals: round ]
!
testBackoffGrowsOnFailureAndResetsAfterAHealthyHandshake
	| socket |
	self newManager.
	"No socket is available yet, so the owner backs off."
	self assert: (self waitUntil: [ manager backoffMilliseconds > ConvexLiveManager initialBackoffMilliseconds ]).
	socket := ConvexFakeWebSocket new.
	manager provideSocket: socket.
	self assert: (self waitUntil: [ socket sentMessages isEmpty not ]).
	self assert: (self waitUntil: [ manager backoffMilliseconds = ConvexLiveManager initialBackoffMilliseconds ]).
	self assert: manager connectionCount >= 1
! !

!ConvexLiveTests methodsFor: 'tests - buffering'!
testDeliveryQueueStaysBoundedWithAStoppedConsumer
	"The owner owns the only Live buffer. A consumer that stops reading must not
	 be able to grow it, and the newest Convex value must still get through."
	| socket subscription latest |
	socket := ConvexFakeWebSocket new.
	self newManager provideSocket: socket.
	subscription := manager subscribe: 'demo:state' args: ConvexJson object.
	self assert: (self waitUntil: [ (socket lastSentOfType: 'ModifyQuerySet') notNil ]).
	1 to: 40 do: [ :index |
		socket queueText: (self
			transitionFrom: index - 1 * 10 to: index * 10 querySet: 0
			modifications: (Array with: (self queryUpdatedFor: subscription queryId count: index))) ].
	self assert: (self waitUntil: [ manager maxObservedTimestamp = 400 ]).
	self assert: manager deliveryCount <= ConvexLiveManager maximumDeliveries.
	self assert: manager deliveryBytes <= ConvexLiveManager maximumDeliveryBytes.
	latest := nil.
	[ | update |
	  update := subscription nextWithinMilliseconds: 50.
	  update ifNil: [ nil ] ifNotNil: [ latest := update ].
	  update notNil ] whileTrue.
	self assert: latest notNil.
	self assert: (latest value at: 'count') equals: 40
!
testSubscriptionCapacityIsBounded
	| socket |
	socket := ConvexFakeWebSocket new.
	self newManager provideSocket: socket.
	1 to: ConvexLiveManager maximumSubscriptions do: [ :index |
		manager subscribe: 'demo:state' args: ConvexJson object ].
	self
		should: [ manager subscribe: 'demo:state' args: ConvexJson object ]
		raise: ConvexProtocolError
!
testUnsubscribeReleasesItsByteCharge
	| socket subscription charged |
	socket := ConvexFakeWebSocket new.
	self newManager provideSocket: socket.
	subscription := manager subscribe: 'demo:state' args: (ConvexJson objectWith: { 'room' -> 'lambda' }).
	charged := manager activeBytes.
	self assert: charged > 0.
	manager unsubscribe: subscription.
	self assert: manager activeBytes equals: 0
! !


!ConvexAdapterTests methodsFor: 'helpers'!
setUp
	super setUp.
	channel := ConvexFakeAdapterChannel new.
	client := ConvexFakeClient new.
	adapter := ConvexAdapter client: client channel: channel
!
tearDown
	adapter ifNotNil: [ [ adapter publisher stop ] on: Error do: [ :ignored | nil ] ].
	super tearDown
!
emitted
	adapter publisher flushWithin: 2000.
	^ channel emittedLines reject: [ :each | each isEmpty ]
!
lastEvent
	^ ConvexJson parseString: self emitted last
!
dispatchLine: aString
	adapter dispatch: (adapter parseCommand: (ZnUTF8Encoder new encodeString: aString))
! !

!ConvexAdapterTests methodsFor: 'tests - protocol'!
testHelloReportsProvenanceAndRuntime
	| event |
	self dispatchLine: '{"protocolVersion":1,"id":"h1","op":"hello"}'.
	event := self lastEvent.
	self assert: (event at: 'protocolVersion') equals: 1.
	self assert: (event at: 'id') equals: 'h1'.
	self assert: (event at: 'type') equals: 'ready'.
	self assert: (event at: 'language') equals: 'smalltalk'.
	self assert: (event at: 'implementation') equals: 'native-pharo12-zinc-zodiac-rfc6455'.
	self assert: ((event at: 'runtime') beginsWith: 'Pharo ')
!
testCallResultCarriesValueAndLogsAndNoSubscriptionId
	| event |
	client queueResult: (ConvexResult value: (ConvexJson objectWith: { 'count' -> 1 }) logs: #('l')).
	self dispatchLine: '{"id":"q1","op":"query","path":"demo:state","args":{"room":"r"}}'.
	event := self lastEvent.
	self assert: (event at: 'type') equals: 'result'.
	self assert: (event at: 'id') equals: 'q1'.
	self assert: ((event at: 'value') at: 'count') equals: 1.
	self assert: (event at: 'logs') equals: #('l').
	self deny: (event includesKey: 'subscriptionId')
!
testStructuredFunctionErrorIsSerialisedAsAnErrorEvent
	| event |
	self dispatchLine: '{"id":"q2","op":"query","path":"demo:missing","args":{}}'.
	event := self lastEvent.
	self assert: (event at: 'type') equals: 'error'.
	self assert: (event at: 'id') equals: 'q2'.
	self assert: ((event at: 'error') at: 'name') equals: 'FunctionError'.
	self assert: ((event at: 'error') at: 'message') equals: 'no scripted result'.
	self deny: ((event at: 'error') includesKey: 'data')
!
testMalformedCommandsProduceAnErrorEventWithoutAnIdField
	| event |
	adapter emitErrorEvent: (ConvexProtocolError message: 'adapter command root must be an object') id: nil.
	event := self lastEvent.
	self assert: (event at: 'type') equals: 'error'.
	self deny: (event includesKey: 'id').
	self deny: (event includesKey: 'subscriptionId')
!
testCommandValidationMatchesTheSharedSchema
	self should: [ adapter parseCommand: (ZnUTF8Encoder new encodeString: '{"id":"a","op":"close","extra":1}') ]
		raise: ConvexProtocolError.
	self should: [ adapter parseCommand: (ZnUTF8Encoder new encodeString: '{"id":42,"op":"close"}') ]
		raise: ConvexProtocolError.
	self should: [ adapter parseCommand: (ZnUTF8Encoder new encodeString: '{"op":"close"}') ]
		raise: ConvexProtocolError.
	self should: [ adapter parseCommand: (ZnUTF8Encoder new encodeString: '{"id":"a","op":"query","path":"demo:state"}') ]
		raise: ConvexProtocolError.
	self should: [ adapter parseCommand: (ZnUTF8Encoder new encodeString: '{"protocolVersion":2,"id":"a","op":"hello"}') ]
		raise: ConvexProtocolError.
	self shouldnt: [ adapter parseCommand: (ZnUTF8Encoder new encodeString: '{"id":"a","op":"unsubscribe","subscriptionId":"s"}') ]
		raise: Error
!
testCloseAcknowledgesAndClosesTheClient
	| event |
	self dispatchLine: '{"id":"c1","op":"close"}'.
	event := self lastEvent.
	self assert: (event at: 'type') equals: 'closed'.
	self assert: (event at: 'id') equals: 'c1'.
	self assert: client isClosed
!
testDebugDisconnectReachesTheClientAndAcknowledges
	| event |
	self dispatchLine: '{"id":"d1","op":"debugDisconnect"}'.
	event := self lastEvent.
	self assert: (event at: 'type') equals: 'ack'.
	self assert: (event at: 'id') equals: 'd1'.
	self assert: client disconnects equals: 1
! !

!ConvexAdapterTests methodsFor: 'tests - relay invalidation'!
testStaleRelayCannotCrossAnUnsubscribeAcknowledgement
	"The relay is paused here at the exact point a real relay is most dangerous:
	 it has already dequeued an update and is about to publish it. Unsubscribe
	 runs in between, so the update must be dropped."
	| subscription paused before |
	self dispatchLine: '{"id":"s1","op":"subscribe","subscriptionId":"room","path":"demo:state","args":{}}'.
	subscription := client subscriptionsMade first.
	paused := ConvexUpdate value: (ConvexJson objectWith: { 'count' -> 7 }) logs: #() generation: 0.
	self dispatchLine: '{"id":"u1","op":"unsubscribe","subscriptionId":"room"}'.
	self assert: (self lastEvent at: 'type') equals: 'ack'.
	self assert: subscription closeCount equals: 1.
	before := self emitted size.
	adapter publishRelayUpdate: paused for: subscription named: 'room'.
	self assert: self emitted size equals: before
!
testStaleRelayCannotCrossASameIdentifierReplacement
	| first second paused before |
	self dispatchLine: '{"id":"s1","op":"subscribe","subscriptionId":"room","path":"demo:state","args":{}}'.
	first := client subscriptionsMade first.
	paused := ConvexUpdate value: (ConvexJson objectWith: { 'count' -> 7 }) logs: #() generation: 0.
	self dispatchLine: '{"id":"s2","op":"subscribe","subscriptionId":"room","path":"demo:state","args":{}}'.
	second := client subscriptionsMade last.
	self deny: first == second.
	before := self emitted size.
	adapter publishRelayUpdate: paused for: first named: 'room'.
	self assert: self emitted size equals: before.
	"The replacement itself still publishes normally."
	adapter publishRelayUpdate: paused for: second named: 'room'.
	self assert: (self lastEvent at: 'type') equals: 'subscription'.
	self assert: (self lastEvent at: 'subscriptionId') equals: 'room'
!
testSubscriptionEventsCarryNoCommandIdentifier
	| event |
	self dispatchLine: '{"id":"s1","op":"subscribe","subscriptionId":"room","path":"demo:state","args":{}}'.
	adapter
		publishRelayUpdate: (ConvexUpdate value: (ConvexJson objectWith: { 'count' -> 2 }) logs: #() generation: 0)
		for: client subscriptionsMade first
		named: 'room'.
	event := self lastEvent.
	self assert: (event at: 'type') equals: 'subscription'.
	self assert: (event at: 'subscriptionId') equals: 'room'.
	self assert: ((event at: 'value') at: 'count') equals: 2.
	self deny: (event includesKey: 'id')
!
testSubscriptionErrorsAreSerialisedWithTheirKind
	| event |
	self dispatchLine: '{"id":"s1","op":"subscribe","subscriptionId":"room","path":"demo:state","args":{}}'.
	adapter
		publishRelayUpdate: (ConvexUpdate
			error: (ConvexFunctionError message: 'query failed' data: nil logs: #() operation: 'subscription')
			generation: 0)
		for: client subscriptionsMade first
		named: 'room'.
	event := self lastEvent.
	self assert: (event at: 'type') equals: 'subscription'.
	self assert: ((event at: 'error') at: 'kind') equals: 'FunctionError'.
	self assert: ((event at: 'error') at: 'message') equals: 'query failed'.
	self deny: (event includesKey: 'value')
! !

!ConvexAdapterTests methodsFor: 'tests - output bounds'!
testSingleOversizedEventIsRefusedBeforeItReachesABlockedController
	self
		should: [ adapter emit: (ConvexJson objectWith: {
			'type' -> 'result'.
			'id' -> 'big'.
			'value' -> (String new: 3 * 1024 * 1024 withAll: $x) }) droppable: false ]
		raise: ConvexProtocolError
!
testQueuedSubscriptionEventsAreDroppedRatherThanGrowingWithoutBound
	"With the controller stopped, subscription values are newest-wins inside a
	 fixed budget. Nothing here grows with the number of events produced."
	| publisher payload |
	channel blockWrites.
	publisher := adapter publisher.
	payload := String new: 200000 withAll: $x.
	1 to: 200 do: [ :index |
		publisher emit: (ConvexJson objectWith: {
			'type' -> 'subscription'.
			'subscriptionId' -> 'room'.
			'value' -> payload }) droppable: true ].
	self assert: publisher queuedBytes <= ConvexAdapterPublisher maximumQueuedBytes.
	self assert: publisher droppedCount > 0
!
testCommandResponsesAreNeverSilentlyDropped
	"A controller waiting for an acknowledgement would hang if one were dropped,
	 so a full queue of command responses is reported as a transport failure."
	| publisher |
	channel blockWrites.
	publisher := adapter publisher.
	self
		should: [ 1 to: 100 do: [ :index |
			publisher emit: (ConvexJson objectWith: { 'id' -> index printString. 'type' -> 'ack' })
				droppable: false ] ]
		raise: ConvexTransportError
!
testWriterFailureClosesTheChannelAndReachesTheCommandLoop
	| deadline |
	channel failWrites.
	adapter emitAck: 'a'.
	deadline := ConvexDeadline afterMilliseconds: 2000.
	[ channel isClosed or: [ deadline isExpired ] ] whileFalse: [ (Delay forMilliseconds: 5) wait ].
	self assert: channel isClosed.
	self should: [ adapter publisher raiseIfFailed ] raise: ConvexTransportError
! !
