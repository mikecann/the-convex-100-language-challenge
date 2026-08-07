# Deterministic loopback Convex peer for the Ring client tests.
#
# This runs as its own process so the client's blocking libcurl handshake has a
# real server to talk to. It speaks the genuine byte protocols: HTTP/1.1 on one
# port and RFC 6455 on another, including the SHA-1 upgrade handshake, masked
# client frames and unmasked server frames it builds by hand. Tests steer it
# through HTTP control requests, which is also how they inject fragmentation,
# malformed transitions, oversized messages, stalled partial frames and abrupt
# transport failures without borrowing another Convex client.
load "convex.ring"
load "openssllib.ring"

FIXTURE_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

nFixHttpPort = 19081
nFixWsPort = 19082
if cvxEnv("FIXTURE_HTTP_PORT") != ""
	nFixHttpPort = number(cvxEnv("FIXTURE_HTTP_PORT"))
ok
if cvxEnv("FIXTURE_WS_PORT") != ""
	nFixWsPort = number(cvxEnv("FIXTURE_WS_PORT"))
ok

oFixLoop = NULL
oFixHttpServer = NULL
oFixWsServer = NULL
oFixHttpConn = NULL
oFixWsConn = NULL
lFixHttpOpen = false
lFixWsOpen = false
# libuv keeps a pointer into the Ring string it is given until the write
# completes, so each outstanding write needs its own live variable. A small
# rotating pool covers the deepest burst this fixture produces, which is the
# three frames of a fragmented message.
nFixSlot = 0
aFixWriteReqs = []
cFixOut1 = ""
cFixOut2 = ""
cFixOut3 = ""
cFixOut4 = ""
cFixOut5 = ""
cFixOut6 = ""
cFixOut7 = ""
cFixOut8 = ""

cFixHttpBuffer = ""
cFixWsBuffer = ""
cFixWsStage = "closed"
aFixResponses = []
cFixLastRequestBody = ""

nFixConnections = 0
nFixPongs = 0
aFixConnects = []
aFixModifications = []
aFixActive = []
nFixQuerySet = 0
cFixRemote = ""
nFixTimestamp = 0
cFixPayload = '{"count":0}'
lFixDone = false

fixtureMain()

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

func fixtureMain
	oFixLoop = uv_default_loop()
	for nIndex = 1 to 8
		add(aFixWriteReqs, new_uv_write_t())
	next
	cFixRemote = fixtureVersion(0, 0)
	oAddress = new_sockaddr_in()
	oFixHttpServer = new_uv_tcp_t()
	uv_tcp_init(oFixLoop, oFixHttpServer)
	uv_ip4_addr("127.0.0.1", nFixHttpPort, oAddress)
	uv_tcp_bind(oFixHttpServer, oAddress, 0)
	if uv_listen(oFixHttpServer, 16, "fixtureAcceptHttp()")
		? "fixture could not listen for HTTP"
		return
	ok
	oWsAddress = new_sockaddr_in()
	oFixWsServer = new_uv_tcp_t()
	uv_tcp_init(oFixLoop, oFixWsServer)
	uv_ip4_addr("127.0.0.1", nFixWsPort, oWsAddress)
	uv_tcp_bind(oFixWsServer, oWsAddress, 0)
	if uv_listen(oFixWsServer, 16, "fixtureAcceptWs()")
		? "fixture could not listen for WebSocket"
		return
	ok
	? "fixture ready"
	while not lFixDone
		uv_run(oFixLoop, UV_RUN_ONCE)
	end

# ---------------------------------------------------------------------------
# Raw output
#
# Each write takes the next slot in the pool, so every buffer libuv still owns
# is backed by a variable this process is still holding.
# ---------------------------------------------------------------------------

