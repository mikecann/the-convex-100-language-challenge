# Deterministic language-local tests for the Ring Convex client.
#
# Nothing here touches the network. These cases pin the JSON scanner's exact
# subtree retention, the integral-number decoder the canonical example depends
# on, the Live transition state machine including its rollback and recovery
# behaviour, the client's bounded delivery queue, and the conformance adapter's
# output ownership, byte budget and generation barriers.
#
# The adapter is loaded rather than copied, so these tests exercise the exact
# executable the shared controller drives. Loading it also brings in the client.
load "convexadapter.ring"

aTestWrites = []
cTestUnicode = "Hello, 世界 👋"

# ---------------------------------------------------------------------------
# JSON scanning keeps Convex values byte-exact
# ---------------------------------------------------------------------------

cNested = '{"unicode":"' + cTestUnicode +
	'","nested":{"booleans":[true,false],"number":42.5,"nil":null},"tail":1}'
assertThat(cvxJsonField(cNested, "nested", true) =
	'{"booleans":[true,false],"number":42.5,"nil":null}',
	"a nested JSON subtree was not retained byte for byte")
assertThat(cvxJsonField(cNested, "tail", true) = "1", "a trailing JSON field was lost")
assertThat(cvxJsonField(cNested, "absent", false) = "", "an absent optional field was invented")
assertThat(cvxJsonUnquote(cvxJsonField(cNested, "unicode", true)) = cTestUnicode,
	"a UTF-8 JSON string did not survive decoding")
assertThat(len(cvxJsonElements('[1,{"x":true},null,"a,b"]')) = 4,
	"the JSON array splitter lost an element")
assertThat(cvxJsonElements('[1,{"x":true},null,"a,b"]')[4] = '"a,b"',
	"a comma inside a JSON string split an array element")

# A value containing braces, brackets or quotes must not confuse the scanner.
cTricky = '{"a":"}{","b":[{"c":"]"}],"d":3}'
assertThat(cvxJsonField(cTricky, "d", true) = "3", "brace-like string content broke field scanning")
assertThat(cvxJsonField(cTricky, "b", true) = '[{"c":"]"}]',
	"a bracket inside a string broke an array subtree")

# Round-tripping through the encoder preserves control characters and the two
# characters JSON itself reserves.
cControl = "line" + CVX_NEWLINE + CVX_TAB + CVX_QUOTE + CVX_BACKSLASH + char(1)
assertThat(cvxJsonUnquote(cvxJsonQuote(cControl)) = cControl,
	"JSON quoting did not round-trip control characters")
assertThat(cvxJsonUnquote(CVX_QUOTE + "A" + CVX_BACKSLASH + "u00e9" + CVX_QUOTE) = "A" + cvxUtf8(233),
	"a JSON unicode escape did not decode")
assertThat(cvxJsonUnquote(CVX_QUOTE + CVX_BACKSLASH + "ud83d" + CVX_BACKSLASH + "udc4b" + CVX_QUOTE) =
	cvxUtf8(128075), "a JSON surrogate pair did not decode")

assertObjectRejected("[1,2]", "a JSON array was accepted as an object")
assertObjectRejected('{"a":"x}', "an unterminated JSON string was accepted")
assertObjectRejected('{"a" 1}', "a JSON object without a separator was accepted")
assertStringRejected("7", "a bare number was accepted as a JSON string")
assertStringRejected("true", "a boolean was accepted as a JSON string")

# ---------------------------------------------------------------------------
# Whole numbers, exactly as the canonical example decodes them
# ---------------------------------------------------------------------------

assertThat(cvxWholeNumber("0", "count") = 0, "the integer zero was rejected")
assertThat(cvxWholeNumber("0.0", "count") = 0, "the integral decimal 0.0 was rejected")
assertThat(cvxWholeNumber("1.0", "count") = 1, "the integral decimal 1.0 was rejected")
assertThat(cvxWholeNumber("1.000", "count") = 1, "a padded integral decimal was rejected")
assertThat(cvxWholeNumber("-3", "count") = -3, "a negative whole number was rejected")
for cToken in [CVX_QUOTE + "1" + CVX_QUOTE, "0.5", "1.01", "true", "false", "null", "1e3",
	"", " ", "+1", "0x10", "1234567890123456789"]
	assertWholeRejected(cToken, "a non-integral token was accepted as a whole number")
