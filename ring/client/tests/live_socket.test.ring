# Real transport tests for the Ring Convex client and its conformance adapter.
#
# A separate fixture process speaks genuine HTTP/1.1 and RFC 6455 on loopback,
# so the client's blocking libcurl handshake has a real peer. Every assertion
# below inspects the exact NDJSON envelope the adapter would put on the wire.
load "convexadapter.ring"

FIXTURE_HTTP = "http://127.0.0.1:19081"
FIXTURE_WS_ORIGIN = "http://127.0.0.1:19082"

aTestWrites = []
nTestChecks = 0

# Reconnect and partial-message deadlines are production values. The socket
# tests shorten the partial-message deadline so the same code path can be
# proven in a bounded test instead of being skipped.
CONVEX_PARTIAL_MESSAGE_MS = 400

cRingExecutable = cvxEnv("RING_EXECUTABLE")
if cRingExecutable = ""
	cRingExecutable = "/opt/ring/bin/ring"
ok
cFixtureScript = cvxEnv("FIXTURE_SCRIPT")
if cFixtureScript = ""
	cFixtureScript = "client/tests/live_fixture.ring"
ok
system(cRingExecutable + " " + cFixtureScript + " > /tmp/ring-fixture.log 2>&1 &")
testWaitForFixture()

cAdapterWriteHook = "testCollectWrite"
lAdapterStreamReady = true

# ---------------------------------------------------------------------------
# Real HTTP through the adapter's exact envelope classifier
# ---------------------------------------------------------------------------

oAdapterClient = new ConvexClient(FIXTURE_HTTP)
lAdapterClientReady = true

testControl("enqueue", '{"status":"success","value":{"ok":true},"logLines":[]}')
assertEnvelope('{"id":"http-success","op":"query","path":"demo:state","args":{}}',
	'{"id":"http-success","type":"result","value":{"ok":true}}',
	"the HTTP success envelope changed")

testControl("enqueue", '{"status":"success","value":{"unicode":"Hello, 世界 👋",' +
	'"nested":{"booleans":[true,false],"number":42.5,"nil":null}},' +
	'"logLines":["[LOG] demo:echo received a JSON-safe value"]}')
assertEnvelope('{"id":"http-nested","op":"query","path":"demo:echo",' +
	'"args":{"value":{"unicode":"Hello, 世界 👋","nested":{"booleans":[true,false],' +
	'"number":42.5,"nil":null}}}}',
	'{"id":"http-nested","type":"result","value":{"unicode":"Hello, 世界 👋",' +
	'"nested":{"booleans":[true,false],"number":42.5,"nil":null}},' +
	'"logs":["[LOG] demo:echo received a JSON-safe value"]}',
	"a nested HTTP value or its log lines were not preserved")

# The request the fixture actually received must still carry the exact UTF-8
# arguments, which proves the client sends bytes and not a re-encoded copy.
cState = testControl("state", "")
cSent = cvxJsonUnquote(cvxJsonField(cState, "lastRequestBody", true))
assertThat(cvxJsonUnquote(cvxJsonField(cvxJsonField(cvxJsonField(cSent, "args", true),
	"value", true), "unicode", true)) = "Hello, 世界 👋",
	"the UTF-8 HTTP request body was not preserved")

testControl("enqueue", '{"status":"error","errorMessage":"fixture HTTP failure",' +
	'"errorData":{"code":"HTTP_FIXTURE"},"logLines":["fixture HTTP log"]}')
assertEnvelope('{"id":"http-function","op":"query","path":"demo:state","args":{}}',
	'{"type":"error","id":"http-function","error":{"name":"FunctionError",' +
	'"message":"fixture HTTP failure","data":{"code":"HTTP_FIXTURE"}},' +
	'"logs":["fixture HTTP log"]}',
	"the HTTP FunctionError envelope changed")

testControl("enqueue", "{malformed")
assertErrorName('{"id":"http-protocol","op":"query","path":"demo:state","args":{}}',
	"ProtocolError", "a malformed HTTP response was not a ProtocolError")

