#!/opt/ring/bin/ring
# Test-only NDJSON adapter protocol v1 executable.
#
# The public-facing client is client/convex.ring; this file exists only so the
# shared controller can drive it. debugDisconnect, the bounded output queue and
# the generation barriers below are conformance machinery, not client API.
#
# RingLibuv owns the controller stream so a stopped reader can never block the
# Live socket, and one repeating timer gives the single Convex owner its turn.
load "convex.ring"

ADAPTER_LANGUAGE       = "ring"
ADAPTER_IMPLEMENTATION = "native-ring-1.27"
ADAPTER_RUNTIME        = "ring-1.27"

# Output bounds. An event count alone is not a memory bound when one protocol
# value can approach the client's message limit, so a conservative byte budget
# is enforced as well, including the NDJSON newline and libuv's own copy.
ADAPTER_MAX_EVENTS            = 16
ADAPTER_CONTROL_RESERVE_EVENTS = 4
ADAPTER_MAX_BYTES             = 6291456
ADAPTER_CONTROL_RESERVE_BYTES = 65536
ADAPTER_ENTRY_OVERHEAD        = 512
ADAPTER_STREAM_OVERHEAD       = 4096

ADAPTER_TICK_MS       = 5
ADAPTER_CLOSE_TIMEOUT_MS = 2000

# Queue entry layout.
ADAPTER_RAW        = 1
ADAPTER_DROPPABLE  = 2
ADAPTER_SUBID      = 3
ADAPTER_GENERATION = 4
ADAPTER_STATE      = 5
ADAPTER_COST       = 6

oAdapterLoop = NULL
oAdapterServer = NULL
oAdapterIn = NULL
oAdapterOut = NULL
oAdapterTimer = NULL
oAdapterWriteReq = NULL
lAdapterWriteReqReady = false
lAdapterStreamReady = false
lAdapterServerOpen = false

# The single record libuv is allowed to read from while a write is in flight.
# Only one write is outstanding at a time, so this variable stays alive for
# exactly as long as libuv owns its bytes.
cAdapterChunk = ""
lAdapterWriting = false

cAdapterInput = ""
aAdapterQueue = []
nAdapterQueueBytes = 0

oAdapterClient = NULL
lAdapterClientReady = false
aAdapterSubs = []
aAdapterGenerations = []

lAdapterClosing = false
lAdapterDone = false
nAdapterCloseDeadline = 0
lAdapterCloseFailed = false

# Test-only deterministic barrier. A test sets this to a function name that runs
# after an entry is dequeued but before libuv is handed its bytes.
cAdapterPauseHook = ""

# Test-only output seam. When a hook is installed the record is handed to it
# instead of to libuv, and lAdapterWriteStalled models a reader that never
# drains. The real socket tests still exercise the genuine libuv path.
cAdapterWriteHook = ""
lAdapterWriteStalled = false

if adapterIsMainProgram()
	adapterRun()
ok

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

# Ring's load command merges a file into the running program, so this file
# starts its controller loop only when Ring was actually asked to run it. The
# language-local tests load it instead, and drive adapterHandle() directly
# without an event loop.
func adapterIsMainProgram
	for cArgument in sysargv
		if not isstring(cArgument)
			loop
		ok
		cName = lower(adapterBaseName(cArgument))
		if cName = "adapter.ring" or cName = "convex-adapter"
			return true
		ok
	next
	return false

func adapterBaseName cPath
	for nIndex = len(cPath) to 1 step -1
		if cPath[nIndex] = "/"
			return substr(cPath, nIndex + 1)
		ok
	next
	return cPath

func adapterRun
	oAdapterLoop = uv_default_loop()
	cListen = cvxEnv("ADAPTER_LISTEN")
	if cListen != ""
		adapterListen(cListen)
	else
		adapterAttachStdio()
	ok
	oAdapterTimer = new_uv_timer_t()
	uv_timer_init(oAdapterLoop, oAdapterTimer)
	uv_timer_start(oAdapterTimer, "adapterTick()", ADAPTER_TICK_MS, ADAPTER_TICK_MS)
	while not lAdapterDone
		uv_run(oAdapterLoop, UV_RUN_ONCE)
	end
	uv_timer_stop(oAdapterTimer)