func fixtureWrite oStream, cBytes
	nFixSlot = nFixSlot % 8 + 1
	oBuffer = new_uv_buf_t()
	set_uv_buf_t_len(oBuffer, len(cBytes))
	switch nFixSlot
	on 1
		cFixOut1 = cBytes
		set_uv_buf_t_base(oBuffer, varptr(:cFixOut1, "char"))
	on 2
		cFixOut2 = cBytes
		set_uv_buf_t_base(oBuffer, varptr(:cFixOut2, "char"))
	on 3
		cFixOut3 = cBytes
		set_uv_buf_t_base(oBuffer, varptr(:cFixOut3, "char"))
	on 4
		cFixOut4 = cBytes
		set_uv_buf_t_base(oBuffer, varptr(:cFixOut4, "char"))
	on 5
		cFixOut5 = cBytes
		set_uv_buf_t_base(oBuffer, varptr(:cFixOut5, "char"))
	on 6
		cFixOut6 = cBytes
		set_uv_buf_t_base(oBuffer, varptr(:cFixOut6, "char"))
	on 7
		cFixOut7 = cBytes
		set_uv_buf_t_base(oBuffer, varptr(:cFixOut7, "char"))
	other
		cFixOut8 = cBytes
		set_uv_buf_t_base(oBuffer, varptr(:cFixOut8, "char"))
	off
	# Each slot keeps its own request object alive. This code runs inside libuv
	# callbacks, so the loop must never be run reentrantly to await completion.
	uv_write(aFixWriteReqs[nFixSlot], oStream, oBuffer, 1, "fixtureWritten()")

func fixtureWritten
	return

# ---------------------------------------------------------------------------
# HTTP peer and control surface
# ---------------------------------------------------------------------------

func fixtureAcceptHttp
	aPara = uv_Eventpara(oFixHttpServer, :connect)
	if aPara[2] < 0
		return
	ok
	oFixHttpConn = new_uv_tcp_t()
	uv_tcp_init(oFixLoop, oFixHttpConn)
	if uv_accept(oFixHttpServer, oFixHttpConn) != 0
		return
	ok
	lFixHttpOpen = true
	cFixHttpBuffer = ""
	uv_read_start(oFixHttpConn, uv_myalloccallback(), "fixtureHttpReadable()")

func fixtureHttpReadable
	aPara = uv_Eventpara(oFixHttpConn, :read)
	nRead = aPara[2]
	if nRead < 0
		fixtureCloseHttp()
		return
	ok
	if nRead = 0
		return
	ok
	cFixHttpBuffer = cFixHttpBuffer + uv_buf2str(uv_buf_init(get_uv_buf_t_base(aPara[3]), nRead))
	nHeaderEnd = substr(cFixHttpBuffer, CVX_RETURN + CVX_NEWLINE + CVX_RETURN + CVX_NEWLINE)
	if nHeaderEnd = 0
		return
	ok
	cHead = left(cFixHttpBuffer, nHeaderEnd - 1)
	nLength = fixtureContentLength(cHead)
	cBody = substr(cFixHttpBuffer, nHeaderEnd + 4)
	if len(cBody) < nLength
		return
	ok
	cFixHttpBuffer = ""
	fixtureHttpDispatch(fixtureRequestPath(cHead), left(cBody, nLength))

func fixtureContentLength cHead
	nAt = substr(lower(cHead), "content-length:")
	if nAt = 0
		return 0
	ok
	cTail = substr(cHead, nAt + len("content-length:"))
	cDigits = ""
	for nIndex = 1 to len(cTail)
		nByte = cvxByte(cTail, nIndex)
		if nByte >= 48 and nByte <= 57
			cDigits = cDigits + cTail[nIndex]
		but len(cDigits) > 0
			exit
		ok
	next
	if cDigits = ""
		return 0
	ok
	return number(cDigits)

func fixtureRequestPath cHead
	nFirst = substr(cHead, " ")
	if nFirst = 0
		return "/"
	ok
	cTail = substr(cHead, nFirst + 1)
	nSecond = substr(cTail, " ")
	if nSecond = 0
		return cTail
	ok
	return left(cTail, nSecond - 1)

func fixtureHttpDispatch cPath, cBody
	if left(cPath, 9) = "/control/"
		fixtureControl(substr(cPath, 10), cBody)
		return
	ok
	cFixLastRequestBody = cBody
	if len(aFixResponses) = 0
		fixtureHttpRespond('{"status":"success","value":null,"logLines":[]}')
		return
	ok
	cResponse = aFixResponses[1]
	del(aFixResponses, 1)
	fixtureHttpRespond(cResponse)

