# A genuine stopped-reader test for the Ring conformance adapter.
#
# The adapter's output is attached to a real loopback TCP connection whose peer
# never reads. Once the kernel buffer fills, libuv stops completing writes and
# the adapter is left holding the ownership boundary this file measures: bounded
# queue memory, exact byte accounting, reserved control admission, a bounded
# close, and drained output that stays ordered and is never duplicated.
load "convexadapter.ring"

PRESSURE_PORT = 19083
PRESSURE_VALUE_BYTES = 196608
PRESSURE_MAX_RSS_KIB = 98304

oPressureLoop = NULL
oPressureServer = NULL
oPressureAccepted = NULL
oPressureClient = NULL
oPressureConnect = NULL
lPressureAccepted = false
lPressureConnected = false
cPressureBuffer = ""
aPressureLines = []
nTestChecks = 0

pressureMain()

func pressureMain
	oPressureLoop = uv_default_loop()
	oAddress = new_sockaddr_in()
	oPressureServer = new_uv_tcp_t()
	uv_tcp_init(oPressureLoop, oPressureServer)
	uv_ip4_addr("127.0.0.1", PRESSURE_PORT, oAddress)
	uv_tcp_bind(oPressureServer, oAddress, 0)
	if uv_listen(oPressureServer, 4, "pressureAccept()")
		raise("the pressure fixture could not listen")
	ok
	oPressureClient = new_uv_tcp_t()
	uv_tcp_init(oPressureLoop, oPressureClient)
	oPressureConnect = new_uv_connect_t()
	oTarget = new_sockaddr_in()
	uv_ip4_addr("127.0.0.1", PRESSURE_PORT, oTarget)
	uv_tcp_connect(oPressureConnect, oPressureClient, oTarget, "pressureConnected()")
	nDeadline = cvxNowMs() + 5000
	while (not lPressureAccepted or not lPressureConnected) and cvxNowMs() < nDeadline
		uv_run(oPressureLoop, UV_RUN_NOWAIT)
	end
	assertThat(lPressureAccepted and lPressureConnected,
		"the loopback pressure connection never established")

	# The reader side is deliberately never started, so nothing drains.
	oAdapterOut = oPressureAccepted
	lAdapterStreamReady = true
	cAdapterWriteHook = ""
	aAdapterSubs = [["same", 1]]
	aAdapterGenerations = [["same", 1]]

	cBlob = copy("x", PRESSURE_VALUE_BYTES)
	nEmitted = 0
	nDeadline = cvxNowMs() + 30000
	while nEmitted < ADAPTER_MAX_EVENTS + 8 and cvxNowMs() < nDeadline
		nEmitted = nEmitted + 1
		adapterEmit('{"type":"subscription","subscriptionId":"same","value":{"sequence":' +
			cvxIntText(nEmitted) + ',"blob":"' + cBlob + '"}}', true, "same", 1)
		uv_run(oPressureLoop, UV_RUN_NOWAIT)
	end
	assertThat(lAdapterWriting, "a stopped reader never produced real write backpressure")
	assertThat(len(aAdapterQueue) <= ADAPTER_MAX_EVENTS - ADAPTER_CONTROL_RESERVE_EVENTS,
		"deliveries consumed the reserved control slots under real backpressure")
	nAccounted = 0
	for aEntry in aAdapterQueue
		nAccounted = nAccounted + aEntry[ADAPTER_COST]
	next
	assertThat(nAdapterQueueBytes = nAccounted, "the adapter byte accounting drifted")
	assertThat(nAdapterQueueBytes <= ADAPTER_MAX_BYTES - ADAPTER_CONTROL_RESERVE_BYTES,
		"queued deliveries consumed the reserved control bytes")
	nRss = pressureResidentKib()
	assertThat(nRss < PRESSURE_MAX_RSS_KIB,
		"the stopped-reader adapter reached " + cvxIntText(nRss) + " KiB of resident memory")

	# Replacement, unsubscribe and close all arrive while delivery bytes are
	# still owned by libuv. Their reserved slots must admit them in order.
	adapterEmit('{"id":"replace","type":"ack"}', false, "", 0)
	adapterInvalidate("same")
	adapterEmit('{"id":"unsubscribe","type":"ack"}', false, "", 0)
	adapterEmit('{"id":"close","type":"closed"}', false, "", 0)
	assertThat(len(aAdapterQueue) <= ADAPTER_MAX_EVENTS,
		"the reserved control events exceeded the adapter event bound")
	nControls = 0
	for aEntry in aAdapterQueue
		if not aEntry[ADAPTER_DROPPABLE]
			nControls = nControls + 1
		ok
	next
	assertThat(nControls = 3, "a reserved control event was lost under real backpressure")

	# Nothing drains, so close must fail on its deadline instead of hanging.
	lAdapterClosing = true
	lAdapterDone = false
	lAdapterCloseFailed = false
	nAdapterCloseDeadline = cvxNowMs() + 500
	nCloseStarted = cvxNowMs()
	while not lAdapterDone and cvxNowMs() - nCloseStarted < 5000
		adapterTick()
		uv_run(oPressureLoop, UV_RUN_NOWAIT)
	end
	nCloseElapsed = cvxNowMs() - nCloseStarted
	assertThat(lAdapterCloseFailed, "a stalled close ignored its deadline")
	assertThat(nCloseElapsed >= 400 and nCloseElapsed < 5000,
		"the stalled close finished at " + cvxIntText(nCloseElapsed) + " ms")

	# Start reading and prove the accepted prefix drains in order, exactly once,
	# with every reserved control response behind it.
	lAdapterClosing = false
	lAdapterDone = false
	uv_read_start(oPressureClient, uv_myalloccallback(), "pressureReadable()")
	nDeadline = cvxNowMs() + 30000
	while len(aAdapterQueue) > 0 and cvxNowMs() < nDeadline
		adapterFlush()
		uv_run(oPressureLoop, UV_RUN_NOWAIT)
	end
	assertThat(len(aAdapterQueue) = 0, "the adapter queue never drained")
	assertThat(nAdapterQueueBytes = 0, "a drained adapter queue retained byte accounting")
	nDeadline = cvxNowMs() + 15000
	while pressureIndexOf('{"id":"close","type":"closed"}') = 0 and cvxNowMs() < nDeadline
		uv_run(oPressureLoop, UV_RUN_NOWAIT)
	end
	nReplace = pressureIndexOf('{"id":"replace","type":"ack"}')
	nUnsubscribe = pressureIndexOf('{"id":"unsubscribe","type":"ack"}')
	nClosed = pressureIndexOf('{"id":"close","type":"closed"}')
	assertThat(nReplace > 0 and nUnsubscribe > nReplace and nClosed > nUnsubscribe,
		"the reserved control envelopes were not delivered in order")
	assertThat(pressureCountOf('{"id":"close","type":"closed"}') = 1,
		"a drained NDJSON record was duplicated")
	for nIndex = nUnsubscribe + 1 to len(aPressureLines)
		assertThat(cvxJsonField(aPressureLines[nIndex], "subscriptionId", false) = "",
			"a stale delivery crossed the unsubscribe acknowledgement")
	next
	? "Ring real stopped-reader test passed: RSS " + cvxIntText(nRss) + " KiB, close " +
		cvxIntText(nCloseElapsed) + " ms, drained " + cvxIntText(len(aPressureLines)) + " records"

