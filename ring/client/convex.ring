# Native Ring Convex client.
#
# RingLibCurl supplies ordinary TLS, HTTP and RFC 6455 transport, and RingLibuv
# supplies the monotonic clock this client needs for absolute deadlines. Every
# Convex-specific decision lives here in Ring: the request envelopes, the
# response classifier, the query-set state machine, the reconnect lifecycle and
# the rules that decide when a subscription value is published.

load "libcurl.ring"
load "libuv.ring"

# Ring's own string escapes are avoided throughout this file. Building the two
# characters JSON cares about from their byte values keeps every literal in the
# scanner readable and removes any doubt about how a lone backslash is parsed.
CVX_BACKSLASH = char(92)
CVX_QUOTE     = char(34)
CVX_TAB       = char(9)
CVX_NEWLINE   = char(10)
CVX_RETURN    = char(13)
CVX_UNIT      = char(31)

# Deployment defaults. Every network call is bounded by one of these budgets so
# no operation can wait on Convex forever.
CONVEX_CLIENT_VERSION       = "ring-0.1.0"
CONVEX_CA_BUNDLE            = "/etc/ssl/certs/ca-certificates.crt"
CONVEX_HTTP_TIMEOUT_MS      = 10000
CONVEX_CONNECT_TIMEOUT_MS   = 10000
CONVEX_HANDSHAKE_TIMEOUT_MS = 15000

# Byte budgets. The HTTP budget bounds one function response; the Live budget
# bounds one reassembled WebSocket message, including its continuation frames.
CONVEX_MAX_RESPONSE_BYTES = 1048576
CONVEX_MAX_MESSAGE_BYTES  = 262144
CONVEX_WS_CHUNK_BYTES     = 65536

# The pinned sync protocol starts every connection at this canonical zero
# timestamp, which is eight little-endian zero bytes in base64.
CONVEX_INITIAL_TIMESTAMP = "AAAAAAAAAAA="

# A message that has started arriving keeps its exact bytes, but it must not be
# allowed to hold the only Live connection open forever.
CONVEX_PARTIAL_MESSAGE_MS = 5000

# Reconnect backoff. A successful handshake resets the delay so a healthy
# connection never inherits an earlier failure's maximum interval.
CONVEX_BACKOFF_START_MS = 100
CONVEX_BACKOFF_MAX_MS   = 15000

# The client owns a bounded delivery queue rather than a runtime mailbox, so
# these limits are its documented slow-consumer behaviour.
CONVEX_MAX_QUEUED_EVENTS = 64
CONVEX_MAX_QUEUED_BYTES  = 2097152

# libcurl result codes this client reacts to by name instead of by number.
CONVEX_CURLE_OK          = 0
CONVEX_CURLE_GOT_NOTHING = 52
CONVEX_CURLE_AGAIN       = 81

# Raised errors carry one of these markers so a caller can classify a failure
# without parsing Ring's own runtime error text.
CONVEX_MARK_PROTOCOL  = "convex-protocol-error: "
CONVEX_MARK_TRANSPORT = "convex-transport-error: "

CONVEX_BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

# The bounded HTTP response sink. libcurl hands a body over in chunks, and this
# callback refuses to grow past the response budget instead of letting a
# runaway or hostile body decide how much memory the client uses.
cvxHttpBody = ""
cvxHttpOverflow = 0

func cvxHttpWrite
	cData = curl_get_data()
	if cvxHttpOverflow = 1
		return
	ok
	if len(cvxHttpBody) + len(cData) > CONVEX_MAX_RESPONSE_BYTES
		cvxHttpOverflow = 1
		return
	ok
	cvxHttpBody = cvxHttpBody + cData

# The Live handle never produces body bytes, but a write callback is installed
# on it anyway. stdout is the adapter's protocol channel, so no libcurl handle
# may ever be allowed to reach it.
func cvxSinkWrite
	curl_get_data()
	return

# ---------------------------------------------------------------------------
# Clock
# ---------------------------------------------------------------------------

# Ring's clock() counts processor ticks, which barely advance while the client
# waits on a socket. RingLibuv's monotonic timer is the wall clock that every
# deadline in this file is measured against.
func cvxNowMs
	return floor(uv_hrtime() / 1000000)

func cvxWaitMs nMilliseconds
	# uv_sleep is libuv's own test-harness helper, not a function RingLibuv
	# exposes to Ring code. Ring's core syssleep() takes the same millisecond
	# count and is what is actually linked in.
	syssleep(nMilliseconds)

# Read one environment variable, treating an unset variable as empty. Wrapping
# the lookup keeps configuration optional everywhere: the adapter answers hello
# without a deployment URL, and the example prints its own message rather than a
# runtime error when CONVEX_URL is missing.
func cvxEnv cName
	cValue = ""
	try
		cValue = sysget(cName)
	catch
		cValue = ""
	done
	if not isstring(cValue)
		return ""
	ok
	return cValue

# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

func cvxRaiseProtocol cDetail
	raise(CONVEX_MARK_PROTOCOL + cDetail)

func cvxRaiseTransport cDetail
	raise(CONVEX_MARK_TRANSPORT + cDetail)

# Turn a caught Ring error back into the structured name and message that the
# adapter and the example both report. Anything unrecognised stays a protocol
# error rather than being flattened into a successful value.
func cvxClassify cCaught
	nMark = substr(cCaught, CONVEX_MARK_TRANSPORT)
	if nMark > 0
		return ["TransportError", substr(cCaught, nMark + len(CONVEX_MARK_TRANSPORT))]
	ok
	nMark = substr(cCaught, CONVEX_MARK_PROTOCOL)
	if nMark > 0
		return ["ProtocolError", substr(cCaught, nMark + len(CONVEX_MARK_PROTOCOL))]
	ok
	return ["ProtocolError", cCaught]

# ---------------------------------------------------------------------------
# Bytes and numbers on the wire
# ---------------------------------------------------------------------------

# Ring numbers are doubles and string() honours the ambient decimals() setting.
# Protocol counters must reach Convex as plain integers, so render them here
# rather than trusting the formatting of the calling program.
func cvxIntText nValue
	cText = string(floor(nValue))
	nDot = substr(cText, ".")
	if nDot > 0
		cText = left(cText, nDot - 1)
	ok
	return cText

# One byte of a Ring string as an unsigned number. ascii() can surface a
# platform-signed value above 127, and every byte of a Convex payload has to be
# read the same way.
func cvxByte cText, nIndex
	return dec(str2hex(substr(cText, nIndex, 1)))

func cvxIsSpace cChar
	return cChar = " " or cChar = CVX_TAB or cChar = CVX_RETURN or cChar = CVX_NEWLINE

