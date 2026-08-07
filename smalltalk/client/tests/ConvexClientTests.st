"Deterministic unit coverage for the parts of the client that ordinary
 happy-path traffic never exercises: strict JSON bounds, canonical timestamps,
 the RFC 6455 frame parser under mid-frame deadlines, bounded close, and the
 Convex HTTP envelope.

 Nothing here reaches the network. The seams used are the same ones the real
 client uses, so no behaviour is test-only.

 The exclamation mark separates chunks in this format, so it never appears in
 this file."

Object subclass: #ConvexFakeStream
	instanceVariableNames: 'inbound position written connected stalled'
	classVariableNames: ''
	package: 'Convex-Tests'!

ConvexHttpTransport subclass: #ConvexFakeHttpTransport
	instanceVariableNames: 'response failure requests'
	classVariableNames: ''
	package: 'Convex-Tests'!

TestCase subclass: #ConvexJsonTests
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'Convex-Tests'!

TestCase subclass: #ConvexTimestampTests
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'Convex-Tests'!

TestCase subclass: #ConvexWebSocketTests
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'Convex-Tests'!

TestCase subclass: #ConvexHttpTests
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'Convex-Tests'!


!ConvexFakeStream class methodsFor: 'instance creation'!
on: aByteArray
	^ self new setInbound: aByteArray
!
empty
	^ self on: #[]
! !

!ConvexFakeStream methodsFor: 'accessing'!
setInbound: aByteArray
	inbound := aByteArray.
	position := 0.
	written := WriteStream on: (ByteArray new: 64).
	connected := true.
	stalled := false
!
feed: aByteArray
	inbound := inbound , aByteArray
!
stall
	"Behave like a peer that has stopped sending without closing."
	stalled := true
!
resume
	stalled := false
!
disconnect
	connected := false
!
written
	^ written contents
!
isConnected
	^ connected
!
isDataAvailable
	"Zodiac answers this without blocking, and the client only reads when it is
	 true, so the fake has to model it too."
	stalled ifTrue: [ ^ false ].
	^ position < inbound size
!
next
	"One byte, or nil once the peer has closed. A stalled peer is modelled the way
	 Zodiac models it: by signalling a read timeout."
	stalled ifTrue: [ ^ ConnectionTimedOut signal: 'fake stream stalled' ].
	position >= inbound size ifTrue: [
		connected ifFalse: [ ^ nil ].
		^ ConnectionTimedOut signal: 'fake stream has no data' ].
	position := position + 1.
	^ inbound at: position
!
nextPutAll: aByteArray
	written nextPutAll: aByteArray.
	^ aByteArray
!
flush
	^ self
!
close
	connected := false
! !


!ConvexFakeHttpTransport methodsFor: 'testing support'!
respondWith: aString
	response := ZnUTF8Encoder new encodeString: aString
!
respondWith: aString httpSuccess: aBoolean
	response := ZnUTF8Encoder new encodeString: aString.
	lastHttpSuccess := aBoolean
!
failWith: anError
	failure := anError
!
requests
	^ requests ifNil: [ requests := OrderedCollection new ]
!
postJson: aJsonString toOperation: anOperation
	self requests add: (Array with: anOperation with: aJsonString).
	failure ifNotNil: [ ^ failure signal ].
	^ response
! !


!ConvexJsonTests methodsFor: 'tests - values'!
testIntegralDecimalsAreAcceptedAndFractionsAreNot
	self assert: (ConvexJson integerFrom: 0.0 named: 'count' between: 0 and: 100) equals: 0.
	self assert: (ConvexJson integerFrom: 1.0 named: 'count' between: 0 and: 100) equals: 1.
	self assert: (ConvexJson integerFrom: 1 named: 'count' between: 0 and: 100) equals: 1.
	self should: [ ConvexJson integerFrom: 1.5 named: 'count' between: 0 and: 100 ] raise: ConvexProtocolError.
	self should: [ ConvexJson integerFrom: '1' named: 'count' between: 0 and: 100 ] raise: ConvexProtocolError.
	self should: [ ConvexJson integerFrom: 101 named: 'count' between: 0 and: 100 ] raise: ConvexProtocolError.
	self should: [ ConvexJson integerFrom: (Float infinity) named: 'count' between: 0 and: 100 ] raise: ConvexProtocolError
!
testParsesTheJsonSubsetConvexActuallySends
	| value |
	value := ConvexJson parseString: '{"count":1,"ok":true,"none":null,"list":[1,2.5,"x"]}'.
	self assert: (value at: 'count') equals: 1.
	self assert: (value at: 'ok').
	self assert: (value at: 'none') isNil.
	self assert: (value at: 'list') size equals: 3.
	self assert: ((value at: 'list') at: 3) equals: 'x'