func fixtureHttpRespond cBody
	cResponse = "HTTP/1.1 200 OK" + CVX_RETURN + CVX_NEWLINE +
		"Content-Type: application/json; charset=utf-8" + CVX_RETURN + CVX_NEWLINE +
		"Content-Length: " + cvxIntText(len(cBody)) + CVX_RETURN + CVX_NEWLINE +
		"Connection: close" + CVX_RETURN + CVX_NEWLINE + CVX_RETURN + CVX_NEWLINE + cBody
	# The response announces Connection: close, so the caller hangs up and the
	# read callback closes this handle. Closing here instead could discard bytes
	# libuv has not yet handed to the kernel.
	fixtureWrite(oFixHttpConn, cResponse)

func fixtureCloseHttp
	if not lFixHttpOpen
		return
	ok
	lFixHttpOpen = false
	uv_read_stop(oFixHttpConn)
	uv_close(oFixHttpConn, "fixtureHandleClosed()")

func fixtureHandleClosed
	return

# The control surface. Each command is one HTTP request, so a test can steer
# this peer without a second protocol and without any shared memory.
func fixtureControl cCommand, cBody
	if cCommand = "enqueue"
		add(aFixResponses, cBody)
		fixtureHttpRespond('{"ok":true}')
		return
	ok
	if cCommand = "state"
		fixtureHttpRespond(cvxJsonObject([
			["connections", cvxIntText(nFixConnections)],
			["pongs", cvxIntText(nFixPongs)],
			["adds", cvxIntText(fixtureCountKind("Add"))],
			["removes", cvxIntText(fixtureCountKind("Remove"))],
			["connects", cvxJsonArray(aFixConnects)],
			["lastRequestBody", cvxJsonQuote(cFixLastRequestBody)]]))
		return
	ok
	if cCommand = "quit"
		fixtureHttpRespond('{"ok":true}')
		lFixDone = true
		return
	ok
	if not lFixWsOpen
		fixtureHttpRespond('{"ok":false}')
		return
	ok
	if cCommand = "update"
		cFixPayload = '{"count":' + trim(cBody) + "}"
		fixtureTransition(fixtureUpdatedModifications(cFixPayload))
	but cCommand = "blob"
		cFixPayload = '{"blob":"' + copy("x", number(trim(cBody))) + '"}'
		fixtureTransition(fixtureUpdatedModifications(cFixPayload))
	but cCommand = "queryfailed"
		fixtureTransition(fixtureFailedModifications(true))
	but cCommand = "queryfailed-nodata"
		fixtureTransition(fixtureFailedModifications(false))
	but cCommand = "malformed-version"
		fixtureRawTransition('{"querySet":"0","identity":0,"ts":"' +
			fixtureTimestamp() + '"}', fixtureUpdatedModifications('{"count":800}'))
	but cCommand = "malformed-queryid"
		fixtureRawTransition(fixtureVersion(nFixQuerySet, fixtureNextStamp()),
			['{"type":"QueryUpdated","queryId":"0","value":{"count":900}}'])
	but cCommand = "malformed-message"
		fixtureRawTransition(fixtureVersion(nFixQuerySet, fixtureNextStamp()),
			['{"type":"QueryFailed","queryId":0,"errorMessage":7}'])
	but cCommand = "fragment"
		fixtureFragmented(trim(cBody))
	but cCommand = "oversize"
		fixtureSendFrame(1, '{"type":"Transition","startVersion":' + cFixRemote +
			',"endVersion":' + cFixRemote + ',"padding":"' +
			copy("y", CONVEX_MAX_MESSAGE_BYTES + 4096) + '"}', true)
	but cCommand = "stall"
		fixtureStallPartialFrame()
	but cCommand = "ping"
		fixtureSendFrame(9, "fixture-barrier", true)
	but cCommand = "drop"
		fixtureCloseWs()
	ok
	fixtureHttpRespond('{"ok":true}')