func assertThat lCondition, cMessage
	nTestChecks = nTestChecks + 1
	if not lCondition
		raise("assertion failed: " + cMessage)
	ok

func pressureAccept
	aPara = uv_Eventpara(oPressureServer, :connect)
	if aPara[2] < 0
		return
	ok
	oPressureAccepted = new_uv_tcp_t()
	uv_tcp_init(oPressureLoop, oPressureAccepted)
	if uv_accept(oPressureServer, oPressureAccepted) = 0
		lPressureAccepted = true
	ok

func pressureConnected
	aPara = uv_Eventpara(oPressureConnect, :connect)
	if aPara[2] < 0
		return
	ok
	lPressureConnected = true

func pressureReadable
	aPara = uv_Eventpara(oPressureClient, :read)
	nRead = aPara[2]
	if nRead <= 0
		return
	ok
	cPressureBuffer = cPressureBuffer + uv_buf2str(uv_buf_init(get_uv_buf_t_base(aPara[3]), nRead))
	while true
		nNewline = substr(cPressureBuffer, nl)
		if nNewline = 0
			return
		ok
		add(aPressureLines, left(cPressureBuffer, nNewline - 1))
		cPressureBuffer = substr(cPressureBuffer, nNewline + 1)
	end

func pressureIndexOf cLine
	for nIndex = 1 to len(aPressureLines)
		if aPressureLines[nIndex] = cLine
			return nIndex
		ok
	next
	return 0

func pressureCountOf cLine
	nCount = 0
	for cCandidate in aPressureLines
		if cCandidate = cLine
			nCount = nCount + 1
		ok
	next
	return nCount

# The resident set of this process, read from the kernel rather than estimated.
func pressureResidentKib
	# read() sizes its buffer with fseek/ftell, and the kernel reports a proc
	# file's size as zero, so it always comes back empty here. fgets reads
	# whatever the kernel hands back on each call instead of trusting a size
	# fixed in advance.
	pStatus = fopen("/proc/self/status", "r")
	cStatus = ""
	while not feof(pStatus)
		cChunk = fgets(pStatus, 4096)
		if not isstring(cChunk)
			exit
		ok
		cStatus = cStatus + cChunk
	end
	fclose(pStatus)
	nAt = substr(cStatus, "VmRSS:")
	if nAt = 0
		raise("the process status did not report VmRSS")
	ok
	cTail = substr(cStatus, nAt + 6)
	cDigits = ""
	for nIndex = 1 to len(cTail)
		nByte = cvxByte(cTail, nIndex)
		if nByte >= 48 and nByte <= 57
			cDigits = cDigits + cTail[nIndex]
		but len(cDigits) > 0
			exit
		ok
	next
	return number(cDigits)