func adapterAttachStdio
	oAdapterIn = new_uv_pipe_t()
	uv_pipe_init(oAdapterLoop, oAdapterIn, 0)
	uv_pipe_open(oAdapterIn, adapterFileHandle(0))
	oAdapterOut = new_uv_pipe_t()
	uv_pipe_init(oAdapterLoop, oAdapterOut, 0)
	uv_pipe_open(oAdapterOut, adapterFileHandle(1))
	lAdapterStreamReady = true
	uv_read_start(oAdapterIn, uv_myalloccallback(), "adapterReadable()")

# uv_pipe_open wants a uv_file*, not the plain descriptor number RingLibuv
# would accept elsewhere, so the descriptor is written through a real pointer
# rather than handed over as a bare Ring number.
func adapterFileHandle nDescriptor
	nFd = nDescriptor
	pFile = new_uv_file()
	memcpy(pFile, varptr(:nFd, "int"), 4)
	return pFile

# The shared harness runs the client container as a TCP service. Exactly one
# controller connection is accepted, after which the listener is closed so the
# process can still finish on its own.
func adapterListen cListen
	nSeparator = 0
	for nIndex = len(cListen) to 1 step -1
		if cListen[nIndex] = ":"
			nSeparator = nIndex
			exit
		ok
	next
	if nSeparator < 2
		adapterDiagnostic("ADAPTER_LISTEN must use host:port")
		lAdapterDone = true
		return
	ok
	cHost = left(cListen, nSeparator - 1)
	nPort = number(substr(cListen, nSeparator + 1))
	oAddress = new_sockaddr_in()
	oAdapterServer = new_uv_tcp_t()
	uv_tcp_init(oAdapterLoop, oAdapterServer)
	uv_ip4_addr(cHost, nPort, oAddress)
	uv_tcp_bind(oAdapterServer, oAddress, 0)
	nResult = uv_listen(oAdapterServer, 16, "adapterAccept()")
	if nResult
		adapterDiagnostic("adapter listen failed: " + uv_strerror(nResult))
		lAdapterDone = true
		return
	ok
	lAdapterServerOpen = true

func adapterAccept
	aPara = uv_Eventpara(oAdapterServer, :connect)
	if aPara[2] < 0 or lAdapterStreamReady
		return
	ok
	oAdapterIn = new_uv_tcp_t()
	uv_tcp_init(oAdapterLoop, oAdapterIn)
	if uv_accept(oAdapterServer, oAdapterIn) != 0
		return
	ok
	oAdapterOut = oAdapterIn
	lAdapterStreamReady = true
	uv_read_start(oAdapterIn, uv_myalloccallback(), "adapterReadable()")
	if lAdapterServerOpen
		uv_close(oAdapterServer, "adapterServerClosed()")
		lAdapterServerOpen = false
	ok

func adapterServerClosed
	return

# ---------------------------------------------------------------------------
# Diagnostics
#
# stdout carries protocol events only. Ring has no portable process exit code,
# so an abnormal shutdown is reported here and by the absence of the terminal
# event the controller is waiting for.
# ---------------------------------------------------------------------------

func adapterDiagnostic cText
	write("/dev/stderr", cText + nl)

# ---------------------------------------------------------------------------
# Controller input
# ---------------------------------------------------------------------------

func adapterReadable
	aPara = uv_Eventpara(oAdapterIn, :read)
	nRead = aPara[2]
	if nRead < 0
		# The controller went away. Drain whatever is still owed, then stop.
		if not lAdapterClosing
			lAdapterClosing = true
			nAdapterCloseDeadline = cvxNowMs() + ADAPTER_CLOSE_TIMEOUT_MS
		ok
		return
	ok
	if nRead = 0
		return
	ok
	cAdapterInput = cAdapterInput + uv_buf2str(uv_buf_init(get_uv_buf_t_base(aPara[3]), nRead))
	while true
		nNewline = substr(cAdapterInput, nl)
		if nNewline = 0
			exit
		ok
		cLine = left(cAdapterInput, nNewline - 1)
		cAdapterInput = substr(cAdapterInput, nNewline + 1)
		if trim(cLine) != ""
			adapterHandle(cLine)
		ok
		if lAdapterClosing
			exit
		ok
	end