func fixtureCountKind cKind
	nCount = 0
	for aEntry in aFixModifications
		if aEntry[2] = cKind
			nCount = nCount + 1
		ok
	next
	return nCount

# ---------------------------------------------------------------------------
# WebSocket peer
# ---------------------------------------------------------------------------

func fixtureAcceptWs
	aPara = uv_Eventpara(oFixWsServer, :connect)
	if aPara[2] < 0
		return
	ok
	oFixWsConn = new_uv_tcp_t()
	uv_tcp_init(oFixLoop, oFixWsConn)
	if uv_accept(oFixWsServer, oFixWsConn) != 0
		return
	ok
	nFixConnections = nFixConnections + 1
	lFixWsOpen = true
	cFixWsBuffer = ""
	cFixWsStage = "handshake"
	aFixActive = []
	nFixQuerySet = 0
	cFixRemote = fixtureVersion(0, 0)
	uv_read_start(oFixWsConn, uv_myalloccallback(), "fixtureWsReadable()")

func fixtureWsReadable
	aPara = uv_Eventpara(oFixWsConn, :read)
	nRead = aPara[2]
	if nRead < 0
		fixtureCloseWs()
		return
	ok
	if nRead = 0
		return
	ok
	cFixWsBuffer = cFixWsBuffer + uv_buf2str(uv_buf_init(get_uv_buf_t_base(aPara[3]), nRead))
	if cFixWsStage = "handshake"
		fixtureHandshake()
	ok
	if cFixWsStage = "open"
		fixtureParseFrames()
	ok

func fixtureHandshake
	nEnd = substr(cFixWsBuffer, CVX_RETURN + CVX_NEWLINE + CVX_RETURN + CVX_NEWLINE)
	if nEnd = 0
		return
	ok
	cHead = left(cFixWsBuffer, nEnd - 1)
	cFixWsBuffer = substr(cFixWsBuffer, nEnd + 4)
	cKey = fixtureHeaderValue(cHead, "sec-websocket-key:")
	if cKey = ""
		fixtureCloseWs()
		return
	ok
	# The accept value is the base64 of the SHA-1 of the client key and the
	# protocol GUID. libcurl checks it, so a wrong value fails the upgrade.
	cAccept = cvxBase64Encode(hex2str(sha1(cKey + FIXTURE_GUID)))
	fixtureWrite(oFixWsConn, "HTTP/1.1 101 Switching Protocols" + CVX_RETURN + CVX_NEWLINE +
		"Upgrade: websocket" + CVX_RETURN + CVX_NEWLINE +
		"Connection: Upgrade" + CVX_RETURN + CVX_NEWLINE +
		"Sec-WebSocket-Accept: " + cAccept + CVX_RETURN + CVX_NEWLINE +
		CVX_RETURN + CVX_NEWLINE)
	cFixWsStage = "open"

func fixtureHeaderValue cHead, cName
	nAt = substr(lower(cHead), cName)
	if nAt = 0
		return ""
	ok
	cTail = substr(cHead, nAt + len(cName))
	nEnd = substr(cTail, CVX_RETURN)
	if nEnd > 0
		cTail = left(cTail, nEnd - 1)
	ok
	return trim(cTail)

func fixtureXor nLeft, nRight
	nResult = 0
	nBit = 1
	for nIndex = 1 to 8
		if (nLeft % 2) != (nRight % 2)
			nResult = nResult + nBit
		ok
		nLeft = floor(nLeft / 2)
		nRight = floor(nRight / 2)
		nBit = nBit * 2
	next
	return nResult