next

# ---------------------------------------------------------------------------
# Canonical timestamps order correctly
# ---------------------------------------------------------------------------

assertThat(cvxTimestampKey("AAAAAAAAAAA=") = "0000000000000000", "the zero timestamp key changed")
assertThat(cvxTimestampKey("AQAAAAAAAAA=") = "0000000000000001", "the little-endian key changed")
assertThat(strcmp(cvxTimestampKey("/wAAAAAAAAA="), cvxTimestampKey("AAEAAAAAAAA=")) < 0,
	"timestamp ordering failed across the 255 to 256 boundary")
assertThat(cvxBase64Encode(cvxBase64Decode("AQIDBAUGBwg=")) = "AQIDBAUGBwg=",
	"base64 did not round-trip")

# ---------------------------------------------------------------------------
# Protocol counters are validated as uint32 tokens, not as Ring numbers
# ---------------------------------------------------------------------------

assertThat(cvxJsonUint32("0", "x") = 0, "the uint32 zero boundary was rejected")
assertThat(cvxJsonUint32("4294967295", "x") = 4294967295, "the uint32 maximum was rejected")
for cToken in [CVX_QUOTE + "0" + CVX_QUOTE, "true", "false", "null", "1.5", "-1",
	"4294967296", "01", "", "1 x"]
	assertUint32Rejected(cToken, "an invalid uint32 token was accepted")
next

# ---------------------------------------------------------------------------
# URLs and TLS configuration
# ---------------------------------------------------------------------------

assertThat(cvxSyncUrl("https://example.convex.cloud") = "wss://example.convex.cloud/api/sync",
	"an HTTPS deployment did not map to a WSS sync URL")
assertThat(cvxSyncUrl("http://backend:3210") = "ws://backend:3210/api/sync",
	"an HTTP deployment did not map to a WS sync URL")
assertThat(cvxValidUrl("ftp://example.test") = false, "a non-HTTP scheme was accepted")
assertThat(CONVEX_CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt",
	"the pinned CA bundle path changed")
assertThat(len(read(CONVEX_CA_BUNDLE)) > 1024,
	"the runtime CA bundle the TLS transport verifies against is missing")

# ---------------------------------------------------------------------------
# The Live transition state machine
# ---------------------------------------------------------------------------

oLive = new ConvexClient("http://127.0.0.1:1")
oLive.aSubscriptions = [[0, "demo:state", "{}", ""]]

cV0 = '{"querySet":0,"identity":0,"ts":"AAAAAAAAAAA="}'
cV1 = '{"querySet":0,"identity":0,"ts":"AQAAAAAAAAA="}'
cV2 = '{"querySet":0,"identity":0,"ts":"AgAAAAAAAAA="}'
cV3 = '{"querySet":0,"identity":0,"ts":"AwAAAAAAAAA="}'
cV4 = '{"querySet":0,"identity":0,"ts":"BAAAAAAAAAA="}'
cV5 = '{"querySet":0,"identity":0,"ts":"BQAAAAAAAAA="}'

oLive.handleMessage(transition(cV0, cV1,
	'{"type":"QueryUpdated","queryId":0,"value":{"count":0.0}}'))
aEvent = oLive.nextEvent()
assertThat(aEvent[2] = "value" and aEvent[3] = '{"count":0.0}',
	"the initial QueryUpdated value was not published exactly")

# The identical value arriving again is a rehydration, not news.
oLive.handleMessage(transition(cV1, cV2,
	'{"type":"QueryUpdated","queryId":0,"value":{"count":0.0}}'))
assertThat(oLive.pendingEvents() = 0, "an unchanged rehydration was published")