# ---------------------------------------------------------------------------
# Envelopes
# ---------------------------------------------------------------------------

# An empty data string means the field is absent. The shared schema rejects a
# serialized null where the value simply was not sent, so absence is preserved
# rather than being spelled out.
func adapterErrorRaw cName, cMessage, cData
	aFields = [["name", cvxJsonQuote(cName)], ["message", cvxJsonQuote(cMessage)]]
	if cData != ""
		add(aFields, ["data", cData])
	ok
	return cvxJsonObject(aFields)

func adapterHasLogs cLogs
	return cLogs != "" and cLogs != "[]"

func adapterRespondError cId, lWithId, cName, cMessage, cData, cLogs
	aFields = [["type", cvxJsonQuote("error")]]
	if lWithId
		add(aFields, ["id", cvxJsonQuote(cId)])
	ok
	add(aFields, ["error", adapterErrorRaw(cName, cMessage, cData)])
	if adapterHasLogs(cLogs)
		add(aFields, ["logs", cLogs])
	ok
	adapterEmit(cvxJsonObject(aFields), false, "", 0)

func adapterAck cId
	adapterEmit(cvxJsonObject([["id", cvxJsonQuote(cId)], ["type", cvxJsonQuote("ack")]]),
		false, "", 0)

# ---------------------------------------------------------------------------
# The bounded output queue
# ---------------------------------------------------------------------------

# The cost of one entry is a genuine upper bound: the NDJSON newline plus a
# conservative allowance for the Ring queue record and libuv's own copy of the
# bytes, not merely the size of the JSON.
func adapterEntryCost cRaw
	return len(cRaw) + 1 + ADAPTER_ENTRY_OVERHEAD + ADAPTER_STREAM_OVERHEAD

func adapterEmit cRaw, lDroppable, cSubscriptionId, nGeneration
	nCost = adapterEntryCost(cRaw)
	nByteLimit = ADAPTER_MAX_BYTES
	nEventLimit = ADAPTER_MAX_EVENTS
	if lDroppable
		nByteLimit = ADAPTER_MAX_BYTES - ADAPTER_CONTROL_RESERVE_BYTES
		nEventLimit = ADAPTER_MAX_EVENTS - ADAPTER_CONTROL_RESERVE_EVENTS
	ok
	if nCost > nByteLimit
		if lDroppable
			return
		ok
		adapterDiagnostic("an adapter control event exceeded the output budget")
		return
	ok
	while len(aAdapterQueue) >= nEventLimit or nAdapterQueueBytes + nCost > nByteLimit
		if not adapterDropOldestDelivery()
			if lDroppable
				return
			ok
			adapterDiagnostic("adapter output stayed backpressured for a control event")
			return
		ok
	end
	add(aAdapterQueue, [cRaw + nl, lDroppable, cSubscriptionId, nGeneration, "queued", nCost])
	nAdapterQueueBytes = nAdapterQueueBytes + nCost
	adapterFlush()

# Bytes libuv already owns cannot be recalled, so only a queued delivery is a
# candidate for the drop that keeps the budget honest.
func adapterDropOldestDelivery
	for nIndex = 1 to len(aAdapterQueue)
		aEntry = aAdapterQueue[nIndex]
		if aEntry[ADAPTER_DROPPABLE] and aEntry[ADAPTER_STATE] = "queued"
			nAdapterQueueBytes = nAdapterQueueBytes - aEntry[ADAPTER_COST]
			del(aAdapterQueue, nIndex)
			return true
		ok
	next
	return false

func adapterDeliveryCurrent cSubscriptionId, nGeneration
	if cSubscriptionId = ""
		return true
	ok
	if adapterGeneration(cSubscriptionId) != nGeneration
		return false
	ok
	return adapterFindSub(cSubscriptionId) > 0