# A refused connection and a TLS handshake against a plaintext listener are both
# transport failures. The second case proves the client will not silently fall
# back when certificate verification cannot succeed.
oAdapterClient.close()
oAdapterClient = new ConvexClient("http://127.0.0.1:19099")
assertErrorName('{"id":"http-refused","op":"query","path":"demo:state","args":{}}',
	"TransportError", "a refused HTTP connection was not a TransportError")
oAdapterClient.close()
oAdapterClient = new ConvexClient("https://127.0.0.1:19081")
assertErrorName('{"id":"http-tls","op":"query","path":"demo:state","args":{}}',
	"TransportError", "TLS against a plaintext listener was not a TransportError")
oAdapterClient.close()

# Malformed commands must never invent an identifier.
oAdapterClient = new ConvexClient(FIXTURE_HTTP)
assertNoId("{", "an unparsable command invented an identifier")
assertNoId("[1,2]", "a command that is not an object invented an identifier")
assertNoId('{"protocolVersion":1,"op":"hello"}', "a command without an id invented one")
assertNoId('{"protocolVersion":1,"id":"","op":"hello"}', "an empty id was accepted")
assertNoId('{"protocolVersion":1,"id":7,"op":"hello"}', "a numeric id was accepted")
assertEnvelope('{"protocolVersion":1,"id":"hello","op":"hello"}',
	'{"protocolVersion":1,"id":"hello","type":"ready","language":"ring",' +
	'"implementation":"' + ADAPTER_IMPLEMENTATION + '","runtime":"' + ADAPTER_RUNTIME + '"}',
	"the ready envelope changed")
assertEnvelope('{"id":"bad-op","op":"nope"}',
	'{"type":"error","id":"bad-op","error":{"name":"ProtocolError",' +
	'"message":"unknown adapter operation nope","data":null}}',
	"the identified error envelope changed")
oAdapterClient.close()

# ---------------------------------------------------------------------------
# Real WebSocket transport
# ---------------------------------------------------------------------------

oAdapterClient = new ConvexClient(FIXTURE_WS_ORIGIN)
lAdapterClientReady = true
aAdapterSubs = []
aAdapterGenerations = []

assertEnvelope('{"id":"subscribe","op":"subscribe","subscriptionId":"same",' +
	'"path":"demo:state","args":{}}', '{"id":"subscribe","type":"ack"}',
	"the subscribe acknowledgement changed")
assertThat(nextSubscriptionEnvelope() =
	'{"type":"subscription","subscriptionId":"same","value":{"count":0}}',
	"the initial subscription envelope changed")

testControl("update", "1")
assertThat(nextSubscriptionEnvelope() =
	'{"type":"subscription","subscriptionId":"same","value":{"count":1}}',
	"an external update was not delivered")

# A fragmented message that is split inside a multi-byte code point must be
# reassembled exactly, and the interleaved Ping must still be answered.
testControl("fragment", "🟨🟩🟦")
cFragmented = nextSubscriptionEnvelope()
assertThat(cvxJsonUnquote(cvxJsonField(cvxJsonField(cFragmented, "value", true), "text", true)) =
	"fragmented 🟨🟩🟦", "a fragmented UTF-8 value was corrupted")
assertThat(number(cvxJsonField(testControl("state", ""), "pongs", true)) >= 1,
	"the interleaved Ping did not receive a Pong")

# QueryFailed is a structured FunctionError, and the same subscription recovers.
testControl("queryfailed", "")
assertThat(nextSubscriptionEnvelope() =
	'{"type":"subscription","subscriptionId":"same","error":{"name":"FunctionError",' +
	'"message":"fixture function failure","data":{"code":"FIXTURE"}},' +
	'"logs":["fixture failure log"]}',
	"the QueryFailed subscription envelope changed")
testControl("update", "2")
assertThat(nextSubscriptionEnvelope() =
	'{"type":"subscription","subscriptionId":"same","value":{"count":2}}',
	"the subscription did not recover after QueryFailed")

# An absent errorData stays absent instead of becoming a serialized null.
testControl("queryfailed-nodata", "")
assertThat(nextSubscriptionEnvelope() =
	'{"type":"subscription","subscriptionId":"same","error":{"name":"FunctionError",' +
	'"message":"fixture function failure"}}',
	"an absent QueryFailed errorData changed the envelope")
