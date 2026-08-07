"Convex from Pharo 12 Smalltalk.

 This file is loaded with CodeImporter, so it uses the classic chunk format that
 Pharo 12 still parses. Everything here uses only packages that ship inside the
 Pharo 12 image: Zinc for HTTPS, Zodiac for TLS sockets, System-Hashing for
 SHA-1 and Zinc-Character-Encoding for UTF-8 and base64.

 Two things are written here rather than delegated, and both are deliberate.
 Pharo 12 ships no WebSocket package at all, so RFC 6455 is implemented below.
 Pharo does ship STON, whose reader also accepts STON syntax and can instantiate
 classes named in the document, so JSON is parsed by the strict reader below
 instead of by a general object deserialiser.

 The exclamation mark separates chunks in this format, so it never appears in
 this file, not even inside a comment."

Error subclass: #ConvexError
	instanceVariableNames: 'kind data logs operation'
	classVariableNames: ''
	package: 'Convex-Educational'!

ConvexError subclass: #ConvexFunctionError
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'Convex-Educational'!

ConvexError subclass: #ConvexProtocolError
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'Convex-Educational'!

ConvexError subclass: #ConvexTransportError
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'Convex-Educational'!

Object subclass: #ConvexDeadline
	instanceVariableNames: 'start budget'
	classVariableNames: ''
	package: 'Convex-Educational'!

Object subclass: #ConvexRandom
	instanceVariableNames: ''
	classVariableNames: 'Source'
	package: 'Convex-Educational'!

Object subclass: #ConvexJson
	instanceVariableNames: 'input position size depth nodes'
	classVariableNames: ''
	package: 'Convex-Educational'!

Object subclass: #ConvexTimestamp
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'Convex-Educational'!

Object subclass: #ConvexResult
	instanceVariableNames: 'value logs'
	classVariableNames: ''
	package: 'Convex-Educational'!

Object subclass: #ConvexUpdate
	instanceVariableNames: 'value logs error generation'
	classVariableNames: ''
	package: 'Convex-Educational'!

ZnClient subclass: #ConvexHttpsClient
	instanceVariableNames: ''
	classVariableNames: ''
	package: 'Convex-Educational'!

Object subclass: #ConvexHttpTransport
	instanceVariableNames: 'deploymentUrl bearerToken clientVersion maximumBodyBytes timeoutSeconds lastHttpSuccess requestLock'
	classVariableNames: ''
	package: 'Convex-Educational'!

Object subclass: #ConvexWebSocketFrame
	instanceVariableNames: 'final opcode payload'
	classVariableNames: ''
	package: 'Convex-Educational'!

Object subclass: #ConvexWebSocket
	instanceVariableNames: 'stream url maximumFrameBytes partialFrameTimeoutMilliseconds frameDeadline state header headerFilled headerNeeded payload payloadNeeded payloadFilled frameFinal frameOpcode closed'
	classVariableNames: ''
	package: 'Convex-Educational'!

Object subclass: #ConvexSubscription
	instanceVariableNames: 'queryId path arguments manager active generation lastRenderedValue'
	classVariableNames: ''
	package: 'Convex-Educational'!

Object subclass: #ConvexLiveCommand
	instanceVariableNames: 'name arguments semaphore value error deadline'
	classVariableNames: ''
	package: 'Convex-Educational'!

Object subclass: #ConvexLiveManager
	instanceVariableNames: 'deploymentUrl clientVersion sessionId commands active activeBytes deliveries deliveryBytes lock socket owner stopped generation connectionCount lastCloseReason maxObservedTimestamp backoffMilliseconds nextConnectAt querySetVersion remoteVersion nextQueryId pendingDisconnect'
	classVariableNames: ''
	package: 'Convex-Educational'!

Object subclass: #ConvexClient
	instanceVariableNames: 'http live deploymentUrl clientVersion closed lock'
	classVariableNames: ''
	package: 'Convex-Educational'!


!ConvexError class methodsFor: 'instance creation'!
kind: aKind message: aMessage
	^ self kind: aKind message: aMessage data: nil logs: #() operation: nil
!
kind: aKind message: aMessage data: aValue logs: someLogs operation: anOperation
	^ self new
		setKind: aKind
		message: aMessage
		data: aValue
		logs: someLogs
		operation: anOperation
! !