# QueryFailed is a structured FunctionError that keeps the subscription alive.
oLive.handleMessage(transition(cV2, cV3,
	'{"type":"QueryFailed","queryId":0,"errorMessage":"fixture failure",' +
	'"errorData":{"code":"ROOM_EMPTY"},"logLines":["failure log"]}'))
aEvent = oLive.nextEvent()
assertThat(aEvent[2] = "error", "QueryFailed did not publish an error")
assertThat(aEvent[5] = "FunctionError", "QueryFailed was not reported as a FunctionError")
assertThat(aEvent[7] = '{"code":"ROOM_EMPTY"}', "QueryFailed errorData was not retained exactly")
assertThat(aEvent[4] = '["failure log"]', "QueryFailed log lines were not retained")

# The value suppressed before the failure must be republished after it.
oLive.handleMessage(transition(cV3, cV4,
	'{"type":"QueryUpdated","queryId":0,"value":{"count":0.0}}'))
aEvent = oLive.nextEvent()
assertThat(aEvent[2] = "value", "the subscription did not recover after QueryFailed")

# A malformed field rolls the entire transition back.
assertRollback(oLive, transition(cV4, '{"querySet":"0","identity":0,"ts":"BQAAAAAAAAA="}',
	'{"type":"QueryUpdated","queryId":0,"value":{"count":9}}'), "an invalid querySet token")
assertRollback(oLive, transition(cV4, '{"querySet":0,"identity":4294967296,"ts":"BQAAAAAAAAA="}',
	'{"type":"QueryUpdated","queryId":0,"value":{"count":9}}'), "an out-of-range identity")
assertRollback(oLive, transition(cV4, cV5,
	'{"type":"QueryUpdated","queryId":"0","value":{"count":9}}'), "a quoted queryId")
assertRollback(oLive, transition(cV4, cV5,
	'{"type":"QueryUpdated","value":{"count":9}}'), "a missing queryId")
assertRollback(oLive, transition(cV4, cV5,
	'{"type":"QueryFailed","queryId":0,"errorMessage":7}'), "a non-string QueryFailed message")
assertRollback(oLive, transition(cV4, cV5,
	'{"type":"Unknown","queryId":0}'), "an unsupported modification")
assertRollback(oLive, transition(cV0, cV5,
	'{"type":"QueryUpdated","queryId":0,"value":{"count":9}}'), "a mismatched start version")

# An unknown query ID is ignored without stalling the version, and a
# QueryFailed without errorData stays absent rather than becoming null.
oLive.handleMessage(transition(cV4, cV5,
	'{"type":"QueryUpdated","queryId":4294967295,"value":{"count":9}}'))
assertThat(oLive.pendingEvents() = 0, "an unknown query ID published a delivery")
oLive.handleMessage(transition(cV5, '{"querySet":0,"identity":0,"ts":"BgAAAAAAAAA="}',
	'{"type":"QueryFailed","queryId":0,"errorMessage":"no data"}'))
aEvent = oLive.nextEvent()
assertThat(aEvent[7] = "", "an absent QueryFailed errorData became a serialized null")

# A retired connection reports a structured failure to every surviving
# subscription and schedules exactly one replacement.
oLive.retire("ProtocolError: fixture parser failure", true)
aEvent = oLive.nextEvent()
assertThat(aEvent[2] = "error" and aEvent[5] = "ProtocolError",
	"a retired connection did not publish a structured ProtocolError")
assertThat(aEvent[6] = "fixture parser failure", "the ProtocolError message kept its class prefix")
assertThat(oLive.reconnectArmed(), "a transport retirement did not schedule a reconnect")
assertThat(oLive.connectionCount() = 1, "the connection counter did not advance")
oLive.retire("TransportError: fixture peer closed", true)
aEvent = oLive.nextEvent()
assertThat(aEvent[5] = "TransportError", "a peer close was not a structured TransportError")
assertThat(oLive.lastCloseReason() = "TransportError: fixture peer closed",
	"the last close reason was not retained")
oLive.close()
assertThat(oLive.reconnectArmed() = false, "close left a reconnect scheduled")

# ---------------------------------------------------------------------------
# The client's bounded delivery queue
# ---------------------------------------------------------------------------