# Client frames are always masked. Unmasking through one hex conversion keeps
# every byte unsigned, which ascii() cannot promise above 127.
func fixtureParseFrames
	while true
		if len(cFixWsBuffer) < 2
			return
		ok
		nFirst = cvxByte(cFixWsBuffer, 1)
		nSecond = cvxByte(cFixWsBuffer, 2)
		nOpcode = nFirst % 16
		nLength = nSecond % 128
		nOffset = 3
		if nLength = 126
			if len(cFixWsBuffer) < 4
				return
			ok
			nLength = cvxByte(cFixWsBuffer, 3) * 256 + cvxByte(cFixWsBuffer, 4)
			nOffset = 5
		but nLength = 127
			if len(cFixWsBuffer) < 10
				return
			ok
			nLength = 0
			for nIndex = 3 to 10
				nLength = nLength * 256 + cvxByte(cFixWsBuffer, nIndex)
			next
			nOffset = 11
		ok
		if floor(nSecond / 128) != 1
			# A client frame that is not masked violates RFC 6455.
			fixtureCloseWs()
			return
		ok
		if len(cFixWsBuffer) < nOffset + 4 + nLength - 1
			return
		ok
		aMask = []
		for nIndex = 0 to 3
			add(aMask, cvxByte(cFixWsBuffer, nOffset + nIndex))
		next
		cMasked = substr(cFixWsBuffer, nOffset + 4, nLength)
		cFixWsBuffer = substr(cFixWsBuffer, nOffset + 4 + nLength)
		cHex = str2hex(cMasked)
		cPayload = ""
		for nIndex = 1 to nLength
			cPayload = cPayload + char(fixtureXor(dec(substr(cHex, nIndex * 2 - 1, 2)),
				aMask[(nIndex - 1) % 4 + 1]))
		next
		if nOpcode = 1
			fixtureHandleJson(cPayload)
		but nOpcode = 8
			fixtureCloseWs()
			return
		but nOpcode = 10
			nFixPongs = nFixPongs + 1
		ok
	end

func fixtureHandleJson cRaw
	cType = cvxJsonStringField(cvxJsonField(cRaw, "type", true), "type")
	if cType = "Connect"
		add(aFixConnects, cRaw)
		return
	ok
	if cType != "ModifyQuerySet"
		return
	ok
	nFixQuerySet = cvxJsonUint32(cvxJsonField(cRaw, "newVersion", true), "newVersion")
	aResponse = []
	for cModification in cvxJsonElements(cvxJsonField(cRaw, "modifications", true))
		cKind = cvxJsonStringField(cvxJsonField(cModification, "type", true), "type")
		cQueryId = trim(cvxJsonField(cModification, "queryId", true))
		add(aFixModifications, [nFixConnections, cKind, cQueryId])
		if cKind = "Add"
			add(aFixActive, cQueryId)
			add(aResponse, '{"type":"QueryUpdated","queryId":' + cQueryId +
				',"value":' + cFixPayload + ',"logLines":[]}')
		but cKind = "Remove"
			aRetained = []
			for cActive in aFixActive
				if cActive != cQueryId
					add(aRetained, cActive)
				ok
			next
			aFixActive = aRetained
			add(aResponse, '{"type":"QueryRemoved","queryId":' + cQueryId + "}")
		ok
	next
	fixtureTransition(aResponse)

func fixtureUpdatedModifications cValue
	aResponse = []
	for cQueryId in aFixActive
		add(aResponse, '{"type":"QueryUpdated","queryId":' + cQueryId +
			',"value":' + cValue + ',"logLines":[]}')
	next
	return aResponse

func fixtureFailedModifications lWithData
	aResponse = []
	for cQueryId in aFixActive
		cEntry = '{"type":"QueryFailed","queryId":' + cQueryId +
			',"errorMessage":"fixture function failure"'
		if lWithData
			cEntry = cEntry + ',"errorData":{"code":"FIXTURE"},"logLines":["fixture failure log"]'
		ok
		add(aResponse, cEntry + "}")
	next
	return aResponse

func fixtureNextStamp
	nFixTimestamp = nFixTimestamp + 1
	return nFixTimestamp

func fixtureTimestamp
	cBytes = ""
	nValue = nFixTimestamp
	for nIndex = 1 to 8
		cBytes = cBytes + char(nValue % 256)
		nValue = floor(nValue / 256)
	next
	return cvxBase64Encode(cBytes)

func fixtureVersion nQuerySet, nStamp
	nSaved = nFixTimestamp
	nFixTimestamp = nStamp
	cVersion = '{"querySet":' + cvxIntText(nQuerySet) + ',"identity":0,"ts":"' +
		fixtureTimestamp() + '"}'
	nFixTimestamp = nSaved
	return cVersion