# Writes are serialised. libuv owns at most one record at a time, which makes
# the pending byte count exact and keeps NDJSON ordering trivially correct.
func adapterFlush
	if lAdapterWriting or not lAdapterStreamReady
		return
	ok
	while len(aAdapterQueue) > 0
		aEntry = aAdapterQueue[1]
		# Recheck ownership immediately before libuv is handed the bytes. This
		# is the acknowledgement barrier: a delivery that unsubscribe or a
		# same-ID replacement retired can never cross its acknowledgement.
		if cAdapterPauseHook != ""
			cHook = cAdapterPauseHook
			cAdapterPauseHook = ""
			call cHook()
			if len(aAdapterQueue) = 0
				return
			ok
			aEntry = aAdapterQueue[1]
		ok
		lStale = false
		if aEntry[ADAPTER_DROPPABLE]
			lStale = not adapterDeliveryCurrent(aEntry[ADAPTER_SUBID],
				aEntry[ADAPTER_GENERATION])
		ok
		if lStale
			nAdapterQueueBytes = nAdapterQueueBytes - aEntry[ADAPTER_COST]
			del(aAdapterQueue, 1)
			loop
		ok
		aAdapterQueue[1][ADAPTER_STATE] = "accepted"
		cAdapterChunk = aEntry[ADAPTER_RAW]
		if cAdapterWriteHook != ""
			lAdapterWriting = true
			cHookName = cAdapterWriteHook
			call cHookName(cAdapterChunk)
			if not lAdapterWriteStalled
				adapterWritten()
			ok
			return
		ok
		oBuffer = new_uv_buf_t()
		set_uv_buf_t_len(oBuffer, len(cAdapterChunk))
		set_uv_buf_t_base(oBuffer, varptr(:cAdapterChunk, "char"))
		if not lAdapterWriteReqReady
			oAdapterWriteReq = new_uv_write_t()
			lAdapterWriteReqReady = true
		ok
		lAdapterWriting = true
		nResult = uv_write(oAdapterWriteReq, oAdapterOut, oBuffer, 1, "adapterWritten()")
		if nResult
			lAdapterWriting = false
			adapterDiagnostic("adapter write failed: " + uv_strerror(nResult))
			lAdapterDone = true
		ok
		return
	end

func adapterWritten
	lAdapterWriting = false
	if len(aAdapterQueue) > 0 and aAdapterQueue[1][ADAPTER_STATE] = "accepted"
		nAdapterQueueBytes = nAdapterQueueBytes - aAdapterQueue[1][ADAPTER_COST]
		del(aAdapterQueue, 1)
	ok
	adapterFlush()

# ---------------------------------------------------------------------------
# Subscription bookkeeping
# ---------------------------------------------------------------------------

func adapterFindSub cSubscriptionId
	for nIndex = 1 to len(aAdapterSubs)
		if aAdapterSubs[nIndex][1] = cSubscriptionId
			return nIndex
		ok
	next
	return 0

func adapterSubByQueryId nQueryId
	for nIndex = 1 to len(aAdapterSubs)
		if aAdapterSubs[nIndex][2] = nQueryId
			return nIndex
		ok
	next
	return 0

# Generations outlive their subscription. A replacement that reuses the same
# controller ID gets a new generation, so an old relay is recognisably stale.
func adapterGeneration cSubscriptionId
	for nIndex = 1 to len(aAdapterGenerations)
		if aAdapterGenerations[nIndex][1] = cSubscriptionId
			return aAdapterGenerations[nIndex][2]
		ok
	next
	return 0

func adapterEnsureGeneration cSubscriptionId
	for nIndex = 1 to len(aAdapterGenerations)
		if aAdapterGenerations[nIndex][1] = cSubscriptionId
			return aAdapterGenerations[nIndex][2]
		ok
	next
	add(aAdapterGenerations, [cSubscriptionId, 1])
	return 1