oQueue = new ConvexClient("http://127.0.0.1:1")
oQueue.aSubscriptions = [[0, "demo:state", "{}", ""]]
for nIndex = 1 to CONVEX_MAX_QUEUED_EVENTS + 8
	oQueue.publishValue(0, '{"count":' + cvxIntText(nIndex) + "}", "[]")
next
assertThat(oQueue.pendingEvents() = CONVEX_MAX_QUEUED_EVENTS,
	"the delivery queue grew past its event bound")
assertThat(oQueue.droppedEvents() = 8, "the delivery queue did not report its drops")
nAccounted = 0
for aEntry in oQueue.aEvents
	nAccounted = nAccounted + aEntry[8]
next
assertThat(oQueue.queuedBytes() = nAccounted, "the delivery queue byte accounting drifted")
aEvent = oQueue.nextEvent()
assertThat(aEvent[3] = '{"count":9}',
	"the delivery queue dropped the newest value instead of the oldest")
oQueue.close()

# ---------------------------------------------------------------------------
# The adapter's output ownership, budget and generation barriers
# ---------------------------------------------------------------------------

cAdapterWriteHook = "testCollectWrite"
lAdapterWriteStalled = false
lAdapterStreamReady = true

assertThat(adapterEntryCost("x") = 1 + 1 + ADAPTER_ENTRY_OVERHEAD + ADAPTER_STREAM_OVERHEAD,
	"the adapter byte cost omitted the newline or its overhead allowance")

# Pausing after dequeue, invalidating the subscription and then publishing the
# acknowledgement is exactly what unsubscribe and same-ID replacement do. The
# stale delivery must not cross that acknowledgement.
aAdapterSubs = [["same", 7]]
aAdapterGenerations = [["same", 1]]
aTestWrites = []
cAdapterPauseHook = "testInvalidateThenAck"
adapterEmit('{"type":"subscription","subscriptionId":"same","value":{"count":99}}',
	true, "same", 1)
assertThat(len(aAdapterQueue) = 0, "a paused stale delivery stayed queued")
assertThat(len(aTestWrites) = 1, "the acknowledgement was not the only record written")
assertThat(trim(aTestWrites[1]) = '{"id":"replace","type":"ack"}',
	"the replacement acknowledgement was not delivered first")

# A delivery tagged with a retired generation is discarded before the write.
aAdapterSubs = [["same", 8]]
aAdapterGenerations = [["same", 2]]
aTestWrites = []
adapterEmit('{"type":"subscription","subscriptionId":"same","value":{"count":98}}',
	true, "same", 1)
assertThat(len(aTestWrites) = 0, "a same-ID replacement admitted an old generation")

# With the reader stopped, deliveries must consume neither the slots nor the
# bytes reserved for controller responses.
aTestWrites = []
aAdapterQueue = []
nAdapterQueueBytes = 0
lAdapterWriting = false
lAdapterWriteStalled = true
for nIndex = 1 to ADAPTER_MAX_EVENTS + 8
	adapterEmit('{"type":"subscription","subscriptionId":"same","value":{"count":' +
		cvxIntText(nIndex) + "}}", true, "same", 2)
next
assertThat(len(aAdapterQueue) = ADAPTER_MAX_EVENTS - ADAPTER_CONTROL_RESERVE_EVENTS,
	"deliveries consumed the reserved control slots")
assertThat(aAdapterQueue[1][ADAPTER_STATE] = "accepted",
	"the record the writer already owns lost its accepted state")
for cId in ["replace", "unsubscribe", "extra", "close"]
	adapterEmit('{"id":"' + cId + '","type":"ack"}', false, "", 0)
next
assertThat(len(aAdapterQueue) = ADAPTER_MAX_EVENTS,
	"a stopped reader prevented the reserved control events")
nAccounted = 0
for aEntry in aAdapterQueue
	nAccounted = nAccounted + aEntry[ADAPTER_COST]
next
assertThat(nAdapterQueueBytes = nAccounted, "the adapter byte accounting drifted")
assertThat(nAdapterQueueBytes <= ADAPTER_MAX_BYTES, "the adapter exceeded its global byte budget")