# ---------------------------------------------------------------------------
# JSON
#
# Convex values are kept as their exact JSON text. Decoding a whole response
# into Ring lists would lose the difference between a number, a string, a
# boolean and null, so the scanner below returns byte-accurate subtrees and only
# the client's own metadata is ever converted into Ring values.
# ---------------------------------------------------------------------------

func cvxJsonSkipSpace cText, nIndex
	nLength = len(cText)
	while nIndex <= nLength
		if not cvxIsSpace(cText[nIndex])
			exit
		ok
		nIndex = nIndex + 1
	end
	return nIndex

# nIndex points at the opening quote. A backslash escape consumes the character
# that follows it, and a unicode escape consumes four more hex digits.
func cvxJsonStringEnd cText, nIndex
	nLength = len(cText)
	nIndex = nIndex + 1
	while nIndex <= nLength
		cChar = cText[nIndex]
		if cChar = CVX_BACKSLASH
			nIndex = nIndex + 1
			if nIndex > nLength
				cvxRaiseProtocol("unterminated JSON escape")
			ok
			if cText[nIndex] = "u"
				nIndex = nIndex + 4
			ok
		but cChar = CVX_QUOTE
			return nIndex + 1
		ok
		nIndex = nIndex + 1
	end
	cvxRaiseProtocol("unterminated JSON string")

func cvxJsonValueEnd cText, nIndex
	nLength = len(cText)
	nIndex = cvxJsonSkipSpace(cText, nIndex)
	if nIndex > nLength
		cvxRaiseProtocol("expected a JSON value")
	ok
	cChar = cText[nIndex]
	if cChar = CVX_QUOTE
		return cvxJsonStringEnd(cText, nIndex)
	ok
	if cChar != "{" and cChar != "["
		nEnd = nIndex
		while nEnd <= nLength
			cCurrent = cText[nEnd]
			if cCurrent = "," or cCurrent = "]" or cCurrent = "}" or cvxIsSpace(cCurrent)
				exit
			ok
			nEnd = nEnd + 1
		end
		return nEnd
	ok
	if cChar = "{"
		cClose = "}"
	else
		cClose = "]"
	ok
	nDepth = 0
	nCursor = nIndex
	while nCursor <= nLength
		cCurrent = cText[nCursor]
		if cCurrent = CVX_QUOTE
			nCursor = cvxJsonStringEnd(cText, nCursor)
			loop
		ok
		if cCurrent = cChar
			nDepth = nDepth + 1
		ok
		if cCurrent = cClose
			nDepth = nDepth - 1
			if nDepth = 0
				return nCursor + 1
			ok
		ok
		nCursor = nCursor + 1
	end
	cvxRaiseProtocol("unterminated JSON container")

# Return one field's exact JSON text, or "" when the field is absent and the
# caller declared it optional.
func cvxJsonField cObject, cName, lRequired
	nIndex = cvxJsonSkipSpace(cObject, 1)
	nLength = len(cObject)
	if nIndex > nLength or cObject[nIndex] != "{"
		cvxRaiseProtocol("expected a JSON object")
	ok
	nIndex = nIndex + 1
	cPlainKey = CVX_QUOTE + cName + CVX_QUOTE
	while true
		nIndex = cvxJsonSkipSpace(cObject, nIndex)
		if nIndex > nLength
			exit
		ok
		if cObject[nIndex] = "}"
			exit
		ok
		if cObject[nIndex] != CVX_QUOTE
			cvxRaiseProtocol("malformed JSON object key")
		ok
		nKeyEnd = cvxJsonStringEnd(cObject, nIndex)
		cKeyRaw = substr(cObject, nIndex, nKeyEnd - nIndex)
		nIndex = cvxJsonSkipSpace(cObject, nKeyEnd)
		if nIndex > nLength or cObject[nIndex] != ":"
			cvxRaiseProtocol("malformed JSON object separator")
		ok
		nStart = cvxJsonSkipSpace(cObject, nIndex + 1)
		nEnd = cvxJsonValueEnd(cObject, nStart)
		# Compare the raw key text first. Convex keys are plain, so unescaping
		# every key of every response would cost far more than it can ever find.
		lMatch = cKeyRaw = cPlainKey
		if not lMatch and substr(cKeyRaw, CVX_BACKSLASH) > 0
			lMatch = cvxJsonUnquote(cKeyRaw) = cName
		ok
		if lMatch
			return substr(cObject, nStart, nEnd - nStart)
		ok
		nIndex = cvxJsonSkipSpace(cObject, nEnd)
		if nIndex <= nLength and cObject[nIndex] = ","
			nIndex = nIndex + 1
		ok
	end
	if lRequired
		cvxRaiseProtocol("a JSON object omitted the required field " + cName)
	ok
	return ""

func cvxJsonElements cArray
	nIndex = cvxJsonSkipSpace(cArray, 1)
	nLength = len(cArray)
	if nIndex > nLength or cArray[nIndex] != "["
		cvxRaiseProtocol("expected a JSON array")
	ok
	nIndex = nIndex + 1
	aResult = []
	while true
		nIndex = cvxJsonSkipSpace(cArray, nIndex)
		if nIndex > nLength or cArray[nIndex] = "]"
			return aResult
		ok
		nEnd = cvxJsonValueEnd(cArray, nIndex)
		add(aResult, substr(cArray, nIndex, nEnd - nIndex))
		nIndex = cvxJsonSkipSpace(cArray, nEnd)
		if nIndex <= nLength and cArray[nIndex] = ","
			nIndex = nIndex + 1
			loop
		ok
		if nIndex <= nLength and cArray[nIndex] = "]"
			return aResult
		ok
		cvxRaiseProtocol("malformed JSON array separator")
	end

# Encode a Ring string as a JSON string literal. Bytes below 0x20 must be
# escaped; everything else is already UTF-8 and travels through unchanged.
func cvxJsonQuote cValue
	cOut = CVX_QUOTE
	nLength = len(cValue)
	for nIndex = 1 to nLength
		cChar = cValue[nIndex]
		if cChar = CVX_QUOTE
			cOut = cOut + CVX_BACKSLASH + CVX_QUOTE
			loop
		ok
		if cChar = CVX_BACKSLASH
			cOut = cOut + CVX_BACKSLASH + CVX_BACKSLASH
			loop
		ok
		nByte = cvxByte(cValue, nIndex)
		if nByte >= 32
			cOut = cOut + cChar
			loop
		ok
		if nByte = 8
			cOut = cOut + CVX_BACKSLASH + "b"
		but nByte = 9
			cOut = cOut + CVX_BACKSLASH + "t"
		but nByte = 10
			cOut = cOut + CVX_BACKSLASH + "n"
		but nByte = 12
			cOut = cOut + CVX_BACKSLASH + "f"
		but nByte = 13
			cOut = cOut + CVX_BACKSLASH + "r"
		else
			cOut = cOut + CVX_BACKSLASH + "u00" + right("0" + lower(hex(nByte)), 2)
		ok
	next
	return cOut + CVX_QUOTE