!ConvexError methodsFor: 'accessing'!
setKind: aKind message: aMessage data: aValue logs: someLogs operation: anOperation
	kind := aKind.
	self messageText: aMessage.
	data := aValue.
	logs := someLogs ifNil: [ #() ].
	operation := anOperation
!
kind
	^ kind ifNil: [ 'ProtocolError' ]
!
data
	^ data
!
logs
	^ logs ifNil: [ #() ]
!
operation
	^ operation
! !

!ConvexFunctionError class methodsFor: 'instance creation'!
message: aMessage data: aValue logs: someLogs operation: anOperation
	"A Convex function ran and reported failure. That is not a transport problem,
	 so it must never be flattened into a successful value."
	^ self kind: 'FunctionError' message: aMessage data: aValue logs: someLogs operation: anOperation
! !

!ConvexProtocolError class methodsFor: 'instance creation'!
message: aMessage
	"The peer said something that is not the Convex protocol this client pinned."
	^ self kind: 'ProtocolError' message: aMessage
! !

!ConvexTransportError class methodsFor: 'instance creation'!
message: aMessage
	"Sockets, TLS, deadlines and shutdown. Recoverable by reconnecting."
	^ self kind: 'TransportError' message: aMessage
! !


!ConvexDeadline class methodsFor: 'instance creation'!
afterMilliseconds: milliseconds
	"Time millisecondClockValue wraps around, so a deadline is a start plus a
	 budget compared through Time millisecondsSince:, which is wrap-safe. Nothing
	 in this client compares two raw clock readings."
	^ self new setStart: Time millisecondClockValue budget: milliseconds
! !

!ConvexDeadline methodsFor: 'accessing'!
setStart: aTime budget: milliseconds
	start := aTime.
	budget := milliseconds
!
elapsedMilliseconds
	^ Time millisecondsSince: start
!
remainingMilliseconds
	^ (budget - self elapsedMilliseconds) max: 0
!
isExpired
	^ self elapsedMilliseconds >= budget
! !


!ConvexRandom class methodsFor: 'accessing'!
source
	"One shared generator, enough for run identifiers, session identifiers and
	 WebSocket masking keys. None of those is a secret."
	^ Source ifNil: [ Source := Random new ]
!
nextByte
	^ (self source nextInteger: 256) - 1
!
bytes: aCount
	| bytes |
	bytes := ByteArray new: aCount.
	1 to: aCount do: [ :index | bytes at: index put: self nextByte ].
	^ bytes
!
hexIdentifier
	"A runId is not secret, but it needs enough entropy that two example runs
	 cannot share an idempotency record. Keep it ASCII so it is safe in JSON."
	^ self hexStringFrom: (self bytes: 16)
!
hexStringFrom: aByteArray
	| digits output byte |
	digits := '0123456789abcdef'.
	output := String new: aByteArray size * 2.
	1 to: aByteArray size do: [ :index |
		byte := aByteArray at: index.
		output at: index * 2 - 1 put: (digits at: (byte bitShift: -4) + 1).
		output at: index * 2 put: (digits at: (byte bitAnd: 15) + 1) ].
	^ output
! !


!ConvexJson class methodsFor: 'limits'!
maximumBytes
	^ 2 * 1024 * 1024
!
maximumDepth
	^ 128
!
maximumNodes
	^ 8192
! !

!ConvexJson class methodsFor: 'parsing'!
parseString: aString
	"Strict RFC 8259 with three bounds: total size, nesting depth and node count.
	 Convex values arrive from the network, so the reader deliberately accepts no
	 STON extension, no trailing content and no unquoted key."
	aString size > self maximumBytes ifTrue: [
		^ (ConvexProtocolError message: 'JSON document exceeds the 2 MiB bound') signal ].
	^ self new parse: aString
!
parseBytes: aByteArray
	"Reject invalid UTF-8 rather than letting a replacement character silently
	 change a Convex value."
	| text |
	aByteArray size > self maximumBytes ifTrue: [
		^ (ConvexProtocolError message: 'JSON document exceeds the 2 MiB bound') signal ].
	text := [ ZnUTF8Encoder new decodeBytes: aByteArray ]
		on: Error
		do: [ :error | (ConvexProtocolError message: 'JSON document was not valid UTF-8') signal ].
	^ self parseString: text
! !

!ConvexJson class methodsFor: 'rendering'!
renderToString: aValue
	^ String streamContents: [ :out | self render: aValue on: out depth: 0 ]
!
renderToBytes: aValue
	^ ZnUTF8Encoder new encodeString: (self renderToString: aValue)
!
render: aValue on: aStream depth: aDepth
	aDepth > self maximumDepth ifTrue: [
		^ (ConvexProtocolError message: 'value nests deeper than 128 levels') signal ].
	aValue isNil ifTrue: [ ^ aStream nextPutAll: 'null' ].
	aValue == true ifTrue: [ ^ aStream nextPutAll: 'true' ].
	aValue == false ifTrue: [ ^ aStream nextPutAll: 'false' ].
	aValue isString ifTrue: [ ^ self renderString: aValue on: aStream ].
	aValue isNumber ifTrue: [ ^ self renderNumber: aValue on: aStream ].
	aValue isDictionary ifTrue: [ ^ self renderObject: aValue on: aStream depth: aDepth ].
	((aValue isKindOf: Collection) and: [ aValue isString not ]) ifTrue: [
		^ self renderArray: aValue on: aStream depth: aDepth ].
	^ (ConvexProtocolError message: 'value is not JSON encodable: ', aValue class name) signal
!
renderNumber: aNumber on: aStream
	"Only Float can be non-finite in Pharo, and JSON has no spelling for those."
	aNumber isInteger ifTrue: [ ^ aStream nextPutAll: aNumber printString ].
	(aNumber isFloat and: [ aNumber isFinite not ]) ifTrue: [
		^ (ConvexProtocolError message: 'JSON has no encoding for a non-finite number') signal ].
	^ aStream nextPutAll: aNumber asFloat printString
!
renderString: aString on: aStream
	| code |
	aStream nextPut: $".
	aString do: [ :character |
		code := character asInteger.
		character = $" ifTrue: [ aStream nextPutAll: '\"' ] ifFalse: [
		character = $\ ifTrue: [ aStream nextPutAll: '\\' ] ifFalse: [
		code = 8 ifTrue: [ aStream nextPutAll: '\b' ] ifFalse: [
		code = 9 ifTrue: [ aStream nextPutAll: '\t' ] ifFalse: [
		code = 10 ifTrue: [ aStream nextPutAll: '\n' ] ifFalse: [
		code = 12 ifTrue: [ aStream nextPutAll: '\f' ] ifFalse: [
		code = 13 ifTrue: [ aStream nextPutAll: '\r' ] ifFalse: [
		code < 32
			ifTrue: [ aStream nextPutAll: (self unicodeEscapeFor: code) ]
			ifFalse: [ aStream nextPut: character ] ] ] ] ] ] ] ] ].
	aStream nextPut: $"
!
unicodeEscapeFor: aCode
	| digits |
	digits := '0123456789abcdef'.
	^ String streamContents: [ :out |
		out nextPutAll: '\u'.
		3 to: 0 by: -1 do: [ :shift |
			out nextPut: (digits at: ((aCode bitShift: shift * -4) bitAnd: 15) + 1) ] ]
!
renderObject: aDictionary on: aStream depth: aDepth
	| first |
	first := true.
	aStream nextPut: ${.
	aDictionary keysAndValuesDo: [ :key :value |
		key isString ifFalse: [
			^ (ConvexProtocolError message: 'JSON object keys must be strings') signal ].
		first ifFalse: [ aStream nextPut: $, ].
		first := false.
		self renderString: key on: aStream.
		aStream nextPut: $:.
		self render: value on: aStream depth: aDepth + 1 ].
	aStream nextPut: $}
!
renderArray: aCollection on: aStream depth: aDepth
	| first |
	first := true.
	aStream nextPut: $[.
	aCollection do: [ :each |
		first ifFalse: [ aStream nextPut: $, ].
		first := false.
		self render: each on: aStream depth: aDepth + 1 ].
	aStream nextPut: $]
! !

!ConvexJson class methodsFor: 'constructing'!
object
	"Outgoing objects keep insertion order, so the wire bytes are reproducible and
	 a test can compare a rendered frame literally."
	^ OrderedDictionary new
!
objectWith: someAssociations
	| result |
	result := self object.
	someAssociations do: [ :each | result at: each key put: each value ].
	^ result
! !

!ConvexJson class methodsFor: 'validating'!
assertObject: aValue named: aName
	aValue isDictionary ifFalse: [
		^ (ConvexProtocolError message: aName, ' must be a JSON object') signal ].
	^ aValue
!
assertString: aValue named: aName
	aValue isString ifFalse: [
		^ (ConvexProtocolError message: aName, ' must be a string') signal ].
	^ aValue
!
assertArray: aValue named: aName
	((aValue isKindOf: Collection) and: [ aValue isString not ]) ifFalse: [
		^ (ConvexProtocolError message: aName, ' must be an array') signal ].
	^ aValue
!
assertLogs: aValue named: aName
	| logs |
	logs := self assertArray: aValue named: aName.
	(logs allSatisfy: [ :each | each isString ]) ifFalse: [
		^ (ConvexProtocolError message: aName, ' must be an array of strings') signal ].
	^ logs asArray
!
assertUnsignedInteger32: aValue named: aName
	^ self
		integerFrom: aValue
		named: aName
		between: 0
		and: 4294967295
!
integerFrom: aValue named: aName between: aMinimum and: aMaximum
	"Convex JSON numbers may arrive in an integral decimal form such as 0.0 or
	 1.0. Those are accepted, while fractional, quoted, non-finite and
	 out-of-range values are refused. The example and the Live decoder share this
	 one rule so they cannot drift apart."
	| number |
	aValue isNumber ifFalse: [
		^ (ConvexProtocolError message: aName, ' must be a number') signal ].
	(aValue isFloat and: [ aValue isFinite not ]) ifTrue: [
		^ (ConvexProtocolError message: aName, ' must be a finite number') signal ].
	aValue = aValue truncated ifFalse: [
		^ (ConvexProtocolError message: aName, ' must be an integral number') signal ].
	number := aValue truncated.
	((number >= aMinimum) and: [ number <= aMaximum ]) ifFalse: [
		^ (ConvexProtocolError message: aName, ' is out of range') signal ].
	^ number
! !

!ConvexJson methodsFor: 'parsing'!
parse: aString
	| result |
	input := aString.
	position := 1.
	size := aString size.
	depth := 0.
	nodes := 0.
	self skipWhitespace.
	result := self parseValue.
	self skipWhitespace.
	position <= size ifTrue: [
		^ (ConvexProtocolError message: 'JSON document has trailing content') signal ].
	^ result
!
fail: aMessage
	^ (ConvexProtocolError message: aMessage) signal
!
countNode
	nodes := nodes + 1.
	nodes > self class maximumNodes ifTrue: [
		self fail: 'JSON document has more than 8192 nodes' ]
!
atEnd
	^ position > size
!
peekCharacter
	self atEnd ifTrue: [ self fail: 'JSON document ended early' ].
	^ input at: position
!
nextCharacter
	| character |
	character := self peekCharacter.
	position := position + 1.
	^ character
!
expect: aCharacter
	self nextCharacter = aCharacter ifFalse: [
		self fail: 'JSON document expected ', aCharacter asString ]
!
skipWhitespace
	| character |
	[ self atEnd ] whileFalse: [
		character := input at: position.
		((character = Character space
			or: [ character = Character tab ])
			or: [ character = Character cr or: [ character = Character lf ] ])
				ifFalse: [ ^ self ].
		position := position + 1 ]
!
parseValue
	| character |
	self countNode.
	character := self peekCharacter.
	character = ${ ifTrue: [ ^ self parseObject ].
	character = $[ ifTrue: [ ^ self parseArray ].
	character = $" ifTrue: [ ^ self parseStringValue ].
	character = $t ifTrue: [ ^ self parseLiteral: 'true' value: true ].
	character = $f ifTrue: [ ^ self parseLiteral: 'false' value: false ].
	character = $n ifTrue: [ ^ self parseLiteral: 'null' value: nil ].
	^ self parseNumber
!
parseLiteral: aWord value: aValue
	(position + aWord size - 1 <= size
		and: [ (input copyFrom: position to: position + aWord size - 1) = aWord ]) ifFalse: [
		self fail: 'JSON document had an unknown literal' ].
	position := position + aWord size.
	^ aValue
!
enterStructure
	depth := depth + 1.
	depth > self class maximumDepth ifTrue: [
		self fail: 'JSON document nests deeper than 128 levels' ]
!
leaveStructure
	depth := depth - 1
!
parseObject
	| result key |
	self enterStructure.
	self expect: ${.
	result := OrderedDictionary new.
	self skipWhitespace.
	self peekCharacter = $} ifTrue: [
		position := position + 1.
		self leaveStructure.
		^ result ].
	[
		self skipWhitespace.
		self peekCharacter = $" ifFalse: [ self fail: 'JSON object keys must be quoted' ].
		key := self parseStringValue.
		(result includesKey: key) ifTrue: [
			self fail: 'JSON object contained a duplicate key' ].
		self skipWhitespace.
		self expect: $:.
		self skipWhitespace.
		result at: key put: self parseValue.
		self skipWhitespace.
		self peekCharacter = $,
	] whileTrue: [ position := position + 1 ].
	self expect: $}.
	self leaveStructure.
	^ result
!
parseArray
	| result |
	self enterStructure.
	self expect: $[.
	result := OrderedCollection new.
	self skipWhitespace.
	self peekCharacter = $] ifTrue: [
		position := position + 1.
		self leaveStructure.
		^ result asArray ].
	[
		self skipWhitespace.
		result add: self parseValue.
		self skipWhitespace.
		self peekCharacter = $,
	] whileTrue: [ position := position + 1 ].
	self expect: $].
	self leaveStructure.
	^ result asArray
!
parseStringValue
	| out character code |
	self expect: $".
	out := WriteStream on: (String new: 16).
	[
		character := self nextCharacter.
		character = $"
	] whileFalse: [
		character = $\
			ifTrue: [
				character := self nextCharacter.
				character = $" ifTrue: [ out nextPut: $" ] ifFalse: [
				character = $\ ifTrue: [ out nextPut: $\ ] ifFalse: [
				character = $/ ifTrue: [ out nextPut: $/ ] ifFalse: [
				character = $b ifTrue: [ out nextPut: (Character value: 8) ] ifFalse: [
				character = $f ifTrue: [ out nextPut: (Character value: 12) ] ifFalse: [
				character = $n ifTrue: [ out nextPut: Character lf ] ifFalse: [
				character = $r ifTrue: [ out nextPut: Character cr ] ifFalse: [
				character = $t ifTrue: [ out nextPut: Character tab ] ifFalse: [
				character = $u
					ifTrue: [
						code := self parseUnicodeEscape.
						out nextPut: (Character value: code) ]
					ifFalse: [ self fail: 'JSON string had an unknown escape' ] ] ] ] ] ] ] ] ] ]
			ifFalse: [
				character asInteger < 32 ifTrue: [
					self fail: 'JSON string contained a raw control character' ].
				out nextPut: character ] ].
	^ out contents
!
parseUnicodeEscape
	"Surrogate pairs are combined here so a Convex string outside the basic plane
	 survives the round trip instead of becoming two lone surrogates."
	| high low |
	high := self parseFourHexDigits.
	(high between: 16rD800 and: 16rDBFF) ifFalse: [
		(high between: 16rDC00 and: 16rDFFF) ifTrue: [
			self fail: 'JSON string had an unpaired low surrogate' ].
		^ high ].
	self expect: $\.
	self expect: $u.
	low := self parseFourHexDigits.
	(low between: 16rDC00 and: 16rDFFF) ifFalse: [
		self fail: 'JSON string had an unpaired high surrogate' ].
	^ 16r10000 + ((high - 16rD800) * 1024) + (low - 16rDC00)