func fixtureTransition aModifications
	cEnd = fixtureVersion(nFixQuerySet, fixtureNextStamp())
	fixtureSendFrame(1, '{"type":"Transition","startVersion":' + cFixRemote +
		',"endVersion":' + cEnd + ',"modifications":[' +
		fixtureJoin(aModifications) + "]}", true)
	cFixRemote = cEnd

# A raw transition deliberately keeps the start version but sends an invalid
# end version or modification, which is how the malformed-field cases are made.
func fixtureRawTransition cEnd, aModifications
	fixtureSendFrame(1, '{"type":"Transition","startVersion":' + cFixRemote +
		',"endVersion":' + cEnd + ',"modifications":[' +
		fixtureJoin(aModifications) + "]}", true)

func fixtureJoin aItems
	cOut = ""
	for nIndex = 1 to len(aItems)
		if nIndex > 1
			cOut = cOut + ","
		ok
		cOut = cOut + aItems[nIndex]
	next
	return cOut

# Server frames are never masked. The length is written in the exact RFC 6455
# form for its size class so libcurl accepts the frame.
func fixtureFrameBytes nOpcode, cPayload, lFinal
	nLength = len(cPayload)
	nFirst = nOpcode
	if lFinal
		nFirst = nFirst + 128
	ok
	cHeader = char(nFirst)
	if nLength < 126
		cHeader = cHeader + char(nLength)
	but nLength <= 65535
		cHeader = cHeader + char(126) + char(floor(nLength / 256)) + char(nLength % 256)
	else
		cHeader = cHeader + char(127) + char(0) + char(0) + char(0) + char(0) +
			char(floor(nLength / 16777216) % 256) + char(floor(nLength / 65536) % 256) +
			char(floor(nLength / 256) % 256) + char(nLength % 256)
	ok
	return cHeader + cPayload

func fixtureSendFrame nOpcode, cPayload, lFinal
	if not lFixWsOpen
		return
	ok
	fixtureWrite(oFixWsConn, fixtureFrameBytes(nOpcode, cPayload, lFinal))

# Split one transition inside a multi-byte UTF-8 code point and interleave a
# Ping between the fragments. The client must reassemble the exact text and
# still answer the control frame.
func fixtureFragmented cMarker
	cValue = '{"text":"fragmented ' + cMarker + '"}'
	cEnd = fixtureVersion(nFixQuerySet, fixtureNextStamp())
	cMessage = '{"type":"Transition","startVersion":' + cFixRemote + ',"endVersion":' + cEnd +
		',"modifications":[' + fixtureJoin(fixtureUpdatedModifications(cValue)) + "]}"
	# Splitting one byte past the marker's first byte puts the fragment
	# boundary inside a multi-byte code point.
	nSplit = substr(cMessage, cMarker)
	if nSplit = 0
		nSplit = floor(len(cMessage) / 2)
	ok
	cFirst = left(cMessage, nSplit)
	cSecond = substr(cMessage, nSplit + 1)
	fixtureWrite(oFixWsConn, fixtureFrameBytes(1, cFirst, false))
	fixtureWrite(oFixWsConn, fixtureFrameBytes(9, "mid-fragment", true))
	fixtureWrite(oFixWsConn, fixtureFrameBytes(0, cSecond, true))
	cFixRemote = cEnd
	cFixPayload = cValue

# Send a complete frame header and one payload byte, then leave the connection
# open. The client must hold those exact bytes until its partial-message
# deadline abandons the connection.
func fixtureStallPartialFrame
	cFrame = fixtureFrameBytes(1, '{"type":"Ping"}', true)
	fixtureWrite(oFixWsConn, left(cFrame, 3))

func fixtureCloseWs
	if not lFixWsOpen
		return
	ok
	lFixWsOpen = false
	cFixWsStage = "closed"
	uv_read_stop(oFixWsConn)
	uv_close(oFixWsConn, "fixtureHandleClosed()")