# Decode a JSON string literal, including surrogate pairs, back into UTF-8.
func cvxJsonUnquote cRaw
	cRaw = trim(cRaw)
	if len(cRaw) < 2 or cRaw[1] != CVX_QUOTE or cRaw[len(cRaw)] != CVX_QUOTE
		cvxRaiseProtocol("expected a JSON string")
	ok
	cOut = ""
	nIndex = 2
	nLast = len(cRaw) - 1
	while nIndex <= nLast
		cChar = cRaw[nIndex]
		if cChar != CVX_BACKSLASH
			cOut = cOut + cChar
			nIndex = nIndex + 1
			loop
		ok
		nIndex = nIndex + 1
		if nIndex > nLast
			cvxRaiseProtocol("unterminated JSON escape")
		ok
		cEscape = cRaw[nIndex]
		if cEscape = "u"
			if nIndex + 4 > nLast
				cvxRaiseProtocol("truncated JSON unicode escape")
			ok
			nCode = dec(substr(cRaw, nIndex + 1, 4))
			nIndex = nIndex + 5
			if nCode >= 55296 and nCode <= 56319 and nIndex + 5 <= nLast
				if cRaw[nIndex] = CVX_BACKSLASH and cRaw[nIndex + 1] = "u"
					nLow = dec(substr(cRaw, nIndex + 2, 4))
					if nLow >= 56320 and nLow <= 57343
						nCode = 65536 + (nCode - 55296) * 1024 + (nLow - 56320)
						nIndex = nIndex + 6
					ok
				ok
			ok
			cOut = cOut + cvxUtf8(nCode)
			loop
		ok
		if cEscape = "n"
			cOut = cOut + CVX_NEWLINE
		but cEscape = "t"
			cOut = cOut + CVX_TAB
		but cEscape = "r"
			cOut = cOut + CVX_RETURN
		but cEscape = "b"
			cOut = cOut + char(8)
		but cEscape = "f"
			cOut = cOut + char(12)
		else
			cOut = cOut + cEscape
		ok
		nIndex = nIndex + 1
	end
	return cOut

func cvxUtf8 nCode
	if nCode < 128
		return char(nCode)
	ok
	if nCode < 2048
		return char(192 + floor(nCode / 64)) + char(128 + (nCode % 64))
	ok
	if nCode < 65536
		return char(224 + floor(nCode / 4096)) +
		       char(128 + (floor(nCode / 64) % 64)) +
		       char(128 + (nCode % 64))
	ok
	return char(240 + floor(nCode / 262144)) +
	       char(128 + (floor(nCode / 4096) % 64)) +
	       char(128 + (floor(nCode / 64) % 64)) +
	       char(128 + (nCode % 64))

func cvxJsonObject aPairs
	cOut = "{"
	for nIndex = 1 to len(aPairs)
		if nIndex > 1
			cOut = cOut + ","
		ok
		cOut = cOut + cvxJsonQuote(aPairs[nIndex][1]) + ":" + aPairs[nIndex][2]
	next
	return cOut + "}"

func cvxJsonArray aValues
	cOut = "["
	for nIndex = 1 to len(aValues)
		if nIndex > 1
			cOut = cOut + ","
		ok
		cOut = cOut + aValues[nIndex]
	next
	return cOut + "]"

# Protocol counters are unsigned 32-bit integers on the wire. Validate the exact
# token, because a quoted, fractional or boolean lookalike must never enter the
# client's state through Ring's deliberately untyped numbers.
func cvxJsonUint32 cRaw, cField
	cToken = trim(cRaw)
	if len(cToken) = 0 or len(cToken) > 10
		cvxRaiseProtocol(cField + " must be a JSON uint32 integer")
	ok
	for nIndex = 1 to len(cToken)
		nByte = cvxByte(cToken, nIndex)
		if nByte < 48 or nByte > 57
			cvxRaiseProtocol(cField + " must be a JSON uint32 integer")
		ok
	next
	if len(cToken) > 1 and cToken[1] = "0"
		cvxRaiseProtocol(cField + " must be a JSON uint32 integer")
	ok
	nValue = number(cToken)
	if nValue > 4294967295
		cvxRaiseProtocol(cField + " must be a JSON uint32 integer")
	ok
	return nValue

func cvxJsonStringField cRaw, cField
	cToken = trim(cRaw)
	if len(cToken) = 0 or cToken[1] != CVX_QUOTE
		cvxRaiseProtocol(cField + " must be a JSON string")
	ok
	return cvxJsonUnquote(cToken)

# Convex spells a whole number in JSON as 0 or as 0.0. Accept the mathematical
# integer, and reject fractions, quoted numbers, non-finite tokens and anything
# that would overflow a double's exact integer range.
func cvxWholeNumber cRaw, cField
	cToken = trim(cRaw)
	if len(cToken) = 0
		cvxRaiseProtocol(cField + " was not a finite whole number")
	ok
	nIndex = 1
	lNegative = false
	if cToken[1] = "-"
		lNegative = true
		nIndex = 2
	ok
	cDigits = ""
	while nIndex <= len(cToken)
		nByte = cvxByte(cToken, nIndex)
		if nByte < 48 or nByte > 57
			exit
		ok
		cDigits = cDigits + cToken[nIndex]
		nIndex = nIndex + 1
	end
	if len(cDigits) = 0 or len(cDigits) > 15
		cvxRaiseProtocol(cField + " was not a finite whole number")
	ok
	if nIndex <= len(cToken)
		if cToken[nIndex] != "."
			cvxRaiseProtocol(cField + " was not a finite whole number")
		ok
		nIndex = nIndex + 1
		if nIndex > len(cToken)
			cvxRaiseProtocol(cField + " was not a finite whole number")
		ok
		while nIndex <= len(cToken)
			if cToken[nIndex] != "0"
				cvxRaiseProtocol(cField + " was not a finite whole number")
			ok
			nIndex = nIndex + 1
		end
	ok
	nValue = number(cDigits)
	if lNegative
		nValue = 0 - nValue
	ok
	return nValue

# ---------------------------------------------------------------------------
# Canonical timestamps
# ---------------------------------------------------------------------------