!
parseFourHexDigits
	| code digit character |
	code := 0.
	4 timesRepeat: [
		character := self nextCharacter.
		digit := '0123456789abcdef' indexOf: character asLowercase.
		digit = 0 ifTrue: [ self fail: 'JSON string had a bad unicode escape' ].
		code := code * 16 + (digit - 1) ].
	^ code
!
parseNumber
	| start integerStart text isDecimal character number |
	start := position.
	isDecimal := false.
	self peekCharacter = $- ifTrue: [ position := position + 1 ].
	integerStart := position.
	self parseDigits.
	(position - integerStart > 1 and: [ (input at: integerStart) = $0 ]) ifTrue: [
		self fail: 'JSON number had a leading zero' ].
	(self atEnd not and: [ self peekCharacter = $. ]) ifTrue: [
		isDecimal := true.
		position := position + 1.
		self parseDigits ].
	self atEnd ifFalse: [
		character := self peekCharacter.
		(character = $e or: [ character = $E ]) ifTrue: [
			isDecimal := true.
			position := position + 1.
			(self atEnd not and: [ self peekCharacter = $+ or: [ self peekCharacter = $- ] ])
				ifTrue: [ position := position + 1 ].
			self parseDigits ] ].
	text := input copyFrom: start to: position - 1.
	number := isDecimal
		ifTrue: [ text asNumber asFloat ]
		ifFalse: [ text asInteger ].
	(number isFloat and: [ number isFinite not ]) ifTrue: [
		self fail: 'JSON number was outside the finite range' ].
	^ number
!
parseDigits
	| start |
	start := position.
	[ self atEnd not and: [ self peekCharacter isDigit ] ] whileTrue: [
		position := position + 1 ].
	position = start ifTrue: [ self fail: 'JSON number was malformed' ]
! !


!ConvexTimestamp class methodsFor: 'converting'!
initialValue
	"The Convex sync protocol carries timestamps as canonical base64 of a
	 little-endian uint64. Zero encodes to this literal, which is the version a
	 fresh connection starts from."
	^ 'AAAAAAAAAAA='
!
encode: anInteger
	| bytes remaining |
	((anInteger isInteger and: [ anInteger >= 0 ]) and: [ anInteger <= 18446744073709551615 ]) ifFalse: [
		^ (ConvexProtocolError message: 'timestamp is outside uint64') signal ].
	bytes := ByteArray new: 8.
	remaining := anInteger.
	1 to: 8 do: [ :index |
		bytes at: index put: (remaining bitAnd: 255).
		remaining := remaining bitShift: -8 ].
	^ ZnBase64Encoder new encode: bytes
!
decode: aString
	"Reject anything that is not the exact canonical encoding. Re-encoding the
	 decoded number is the cheapest way to refuse alternative paddings."
	| bytes number |
	(aString isString and: [ aString size = 12 ]) ifFalse: [
		^ (ConvexProtocolError message: 'timestamp is not canonical base64 uint64') signal ].
	bytes := [ ZnBase64Encoder new decode: aString ]
		on: Error
		do: [ :error | (ConvexProtocolError message: 'timestamp is not valid base64') signal ].
	bytes size = 8 ifFalse: [
		^ (ConvexProtocolError message: 'timestamp did not decode to eight bytes') signal ].
	number := 0.
	8 to: 1 by: -1 do: [ :index | number := (number bitShift: 8) + (bytes at: index) ].
	(self encode: number) = aString ifFalse: [
		^ (ConvexProtocolError message: 'timestamp is not canonical') signal ].
	^ number
! !


!ConvexResult class methodsFor: 'instance creation'!
value: aValue logs: someLogs
	^ self new setValue: aValue logs: someLogs
! !