testControl("update", "3")
assertThat(nextSubscriptionEnvelope() =
	'{"type":"subscription","subscriptionId":"same","value":{"count":3}}',
	"the subscription did not recover after an omitted errorData")

# Each malformed wire field crosses the adapter as a structured ProtocolError,
# then the connection is rebuilt, the Add is replayed and a later value arrives.
assertMalformedRecovery("malformed-version", 4)
assertMalformedRecovery("malformed-queryid", 5)
assertMalformedRecovery("malformed-message", 6)

# A message larger than the client's Live budget is refused before it can be
# buffered, and the subscription survives the reconnect that follows.
assertMalformedRecovery("oversize", 7)

# Closing the real peer is a TransportError that also recovers.
nBeforeConnections = number(cvxJsonField(testControl("state", ""), "connections", true))
testControl("drop", "")
assertThat(cvxJsonField(cvxJsonField(nextSubscriptionEnvelope(), "error", true), "name", true) =
	CVX_QUOTE + "TransportError" + CVX_QUOTE, "a peer close was not a TransportError")
# The fixture only pushes to whichever peer is connected right now, so the
# update below would race the reconnect and be lost if it were sent before
# the new connection (and its replayed Add) is actually in place.
testPumpUntilConnected()
testControl("update", "8")
assertThat(nextSubscriptionEnvelope() =
	'{"type":"subscription","subscriptionId":"same","value":{"count":8}}',
	"a transport failure stranded the subscription")
assertThat(number(cvxJsonField(testControl("state", ""), "connections", true)) > nBeforeConnections,
	"the transport failure did not open a new connection")

# A peer that sends only a frame prefix is abandoned on a deterministic
# deadline, and the retained subscription recovers on the next connection.
nStalled = cvxNowMs()
testControl("stall", "")
assertThat(cvxJsonField(cvxJsonField(nextSubscriptionEnvelope(), "error", true), "name", true) =
	CVX_QUOTE + "TransportError" + CVX_QUOTE,
	"a stalled partial frame was not a TransportError")
nElapsed = cvxNowMs() - nStalled
assertThat(nElapsed >= CONVEX_PARTIAL_MESSAGE_MS and nElapsed < 5000,
	"the partial-message deadline fired at the wrong time")
# As above: wait for the replayed Add before pushing the next update, or the
# fixture has nowhere to send it.
testPumpUntilConnected()
testControl("update", "9")
assertThat(nextSubscriptionEnvelope() =
	'{"type":"subscription","subscriptionId":"same","value":{"count":9}}',
	"a stalled partial frame stranded the subscription")

# Five real forced reconnects. Each acknowledgement is published only after the
# old connection is retired, the unchanged rehydration is suppressed, and the
# replacement connection replays the active Add.
for nAttempt = 1 to 5
	cBefore = oAdapterClient.maxObservedTimestamp()
	nBefore = number(cvxJsonField(testControl("state", ""), "connections", true))
	aTestWrites = []
	adapterHandle('{"id":"debug-' + cvxIntText(nAttempt) + '","op":"debugDisconnect"}')
	assertThat(oAdapterClient.isConnected() = false,
		"debugDisconnect acknowledged before the socket was retired")
	assertThat(oAdapterClient.reconnectArmed(),
		"debugDisconnect acknowledged before the reconnect was scheduled")
	assertThat(trim(aTestWrites[1]) = '{"id":"debug-' + cvxIntText(nAttempt) + '","type":"ack"}',
		"the debugDisconnect acknowledgement changed")
	testPumpUntilConnected()
	assertThat(number(cvxJsonField(testControl("state", ""), "connections", true)) > nBefore,
		"debugDisconnect did not open a new connection")
	aTestWrites = []
	testPumpFor(250)
	assertThat(len(aTestWrites) = 0, "an unchanged rehydration crossed the acknowledgement")
	testControl("update", cvxIntText(10 + nAttempt))
	assertThat(nextSubscriptionEnvelope() = '{"type":"subscription","subscriptionId":"same",' +
		'"value":{"count":' + cvxIntText(10 + nAttempt) + "}}",
		"the value after reconnect " + cvxIntText(nAttempt) + " was wrong")
	cState = testControl("state", "")
	aConnects = cvxJsonElements(cvxJsonField(cState, "connects", true))
	cLatest = aConnects[len(aConnects)]
	assertThat(cvxJsonUnquote(cvxJsonField(cLatest, "lastCloseReason", true)) = "DebugDisconnect",
		"the reconnect lost its lastCloseReason")
	assertThat(number(cvxJsonField(cLatest, "connectionCount", true)) > 0,
		"the reconnect lost its connectionCount")
	if cBefore != ""
		assertThat(cvxJsonUnquote(cvxJsonField(cLatest, "maxObservedTimestamp", true)) = cBefore,
			"the reconnect lost its maxObservedTimestamp")
	ok
	assertThat(oAdapterClient.nBackoffMs = CONVEX_BACKOFF_START_MS,
		"a healthy reconnect did not reset the transport backoff")
	assertThat(number(cvxJsonField(cState, "adds", true)) >= nAttempt + 1,
		"the reconnect did not replay the active Add")