func adapterInvalidate cSubscriptionId
	adapterEnsureGeneration(cSubscriptionId)
	for nIndex = 1 to len(aAdapterGenerations)
		if aAdapterGenerations[nIndex][1] = cSubscriptionId
			aAdapterGenerations[nIndex][2] = aAdapterGenerations[nIndex][2] + 1
		ok
	next
	nPosition = adapterFindSub(cSubscriptionId)
	if nPosition > 0
		del(aAdapterSubs, nPosition)
	ok
	# Queued stale relays disappear now. Bytes libuv already owns stay budgeted
	# and remain ahead of the acknowledgement on the single output stream.
	aRetained = []
	nBytes = 0
	for aEntry in aAdapterQueue
		if aEntry[ADAPTER_SUBID] = cSubscriptionId and aEntry[ADAPTER_STATE] = "queued"
			loop
		ok
		add(aRetained, aEntry)
		nBytes = nBytes + aEntry[ADAPTER_COST]
	next
	aAdapterQueue = aRetained
	nAdapterQueueBytes = nBytes

# ---------------------------------------------------------------------------
# The tick
# ---------------------------------------------------------------------------

func adapterTick
	if lAdapterClientReady
		oAdapterClient.pump(0)
		adapterDrainClient()
	ok
	adapterFlush()
	if lAdapterClosing
		if len(aAdapterQueue) = 0
			lAdapterDone = true
		but cvxNowMs() >= nAdapterCloseDeadline
			lAdapterCloseFailed = true
			adapterDiagnostic("the adapter close response could not drain before its deadline")
			lAdapterDone = true
		ok
	ok

func adapterDrainClient
	while true
		aEvent = oAdapterClient.nextEvent()
		if len(aEvent) = 0
			return
		ok
		nPosition = adapterSubByQueryId(aEvent[1])
		if nPosition = 0
			loop
		ok
		cSubscriptionId = aAdapterSubs[nPosition][1]
		nGeneration = adapterGeneration(cSubscriptionId)
		aFields = [["type", cvxJsonQuote("subscription")],
			["subscriptionId", cvxJsonQuote(cSubscriptionId)]]
		if aEvent[2] = "value"
			add(aFields, ["value", aEvent[3]])
		else
			add(aFields, ["error", adapterErrorRaw(aEvent[5], aEvent[6], aEvent[7])])
		ok
		if adapterHasLogs(aEvent[4])
			add(aFields, ["logs", aEvent[4]])
		ok
		adapterEmit(cvxJsonObject(aFields), true, cSubscriptionId, nGeneration)
	end

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

func adapterEnsureClient
	if lAdapterClientReady
		return
	ok
	cUrl = cvxEnv("CONVEX_URL")
	if cUrl = ""
		raise("CONVEX_URL is required")
	ok
	oAdapterClient = new ConvexClient(cUrl)
	oAdapterClient.setClientVersion(ADAPTER_IMPLEMENTATION)
	cToken = cvxEnv("CONVEX_AUTH_TOKEN")
	if cToken != ""
		oAdapterClient.setAuth(cToken)
	ok
	lAdapterClientReady = true

# A command identifier must be a JSON string of 1..128 characters. Anything else
# is reported without an id rather than by inventing one.
func adapterRequiredString cLine, cField
	cRaw = trim(cvxJsonField(cLine, cField, false))
	if cRaw = "" or cRaw[1] != CVX_QUOTE
		cvxRaiseProtocol("the command omitted a valid " + cField)
	ok
	cValue = cvxJsonUnquote(cRaw)
	if len(cValue) < 1 or len(cValue) > 128
		cvxRaiseProtocol("the command omitted a valid " + cField)
	ok
	return cValue

func adapterHandle cLine
	cId = ""
	try
		cvxJsonValueEnd(cLine, 1)
		cId = adapterRequiredString(cLine, "id")
	catch
		aClassified = cvxClassify(cCatchError)
		adapterRespondError("", false, aClassified[1], aClassified[2], "null", "[]")
		return
	done
	cOperation = ""
	try
		cOperation = adapterRequiredString(cLine, "op")
	catch
		aClassified = cvxClassify(cCatchError)
		adapterRespondError(cId, true, aClassified[1], aClassified[2], "null", "[]")
		return
	done
	try
		adapterDispatch(cLine, cId, cOperation)
	catch
		aClassified = cvxClassify(cCatchError)
		adapterRespondError(cId, true, aClassified[1], aClassified[2], "null", "[]")
	done