!
testRoundTripsUnicodeIncludingSurrogatePairs
	"Escapes are used instead of literal characters so this file stays ASCII and
	 the round trip proves the escape handling rather than the file encoding."
	| value roundTripped |
	value := ConvexJson parseString: '{"emoji":"\uD83D\uDE00","greek":"\u03BB","tab":"\t"}'.
	self assert: (value at: 'emoji') size equals: 1.
	self assert: (value at: 'emoji') first asInteger equals: 16r1F600.
	self assert: (value at: 'greek') equals: (String with: (Character value: 16r03BB)).
	self assert: (value at: 'tab') equals: (String with: Character tab).
	roundTripped := ConvexJson parseString: (ConvexJson renderToString: value).
	self assert: (roundTripped at: 'emoji') equals: (value at: 'emoji').
	self assert: (roundTripped at: 'greek') equals: (value at: 'greek').
	self assert: (roundTripped at: 'tab') equals: (value at: 'tab')
!
testRejectsUnpairedSurrogates
	self should: [ ConvexJson parseString: '{"bad":"\uD83D"}' ] raise: ConvexProtocolError.
	self should: [ ConvexJson parseString: '{"bad":"\uDE00"}' ] raise: ConvexProtocolError
!
testRendersObjectsInInsertionOrder
	| object |
	object := ConvexJson objectWith: {
		'type' -> 'Add'.
		'queryId' -> 1.
		'udfPath' -> 'demo:state' }.
	self
		assert: (ConvexJson renderToString: object)
		equals: '{"type":"Add","queryId":1,"udfPath":"demo:state"}'