# The terminal response cannot be unsent once the writer owns earlier bytes, so
# close fails on its deadline instead of waiting forever.
lAdapterClosing = true
nAdapterCloseDeadline = cvxNowMs() - 1
lAdapterCloseFailed = false
lAdapterDone = false
adapterTick()
assertThat(lAdapterCloseFailed, "a stalled close ignored its deadline")
assertThat(lAdapterDone, "a stalled close did not finish")

# Letting the same queue drain keeps NDJSON order and never duplicates a record.
aTestWrites = []
lAdapterWriteStalled = false
lAdapterWriting = false
aAdapterQueue[1][ADAPTER_STATE] = "queued"
adapterFlush()
assertThat(len(aAdapterQueue) = 0, "the adapter queue did not drain")
assertThat(nAdapterQueueBytes = 0, "a drained adapter queue retained byte accounting")
nCloseIndex = 0
for nIndex = 1 to len(aTestWrites)
	if trim(aTestWrites[nIndex]) = '{"id":"close","type":"ack"}'
		assertThat(nCloseIndex = 0, "an adapter record was written twice")
		nCloseIndex = nIndex
	ok
next
assertThat(nCloseIndex = len(aTestWrites),
	"the reserved control events did not drain last and in order")

cAdapterWriteHook = ""
lAdapterStreamReady = false
lAdapterClosing = false
? "Ring client unit tests passed"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func assertThat lCondition, cMessage
	if not lCondition
		raise("assertion failed: " + cMessage)
	ok

func transition cStart, cEnd, cModifications
	return '{"type":"Transition","startVersion":' + cStart + ',"endVersion":' + cEnd +
		',"modifications":[' + cModifications + "]}"

func assertObjectRejected cRaw, cMessage
	lFailed = false
	try
		cvxJsonField(cRaw, "a", true)
	catch
		lFailed = true
	done
	assertThat(lFailed, cMessage)

func assertStringRejected cRaw, cMessage
	lFailed = false
	try
		cvxJsonStringField(cRaw, "field")
	catch
		lFailed = true
	done
	assertThat(lFailed, cMessage)

func assertWholeRejected cToken, cMessage
	lFailed = false
	try
		cvxWholeNumber(cToken, "count")
	catch
		lFailed = true
	done
	assertThat(lFailed, cMessage + ": " + cToken)

func assertUint32Rejected cToken, cMessage
	lFailed = false
	try
		cvxJsonUint32(cToken, "x")
	catch
		lFailed = true
	done
	assertThat(lFailed, cMessage + ": " + cToken)

# A malformed transition must change nothing: not the committed version, not the
# observed timestamp, and not the queue of pending deliveries.
func assertRollback oClient, cRaw, cDescription
	cBeforeRemote = oClient.remoteVersion()
	cBeforeTimestamp = oClient.maxObservedTimestamp()
	nBeforeEvents = oClient.pendingEvents()
	lFailed = false
	try
		oClient.handleMessage(cRaw)
	catch
		lFailed = true
	done
	assertThat(lFailed, cDescription + " was accepted")
	assertThat(oClient.remoteVersion() = cBeforeRemote, cDescription + " committed its version")
	assertThat(oClient.maxObservedTimestamp() = cBeforeTimestamp,
		cDescription + " committed its timestamp")
	assertThat(oClient.pendingEvents() = nBeforeEvents, cDescription + " published a delivery")

func testCollectWrite cRecord
	# adapterEmit always terminates a record with the NDJSON newline, and
	# Ring's trim() strips only spaces, never that byte. Drop it here, the
	# same way adapterReadable drops it on the read side, so every assertion
	# below can compare against a bare JSON literal.
	if right(cRecord, 1) = nl
		cRecord = left(cRecord, len(cRecord) - 1)
	ok
	add(aTestWrites, cRecord)

func testInvalidateThenAck
	adapterInvalidate("same")
	adapterEmit('{"id":"replace","type":"ack"}', false, "", 0)