# Convex timestamps arrive base64-encoded and little-endian. Turning one into a
# big-endian hex key makes ordering a plain string comparison, which is what
# keeps maxObservedTimestamp monotonic across reconnects.
func cvxTimestampKey cEncoded
	cBytes = cvxBase64Decode(cEncoded)
	if len(cBytes) != 8
		cvxRaiseProtocol("invalid canonical timestamp")
	ok
	cKey = ""
	for nIndex = 8 to 1 step -1
		cKey = cKey + right("0" + lower(hex(cvxByte(cBytes, nIndex))), 2)
	next
	return cKey

func cvxBase64Decode cEncoded
	cOut = ""
	nAccumulator = 0
	nBits = 0
	for nIndex = 1 to len(cEncoded)
		cChar = cEncoded[nIndex]
		if cChar = "="
			exit
		ok
		nDigit = substr(CONVEX_BASE64_ALPHABET, cChar)
		if nDigit = 0
			cvxRaiseProtocol("invalid base64 timestamp")
		ok
		nAccumulator = nAccumulator * 64 + (nDigit - 1)
		nBits = nBits + 6
		if nBits >= 8
			nBits = nBits - 8
			nShift = 1
			for nPower = 1 to nBits
				nShift = nShift * 2
			next
			cOut = cOut + char(floor(nAccumulator / nShift) % 256)
			nAccumulator = nAccumulator % nShift
		ok
	next
	return cOut

func cvxBase64Encode cBytes
	cOut = ""
	nIndex = 1
	nLength = len(cBytes)
	while nIndex <= nLength
		nFirst = cvxByte(cBytes, nIndex)
		nSecond = 0
		nThird = 0
		nAvailable = 1
		if nIndex + 1 <= nLength
			nSecond = cvxByte(cBytes, nIndex + 1)
			nAvailable = 2
		ok
		if nIndex + 2 <= nLength
			nThird = cvxByte(cBytes, nIndex + 2)
			nAvailable = 3
		ok
		nTriple = nFirst * 65536 + nSecond * 256 + nThird
		cOut = cOut + CONVEX_BASE64_ALPHABET[floor(nTriple / 262144) + 1]
		cOut = cOut + CONVEX_BASE64_ALPHABET[(floor(nTriple / 4096) % 64) + 1]
		if nAvailable > 1
			cOut = cOut + CONVEX_BASE64_ALPHABET[(floor(nTriple / 64) % 64) + 1]
		else
			cOut = cOut + "="
		ok
		if nAvailable > 2
			cOut = cOut + CONVEX_BASE64_ALPHABET[(nTriple % 64) + 1]
		else
			cOut = cOut + "="
		ok
		nIndex = nIndex + 3
	end
	return cOut

# ---------------------------------------------------------------------------
# URLs
# ---------------------------------------------------------------------------

func cvxValidUrl cUrl
	if left(lower(cUrl), 7) = "http://" and len(cUrl) > 7
		return true
	ok
	if left(lower(cUrl), 8) = "https://" and len(cUrl) > 8
		return true
	ok
	return false

func cvxSyncUrl cUrl
	if left(lower(cUrl), 8) = "https://"
		return "wss://" + substr(cUrl, 9) + "/api/sync"
	ok
	return "ws://" + substr(cUrl, 8) + "/api/sync"

# ---------------------------------------------------------------------------
# The client
# ---------------------------------------------------------------------------