!
testEscapesControlCharactersAndQuotes
	self
		assert: (ConvexJson renderToString: (String with: $" with: $\ with: (Character value: 1)))
		equals: '"\"\\\u0001"'
!
testRefusesNonFiniteNumbers
	self should: [ ConvexJson renderToString: Float infinity ] raise: ConvexProtocolError.
	self should: [ ConvexJson renderToString: Float nan ] raise: ConvexProtocolError
! !

!ConvexJsonTests methodsFor: 'tests - hostile input'!
testRefusesStonSyntaxThatIsNotJson
	"Pharo ships STON, whose reader would happily instantiate a class named in
	 the document. The Convex reader accepts JSON and nothing else."
	self should: [ ConvexJson parseString: 'Point[1,2]' ] raise: ConvexProtocolError.
	self should: [ ConvexJson parseString: '#[1 2 3]' ] raise: ConvexProtocolError.
	self should: [ ConvexJson parseString: '{#foo:1}' ] raise: ConvexProtocolError.
	self should: [ ConvexJson parseString: '{key:1}' ] raise: ConvexProtocolError
!
testRefusesTrailingContentAndTruncatedDocuments
	self should: [ ConvexJson parseString: '{"a":1} {"b":2}' ] raise: ConvexProtocolError.
	self should: [ ConvexJson parseString: '{"a":1' ] raise: ConvexProtocolError.
	self should: [ ConvexJson parseString: '{"a":"unterminated}' ] raise: ConvexProtocolError
!
testRefusesDuplicateKeysLeadingZeroesAndNonFiniteConversions
	self should: [ ConvexJson parseString: '{"a":1,"a":2}' ] raise: ConvexProtocolError.
	self should: [ ConvexJson parseString: '{"a":01}' ] raise: ConvexProtocolError.
	self should: [ ConvexJson parseString: '{"a":-01}' ] raise: ConvexProtocolError.
	self should: [ ConvexJson parseString: '{"a":1e9999}' ] raise: ConvexProtocolError
!
testRefusesRawControlCharactersInStrings
	self
		should: [ ConvexJson parseString: (String streamContents: [ :out |
			out nextPutAll: '{"a":"'; nextPut: (Character value: 10); nextPutAll: '"}' ]) ]
		raise: ConvexProtocolError
!
testBoundsNestingDepth
	| deep |
	deep := String streamContents: [ :out |
		200 timesRepeat: [ out nextPut: $[ ].
		200 timesRepeat: [ out nextPut: $] ] ].
	self should: [ ConvexJson parseString: deep ] raise: ConvexProtocolError
!
testBoundsNodeCount
	| wide |
	wide := String streamContents: [ :out |
		out nextPut: $[.
		1 to: 9000 do: [ :index |
			index > 1 ifTrue: [ out nextPut: $, ].
			out nextPut: $1 ].
		out nextPut: $] ].
	self should: [ ConvexJson parseString: wide ] raise: ConvexProtocolError
!
testBoundsDocumentSize
	self
		should: [ ConvexJson parseString: (String new: ConvexJson maximumBytes + 1 withAll: $a) ]
		raise: ConvexProtocolError
!
testRefusesInvalidUtf8
	self should: [ ConvexJson parseBytes: #[123 34 97 34 58 34 16rFF 34 125] ] raise: ConvexProtocolError
! !


!ConvexTimestampTests methodsFor: 'tests'!
testInitialValueIsCanonicalZero
	self assert: (ConvexTimestamp decode: ConvexTimestamp initialValue) equals: 0.
	self assert: (ConvexTimestamp encode: 0) equals: ConvexTimestamp initialValue
!
testRoundTripsLargeTimestamps
	| number |
	number := 1739000000000000000.
	self assert: (ConvexTimestamp decode: (ConvexTimestamp encode: number)) equals: number
!
testRefusesNonCanonicalEncodings
	"A timestamp whose trailing base64 bits are not zero decodes to the same
	 number as the canonical form. Accepting both would let one logical version
	 have two spellings."
	self should: [ ConvexTimestamp decode: 'AAAAAAAAAAB=' ] raise: ConvexProtocolError.
	self should: [ ConvexTimestamp decode: 'AAAAAAAAAAA' ] raise: ConvexProtocolError.
	self should: [ ConvexTimestamp decode: 'not base64x=' ] raise: ConvexProtocolError.
	self should: [ ConvexTimestamp decode: 42 ] raise: ConvexProtocolError
! !


!ConvexWebSocketTests methodsFor: 'helpers'!
textFrameBytesFor: aString
	"An unmasked final text frame, exactly as a server sends it."
	| payload |
	payload := ZnUTF8Encoder new encodeString: aString.
	payload size < 126 ifFalse: [ self error: 'helper only builds short frames' ].
	^ (ByteArray with: 129 with: payload size) , payload
!
socketOn: aStream
	^ ConvexWebSocket onStream: aStream
! !

!ConvexWebSocketTests methodsFor: 'tests - parsing'!
testReadsAWholeTextFrame
	| stream socket frame |
	stream := ConvexFakeStream on: (self textFrameBytesFor: '{"type":"Ping"}').
	socket := self socketOn: stream.
	frame := socket readFrameWithin: 200.
	self assert: frame isFinal.
	self assert: frame opcode equals: ConvexWebSocket opcodeText.
	self assert: (ZnUTF8Encoder new decodeBytes: frame payload) equals: '{"type":"Ping"}'
!
testTimeoutInsideAFrameKeepsParserStateInsteadOfResynchronising
	"This is the case a naive reader gets wrong: after the header and part of the
	 payload have been consumed, a timeout must not restart at a false frame
	 boundary. The parser reports partial progress, then finishes the same frame
	 once the remaining bytes arrive."
	| all stream socket frame stateAfterTimeout |
	all := self textFrameBytesFor: '{"type":"Ping"}'.
	stream := ConvexFakeStream on: (all copyFrom: 1 to: 6).
	socket := self socketOn: stream.
	self assert: (socket readFrameWithin: 30) isNil.
	stateAfterTimeout := socket parserState.
	self assert: (stateAfterTimeout at: 1) equals: #payload.
	self assert: (stateAfterTimeout at: 3) equals: 4.
	stream feed: (all copyFrom: 7 to: all size).
	frame := socket readFrameWithin: 500.
	self assert: (ZnUTF8Encoder new decodeBytes: frame payload) equals: '{"type":"Ping"}'
!
testTimeoutBetweenHeaderBytesKeepsParserState
	| stream socket |
	stream := ConvexFakeStream on: #[129].
	socket := self socketOn: stream.
	self assert: (socket readFrameWithin: 30) isNil.
	self assert: (socket parserState at: 1) equals: #header.
	self assert: (socket parserState at: 2) equals: 1.
	stream feed: #[1 65].
	self assert: (socket readFrameWithin: 500) payload equals: #[65]
!
testPartialFrameHasOneAbsoluteDeadlineAcrossRepeatedReads
	"Short polling budgets must not renew a malicious peer's frame deadline."
	| stream socket |
	stream := ConvexFakeStream on: #[129].
	socket := self socketOn: stream.
	socket partialFrameTimeoutMilliseconds: 40.
	self assert: (socket readFrameWithin: 10) isNil.
	(Delay forMilliseconds: 50) wait.
	self should: [ socket readFrameWithin: 10 ] raise: ConvexTransportError
!
testRefusesMaskedServerFrames
	| socket |
	socket := self socketOn: (ConvexFakeStream on: #[129 129 0 0 0 0 65]).
	self should: [ socket readFrameWithin: 200 ] raise: ConvexProtocolError
!
testRefusesReservedBits
	| socket |
	socket := self socketOn: (ConvexFakeStream on: #[193 1 65]).
	self should: [ socket readFrameWithin: 200 ] raise: ConvexProtocolError
!
testRefusesUnassignedOpcodes
	| socket |
	socket := self socketOn: (ConvexFakeStream on: #[131 1 65]).
	self should: [ socket readFrameWithin: 200 ] raise: ConvexProtocolError
!
testRefusesFragmentedOrOversizedControlFrames
	self
		should: [ (self socketOn: (ConvexFakeStream on: #[9 1 65])) readFrameWithin: 200 ]
		raise: ConvexProtocolError.
	self
		should: [ (self socketOn: (ConvexFakeStream on: #[137 126 0 200])) readFrameWithin: 200 ]
		raise: ConvexProtocolError
!
testRefusesNonMinimalLengthEncodings
	self
		should: [ (self socketOn: (ConvexFakeStream on: #[129 126 0 10])) readFrameWithin: 200 ]
		raise: ConvexProtocolError.
	self
		should: [ (self socketOn: (ConvexFakeStream on: #[129 127 0 0 0 0 0 0 1 0])) readFrameWithin: 200 ]
		raise: ConvexProtocolError
!
testRefusesFramesOverTheByteBound
	| socket |
	socket := self socketOn: (ConvexFakeStream on: #[129 127 0 0 0 0 0 64 0 1]).
	self should: [ socket readFrameWithin: 200 ] raise: ConvexProtocolError
!
testDetectsAPeerThatWentAwayInsteadOfWaitingForever
	| stream socket |
	stream := ConvexFakeStream empty.
	socket := self socketOn: stream.
	stream disconnect.
	self should: [ socket readFrameWithin: 200 ] raise: ConvexTransportError
! !

!ConvexWebSocketTests methodsFor: 'tests - writing'!
testClientFramesAreMaskedAndUnmaskToThePayload
	| stream socket bytes mask payload |
	stream := ConvexFakeStream empty.
	socket := self socketOn: stream.
	socket sendText: 'hi'.
	bytes := stream written.
	self assert: (bytes at: 1) equals: 129.
	self assert: (bytes at: 2) equals: 128 + 2.
	mask := bytes copyFrom: 3 to: 6.
	payload := ByteArray new: 2.
	1 to: 2 do: [ :index |
		payload at: index put: ((bytes at: 6 + index) bitXor: (mask at: index)) ].
	self assert: (ZnUTF8Encoder new decodeBytes: payload) equals: 'hi'
!
testRefusesToSendFramesOverTheByteBound
	| socket |
	socket := self socketOn: ConvexFakeStream empty.
	self
		should: [ socket sendText: (String new: (2 * 1024 * 1024) + 1 withAll: $a) ]
		raise: ConvexProtocolError
! !

!ConvexWebSocketTests methodsFor: 'tests - closing'!
testCloseIsBoundedWhenThePeerIsIdle
	"The deadline is the contract. A peer that never answers the close frame must
	 not be able to hold the client open."
	| stream socket deadline |
	stream := ConvexFakeStream empty.
	stream stall.
	socket := self socketOn: stream.
	deadline := ConvexDeadline afterMilliseconds: 5000.
	socket closeWithin: 150.
	self assert: deadline elapsedMilliseconds < 3000.
	self assert: socket isClosed
!
testCloseIsBoundedWhenThePeerIsStalledHalfwayThroughAFrame
	| stream socket deadline |
	stream := ConvexFakeStream on: #[129 10 65 66].
	socket := self socketOn: stream.
	self assert: (socket readFrameWithin: 20) isNil.
	stream stall.
	deadline := ConvexDeadline afterMilliseconds: 5000.
	socket closeWithin: 150.
	self assert: deadline elapsedMilliseconds < 3000.
	self assert: socket isClosed
!
testCloseIsBoundedWhenThePeerKeepsSending
	| stream socket deadline |
	stream := ConvexFakeStream empty.
	1 to: 400 do: [ :ignored | stream feed: (self textFrameBytesFor: 'noise') ].
	socket := self socketOn: stream.
	deadline := ConvexDeadline afterMilliseconds: 5000.
	socket closeWithin: 150.
	self assert: deadline elapsedMilliseconds < 3000.
	self assert: socket isClosed
! !


!ConvexHttpTests methodsFor: 'helpers'!
transport
	^ ConvexFakeHttpTransport
		deployment: 'https://example.convex.cloud'
		bearerToken: nil
		clientVersion: 'smalltalk-0.1.0'
! !

!ConvexHttpTests methodsFor: 'tests'!
testSuccessEnvelopeCarriesValueAndLogLines
	| transport result |
	transport := self transport.
	transport respondWith: '{"status":"success","value":{"count":1},"logLines":["hello"]}'.
	result := transport call: 'query' path: 'demo:state' args: (ConvexJson objectWith: { 'room' -> 'r' }).
	self assert: (result value at: 'count') equals: 1.
	self assert: result logs equals: #('hello')
!
testRequestBodyUsesTheDocumentedJsonFormat
	| transport |
	transport := self transport.
	transport respondWith: '{"status":"success","value":null,"logLines":[]}'.
	transport call: 'mutation' path: 'demo:increment' args: (ConvexJson objectWith: { 'room' -> 'r' }).
	self assert: transport requests first first equals: 'mutation'.
	self
		assert: transport requests first second
		equals: '{"path":"demo:increment","args":{"room":"r"},"format":"json"}'
!
testStructuredFunctionErrorStaysAFunctionError
	| transport raised |
	transport := self transport.
	transport respondWith: '{"status":"error","errorMessage":"boom","errorData":{"code":7},"logLines":["l"]}'.
	raised := nil.
	[ transport call: 'query' path: 'demo:state' args: ConvexJson object ]
		on: ConvexError
		do: [ :error | raised := error ].
	self assert: raised class equals: ConvexFunctionError.
	self assert: raised kind equals: 'FunctionError'.
	self assert: raised messageText equals: 'boom'.
	self assert: (raised data at: 'code') equals: 7.
	self assert: raised logs equals: #('l')
!
testNonConvexJsonBecomesAProtocolErrorNotAValue
	| transport |
	transport := self transport.
	transport respondWith: '<html>gateway timeout</html>'.
	self
		should: [ transport call: 'query' path: 'demo:state' args: ConvexJson object ]
		raise: ConvexProtocolError
!
testMissingStatusBecomesAProtocolError
	| transport |
	transport := self transport.
	transport respondWith: '{"value":{"count":1}}'.
	self
		should: [ transport call: 'query' path: 'demo:state' args: ConvexJson object ]
		raise: ConvexProtocolError
!
testNonSuccessHttpStatusCannotMasqueradeAsAConvexSuccess
	| transport |
	transport := self transport.
	transport
		respondWith: '{"status":"success","value":{"count":99},"logLines":[]}'
		httpSuccess: false.
	self
		should: [ transport call: 'query' path: 'demo:state' args: ConvexJson object ]
		raise: ConvexProtocolError
!
testMalformedLogLinesBecomeAProtocolError
	| transport |
	transport := self transport.
	transport respondWith: '{"status":"success","value":1,"logLines":[7]}'.
	self
		should: [ transport call: 'query' path: 'demo:state' args: ConvexJson object ]
		raise: ConvexProtocolError.
	transport respondWith: '{"status":"success","value":1,"logLines":null}'.
	self
		should: [ transport call: 'query' path: 'demo:state' args: ConvexJson object ]
		raise: ConvexProtocolError
!
testFunctionErrorRequiresAStringMessage
	| transport |
	transport := self transport.
	transport respondWith: '{"status":"error","logLines":[]}'.
	self
		should: [ transport call: 'query' path: 'demo:state' args: ConvexJson object ]
		raise: ConvexProtocolError
!
testTransportFailureIsNotFlattenedIntoAValue
	| transport |
	transport := self transport.
	transport failWith: (ConvexTransportError message: 'connection refused').
	self
		should: [ transport call: 'query' path: 'demo:state' args: ConvexJson object ]
		raise: ConvexTransportError
!
testRefusesMalformedPathsAndHeaderInjection
	| transport |
	transport := self transport.
	transport respondWith: '{"status":"success","value":1,"logLines":[]}'.
	self should: [ transport call: 'query' path: 'demostate' args: ConvexJson object ] raise: ConvexProtocolError.
	self should: [ transport call: 'query' path: 'a:b:c' args: ConvexJson object ] raise: ConvexProtocolError.
	self
		should: [ transport bearerToken: (String with: $a with: Character cr with: $b) ]
		raise: ConvexProtocolError
!
testRefusesNonHttpDeployments
	self
		should: [ ConvexHttpTransport deployment: 'ftp://example.com' bearerToken: nil clientVersion: 'v' ]
		raise: ConvexProtocolError
! !