next

# Unsubscribe reaches the real peer and retires the relay before its
# acknowledgement, after which no further delivery may appear.
aTestWrites = []
adapterHandle('{"id":"unsubscribe","op":"unsubscribe","subscriptionId":"same"}')
assertThat(trim(aTestWrites[len(aTestWrites)]) = '{"id":"unsubscribe","type":"ack"}',
	"the unsubscribe acknowledgement was not the last record")
testControl("update", "99")
aTestWrites = []
testPumpFor(400)
assertThat(len(aTestWrites) = 0, "a delivery crossed the unsubscribe acknowledgement")
assertThat(number(cvxJsonField(testControl("state", ""), "removes", true)) >= 1,
	"unsubscribe did not send a Remove to the real peer")

# Close is bounded and terminal.
aTestWrites = []
nCloseStarted = cvxNowMs()
adapterHandle('{"id":"close","op":"close"}')
assertThat(trim(aTestWrites[len(aTestWrites)]) = '{"id":"close","type":"closed"}',
	"the close envelope changed")
assertThat(cvxNowMs() - nCloseStarted < 2000, "close was not bounded")

testControl("quit", "")
? "Ring real transport and adapter envelope tests passed (" + cvxIntText(nTestChecks) + " checks)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func assertThat lCondition, cMessage
	nTestChecks = nTestChecks + 1
	if not lCondition
		testControl("quit", "")
		raise("assertion failed: " + cMessage)
	ok

func testCollectWrite cRecord
	# adapterEmit always terminates a record with the NDJSON newline, and
	# Ring's trim() strips only spaces, never that byte. Drop it here, the
	# same way adapterReadable drops it on the read side, so every assertion
	# below can compare against a bare JSON literal.
	if right(cRecord, 1) = nl
		cRecord = left(cRecord, len(cRecord) - 1)
	ok
	add(aTestWrites, cRecord)

# One control request drives the fixture. It uses its own libcurl handle so the
# client under test is never disturbed.
func testControl cCommand, cBody
	oCurl = curl_easy_init()
	cvxHttpBody = ""
	cvxHttpOverflow = 0
	curl_easy_setopt(oCurl, CURLOPT_URL, FIXTURE_HTTP + "/control/" + cCommand)
	curl_easy_setopt(oCurl, CURLOPT_POST, 1)
	curl_easy_setopt(oCurl, CURLOPT_COPYPOSTFIELDS, cBody)
	curl_easy_setopt(oCurl, CURLOPT_WRITEFUNCTION, :cvxHttpWrite)
	curl_easy_setopt(oCurl, CURLOPT_TIMEOUT_MS, 5000)
	curl_easy_setopt(oCurl, CURLOPT_NOSIGNAL, 1)
	nResult = curl_easy_perform(oCurl)
	cOut = cvxHttpBody
	cvxHttpBody = ""
	curl_easy_cleanup(oCurl)
	if nResult != CONVEX_CURLE_OK
		raise("the fixture control request " + cCommand + " failed with libcurl code " +
			cvxIntText(nResult))
	ok
	return cOut