!ConvexResult methodsFor: 'accessing'!
setValue: aValue logs: someLogs
	value := aValue.
	logs := someLogs ifNil: [ #() ]
!
value
	^ value
!
logs
	^ logs
! !


!ConvexUpdate class methodsFor: 'instance creation'!
value: aValue logs: someLogs generation: aGeneration
	^ self new setValue: aValue logs: someLogs error: nil generation: aGeneration
!
error: anError generation: aGeneration
	^ self new setValue: nil logs: anError logs error: anError generation: aGeneration
! !

!ConvexUpdate methodsFor: 'accessing'!
setValue: aValue logs: someLogs error: anError generation: aGeneration
	value := aValue.
	logs := someLogs ifNil: [ #() ].
	error := anError.
	generation := aGeneration
!
value
	^ value
!
logs
	^ logs
!
error
	^ error
!
generation
	^ generation
! !


!ConvexHttpsClient methodsFor: 'private'!
setupTLSTo: aUrl
	"Zodiac performs the handshake but never refuses an untrusted chain on its
	 own, so plain ZnClient would happily talk to a forged deployment.
	 Verification state zero is the only accepted answer, and it is checked
	 before any request body is written."
	| verification |
	super setupTLSTo: aUrl.
	verification := [ self connection sslSession certificateVerificationState ]
		on: Error
		do: [ :error |
			(ConvexTransportError message: 'TLS verification state was unavailable: ', error messageText) signal ].
	verification = 0 ifFalse: [
		[ self connection close ] on: Error do: [ :ignored | nil ].
		(ConvexTransportError message: 'TLS certificate for ', aUrl host, ' failed verification with state ', verification printString) signal ]
! !


!ConvexHttpTransport class methodsFor: 'instance creation'!
deployment: aUrlString bearerToken: aToken clientVersion: aVersion
	^ self new setDeployment: aUrlString bearerToken: aToken clientVersion: aVersion
! !

!ConvexHttpTransport methodsFor: 'initialization'!
setDeployment: aUrlString bearerToken: aToken clientVersion: aVersion
	((aUrlString beginsWith: 'http://') or: [ aUrlString beginsWith: 'https://' ]) ifFalse: [
		^ (ConvexProtocolError message: 'CONVEX_URL must be an http or https URL') signal ].
	self assertHeaderSafe: aUrlString named: 'deployment URL'.
	self assertHeaderSafe: aVersion named: 'client version'.
	deploymentUrl := aUrlString.
	[ deploymentUrl endsWith: '/' ] whileTrue: [
		deploymentUrl := deploymentUrl copyFrom: 1 to: deploymentUrl size - 1 ].
	clientVersion := aVersion.
	maximumBodyBytes := ConvexJson maximumBytes.
	timeoutSeconds := 30.
	lastHttpSuccess := true.
	requestLock := Semaphore forMutualExclusion.
	self bearerToken: aToken
!
assertHeaderSafe: aString named: aName
	"A URL or token carrying CR or LF would let a caller inject a second header."
	aString ifNil: [ ^ self ].
	aString isString ifFalse: [
		^ (ConvexProtocolError message: aName, ' must be a string') signal ].
	((aString includes: Character cr) or: [ aString includes: Character lf ]) ifTrue: [
		^ (ConvexProtocolError message: aName, ' cannot contain an HTTP line break') signal ]
! !

!ConvexHttpTransport methodsFor: 'accessing'!
bearerToken: aToken
	^ requestLock critical: [
		self assertHeaderSafe: aToken named: 'bearer token'.
		bearerToken := (aToken isNil or: [ aToken isEmpty ]) ifTrue: [ nil ] ifFalse: [ aToken ] ]
!
deploymentUrl
	^ deploymentUrl
!
clientVersion
	^ clientVersion
! !

!ConvexHttpTransport methodsFor: 'calling'!
call: anOperation path: aPath args: someArguments
	"One Convex JSON HTTP function call. Transport, protocol and function
	 failures stay three distinct kinds all the way back to the caller."
	| requestJson responseBytes payload status logs |
	^ requestLock critical: [
	self assertPath: aPath.
	ConvexJson assertObject: someArguments named: 'args'.
	requestJson := ConvexJson renderToString: (ConvexJson objectWith: {
		'path' -> aPath.
		'args' -> someArguments.
		'format' -> 'json' }).
	responseBytes := self postJson: requestJson toOperation: anOperation.
	payload := [ ConvexJson parseBytes: responseBytes ]
		on: ConvexProtocolError
		do: [ :error |
			(ConvexProtocolError message: anOperation, ' returned non-Convex JSON: ', error messageText) signal ].
	ConvexJson assertObject: payload named: anOperation, ' response'.
	status := payload at: 'status' ifAbsent: [ nil ].
	logs := ConvexJson assertLogs: (payload at: 'logLines' ifAbsent: [ #() ]) named: 'logLines'.
	(status = 'success' and: [ payload includesKey: 'value' ]) ifTrue: [
		lastHttpSuccess ifFalse: [
			^ (ConvexProtocolError message: anOperation, ' returned a success envelope with a non-success HTTP status') signal ].
		^ ConvexResult value: (payload at: 'value') logs: logs ].
	status = 'error' ifTrue: [
		^ (ConvexFunctionError
			message: (ConvexJson
				assertString: (payload at: 'errorMessage' ifAbsent: [ nil ])
				named: 'errorMessage')
			data: (payload at: 'errorData' ifAbsent: [ nil ])
			logs: logs
			operation: anOperation) signal ].
	(ConvexProtocolError message: anOperation, ' response had no usable Convex status') signal ]
!
assertPath: aPath
	"Convex function references are module:function. Refusing anything else here
	 keeps a malformed path from turning into a confusing server-side error."
	((aPath isString and: [ aPath size >= 3 ]) and: [ (aPath occurrencesOf: $:) = 1 ]) ifFalse: [
		^ (ConvexProtocolError message: 'function path must be module:function') signal ].
	self assertHeaderSafe: aPath named: 'function path'
!
postJson: aJsonString toOperation: anOperation
	"Zinc owns TLS, framing and redirects. maximumEntitySize: is what makes the
	 response bounded, so an unexpected oversized body is refused while it is
	 still streaming rather than after it has been buffered."
	| client endpoint contents |
	endpoint := deploymentUrl, '/api/', anOperation.
	client := ConvexHttpsClient new.
	^ [
		client
			url: endpoint;
			beBinary;
			timeout: timeoutSeconds;
			numberOfRetries: 0;
			followRedirects: false;
			enforceHttpSuccess: false;
			maximumEntitySize: maximumBodyBytes;
			headerAt: 'Accept' put: 'application/json';
			headerAt: 'Convex-Client' put: clientVersion.
		bearerToken ifNotNil: [ :token | client setBearerAuthentication: token ].
		client entity: (ZnEntity json: aJsonString).
		contents := [ client post ]
			on: Error
			do: [ :error |
				(error isKindOf: ConvexError)
					ifTrue: [ error signal ]
					ifFalse: [ (ConvexTransportError message: anOperation, ' transport failed: ', error messageText) signal ] ].
		contents ifNil: [
			(ConvexProtocolError message: anOperation, ' returned an empty body') signal ].
		lastHttpSuccess := client response isSuccess.
		contents
	] ensure: [ [ client close ] on: Error do: [ :ignored | nil ] ]
! !


!ConvexWebSocketFrame class methodsFor: 'instance creation'!
final: aBoolean opcode: anOpcode payload: aByteArray
	^ self new setFinal: aBoolean opcode: anOpcode payload: aByteArray
! !

!ConvexWebSocketFrame methodsFor: 'accessing'!
setFinal: aBoolean opcode: anOpcode payload: aByteArray
	final := aBoolean.
	opcode := anOpcode.
	payload := aByteArray
!
isFinal
	^ final
!
opcode
	^ opcode
!
payload
	^ payload
!
isControl
	^ opcode >= 8
! !


!ConvexWebSocket class methodsFor: 'opcodes'!
opcodeContinuation
	^ 0
!
opcodeText
	^ 1
!
opcodeBinary
	^ 2
!
opcodeClose
	^ 8
!
opcodePing
	^ 9
!
opcodePong
	^ 10
!
handshakeGuid
	^ '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
! !

!ConvexWebSocket class methodsFor: 'instance creation'!
openTo: aUrlString clientVersion: aVersion within: milliseconds
	^ self new openTo: aUrlString clientVersion: aVersion within: milliseconds
!
onStream: aStream
	"Tests drive the frame codec over an in-image stream. The parser is the same
	 object the real socket uses, so nothing about framing is test-only."
	^ self new setStream: aStream
! !

!ConvexWebSocket methodsFor: 'initialization'!
setStream: aStream
	stream := aStream.
	maximumFrameBytes := 2 * 1024 * 1024.
	partialFrameTimeoutMilliseconds := 5000.
	closed := false.
	self resetFrameState
!
resetFrameState
	"Frame parsing is an explicit state machine over bytes already consumed, so a
	 deadline can expire between any two bytes and the next call resumes the same
	 frame rather than resynchronising at a false boundary."
	state := #header.
	header := ByteArray new: 10.
	headerFilled := 0.
	headerNeeded := 2.
	payload := nil.
	payloadNeeded := 0.
	payloadFilled := 0.
	frameFinal := false.
	frameOpcode := nil.
	frameDeadline := nil
!
maximumFrameBytes: anInteger
	maximumFrameBytes := anInteger
!
partialFrameTimeoutMilliseconds: anInteger
	"Tests shorten the production five-second absolute deadline without changing
	 the parser or introducing a test-only transport."
	partialFrameTimeoutMilliseconds := anInteger
! !

!ConvexWebSocket methodsFor: 'connecting'!
openTo: aUrlString clientVersion: aVersion within: milliseconds
	| deadline key |
	self setStream: nil.
	url := aUrlString asZnUrl.
	deadline := ConvexDeadline afterMilliseconds: milliseconds.
	stream := self openStreamWithin: deadline.
	key := ZnBase64Encoder new encode: (ConvexRandom bytes: 16).
	self sendHandshakeWithKey: key clientVersion: aVersion.
	self readHandshakeResponseFor: key within: deadline.
	^ self
!
openStreamWithin: aDeadline
	"ZnNetworkingUtils already maps ws and wss onto the right Zodiac stream class.
	 Reading the port from the deployment URL keeps that mapping from depending on
	 ZnUrl knowing the default port of a WebSocket scheme."
	| candidate secure |
	secure := url scheme asString = 'wss'.
	candidate := [ ZnNetworkingUtils default socketStreamToUrl: url ]
		on: Error
		do: [ :error |
			(error isKindOf: ConvexError)
				ifTrue: [ error signal ]
				ifFalse: [ (ConvexTransportError message: 'Live connect failed: ', error messageText) signal ] ].
	candidate
		binary;
		timeout: 1.
	secure ifTrue: [ self negotiateTlsOn: candidate ].
	^ candidate
!
negotiateTlsOn: aStream
	[
		aStream sslSession serverName: url host.
		aStream connect.
		aStream sslSession certificateVerificationState = 0 ifFalse: [
			(ConvexTransportError message: 'Live TLS certificate for ', url host, ' failed verification') signal ]
	] on: Error do: [ :error |
		[ aStream close ] on: Error do: [ :ignored | nil ].
		(error isKindOf: ConvexError)
			ifTrue: [ error signal ]
			ifFalse: [ (ConvexTransportError message: 'Live TLS handshake failed: ', error messageText) signal ] ]
!
sendHandshakeWithKey: aKey clientVersion: aVersion
	| request |
	request := String streamContents: [ :out |
		out nextPutAll: 'GET '; nextPutAll: self requestTarget; nextPutAll: ' HTTP/1.1'; nextPutAll: String crlf.
		out nextPutAll: 'Host: '; nextPutAll: self hostHeader; nextPutAll: String crlf.
		out nextPutAll: 'Upgrade: websocket'; nextPutAll: String crlf.
		out nextPutAll: 'Connection: Upgrade'; nextPutAll: String crlf.
		out nextPutAll: 'Sec-WebSocket-Key: '; nextPutAll: aKey; nextPutAll: String crlf.
		out nextPutAll: 'Sec-WebSocket-Version: 13'; nextPutAll: String crlf.
		out nextPutAll: 'Convex-Client: '; nextPutAll: aVersion; nextPutAll: String crlf.
		out nextPutAll: String crlf ].
	self writeBytes: (ZnUTF8Encoder new encodeString: request)
!
requestTarget
	| path |
	path := url path.
	^ (path isNil or: [ path isEmpty ]) ifTrue: [ '/' ] ifFalse: [ '/', path ]
!
hostHeader
	^ url host, ':', url portOrDefault printString
!
readHandshakeResponseFor: aKey within: aDeadline
	"Read the upgrade response one bounded line at a time. A server that answers
	 with an ordinary HTTP page must be refused, not parsed as frames."
	| statusLine expected headers headerCount line colon name |
	statusLine := self readHeaderLineWithin: aDeadline.
	statusLine = 'HTTP/1.1 101 Switching Protocols' ifFalse: [
		^ (ConvexProtocolError message: 'Live upgrade was rejected: ', statusLine) signal ].
	headers := Dictionary new.
	headerCount := 0.
	[
		line := self readHeaderLineWithin: aDeadline.
		line isEmpty
	] whileFalse: [
		headerCount := headerCount + 1.
		headerCount > 64 ifTrue: [
			^ (ConvexProtocolError message: 'Live upgrade response had too many headers') signal ].
		colon := line indexOf: $:.
		colon > 1 ifFalse: [
			^ (ConvexProtocolError message: 'Live upgrade response had a malformed header') signal ].
		name := (line copyFrom: 1 to: colon - 1) asLowercase trimBoth.
		(headers includesKey: name) ifTrue: [
			^ (ConvexProtocolError message: 'Live upgrade response repeated a header') signal ].
		headers at: name put: (line copyFrom: colon + 1 to: line size) trimBoth ].
	(self header: (headers at: 'upgrade' ifAbsent: [ '' ]) containsToken: 'websocket') ifFalse: [
		^ (ConvexProtocolError message: 'Live upgrade response did not upgrade to websocket') signal ].
	(self header: (headers at: 'connection' ifAbsent: [ '' ]) containsToken: 'upgrade') ifFalse: [
		^ (ConvexProtocolError message: 'Live upgrade response did not confirm the upgrade') signal ].
	expected := ZnBase64Encoder new encode:
		(SHA1 new hashMessage: (ZnUTF8Encoder new encodeString: aKey, self class handshakeGuid)).
	(headers at: 'sec-websocket-accept' ifAbsent: [ '' ]) = expected ifFalse: [
		^ (ConvexProtocolError message: 'Live upgrade response had a wrong Sec-WebSocket-Accept') signal ]
!
header: aString containsToken: aToken
	^ ((aString findTokens: ',') collect: [ :each | each trimBoth asLowercase ])
		includes: aToken
!
readHeaderLineWithin: aDeadline
	| out byte length contents |
	length := 0.
	out := WriteStream on: (String new: 128).
	[
		byte := self readOneByteWithin: aDeadline.
		byte ifNil: [
			^ (ConvexTransportError message: 'Live upgrade response timed out') signal ].
		byte = 10
	] whileFalse: [
		length := length + 1.
		length > 4096 ifTrue: [
			^ (ConvexProtocolError message: 'Live upgrade header line exceeded 4 KiB') signal ].
		out nextPut: (Character value: byte) ].
	contents := out contents.
	(contents isEmpty or: [ contents last ~= Character cr ]) ifTrue: [
		^ (ConvexProtocolError message: 'Live upgrade response did not use CRLF') signal ].
	^ contents size = 1
		ifTrue: [ '' ]
		ifFalse: [ contents copyFrom: 1 to: contents size - 1 ]
!
readOneByteWithin: aDeadline
	| buffer read |
	buffer := ByteArray new: 1.
	[
		read := self readAvailableInto: buffer startingAt: 1 count: 1.
		read = 1 ifTrue: [ ^ buffer at: 1 ].
		aDeadline isExpired ifTrue: [ ^ nil ].
		(Delay forMilliseconds: 2) wait
	] repeat
! !

!ConvexWebSocket methodsFor: 'private - io'!
readAvailableInto: aByteArray startingAt: anOffset count: aCount
	"Answer how many bytes were actually taken, which may be zero.

	 Zodiac streams ignore shouldSignal: and always raise on a read timeout, and a
	 bulk read that raises part way through has already consumed bytes that the
	 caller can no longer see. Taking one byte at a time is what makes a timeout
	 harmless: every byte this method reports is already stored in the parser, so
	 the frame resumes instead of restarting at a false boundary."
	| filled byte |
	filled := 0.
	[ filled < aCount ] whileTrue: [
		(filled = 0 and: [ self isStreamDataAvailable not ]) ifTrue: [
			self assertStreamStillConnected.
			^ 0 ].
		byte := self nextByteOrNil.
		byte ifNil: [ ^ filled ].
		aByteArray at: anOffset + filled put: byte.
		filled := filled + 1 ].
	^ filled
!
nextByteOrNil
	"Answer the next byte, or nil when nothing arrived inside the stream timeout.
	 A closed peer is a transport failure and is reported as one."
	^ [ stream next
			ifNil: [
				closed := true.
				(ConvexTransportError message: 'Live socket closed by the peer') signal ] ]
		on: Error
		do: [ :error |
			(error isKindOf: ConvexError) ifTrue: [ error signal ].
			(error isKindOf: ConnectionTimedOut) ifTrue: [ ^ nil ].
			closed := true.
			(ConvexTransportError message: 'Live socket read failed: ', (error messageText ifNil: [ error class name ])) signal ]
!
isStreamDataAvailable
	^ [ stream isDataAvailable ] on: Error do: [ :ignored | false ]
!
assertStreamStillConnected
	([ (stream respondsTo: #isConnected) and: [ stream isConnected not ] ]
		on: Error
		do: [ :ignored | false ]) ifTrue: [
		closed := true.
		^ (ConvexTransportError message: 'Live socket closed by the peer') signal ]
!
writeBytes: aByteArray
	[
		stream nextPutAll: aByteArray.
		stream flush
	] on: Error do: [ :error |
		(ConvexTransportError message: 'Live socket write failed: ', error messageText) signal ]
! !

!ConvexWebSocket methodsFor: 'reading'!
readFrameWithin: milliseconds
	"Answer one complete frame, or nil when the budget expires. Returning nil is
	 always safe: every byte already consumed stays in the parser."
	| deadline |
	deadline := ConvexDeadline afterMilliseconds: milliseconds.
	[
		state = #header ifTrue: [
			(self fillHeaderWithin: deadline) ifFalse: [ ^ nil ].
			self interpretHeader ].
		state = #extendedLength ifTrue: [
			(self fillHeaderWithin: deadline) ifFalse: [ ^ nil ].
			self interpretExtendedLength ].
		state = #payload ifTrue: [
			(self fillPayloadWithin: deadline) ifFalse: [ ^ nil ].
			state := #complete ].
		state = #complete ifTrue: [ ^ self takeCompletedFrame ]
	] repeat
!
fillHeaderWithin: aDeadline
	| read |
	[ headerFilled < headerNeeded ] whileTrue: [
		read := self readAvailableInto: header startingAt: headerFilled + 1 count: headerNeeded - headerFilled.
		read = 0
			ifTrue: [
				self assertPartialFrameDeadline.
				aDeadline isExpired ifTrue: [ ^ false ].
				(Delay forMilliseconds: 2) wait ]
			ifFalse: [
				frameDeadline ifNil: [ frameDeadline := ConvexDeadline afterMilliseconds: partialFrameTimeoutMilliseconds ].
				headerFilled := headerFilled + read.
				self assertPartialFrameDeadline ] ].
	^ true
!
fillPayloadWithin: aDeadline
	| read |
	[ payloadFilled < payloadNeeded ] whileTrue: [
		read := self readAvailableInto: payload startingAt: payloadFilled + 1 count: payloadNeeded - payloadFilled.
		read = 0
			ifTrue: [
				self assertPartialFrameDeadline.
				aDeadline isExpired ifTrue: [ ^ false ].
				(Delay forMilliseconds: 2) wait ]
			ifFalse: [
				payloadFilled := payloadFilled + read.
				self assertPartialFrameDeadline ] ].
	^ true
!
assertPartialFrameDeadline
	(frameDeadline notNil and: [ frameDeadline isExpired ]) ifTrue: [
		^ (ConvexTransportError message: 'Live frame did not finish inside the absolute deadline') signal ]
!
interpretHeader
	| first second length |
	first := header at: 1.
	second := header at: 2.
	(first bitAnd: 112) = 0 ifFalse: [
		^ (ConvexProtocolError message: 'Live frame set a reserved bit') signal ].
	(second bitAnd: 128) = 0 ifFalse: [
		^ (ConvexProtocolError message: 'Live server frame was masked') signal ].
	frameFinal := (first bitAnd: 128) = 128.
	frameOpcode := first bitAnd: 15.
	(#(0 1 2 8 9 10) includes: frameOpcode) ifFalse: [
		^ (ConvexProtocolError message: 'Live frame used an unassigned opcode') signal ].
	length := second bitAnd: 127.
	frameOpcode >= 8 ifTrue: [
		frameFinal ifFalse: [
			^ (ConvexProtocolError message: 'Live control frame was fragmented') signal ].
		length > 125 ifTrue: [
			^ (ConvexProtocolError message: 'Live control frame payload exceeded 125 bytes') signal ] ].
	length = 126 ifTrue: [ headerNeeded := 4. state := #extendedLength. ^ self ].
	length = 127 ifTrue: [ headerNeeded := 10. state := #extendedLength. ^ self ].
	^ self beginPayloadOfLength: length
!
interpretExtendedLength
	| length |
	length := 0.
	3 to: headerNeeded do: [ :index | length := (length bitShift: 8) + (header at: index) ].
	"Refuse a non-minimal length so two encodings of the same frame cannot slip
	 different bounds past the same check."
	(headerNeeded = 4 and: [ length < 126 ]) ifTrue: [
		^ (ConvexProtocolError message: 'Live frame used a non-minimal length') signal ].
	(headerNeeded = 10 and: [ length < 65536 ]) ifTrue: [
		^ (ConvexProtocolError message: 'Live frame used a non-minimal length') signal ].
	^ self beginPayloadOfLength: length
!
beginPayloadOfLength: aLength
	aLength > maximumFrameBytes ifTrue: [
		^ (ConvexProtocolError message: 'Live frame exceeds the 2 MiB bound') signal ].
	payloadNeeded := aLength.
	payload := ByteArray new: aLength.
	payloadFilled := 0.
	state := #payload
!
takeCompletedFrame
	| frame |
	frame := ConvexWebSocketFrame final: frameFinal opcode: frameOpcode payload: payload.
	self resetFrameState.
	^ frame
!
parserState
	"Exposed so a deterministic test can prove that a timeout in the middle of a
	 frame preserved parser state instead of restarting at a false boundary."
	^ Array with: state with: headerFilled with: payloadFilled
! !

!ConvexWebSocket methodsFor: 'writing'!
sendText: aString
	^ self sendFrameWithOpcode: self class opcodeText payload: (ZnUTF8Encoder new encodeString: aString)
!
sendPongWith: aByteArray
	^ self sendFrameWithOpcode: self class opcodePong payload: aByteArray
!
sendFrameWithOpcode: anOpcode payload: aByteArray
	"Every client frame is masked, as RFC 6455 requires. The mask is applied into
	 a copy so the caller can keep using the payload it handed over."
	| length out mask masked |
	length := aByteArray size.
	length > maximumFrameBytes ifTrue: [
		^ (ConvexProtocolError message: 'Live frame exceeds the 2 MiB bound') signal ].
	mask := ConvexRandom bytes: 4.
	out := WriteStream on: (ByteArray new: length + 14).
	out nextPut: (128 bitOr: anOpcode).
	length < 126
		ifTrue: [ out nextPut: (128 bitOr: length) ]
		ifFalse: [
			length < 65536
				ifTrue: [
					out nextPut: 254.
					out nextPut: (length bitShift: -8); nextPut: (length bitAnd: 255) ]
				ifFalse: [
					out nextPut: 255.
					8 to: 1 by: -1 do: [ :index |
						out nextPut: ((length bitShift: (index - 1) * -8) bitAnd: 255) ] ] ].
	out nextPutAll: mask.
	masked := ByteArray new: length.
	1 to: length do: [ :index |
		masked at: index put: ((aByteArray at: index) bitXor: (mask at: (index - 1 \\ 4) + 1)) ].
	out nextPutAll: masked.
	self writeBytes: out contents
! !

!ConvexWebSocket methodsFor: 'closing'!
closeWithin: milliseconds
	"Close is bounded whether the peer answers, stays silent, keeps sending, or
	 stalls halfway through a frame. The deadline is the contract, not the peer."
	| deadline frame |
	closed ifTrue: [ ^ self abandon ].
	closed := true.
	[ self sendFrameWithOpcode: self class opcodeClose payload: #[3 232] ]
		on: Error
		do: [ :ignored | nil ].
	deadline := ConvexDeadline afterMilliseconds: milliseconds.
	[ deadline isExpired ] whileFalse: [
		[
			frame := self readFrameWithin: (deadline remainingMilliseconds min: 20).
			(frame notNil and: [ frame opcode = self class opcodeClose ]) ifTrue: [ ^ self abandon ]
		] on: Error do: [ :ignored | ^ self abandon ] ].
	^ self abandon
!
abandon
	[ stream ifNotNil: [ stream close ] ] on: Error do: [ :ignored | nil ].
	stream := nil.
	closed := true
!
isClosed
	^ closed
! !


!ConvexSubscription class methodsFor: 'instance creation'!
queryId: anId path: aPath args: someArguments manager: aManager generation: aGeneration
	^ self new setQueryId: anId path: aPath args: someArguments manager: aManager generation: aGeneration
! !

!ConvexSubscription methodsFor: 'accessing'!
setQueryId: anId path: aPath args: someArguments manager: aManager generation: aGeneration
	queryId := anId.
	path := aPath.
	arguments := someArguments.
	manager := aManager.
	generation := aGeneration.
	active := true.
	lastRenderedValue := nil
!
queryId
	^ queryId
!
path
	^ path
!
arguments
	^ arguments
!
generation
	^ generation
!
isActive
	^ active
!
beInactive
	active := false
!
lastRenderedValue
	^ lastRenderedValue
!
lastRenderedValue: aString
	lastRenderedValue := aString
! !

!ConvexSubscription methodsFor: 'consuming'!
nextWithinMilliseconds: milliseconds
	"Deliveries are buffered by the Live owner, never by the socket reader. This
	 consumer polls the owner queue instead of owning a mailbox, so a slow
	 consumer cannot grow memory past the owner bound."
	| deadline update |
	deadline := ConvexDeadline afterMilliseconds: milliseconds.
	[
		update := manager takeUpdateFor: self.
		update ifNotNil: [ ^ update ].
		deadline isExpired ifTrue: [ ^ nil ].
		(Delay forMilliseconds: 5) wait
	] repeat
!
close
	"Unsubscribe travels through the owner, so it cannot race an in-progress read."
	^ manager unsubscribe: self
! !


!ConvexLiveCommand class methodsFor: 'instance creation'!
named: aName arguments: someArguments
	^ self new setName: aName arguments: someArguments
! !

!ConvexLiveCommand methodsFor: 'accessing'!
setName: aName arguments: someArguments
	name := aName.
	arguments := someArguments.
	semaphore := Semaphore new.
	deadline := ConvexDeadline afterMilliseconds: 5000
!
isExpired
	^ deadline isExpired
!
name
	^ name
!
arguments
	^ arguments
!
completeWith: aValue
	value := aValue.
	semaphore signal
!
failWith: anError
	error := anError.
	semaphore signal
!
waitMilliseconds: milliseconds
	"Answer the owner result or raise. A command that is never acknowledged is a
	 transport failure, not a hang."
	(semaphore waitTimeoutMSecs: milliseconds) ifTrue: [
		^ (ConvexTransportError message: 'Live owner did not acknowledge ', name, ' in time') signal ].
	error ifNotNil: [ ^ error signal ].
	^ value
! !


!ConvexLiveManager class methodsFor: 'limits'!
maximumSubscriptions
	^ 64
!
maximumSubscriptionBytes
	^ 8 * 1024 * 1024
!
maximumDeliveries
	^ 16
!
maximumDeliveryBytes
	"Deliveries are charged their exact rendered JSON size plus a conservative
	 per-entry overhead. Sixteen near-maximum Convex values stay far below the
	 shared 128 MiB adapter limit."
	^ 20 * 1024 * 1024
!
deliveryOverheadBytes
	^ 4096
!
initialBackoffMilliseconds
	^ 100
!
maximumBackoffMilliseconds
	^ 15000
! !

!ConvexLiveManager class methodsFor: 'instance creation'!
deployment: aUrlString clientVersion: aVersion
	^ self new setDeployment: aUrlString clientVersion: aVersion
! !

!ConvexLiveManager methodsFor: 'initialization'!
setDeployment: aUrlString clientVersion: aVersion
	deploymentUrl := aUrlString.
	clientVersion := aVersion.
	sessionId := ConvexRandom hexIdentifier.
	commands := SharedQueue new.
	active := Dictionary new.
	activeBytes := 0.
	deliveries := OrderedCollection new.
	deliveryBytes := 0.
	lock := Semaphore forMutualExclusion.
	stopped := false.
	generation := 0.
	connectionCount := 0.
	lastCloseReason := 'InitialConnect'.
	maxObservedTimestamp := 0.
	backoffMilliseconds := self class initialBackoffMilliseconds.
	nextConnectAt := nil.
	querySetVersion := 0.
	remoteVersion := self zeroVersion.
	nextQueryId := 1.
	pendingDisconnect := nil.
	owner := [ self ownerLoop ] forkAt: Processor userBackgroundPriority.
	^ self
!
zeroVersion
	^ Array with: 0 with: 0 with: ConvexTimestamp initialValue
! !

!ConvexLiveManager methodsFor: 'accessing'!
connectionCount
	^ connectionCount
!
lastCloseReason
	^ lastCloseReason
!
maxObservedTimestamp
	^ maxObservedTimestamp
!
generation
	^ generation
!
backoffMilliseconds
	^ backoffMilliseconds
!
querySetVersion
	^ querySetVersion
!
isStopped
	^ stopped
!
hasSocket
	^ socket notNil
!
activeSubscriptions
	^ lock critical: [ active values asArray ]
!
activeBytes
	^ lock critical: [ activeBytes ]
! !

!ConvexLiveManager methodsFor: 'public'!
subscribe: aPath args: someArguments
	^ (self submit: 'subscribe' arguments: (Array with: aPath with: someArguments))
		waitMilliseconds: 10000
!
unsubscribe: aSubscription
	^ (self submit: 'unsubscribe' arguments: (Array with: aSubscription))
		waitMilliseconds: 10000
!
close
	stopped ifTrue: [ ^ true ].
	^ (self submit: 'close' arguments: #()) waitMilliseconds: 10000
!
submit: aName arguments: someArguments
	| command |
	stopped ifTrue: [
		^ (ConvexTransportError message: 'Live manager is closed') signal ].
	command := ConvexLiveCommand named: aName arguments: someArguments.
	commands nextPut: command.
	^ command
! !

!ConvexLiveManager methodsFor: 'deliveries'!
takeUpdateFor: aSubscription
	"The owner publishes, a consumer takes. Subscription identity and owner
	 generation are both re-checked here, so a value queued before a retirement or
	 a same-identifier replacement can never reach the new owner of that slot."
	| found |
	^ lock critical: [
		found := deliveries
			detect: [ :each | (each key == aSubscription) and: [ each value generation = generation ] ]
			ifNone: [ nil ].
		found
			ifNil: [ nil ]
			ifNotNil: [
				deliveries remove: found.
				deliveryBytes := deliveryBytes - (self chargeFor: found value).
				found value ] ]
!
chargeFor: anUpdate
	"Charge every object the queued update retains. Function-error data and logs
	 can be as large as a successful value, so counting only value would make the
	 byte budget fictional on the error path."
	| retained rendered |
	retained := Array
		with: anUpdate value
		with: anUpdate logs
		with: (anUpdate error
			ifNil: [ nil ]
			ifNotNil: [ :error | Array with: error messageText with: error data with: error logs ]).
	rendered := [ ConvexJson renderToBytes: retained ] on: Error do: [ :ignored | #[] ].
	^ rendered size + self class deliveryOverheadBytes
!
publish: anUpdate for: aSubscription
	"Bounded newest-wins. Dropping the oldest entry keeps a stopped reader from
	 growing the image while still letting the newest Convex value through."
	| oldest |
	lock critical: [
		deliveries add: (aSubscription -> anUpdate).
		deliveryBytes := deliveryBytes + (self chargeFor: anUpdate).
		[ deliveries size > self class maximumDeliveries
			or: [ deliveryBytes > self class maximumDeliveryBytes ] ] whileTrue: [
			oldest := deliveries removeFirst.
			deliveryBytes := deliveryBytes - (self chargeFor: oldest value) ] ]
!
purgeDeliveriesFor: aSubscription
	| doomed |
	lock critical: [
		doomed := deliveries select: [ :each | each key == aSubscription ].
		doomed do: [ :each |
			deliveries remove: each.
			deliveryBytes := deliveryBytes - (self chargeFor: each value) ] ]
!
deliveryCount
	^ lock critical: [ deliveries size ]
!
deliveryBytes
	^ lock critical: [ deliveryBytes ]
! !

!ConvexLiveManager methodsFor: 'owner'!
ownerLoop
	"One process owns the socket, the query set version, reconnection and every
	 publication. Controller and consumer processes reach it only through the
	 command queue, so nothing else ever touches the stream."
	[ stopped ] whileFalse: [
		[
			self runPendingCommands.
			stopped ifFalse: [
				socket
					ifNil: [ self connectIfDue ]
					ifNotNil: [ self pumpOneFrame ].
				self runPendingDisconnect ]
		] on: Error do: [ :error | self handleOwnerFailure: error ] ]
!
runPendingCommands
	| command |
	[
		command := commands nextOrNil.
		command ifNil: [ ^ self ].
		self runCommand: command
	] repeat
!
runCommand: aCommand
	[
		aCommand name = 'subscribe' ifTrue: [ ^ self runSubscribe: aCommand ].
		aCommand name = 'unsubscribe' ifTrue: [ ^ self runUnsubscribe: aCommand ].
		aCommand name = 'debugDisconnect' ifTrue: [ ^ self runDebugDisconnect: aCommand ].
		aCommand name = 'close' ifTrue: [ ^ self runClose: aCommand ].
		aCommand failWith: (ConvexProtocolError message: 'unknown Live owner command')
	] on: Error do: [ :error |
		aCommand failWith: ((error isKindOf: ConvexError)
			ifTrue: [ error ]
			ifFalse: [ ConvexTransportError message: (error messageText ifNil: [ 'Live command failed' ]) ]) ]
!
runSubscribe: aCommand
	| path arguments subscription charge |
	path := aCommand arguments first.
	arguments := aCommand arguments second.
	charge := self subscriptionChargeForPath: path arguments: arguments.
	(active size >= self class maximumSubscriptions
		or: [ activeBytes + charge > self class maximumSubscriptionBytes ]) ifTrue: [
		^ aCommand failWith: (ConvexProtocolError message: 'Live subscription capacity exceeded') ].
	nextQueryId >= 4294967295 ifTrue: [
		^ aCommand failWith: (ConvexProtocolError message: 'Live query identifiers are exhausted') ].
	subscription := ConvexSubscription
		queryId: nextQueryId
		path: path
		args: arguments
		manager: self
		generation: generation.
	nextQueryId := nextQueryId + 1.
	lock critical: [ active at: subscription queryId put: subscription ].
	activeBytes := activeBytes + charge.
	socket ifNotNil: [
		[ self sendModification: (self addModificationFor: subscription) ]
			on: Error
			do: [ :error |
				subscription beInactive.
				lock critical: [
					active removeKey: subscription queryId ifAbsent: [ nil ].
					activeBytes := activeBytes - charge ].
				self handleOwnerFailure: error.
				^ aCommand failWith: (self recoverableErrorFrom: error) ] ].
	aCommand completeWith: subscription
!
runUnsubscribe: aCommand
	"Invalidate before acknowledging. Once this returns, the relay identity check
	 fails for the old subscription, so no value queued earlier can cross the
	 acknowledgement."
	| subscription |
	subscription := aCommand arguments first.
	subscription isActive ifTrue: [
		subscription beInactive.
		lock critical: [
			(active at: subscription queryId ifAbsent: [ nil ]) == subscription ifTrue: [
				active removeKey: subscription queryId ifAbsent: [ nil ].
				activeBytes := activeBytes - (self
					subscriptionChargeForPath: subscription path
					arguments: subscription arguments) ] ].
		self purgeDeliveriesFor: subscription.
		socket ifNotNil: [
			[ self sendModification: (self removeModificationFor: subscription) ]
				on: Error
				do: [ :ignored | nil ] ] ].
	aCommand completeWith: true
!
subscriptionChargeForPath: aPath arguments: someArguments
	"Charge encoded bytes, not Smalltalk characters, so non-ASCII rooms cannot
	 bypass the fixed subscription-state budget."
	^ (ZnUTF8Encoder new encodeString: aPath) size
		+ (ConvexJson renderToBytes: someArguments) size
!
runDebugDisconnect: aCommand
	"Adapter-only. A subscribe is acknowledged as soon as the owner records it,
	 which can be before the first connection finishes, so a disconnect that
	 arrives in that window waits for a socket instead of failing a healthy run."
	socket ifNil: [ ^ pendingDisconnect := aCommand ].
	^ self performDisconnectFor: aCommand
!
performDisconnectFor: aCommand
	"The acknowledgement happens after the old connection is retired and the
	 reconnect is scheduled, so the controller can rely on the ordering."
	self retire: 'debugDisconnect' bounded: 200.
	backoffMilliseconds := self class initialBackoffMilliseconds.
	nextConnectAt := nil.
	aCommand completeWith: true
!
runPendingDisconnect
	pendingDisconnect ifNil: [ ^ self ].
	socket ifNotNil: [ | command |
		command := pendingDisconnect.
		pendingDisconnect := nil.
		^ self performDisconnectFor: command ].
	pendingDisconnect isExpired ifTrue: [ | command |
		command := pendingDisconnect.
		pendingDisconnect := nil.
		command failWith: (ConvexTransportError message: 'Live socket did not connect in time to disconnect') ]
!
runClose: aCommand
	stopped := true.
	pendingDisconnect ifNotNil: [ :command |
		pendingDisconnect := nil.
		command failWith: (ConvexTransportError message: 'Live manager closed before the disconnect ran') ].
	lock critical: [
		active valuesDo: [ :each | each beInactive ].
		active := Dictionary new.
		deliveries := OrderedCollection new.
		deliveryBytes := 0 ].
	activeBytes := 0.
	self retire: 'ClientClosed' bounded: 200.
	aCommand completeWith: true
! !

!ConvexLiveManager methodsFor: 'connecting'!
connectIfDue
	(nextConnectAt notNil and: [ nextConnectAt isExpired not ]) ifTrue: [
		(Delay forMilliseconds: (nextConnectAt remainingMilliseconds min: 25)) wait.
		^ self ].
	[
		socket := self openSocket.
		connectionCount := connectionCount + 1.
		self sendConnect.
		self replayActiveSubscriptions.
		remoteVersion := self zeroVersion.
		nextConnectAt := nil.
		"A healthy handshake resets the exponential delay, so five real reconnects
		 never inherit an earlier maximum."
		backoffMilliseconds := self class initialBackoffMilliseconds
	] on: Error do: [ :error |
		socket ifNotNil: [ [ socket abandon ] on: Error do: [ :ignored | nil ] ].
		socket := nil.
		lastCloseReason := error messageText ifNil: [ 'ConnectFailed' ].
		nextConnectAt := ConvexDeadline afterMilliseconds: backoffMilliseconds.
		backoffMilliseconds := (backoffMilliseconds * 2) min: self class maximumBackoffMilliseconds ]
!
openSocket
	^ ConvexWebSocket openTo: self websocketUrl clientVersion: clientVersion within: 5000
!
websocketUrl
	^ (deploymentUrl beginsWith: 'https://')
		ifTrue: [ 'wss://', (deploymentUrl copyFrom: 9 to: deploymentUrl size), '/api/sync' ]
		ifFalse: [ 'ws://', (deploymentUrl copyFrom: 8 to: deploymentUrl size), '/api/sync' ]
!
sendConnect
	| message |
	message := ConvexJson objectWith: {
		'type' -> 'Connect'.
		'sessionId' -> sessionId.
		'connectionCount' -> (connectionCount - 1).
		'lastCloseReason' -> lastCloseReason.
		'clientTs' -> 0 }.
	maxObservedTimestamp > 0 ifTrue: [
		message at: 'maxObservedTimestamp' put: (ConvexTimestamp encode: maxObservedTimestamp) ].
	socket sendText: (ConvexJson renderToString: message)
!
replayActiveSubscriptions
	"Every new connection resends the whole active Add set from query set version
	 zero. Without this a reconnect would silently stop delivering."
	| subscriptions modifications |
	subscriptions := lock critical: [ active values asArray ].
	querySetVersion := 0.
	subscriptions isEmpty ifTrue: [ ^ self ].
	modifications := (subscriptions asSortedCollection: [ :left :right | left queryId <= right queryId ]) asArray
		collect: [ :each | self addModificationFor: each ].
	socket sendText: (ConvexJson renderToString: (ConvexJson objectWith: {
		'type' -> 'ModifyQuerySet'.
		'baseVersion' -> 0.
		'newVersion' -> 1.
		'modifications' -> modifications })).
	querySetVersion := 1
!
addModificationFor: aSubscription
	^ ConvexJson objectWith: {
		'type' -> 'Add'.
		'queryId' -> aSubscription queryId.
		'udfPath' -> aSubscription path.
		'args' -> (Array with: aSubscription arguments) }
!
removeModificationFor: aSubscription
	^ ConvexJson objectWith: {
		'type' -> 'Remove'.
		'queryId' -> aSubscription queryId }
!
sendModification: aModification
	querySetVersion >= 4294967295 ifTrue: [
		^ (ConvexProtocolError message: 'Live query set version is exhausted') signal ].
	socket sendText: (ConvexJson renderToString: (ConvexJson objectWith: {
		'type' -> 'ModifyQuerySet'.
		'baseVersion' -> querySetVersion.
		'newVersion' -> (querySetVersion + 1).
		'modifications' -> (Array with: aModification) })).
	querySetVersion := querySetVersion + 1
!
retire: aReason bounded: milliseconds
	"Retiring bumps the generation first. Anything already queued is stale by
	 construction from that moment on, whichever process looks at it next."
	generation := generation + 1.
	lastCloseReason := aReason.
	socket ifNotNil: [
		[ socket closeWithin: milliseconds ] on: Error do: [ :ignored | nil ] ].
	socket := nil
!
handleOwnerFailure: anError
	"A protocol or transport failure retires the connection and tells every live
	 subscription, but never strands them: the next connection replays their Add
	 operations and they can deliver a later valid value."
	| subscriptions retiredGeneration |
	subscriptions := lock critical: [ active values asArray ].
	self retire: (anError messageText ifNil: [ 'OwnerFailure' ]) bounded: 100.
	retiredGeneration := generation.
	subscriptions do: [ :each |
		each isActive ifTrue: [
			each lastRenderedValue: nil.
			self publish: (ConvexUpdate error: (self recoverableErrorFrom: anError) generation: retiredGeneration)
				for: each ] ].
	nextConnectAt := ConvexDeadline afterMilliseconds: backoffMilliseconds.
	backoffMilliseconds := (backoffMilliseconds * 2) min: self class maximumBackoffMilliseconds
!
recoverableErrorFrom: anError
	^ (anError isKindOf: ConvexError)
		ifTrue: [ anError ]
		ifFalse: [ ConvexTransportError message: (anError messageText ifNil: [ 'Live transport failed' ]) ]
! !

!ConvexLiveManager methodsFor: 'receiving'!
pumpOneFrame
	| frame |
	frame := socket readFrameWithin: 25.
	frame ifNil: [ ^ self ].
	frame opcode = ConvexWebSocket opcodePing ifTrue: [
		^ socket sendPongWith: frame payload ].
	frame opcode = ConvexWebSocket opcodePong ifTrue: [ ^ self ].
	frame opcode = ConvexWebSocket opcodeClose ifTrue: [
		^ (ConvexTransportError message: 'Live server closed the WebSocket') signal ].
	frame opcode = ConvexWebSocket opcodeBinary ifTrue: [
		^ (ConvexProtocolError message: 'Live binary messages are unsupported') signal ].
	frame opcode = ConvexWebSocket opcodeContinuation ifTrue: [
		^ (ConvexProtocolError message: 'Live continuation frame had no start') signal ].
	frame isFinal ifFalse: [ ^ self readFragmentsAfter: frame ].
	^ self handleMessageBytes: frame payload
!
readFragmentsAfter: aFrame
	"Fragments are reassembled under the same byte bound as a single frame, and a
	 control frame in the middle is handled without breaking the message. UTF-8 is
	 decoded only once the whole message has arrived."
	| chunks total deadline frame |
	chunks := OrderedCollection with: aFrame payload.
	total := aFrame payload size.
	deadline := ConvexDeadline afterMilliseconds: 5000.
	[
		frame := socket readFrameWithin: (deadline remainingMilliseconds min: 100).
		frame
			ifNil: [
				deadline isExpired ifTrue: [
					^ (ConvexTransportError message: 'fragmented Live message did not finish in time') signal ] ]
			ifNotNil: [
				frame isControl
					ifTrue: [
						frame opcode = ConvexWebSocket opcodePing ifTrue: [ socket sendPongWith: frame payload ].
						frame opcode = ConvexWebSocket opcodeClose ifTrue: [
							^ (ConvexTransportError message: 'Live server closed the WebSocket') signal ] ]
					ifFalse: [
						frame opcode = ConvexWebSocket opcodeContinuation ifFalse: [
							^ (ConvexProtocolError message: 'Live message interleaved a new data frame') signal ].
						chunks size >= 4096 ifTrue: [
							^ (ConvexProtocolError message: 'fragmented Live message used too many frames') signal ].
						total := total + frame payload size.
						total > ConvexJson maximumBytes ifTrue: [
							^ (ConvexProtocolError message: 'fragmented Live message exceeds the 2 MiB bound') signal ].
						chunks add: frame payload.
						frame isFinal ifTrue: [
							^ self handleMessageBytes: (self joinChunks: chunks total: total) ] ] ]
	] repeat
!
joinChunks: someChunks total: aTotal
	| result offset |
	result := ByteArray new: aTotal.
	offset := 1.
	someChunks do: [ :chunk |
		result replaceFrom: offset to: offset + chunk size - 1 with: chunk startingAt: 1.
		offset := offset + chunk size ].
	^ result
!
handleMessageBytes: someBytes
	| message type |
	message := ConvexJson parseBytes: someBytes.
	ConvexJson assertObject: message named: 'Live message'.
	type := ConvexJson assertString: (message at: 'type' ifAbsent: [ nil ]) named: 'Live message type'.
	type = 'Transition' ifTrue: [ ^ self applyTransition: message ].
	(#('Ping' 'MutationResponse' 'ActionResponse') includes: type) ifTrue: [ ^ self ].
	type = 'FatalError' ifTrue: [
		^ (ConvexProtocolError message: 'Live server reported a fatal error') signal ].
	^ (ConvexProtocolError message: 'unsupported Live server message: ', type) signal
!
applyTransition: aMessage
	"Nothing is published until the whole transition validates. A partially
	 applied transition would let a bad frame move client state forward."
	| startVersion endVersion modifications startTimestamp endTimestamp pending parsed seen queryId |
	startVersion := self validVersion: (aMessage at: 'startVersion' ifAbsent: [ nil ]).
	endVersion := self validVersion: (aMessage at: 'endVersion' ifAbsent: [ nil ]).
	(self version: startVersion equals: remoteVersion) ifFalse: [
		^ (ConvexProtocolError message: 'Live transition start version did not match local state') signal ].
	modifications := ConvexJson assertArray: (aMessage at: 'modifications' ifAbsent: [ nil ]) named: 'modifications'.
	startTimestamp := ConvexTimestamp decode: (startVersion at: 3).
	endTimestamp := ConvexTimestamp decode: (endVersion at: 3).
	endTimestamp < startTimestamp ifTrue: [
		^ (ConvexProtocolError message: 'Live transition moved the timestamp backwards') signal ].
	pending := OrderedDictionary new.
	seen := Set new.
	modifications do: [ :each |
		ConvexJson assertObject: each named: 'Live modification'.
		queryId := ConvexJson assertUnsignedInteger32: (each at: 'queryId' ifAbsent: [ nil ]) named: 'queryId'.
		(seen includes: queryId) ifTrue: [
			^ (ConvexProtocolError message: 'Live transition repeated a queryId') signal ].
		seen add: queryId.
		parsed := self parseModification: each.
		parsed ifNotNil: [ pending at: parsed key put: parsed value ] ].
	remoteVersion := endVersion.
	endTimestamp > maxObservedTimestamp ifTrue: [ maxObservedTimestamp := endTimestamp ].
	pending keysAndValuesDo: [ :subscription :update | self publishIfChanged: update for: subscription ].
	"A valid server transition is as good a health signal as a fresh handshake."
	backoffMilliseconds := self class initialBackoffMilliseconds.
	nextConnectAt := nil
!
publishIfChanged: anUpdate for: aSubscription
	"After a reconnect the server rehydrates every active query. Suppressing an
	 identical value keeps the reconnect sequence exactly initial value,
	 acknowledgement, external mutation, new value."
	| rendered |
	anUpdate error ifNotNil: [ ^ self publish: anUpdate for: aSubscription ].
	rendered := ConvexJson renderToString: anUpdate value.
	rendered = aSubscription lastRenderedValue ifTrue: [ ^ self ].
	aSubscription lastRenderedValue: rendered.
	^ self publish: anUpdate for: aSubscription
!
parseModification: aModification
	| type queryId subscription logs |
	ConvexJson assertObject: aModification named: 'Live modification'.
	type := ConvexJson assertString: (aModification at: 'type' ifAbsent: [ nil ]) named: 'Live modification type'.
	queryId := ConvexJson assertUnsignedInteger32: (aModification at: 'queryId' ifAbsent: [ nil ]) named: 'queryId'.
	subscription := lock critical: [ active at: queryId ifAbsent: [ nil ] ].
	type = 'QueryUpdated' ifTrue: [
		(aModification includesKey: 'value') ifFalse: [
			^ (ConvexProtocolError message: 'QueryUpdated is missing value') signal ].
		logs := ConvexJson assertLogs: (aModification at: 'logLines' ifAbsent: [ #() ]) named: 'logLines'.
		subscription ifNil: [ ^ nil ].
		^ subscription -> (ConvexUpdate value: (aModification at: 'value') logs: logs generation: generation) ].
	type = 'QueryFailed' ifTrue: [
		logs := ConvexJson assertLogs: (aModification at: 'logLines' ifAbsent: [ #() ]) named: 'logLines'.
		subscription ifNil: [ ^ nil ].
		^ subscription -> (ConvexUpdate
			error: (ConvexFunctionError
				message: (ConvexJson assertString: (aModification at: 'errorMessage' ifAbsent: [ nil ]) named: 'errorMessage')
				data: (aModification at: 'errorData' ifAbsent: [ nil ])
				logs: logs
				operation: 'subscription')
			generation: generation) ].
	type = 'QueryRemoved' ifTrue: [ ^ nil ].
	^ (ConvexProtocolError message: 'unsupported Live modification: ', type) signal
!
validVersion: aVersion
	| querySet identity timestamp |
	ConvexJson assertObject: aVersion named: 'Live state version'.
	querySet := ConvexJson assertUnsignedInteger32: (aVersion at: 'querySet' ifAbsent: [ nil ]) named: 'querySet'.
	identity := ConvexJson assertUnsignedInteger32: (aVersion at: 'identity' ifAbsent: [ nil ]) named: 'identity'.
	timestamp := ConvexJson assertString: (aVersion at: 'ts' ifAbsent: [ nil ]) named: 'ts'.
	ConvexTimestamp decode: timestamp.
	^ Array with: querySet with: identity with: timestamp
!
version: aVersion equals: anotherVersion
	^ ((aVersion at: 1) = (anotherVersion at: 1))
		and: [ ((aVersion at: 2) = (anotherVersion at: 2))
		and: [ (aVersion at: 3) = (anotherVersion at: 3) ] ]
! !


!ConvexClient class methodsFor: 'instance creation'!
deployment: aUrlString
	^ self deployment: aUrlString bearerToken: nil
!
deployment: aUrlString bearerToken: aToken
	^ self new setDeployment: aUrlString bearerToken: aToken clientVersion: self clientVersion
!
clientVersion
	^ 'smalltalk-0.1.0'
! !

!ConvexClient methodsFor: 'initialization'!
setDeployment: aUrlString bearerToken: aToken clientVersion: aVersion
	deploymentUrl := aUrlString.
	clientVersion := aVersion.
	http := ConvexHttpTransport deployment: aUrlString bearerToken: aToken clientVersion: aVersion.
	live := nil.
	closed := false.
	lock := Semaphore forMutualExclusion.
	^ self
! !

!ConvexClient methodsFor: 'calling'!
query: aPath args: someArguments
	^ (self call: 'query' path: aPath args: someArguments) value
!
mutation: aPath args: someArguments
	^ (self call: 'mutation' path: aPath args: someArguments) value
!
action: aPath args: someArguments
	^ (self call: 'action' path: aPath args: someArguments) value
!
call: anOperation path: aPath args: someArguments
	"Answer the whole result, including logLines, for callers that want them."
	self assertOpen.
	^ http call: anOperation path: aPath args: someArguments
!
setBearerToken: aToken
	"Later HTTP calls carry the new token. Live authentication is deferred."
	self assertOpen.
	http bearerToken: aToken
! !

!ConvexClient methodsFor: 'live'!
subscribe: aPath args: someArguments
	self assertOpen.
	http assertPath: aPath.
	ConvexJson assertObject: someArguments named: 'args'.
	^ self liveManager subscribe: aPath args: someArguments
!
liveManager
	"Live starts lazily, so a client that only makes HTTP calls never opens a
	 WebSocket."
	^ lock critical: [
		live ifNil: [ live := ConvexLiveManager deployment: deploymentUrl clientVersion: clientVersion ] ]
!
hasLiveManager
	^ lock critical: [ live notNil ]
! !

!ConvexClient methodsFor: 'closing'!
close
	| manager |
	closed ifTrue: [ ^ self ].
	closed := true.
	manager := lock critical: [ live ].
	manager ifNotNil: [ [ manager close ] on: Error do: [ :ignored | nil ] ]
!
isClosed
	^ closed
!
assertOpen
	closed ifTrue: [
		^ (ConvexTransportError message: 'Convex client is closed') signal ]
! !