class ConvexClient

	cUrl = ""
	cClientVersion = CONVEX_CLIENT_VERSION
	cAuthToken = ""
	lClosed = false

	oHttp = NULL
	lHttpReady = false
	oHeaders = NULL
	cHeaderToken = ""
	lHeadersReady = false

	# Live transport state. One worker owns this handle: every send, receive,
	# reconnect and query-set version change goes through the methods below, so
	# no caller ever touches the socket concurrently.
	oSocket = NULL
	lSocketOpen = false
	cPending = ""
	nPendingSince = 0
	nConnectionCount = 0
	cLastCloseReason = "InitialConnect"
	cMaxTimestamp = ""
	nBackoffMs = CONVEX_BACKOFF_START_MS
	nReconnectAt = 0
	lReconnectArmed = false

	# Query-set state. nQuerySet is the version this client has published to the
	# server; cRemote is the exact state version the server last transitioned to.
	nQuerySet = 0
	cRemote = ""
	nNextQueryId = 0
	aSubscriptions = []

	# The bounded delivery queue. Callers drain it with nextEvent(). It is a
	# FIFO rather than a coalescing buffer, so a 0 followed by a 1 is never
	# collapsed into a single publication.
	aEvents = []
	nQueuedBytes = 0
	nDroppedEvents = 0

	func init cDeploymentUrl
		if not cvxValidUrl(cDeploymentUrl)
			raise("a Convex deployment URL must be an absolute HTTP(S) URL")
		ok
		while right(cDeploymentUrl, 1) = "/"
			cDeploymentUrl = left(cDeploymentUrl, len(cDeploymentUrl) - 1)
		end
		self.cUrl = cDeploymentUrl
		self.cRemote = self.zeroVersion()
		self.oHttp = curl_easy_init()
		self.lHttpReady = true

	func zeroVersion
		return cvxJsonObject([["querySet", "0"], ["identity", "0"],
			["ts", cvxJsonQuote(CONVEX_INITIAL_TIMESTAMP)]])

	func setClientVersion cVersion
		self.cClientVersion = cVersion
		self.lHeadersReady = false

	func setAuth cToken
		if self.lClosed
			raise("the client is closed")
		ok
		self.cAuthToken = cToken
		self.lHeadersReady = false

	# -------------------------------------------------------------------
	# HTTP
	# -------------------------------------------------------------------

	# One header list is cached per distinct bearer token. Convex needs the
	# Convex-Client identifier on every request, and rebuilding the list only
	# when the token changes keeps the reused libcurl handle from allocating a
	# new list for each call.
	func ensureHeaders
		if self.lHeadersReady and self.cHeaderToken = self.cAuthToken
			return
		ok
		oList = curl_slist_append(NULL, "Content-Type: application/json")
		oList = curl_slist_append(oList, "Accept: application/json")
		oList = curl_slist_append(oList, "Convex-Client: " + self.cClientVersion)
		if self.cAuthToken != ""
			oList = curl_slist_append(oList, "Authorization: Bearer " + self.cAuthToken)
		ok
		self.oHeaders = oList
		self.cHeaderToken = self.cAuthToken
		self.lHeadersReady = true

	func query cPath, cArgsRaw
		return self.httpCall("query", cPath, cArgsRaw)

	func mutation cPath, cArgsRaw
		return self.httpCall("mutation", cPath, cArgsRaw)

	func action cPath, cArgsRaw
		return self.httpCall("action", cPath, cArgsRaw)

	# Returns a result record. A Convex function that threw is reported as a
	# structured FunctionError rather than being flattened into a value, and a
	# malformed envelope stays a protocol error.
	func httpCall cOperation, cPath, cArgsRaw
		if self.lClosed
			raise("the client is closed")
		ok
		if substr(cPath, ":") = 0
			cvxRaiseProtocol("a Convex function path is required")
		ok
		cArgsRaw = trim(cArgsRaw)
		if len(cArgsRaw) = 0 or cArgsRaw[1] != "{"
			cvxRaiseProtocol("Convex arguments must be a JSON object")
		ok
		# Parse the arguments once so a malformed object is rejected before it
		# reaches Convex, then send the caller's exact bytes.
		cvxJsonValueEnd(cArgsRaw, 1)
		cBody = cvxJsonObject([["path", cvxJsonQuote(cPath)], ["args", cArgsRaw],
			["format", cvxJsonQuote("json")]])

		self.ensureHeaders()
		cvxHttpBody = ""
		cvxHttpOverflow = 0
		curl_easy_setopt(self.oHttp, CURLOPT_URL, self.cUrl + "/api/" + cOperation)
		curl_easy_setopt(self.oHttp, CURLOPT_POST, 1)
		curl_easy_setopt(self.oHttp, CURLOPT_COPYPOSTFIELDS, cBody)
		curl_easy_setopt(self.oHttp, CURLOPT_HTTPHEADER, self.oHeaders)
		curl_easy_setopt(self.oHttp, CURLOPT_WRITEFUNCTION, :cvxHttpWrite)
		curl_easy_setopt(self.oHttp, CURLOPT_TIMEOUT_MS, CONVEX_HTTP_TIMEOUT_MS)
		curl_easy_setopt(self.oHttp, CURLOPT_CONNECTTIMEOUT_MS, CONVEX_CONNECT_TIMEOUT_MS)
		curl_easy_setopt(self.oHttp, CURLOPT_NOSIGNAL, 1)
		curl_easy_setopt(self.oHttp, CURLOPT_MAXFILESIZE, CONVEX_MAX_RESPONSE_BYTES)
		curl_easy_setopt(self.oHttp, CURLOPT_SSL_VERIFYPEER, 1)
		curl_easy_setopt(self.oHttp, CURLOPT_SSL_VERIFYHOST, 2)
		curl_easy_setopt(self.oHttp, CURLOPT_CAINFO, CONVEX_CA_BUNDLE)

		nResult = curl_easy_perform(self.oHttp)
		cRaw = cvxHttpBody
		cvxHttpBody = ""
		if nResult != CONVEX_CURLE_OK
			cvxRaiseTransport("the HTTP " + cOperation +
				" failed with libcurl code " + cvxIntText(nResult))
		ok
		if cvxHttpOverflow = 1
			cvxRaiseTransport("the HTTP response exceeded the client byte budget")
		ok
		nStatusCode = curl_getResponseCode(self.oHttp)
		if nStatusCode != 200
			cvxRaiseTransport("the HTTP " + cOperation + " returned status " +
				cvxIntText(nStatusCode))
		ok
		return self.classifyResponse(cRaw)

	func classifyResponse cRaw
		cStatusRaw = cvxJsonField(cRaw, "status", false)
		if cStatusRaw = ""
			cvxRaiseProtocol("the HTTP response omitted status")
		ok
		cStatus = cvxJsonStringField(cStatusRaw, "the HTTP response status")
		if cStatus = "success"
			cLogs = cvxJsonField(cRaw, "logLines", false)
			if cLogs = ""
				cLogs = "[]"
			ok
			return [["status", "success"],
				["value", cvxJsonField(cRaw, "value", true)],
				["logs", cLogs]]
		ok
		if cStatus = "error"
			cMessageRaw = cvxJsonField(cRaw, "errorMessage", false)
			if cMessageRaw = ""
				cMessage = "the Convex function failed"
			else
				cMessage = cvxJsonStringField(cMessageRaw, "the HTTP errorMessage")
			ok
			cLogs = cvxJsonField(cRaw, "logLines", false)
			if cLogs = ""
				cLogs = "[]"
			ok
			return [["status", "error"], ["name", "FunctionError"],
				["message", cMessage],
				["data", cvxJsonField(cRaw, "errorData", false)],
				["logs", cLogs]]
		ok
		cvxRaiseProtocol("the HTTP response had an unknown status")

	# -------------------------------------------------------------------
	# Live subscriptions
	# -------------------------------------------------------------------

	func subscribe cPath, cArgsRaw
		if self.lClosed
			raise("the client is closed")
		ok
		cArgsRaw = trim(cArgsRaw)
		if len(cArgsRaw) = 0 or cArgsRaw[1] != "{"
			cvxRaiseProtocol("Convex arguments must be a JSON object")
		ok
		cvxJsonValueEnd(cArgsRaw, 1)
		nQueryId = self.nNextQueryId
		self.nNextQueryId = nQueryId + 1
		add(self.aSubscriptions, [nQueryId, cPath, cArgsRaw, ""])
		# A connection that opens here already replays the whole query set, so
		# only an existing connection needs this one extra Add.
		lWasOpen = self.lSocketOpen
		self.openLive()
		if lWasOpen and self.lSocketOpen
			self.modify([self.addModification(nQueryId, cPath, cArgsRaw)])
		ok
		return nQueryId

	func unsubscribe nQueryId
		nPosition = self.findSubscription(nQueryId)
		if nPosition = 0
			return
		ok
		del(self.aSubscriptions, nPosition)
		# Retire anything this subscription has already queued. A caller's
		# acknowledgement must never be crossed by a value it just removed.
		self.dropQueued(nQueryId)
		if self.lSocketOpen
			try
				self.modify([cvxJsonObject([["type", cvxJsonQuote("Remove")],
					["queryId", cvxIntText(nQueryId)]])])
			catch
				# The socket is already gone. Reconnect rebuilds the query set
				# from the surviving subscriptions, so nothing is stranded.
			done
		ok

	func findSubscription nQueryId
		for nIndex = 1 to len(self.aSubscriptions)
			if self.aSubscriptions[nIndex][1] = nQueryId
				return nIndex
			ok
		next
		return 0

	func addModification nQueryId, cPath, cArgsRaw
		return cvxJsonObject([["type", cvxJsonQuote("Add")],
			["queryId", cvxIntText(nQueryId)],
			["udfPath", cvxJsonQuote(cPath)],
			["args", cvxJsonArray([cArgsRaw])]])

	func modify aModifications
		nCurrent = self.nQuerySet
		self.send(cvxJsonObject([["type", cvxJsonQuote("ModifyQuerySet")],
			["baseVersion", cvxIntText(nCurrent)],
			["newVersion", cvxIntText(nCurrent + 1)],
			["modifications", cvxJsonArray(aModifications)]]))
		self.nQuerySet = nCurrent + 1

	# The owner's connect step. libcurl performs the TLS handshake and the RFC
	# 6455 upgrade; this client owns everything above the frame layer.
	func openLive
		if self.lClosed or len(self.aSubscriptions) = 0 or self.lSocketOpen
			return
		ok
		self.lReconnectArmed = false
		oCurl = curl_easy_init()
		curl_easy_setopt(oCurl, CURLOPT_URL, cvxSyncUrl(self.cUrl))
		curl_easy_setopt(oCurl, CURLOPT_CONNECT_ONLY, 2)
		curl_easy_setopt(oCurl, CURLOPT_WRITEFUNCTION, :cvxSinkWrite)
		curl_easy_setopt(oCurl, CURLOPT_CONNECTTIMEOUT_MS, CONVEX_CONNECT_TIMEOUT_MS)
		curl_easy_setopt(oCurl, CURLOPT_TIMEOUT_MS, CONVEX_HANDSHAKE_TIMEOUT_MS)
		curl_easy_setopt(oCurl, CURLOPT_NOSIGNAL, 1)
		curl_easy_setopt(oCurl, CURLOPT_SSL_VERIFYPEER, 1)
		curl_easy_setopt(oCurl, CURLOPT_SSL_VERIFYHOST, 2)
		curl_easy_setopt(oCurl, CURLOPT_CAINFO, CONVEX_CA_BUNDLE)
		nResult = curl_easy_perform(oCurl)
		if nResult != CONVEX_CURLE_OK
			curl_easy_cleanup(oCurl)
			self.retire("TransportError: the Live handshake failed with libcurl code " +
				cvxIntText(nResult), true)
			return
		ok
		self.oSocket = oCurl
		self.lSocketOpen = true
		self.cPending = ""
		self.nPendingSince = 0
		# A connection that cannot carry its own Connect and query set is not
		# usable. Retire it here so the caller sees a scheduled reconnect
		# instead of a socket that will never hydrate.
		try
			self.socketOpen()
		catch
			aClassified = cvxClassify(cCatchError)
			self.retire(aClassified[1] + ": " + aClassified[2], true)
		done

	# A fresh connection restarts the query-set version at zero and replays the
	# active Add operations, so the server rebuilds exactly the set this client
	# still cares about.
	func socketOpen
		self.nBackoffMs = CONVEX_BACKOFF_START_MS
		self.nQuerySet = 0
		self.cRemote = self.zeroVersion()
		aFields = [["type", cvxJsonQuote("Connect")],
			["sessionId", cvxJsonQuote(self.sessionId())],
			["connectionCount", cvxIntText(self.nConnectionCount)],
			["lastCloseReason", cvxJsonQuote(self.cLastCloseReason)],
			["clientTs", "0"]]
		if self.cMaxTimestamp != ""
			add(aFields, ["maxObservedTimestamp", cvxJsonQuote(self.cMaxTimestamp)])
		ok
		self.send(cvxJsonObject(aFields))
		aAdditions = []
		for aSubscription in self.aSubscriptions
			add(aAdditions, self.addModification(aSubscription[1],
				aSubscription[2], aSubscription[3]))
		next
		if len(aAdditions) > 0
			self.modify(aAdditions)
		ok

	# The pinned sync protocol wants exactly 32 hex characters here. The
	# monotonic clock supplies the changing part and the connection counter keeps
	# two sessions inside the same microsecond distinct.
	func sessionId
		cSeed = lower(hex(floor(uv_hrtime() / 1000))) +
			lower(hex(self.nConnectionCount + 1))
		return right(copy("0", 32) + cSeed, 32)

	func send cRaw
		if not self.lSocketOpen
			cvxRaiseTransport("the Live WebSocket is not connected")
		ok
		aResult = curl_ws_send(self.oSocket, cRaw, 0, CURLWS_TEXT)
		if aResult[1] = CONVEX_CURLE_AGAIN
			# libcurl accepted no bytes at all, so the frame is intact and can
			# be offered again once the socket drains.
			nDeadline = cvxNowMs() + CONVEX_HTTP_TIMEOUT_MS
			while aResult[1] = CONVEX_CURLE_AGAIN and cvxNowMs() < nDeadline
				cvxWaitMs(5)
				aResult = curl_ws_send(self.oSocket, cRaw, 0, CURLWS_TEXT)
			end
		ok
		if aResult[1] != CONVEX_CURLE_OK
			cvxRaiseTransport("the Live send failed with libcurl code " +
				cvxIntText(aResult[1]))
		ok
		if aResult[2] != len(cRaw)
			cvxRaiseTransport("the Live send was truncated")
		ok

	# Retire the current connection. A parser failure or an unexpected peer close
	# is a subscription failure, not an invisible diagnostic, so every surviving
	# subscription is told about it and stays active for the next valid value.
	func retire cReason, lReconnect
		if self.lSocketOpen
			curl_easy_cleanup(self.oSocket)
		ok
		self.oSocket = NULL
		self.lSocketOpen = false
		self.cPending = ""
		self.nPendingSince = 0
		self.cLastCloseReason = cReason
		self.nConnectionCount = self.nConnectionCount + 1
		if cReason != "client-closed" and cReason != "DebugDisconnect" and not self.lClosed
			cName = "TransportError"
			cMessage = cReason
			if left(cReason, 15) = "ProtocolError: "
				cName = "ProtocolError"
				cMessage = substr(cReason, 16)
			but left(cReason, 16) = "TransportError: "
				cMessage = substr(cReason, 17)
			ok
			aIds = []
			for aSubscription in self.aSubscriptions
				add(aIds, aSubscription[1])
			next
			for nQueryId in aIds
				# publishError is for an in-band QueryFailed: the connection
				# stays open, so clearing the signature only affects a later,
				# independently-arriving value. Retiring the whole connection
				# is different: the reconnect that follows replays every
				# active Add, and the rehydration it gets back is often the
				# same value the subscription already had. Clearing the
				# signature here would un-suppress that rehydration and let
				# it cross the acknowledgement as if it were new, so this
				# error is delivered without touching it.
				self.publishConnectionError(nQueryId, cName, cMessage)
			next
		ok
		if not lReconnect or self.lClosed or len(self.aSubscriptions) = 0
			self.lReconnectArmed = false
			return
		ok
		self.nReconnectAt = cvxNowMs() + self.nBackoffMs
		self.lReconnectArmed = true
		nNext = self.nBackoffMs * 2
		if nNext > CONVEX_BACKOFF_MAX_MS
			nNext = CONVEX_BACKOFF_MAX_MS
		ok
		self.nBackoffMs = nNext

	# The adapter-only reconnect hook. It returns after the old connection is
	# retired and the replacement is scheduled, never before.
	func debugDisconnect
		if not self.lSocketOpen
			cvxRaiseTransport("the Live WebSocket is not connected")
		ok
		self.retire("DebugDisconnect", true)
		if self.lSocketOpen or not self.lReconnectArmed
			cvxRaiseTransport("debugDisconnect did not retire the socket and schedule a reconnect")
		ok

	func close
		if self.lClosed
			return
		ok
		self.lClosed = true
		self.aSubscriptions = []
		self.lReconnectArmed = false
		if self.lSocketOpen
			self.retire("client-closed", false)
		ok
		if self.lHttpReady
			curl_easy_cleanup(self.oHttp)
			self.oHttp = NULL
			self.lHttpReady = false
		ok
		self.aEvents = []
		self.nQueuedBytes = 0

	# -------------------------------------------------------------------
	# The pump
	#
	# One call drains everything the socket already holds, honours the reconnect
	# schedule and enforces the partial-message deadline. nBudgetMs is an
	# absolute ceiling: the pump never runs past it.
	# -------------------------------------------------------------------

	func pump nBudgetMs
		nDeadline = cvxNowMs() + nBudgetMs
		while true
			if self.lReconnectArmed and cvxNowMs() >= self.nReconnectAt
				self.openLive()
			ok
			if not self.lSocketOpen
				lWaiting = self.lReconnectArmed and cvxNowMs() < nDeadline
				if len(self.aEvents) > 0 or not lWaiting
					return
				ok
				cvxWaitMs(5)
				loop
			ok
			# Drain what the socket already holds, but never without a bound:
			# a peer that keeps sending must not be able to own this thread.
			nDrained = 0
			while nDrained < 64 and self.lSocketOpen and self.receiveOnce()
				nDrained = nDrained + 1
			end
			self.checkPartialDeadline()
			if len(self.aEvents) > 0 or cvxNowMs() >= nDeadline
				return
			ok
			cvxWaitMs(5)
		end

	# Read whatever libcurl already holds. Returns true when a frame was
	# consumed, so the caller knows the socket is still producing.
	func receiveOnce
		aResult = curl_ws_recv(self.oSocket, CONVEX_WS_CHUNK_BYTES)
		nCode = aResult[1]
		if nCode = CONVEX_CURLE_AGAIN
			return false
		ok
		if nCode = CONVEX_CURLE_GOT_NOTHING
			self.retire("TransportError: the Live peer closed the connection", true)
			return true
		ok
		if nCode != CONVEX_CURLE_OK
			self.retire("TransportError: the Live receive failed with libcurl code " +
				cvxIntText(nCode), true)
			return true
		ok
		aMeta = aResult[4]
		if len(aMeta) < 5
			self.retire("ProtocolError: a Live frame arrived without metadata", true)
			return true
		ok
		nFlags = aMeta[2]
		nBytesLeft = aMeta[4]
		cChunk = aResult[2]
		if self.hasFlag(nFlags, CURLWS_CLOSE)
			self.retire("TransportError: the Live peer sent a close frame", true)
			return true
		ok
		if self.hasFlag(nFlags, CURLWS_PING) or self.hasFlag(nFlags, CURLWS_PONG)
			# libcurl answers a ping itself. Control traffic must not disturb a
			# data message that is still being reassembled.
			return true
		ok
		if self.hasFlag(nFlags, CURLWS_BINARY)
			self.retire("ProtocolError: binary Live data is unsupported", true)
			return true
		ok
		if len(self.cPending) + len(cChunk) > CONVEX_MAX_MESSAGE_BYTES
			self.retire("ProtocolError: a Live message exceeded the client byte budget", true)
			return true
		ok
		if len(self.cPending) = 0 and len(cChunk) > 0
			self.nPendingSince = cvxNowMs()
		ok
		self.cPending = self.cPending + cChunk
		if nBytesLeft > 0
			# The frame is still arriving. The bytes consumed so far are kept
			# exactly, so a later read resumes instead of restarting at a false
			# frame boundary.
			return true
		ok
		if self.hasFlag(nFlags, CURLWS_CONT)
			# Not the final frame of a fragmented message.
			return true
		ok
		cMessage = self.cPending
		self.cPending = ""
		self.nPendingSince = 0
		try
			self.handleMessage(cMessage)
		catch
			aClassified = cvxClassify(cCatchError)
			self.retire(aClassified[1] + ": " + aClassified[2], true)
		done
		return true

	func checkPartialDeadline
		if self.nPendingSince = 0
			return
		ok
		if cvxNowMs() - self.nPendingSince < CONVEX_PARTIAL_MESSAGE_MS
			return
		ok
		self.retire("TransportError: a partial Live message passed its deadline", true)

	func hasFlag nFlags, nBit
		if nBit = 0
			return false
		ok
		return (floor(nFlags / nBit) % 2) = 1

	# -------------------------------------------------------------------
	# The transition decoder
	# -------------------------------------------------------------------

	func handleMessage cRaw
		cType = cvxJsonStringField(cvxJsonField(cRaw, "type", true), "the Live message type")
		if cType = "Ping" or cType = "MutationResponse" or cType = "ActionResponse"
			return
		ok
		if cType = "TransitionChunk"
			cvxRaiseProtocol("TransitionChunk is not implemented")
		ok
		if cType = "FatalError" or cType = "AuthError"
			cDetail = cvxJsonField(cRaw, "error", false)
			if cDetail = ""
				cDetail = cvxJsonQuote(cType)
			ok
			cvxRaiseProtocol(cType + " " + cDetail)
		ok
		if cType != "Transition"
			cvxRaiseProtocol("unsupported Live message " + cType)
		ok
		cStart = self.normalizeVersion(cvxJsonField(cRaw, "startVersion", true))
		if cStart != self.cRemote
			cvxRaiseProtocol("the transition start version did not match")
		ok
		cEnd = self.normalizeVersion(cvxJsonField(cRaw, "endVersion", true))

		# Validate every modification before anything is published. A malformed
		# field rolls the whole transition back, so a partially applied version
		# can never be observed.
		aPending = []
		for cModification in cvxJsonElements(cvxJsonField(cRaw, "modifications", true))
			nQueryId = cvxJsonUint32(cvxJsonField(cModification, "queryId", false),
				"the Live queryId")
			cKind = cvxJsonStringField(cvxJsonField(cModification, "type", true),
				"the Live modification type")
			aItem = []
			if cKind = "QueryUpdated"
				cLogs = cvxJsonField(cModification, "logLines", false)
				if cLogs = ""
					cLogs = "[]"
				ok
				aItem = ["value", cvxJsonField(cModification, "value", true), cLogs, ""]
			but cKind = "QueryFailed"
				cMessage = cvxJsonStringField(cvxJsonField(cModification, "errorMessage", false),
					"QueryFailed.errorMessage")
				cLogs = cvxJsonField(cModification, "logLines", false)
				if cLogs = ""
					cLogs = "[]"
				ok
				aItem = ["error", cMessage, cLogs,
					cvxJsonField(cModification, "errorData", false)]
			but cKind != "QueryRemoved"
				cvxRaiseProtocol("unsupported Live modification " + cKind)
			ok
			if len(aItem) > 0 and self.findSubscription(nQueryId) > 0
				# Several changes to one query inside a single transition
				# collapse to the newest, so no consumer ever observes an
				# intermediate transaction state.
				aPending = self.replacePending(aPending, nQueryId, aItem)
			ok
		next

		cTimestamp = cvxJsonStringField(cvxJsonField(cEnd, "ts", true), "the state version ts")
		lNewer = self.cMaxTimestamp = ""
		if not lNewer
			lNewer = strcmp(cvxTimestampKey(cTimestamp),
				cvxTimestampKey(self.cMaxTimestamp)) > 0
		ok
		if lNewer
			self.cMaxTimestamp = cTimestamp
		ok
		self.cRemote = cEnd
		for aEntry in aPending
			self.publish(aEntry[1], aEntry[2])
		next

	func replacePending aPending, nQueryId, aItem
		for nIndex = 1 to len(aPending)
			if aPending[nIndex][1] = nQueryId
				aPending[nIndex][2] = aItem
				return aPending
			ok
		next
		add(aPending, [nQueryId, aItem])
		return aPending

	# Rebuild the canonical state version from validated fields. Comparing the
	# rebuilt text means a quoted or oversized counter can never enter the
	# client's state through a lookalike token.
	func normalizeVersion cRaw
		nQuerySet = cvxJsonUint32(cvxJsonField(cRaw, "querySet", false),
			"the state version querySet")
		nIdentity = cvxJsonUint32(cvxJsonField(cRaw, "identity", false),
			"the state version identity")
		cTimestamp = cvxJsonStringField(cvxJsonField(cRaw, "ts", true),
			"the state version ts")
		cvxTimestampKey(cTimestamp)
		return cvxJsonObject([["querySet", cvxIntText(nQuerySet)],
			["identity", cvxIntText(nIdentity)], ["ts", cvxJsonQuote(cTimestamp)]])

	# -------------------------------------------------------------------
	# Publication
	# -------------------------------------------------------------------

	func publish nQueryId, aItem
		if aItem[1] = "value"
			self.publishValue(nQueryId, aItem[2], aItem[3])
		else
			self.publishError(nQueryId, "FunctionError", aItem[2], aItem[4], aItem[3])
		ok

	# An unchanged rehydration after a reconnect is suppressed. That is what
	# keeps the reconnect sequence exactly initial value, acknowledgement,
	# external mutation, new value.
	func publishValue nQueryId, cValue, cLogs
		nPosition = self.findSubscription(nQueryId)
		if nPosition = 0
			return
		ok
		cSignature = "value" + CVX_UNIT + cValue + CVX_UNIT + cLogs
		if self.aSubscriptions[nPosition][4] = cSignature
			return
		ok
		self.aSubscriptions[nPosition][4] = cSignature
		self.enqueue([nQueryId, "value", cValue, cLogs, "", "", ""])

	func publishError nQueryId, cName, cMessage, cData, cLogs
		nPosition = self.findSubscription(nQueryId)
		if nPosition = 0
			return
		ok
		# A failure always reaches the consumer, and it clears the suppression
		# signature so the repaired value is published even when it is identical
		# to the value seen before the failure.
		self.aSubscriptions[nPosition][4] = ""
		self.enqueue([nQueryId, "error", "", cLogs, cName, cMessage, cData])

	# retire()'s connection-level broadcast uses this instead of publishError.
	# The failure still always reaches the consumer, but the signature is left
	# alone: a reconnect follows, and the Add it replays is expected to
	# rehydrate this same value, which the ordinary unchanged-rehydration
	# suppression in publishValue must still catch.
	func publishConnectionError nQueryId, cName, cMessage
		if self.findSubscription(nQueryId) = 0
			return
		ok
		self.enqueue([nQueryId, "error", "", "[]", cName, cMessage, ""])

	# The bounded delivery queue. A slow consumer loses the oldest deliveries
	# rather than letting the client's memory follow the server's update rate.
	func enqueue aEvent
		nCost = 256
		for nIndex = 3 to len(aEvent)
			nCost = nCost + len(aEvent[nIndex])
		next
		while self.overQueueBound(nCost)
			if len(self.aEvents) = 0
				self.nDroppedEvents = self.nDroppedEvents + 1
				return
			ok
			self.nQueuedBytes = self.nQueuedBytes - self.aEvents[1][8]
			del(self.aEvents, 1)
			self.nDroppedEvents = self.nDroppedEvents + 1
		end
		add(aEvent, nCost)
		add(self.aEvents, aEvent)
		self.nQueuedBytes = self.nQueuedBytes + nCost

	func overQueueBound nCost
		if len(self.aEvents) >= CONVEX_MAX_QUEUED_EVENTS
			return true
		ok
		return self.nQueuedBytes + nCost > CONVEX_MAX_QUEUED_BYTES

	func dropQueued nQueryId
		aRetained = []
		nBytes = 0
		for aEvent in self.aEvents
			if aEvent[1] != nQueryId
				add(aRetained, aEvent)
				nBytes = nBytes + aEvent[8]
			ok
		next
		self.aEvents = aRetained
		self.nQueuedBytes = nBytes

	# Take the oldest pending delivery, or an empty list when nothing is queued.
	func nextEvent
		if len(self.aEvents) = 0
			return []
		ok
		aEvent = self.aEvents[1]
		self.nQueuedBytes = self.nQueuedBytes - aEvent[8]
		del(self.aEvents, 1)
		return aEvent

	func pendingEvents
		return len(self.aEvents)

	func queuedBytes
		return self.nQueuedBytes

	func droppedEvents
		return self.nDroppedEvents

	func connectionCount
		return self.nConnectionCount

	func lastCloseReason
		return self.cLastCloseReason

	func maxObservedTimestamp
		return self.cMaxTimestamp

	func isConnected
		return self.lSocketOpen

	func reconnectArmed
		return self.lReconnectArmed

	func subscriptionCount
		return len(self.aSubscriptions)

	func querySetVersion
		return self.nQuerySet

	func remoteVersion
		return self.cRemote