func testWaitForFixture
	nDeadline = cvxNowMs() + 15000
	while cvxNowMs() < nDeadline
		oCurl = curl_easy_init()
		cvxHttpBody = ""
		curl_easy_setopt(oCurl, CURLOPT_URL, FIXTURE_HTTP + "/control/state")
		curl_easy_setopt(oCurl, CURLOPT_POST, 1)
		curl_easy_setopt(oCurl, CURLOPT_COPYPOSTFIELDS, "")
		curl_easy_setopt(oCurl, CURLOPT_WRITEFUNCTION, :cvxSinkWrite)
		curl_easy_setopt(oCurl, CURLOPT_TIMEOUT_MS, 1000)
		curl_easy_setopt(oCurl, CURLOPT_NOSIGNAL, 1)
		nResult = curl_easy_perform(oCurl)
		curl_easy_cleanup(oCurl)
		if nResult = CONVEX_CURLE_OK
			return
		ok
		cvxWaitMs(100)
	end
	raise("the loopback fixture never became ready")

func assertEnvelope cCommand, cExpected, cMessage
	aTestWrites = []
	adapterHandle(cCommand)
	assertThat(len(aTestWrites) >= 1, cMessage + " (no envelope was written)")
	assertThat(trim(aTestWrites[1]) = cExpected, cMessage + ": " + trim(aTestWrites[1]))

func assertErrorName cCommand, cName, cMessage
	aTestWrites = []
	adapterHandle(cCommand)
	assertThat(len(aTestWrites) >= 1, cMessage + " (no envelope was written)")
	cEnvelope = trim(aTestWrites[1])
	assertThat(cvxJsonField(cvxJsonField(cEnvelope, "error", true), "name", true) =
		CVX_QUOTE + cName + CVX_QUOTE, cMessage + ": " + cEnvelope)

func assertNoId cCommand, cMessage
	aTestWrites = []
	adapterHandle(cCommand)
	cEnvelope = trim(aTestWrites[1])
	assertThat(cvxJsonField(cEnvelope, "id", false) = "", cMessage + ": " + cEnvelope)
	assertThat(cvxJsonField(cvxJsonField(cEnvelope, "error", true), "name", true) =
		CVX_QUOTE + "ProtocolError" + CVX_QUOTE, cMessage + ": " + cEnvelope)

# Pump the client until one subscription envelope is written, or fail on the
# deadline. Everything is driven by the adapter's real tick.
func nextSubscriptionEnvelope
	aTestWrites = []
	nDeadline = cvxNowMs() + 20000
	while cvxNowMs() < nDeadline
		adapterTick()
		if len(aTestWrites) > 0
			return trim(aTestWrites[1])
		ok
		cvxWaitMs(5)
	end
	raise("no subscription envelope arrived before the deadline")

func testPumpFor nMilliseconds
	nDeadline = cvxNowMs() + nMilliseconds
	while cvxNowMs() < nDeadline
		adapterTick()
		cvxWaitMs(5)
	end

func testPumpUntilConnected
	nDeadline = cvxNowMs() + 20000
	while cvxNowMs() < nDeadline
		adapterTick()
		if oAdapterClient.isConnected()
			return
		ok
		cvxWaitMs(5)
	end
	raise("the client never reconnected")

# A malformed wire field must cross the adapter as a ProtocolError, then the
# same subscription must publish a later valid value on a new connection.
func assertMalformedRecovery cCommand, nRecoveryValue
	testControl(cCommand, "")
	cEnvelope = nextSubscriptionEnvelope()
	assertThat(cvxJsonField(cvxJsonField(cEnvelope, "error", true), "name", true) =
		CVX_QUOTE + "ProtocolError" + CVX_QUOTE,
		cCommand + " was not reported as a ProtocolError: " + cEnvelope)
	testPumpUntilConnected()
	testControl("update", cvxIntText(nRecoveryValue))
	assertThat(nextSubscriptionEnvelope() = '{"type":"subscription","subscriptionId":"same",' +
		'"value":{"count":' + cvxIntText(nRecoveryValue) + "}}",
		cCommand + " stranded the subscription")