func adapterDispatch cLine, cId, cOperation
	if cOperation = "hello"
		cVersion = cvxJsonField(cLine, "protocolVersion", false)
		if trim(cVersion) != "1"
			cvxRaiseProtocol("unsupported adapter protocol version")
		ok
		adapterEmit(cvxJsonObject([["protocolVersion", "1"], ["id", cvxJsonQuote(cId)],
			["type", cvxJsonQuote("ready")],
			["language", cvxJsonQuote(ADAPTER_LANGUAGE)],
			["implementation", cvxJsonQuote(ADAPTER_IMPLEMENTATION)],
			["runtime", cvxJsonQuote(ADAPTER_RUNTIME)]]), false, "", 0)
		return
	ok
	if cOperation = "query" or cOperation = "mutation" or cOperation = "action"
		adapterEnsureClient()
		cPath = cvxJsonStringField(cvxJsonField(cLine, "path", true), "the command path")
		aResult = oAdapterClient.httpCall(cOperation, cPath, cvxJsonField(cLine, "args", true))
		if aResult[:status] = "error"
			adapterRespondError(cId, true, aResult[:name], aResult[:message],
				aResult[:data], aResult[:logs])
			return
		ok
		aFields = [["id", cvxJsonQuote(cId)], ["type", cvxJsonQuote("result")],
			["value", aResult[:value]]]
		if adapterHasLogs(aResult[:logs])
			add(aFields, ["logs", aResult[:logs]])
		ok
		adapterEmit(cvxJsonObject(aFields), false, "", 0)
		return
	ok
	if cOperation = "setAuth"
		adapterEnsureClient()
		oAdapterClient.setAuth(cvxJsonStringField(cvxJsonField(cLine, "token", true),
			"the command token"))
		adapterAck(cId)
		return
	ok
	if cOperation = "subscribe"
		adapterEnsureClient()
		cSubscriptionId = adapterRequiredString(cLine, "subscriptionId")
		nExisting = adapterFindSub(cSubscriptionId)
		if nExisting > 0
			# Retire the old relay before the replacement can expose its
			# acknowledgement.
			oAdapterClient.unsubscribe(aAdapterSubs[nExisting][2])
			adapterInvalidate(cSubscriptionId)
		ok
		adapterEnsureGeneration(cSubscriptionId)
		cPath = cvxJsonStringField(cvxJsonField(cLine, "path", true), "the command path")
		nQueryId = oAdapterClient.subscribe(cPath, cvxJsonField(cLine, "args", true))
		add(aAdapterSubs, [cSubscriptionId, nQueryId])
		adapterAck(cId)
		return
	ok
	if cOperation = "unsubscribe"
		adapterEnsureClient()
		cSubscriptionId = adapterRequiredString(cLine, "subscriptionId")
		nExisting = adapterFindSub(cSubscriptionId)
		if nExisting > 0
			oAdapterClient.unsubscribe(aAdapterSubs[nExisting][2])
			adapterInvalidate(cSubscriptionId)
		ok
		adapterAck(cId)
		return
	ok
	if cOperation = "debugDisconnect"
		adapterEnsureClient()
		oAdapterClient.debugDisconnect()
		if oAdapterClient.isConnected() or not oAdapterClient.reconnectArmed()
			cvxRaiseTransport("the debugDisconnect acknowledgement barrier was not reached")
		ok
		adapterAck(cId)
		return
	ok
	if cOperation = "close"
		if lAdapterClientReady
			for aEntry in aAdapterSubs
				oAdapterClient.unsubscribe(aEntry[2])
			next
			aRetiring = aAdapterSubs
			for aEntry in aRetiring
				adapterInvalidate(aEntry[1])
			next
			oAdapterClient.close()
		ok
		aAdapterSubs = []
		adapterEmit(cvxJsonObject([["id", cvxJsonQuote(cId)],
			["type", cvxJsonQuote("closed")]]), false, "", 0)
		lAdapterClosing = true
		nAdapterCloseDeadline = cvxNowMs() + ADAPTER_CLOSE_TIMEOUT_MS
		return
	ok
	cvxRaiseProtocol("unknown adapter operation " + cOperation)
