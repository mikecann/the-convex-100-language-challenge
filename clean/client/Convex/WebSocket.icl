implementation module Convex.WebSocket

import StdEnv
import StdMaybe
from System._Pointer import :: Pointer
import Convex.Result
import Convex.Mem
import Convex.Transport
import Convex.Deadline
import Convex.HTTP
import Crypto.Hash.SHA1
import Text.Encodings.Base64

// Only this module's own `RAND_bytes` ccall (the WebSocket key and every
// frame mask) needs libcrypto directly; Convex.TLS links libssl (and
// libcrypto transitively through it) for the record layer instead.
import code from library "-lcrypto"

wsGuid :: String
wsGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

maxWsMessage :: Int
maxWsMessage = 2 * 1024 * 1024

// --- randomness ------------------------------------------------------------

RAND_bytes :: !Pointer !Int !*World -> (!Int, !*World)
RAND_bytes buf n w = code {
	ccall RAND_bytes "pI:I:A"
}

bytesToStringW :: !Pointer !Int !*World -> (!String, !*World)
bytesToStringW p n w
	# (chars, w) = walk 0 w
	= ({c \\ c <- chars}, w)
where
	walk i w
		| i == n = ([], w)
		# (b, w) = readByteW p i w
		# (rest, w) = walk (i + 1) w
		= ([toChar b : rest], w)

// RFC 6455 does not require cryptographically secure randomness for the
// handshake key or a frame mask, only that it be effectively unpredictable
// to a caching intermediary; OpenSSL's own CSPRNG (already linked for TLS
// elsewhere in this client) is a convenient, more-than-sufficient source.
// A `RAND_bytes` failure is vanishingly rare on a runtime that has already
// completed a real TLS handshake, so — matching this project's other native
// clients' treatment of their own random-byte source as infallible — this
// does not thread a `Result`.
randomBytesStr :: !Int !*World -> (!String, !*World)
randomBytesStr n w
	# (buf, w) = mallocW n w
	# (_, w) = RAND_bytes buf n w
	# (s, w) = bytesToStringW buf n w
	# w = freeW buf w
	= (s, w)

// --- handshake ---------------------------------------------------------

computeAcceptKey :: !String -> String
computeAcceptKey key
	# (SHA1Digest raw) = sha1StringDigest (key +++ wsGuid)
	= base64Encode raw

buildHandshakeRequest :: !String !String !String ![(String, String)] -> String
buildHandshakeRequest path host key extraHeaders =
	"GET " +++ path +++ " HTTP/1.1\r\n" +++
	"Host: " +++ host +++ "\r\n" +++
	"Upgrade: websocket\r\n" +++
	"Connection: Upgrade\r\n" +++
	"Sec-WebSocket-Key: " +++ key +++ "\r\n" +++
	"Sec-WebSocket-Version: 13\r\n" +++
	extraHeaderLines extraHeaders +++
	"\r\n"
where
	extraHeaderLines [] = ""
	extraHeaderLines [(k, v) : rest] = k +++ ": " +++ v +++ "\r\n" +++ extraHeaderLines rest

wsHandshake :: !Transport !String !String ![(String, String)] !Deadline !*World -> (!Result WsConn, !*World)
wsHandshake t host path extraHeaders d w
	# (keyRaw, w) = randomBytesStr 16 w
	# key = base64Encode keyRaw
	# request = buildHandshakeRequest path host key extraHeaders
	# (sent, w) = transportWriteAll t request d w
	= case sent of
		RErr e = (RErr e, w)
		ROk _ = afterSend t key d w

afterSend :: !Transport !String !Deadline !*World -> (!Result WsConn, !*World)
afterSend t key d w
	# (headersResult, w) = readHeaders t "" d w
	= case headersResult of
		RErr e = (RErr e, w)
		ROk (headerText, leftover) = validateHandshake t key headerText leftover w

validateHandshake :: !Transport !String !String !String !*World -> (!Result WsConn, !*World)
validateHandshake t key headerText leftover w = case parseStatusLine headerText of
	Nothing = (RErr "malformed WebSocket handshake status line", w)
	Just 101 = checkAccept t key headerText leftover w
	Just statusCode = (RErr ("deployment did not upgrade the connection to a WebSocket (status " +++ toString statusCode +++ ")"), w)

checkAccept :: !Transport !String !String !String !*World -> (!Result WsConn, !*World)
checkAccept t key headerText leftover w = case headerValue headerText "sec-websocket-accept" of
	Nothing = (RErr "WebSocket handshake response had no Sec-WebSocket-Accept header", w)
	Just accept
		| trimStr accept == computeAcceptKey key = (ROk {wcTransport = t, wcPending = leftover}, w)
		= (RErr "WebSocket handshake accept key did not match", w)

// --- frame encode --------------------------------------------------------

opcodeByte :: !WsOpcode -> Int
opcodeByte WsContinuation = 0x0
opcodeByte WsText = 0x1
opcodeByte WsBinary = 0x2
opcodeByte WsClose = 0x8
opcodeByte WsPing = 0x9
opcodeByte WsPong = 0xa

byteToOpcode :: !Int -> Maybe WsOpcode
byteToOpcode 0x0 = Just WsContinuation
byteToOpcode 0x1 = Just WsText
byteToOpcode 0x2 = Just WsBinary
byteToOpcode 0x8 = Just WsClose
byteToOpcode 0x9 = Just WsPing
byteToOpcode 0xa = Just WsPong
byteToOpcode _ = Nothing

byteAtBE :: !Int !Int -> Int
byteAtBE n i = (n >> (i * 8)) bitand 255

lengthBytes :: !Int -> String
lengthBytes n
	| n <= 125 = {toChar (0x80 bitor n)}
	| n <= 65535 = {toChar (0x80 bitor 126)} +++ {toChar (byteAtBE n 1), toChar (byteAtBE n 0)}
	= {toChar (0x80 bitor 127)} +++ {toChar (byteAtBE n i) \\ i <- [7, 6 .. 0]}

maskPayload :: !String !String -> String
maskPayload payload mask = {toChar (toInt payload.[i] bitxor toInt mask.[i - (i / 4) * 4]) \\ i <- [0 .. size payload - 1]}

wsWriteFrame :: !Transport !WsOpcode !String !Deadline !*World -> (!Result (), !*World)
wsWriteFrame t opcode payload d w
	# (mask, w) = randomBytesStr 4 w
	# header = {toChar (0x80 bitor opcodeByte opcode)} +++ lengthBytes (size payload) +++ mask
	# framed = if (size payload == 0) header (header +++ maskPayload payload mask)
	# (sent, w) = transportWriteAll t framed d w
	= case sent of
		RErr e = (RErr e, w)
		ROk _ = (ROk (), w)

// --- frame decode --------------------------------------------------------

:: RawFrame = {rfFin :: !Bool, rfOpcode :: !WsOpcode, rfPayload :: !String, rfPending :: !String}

readExactWs :: !Transport !String !Int !Deadline !*World -> (!Result (!String, !String), !*World)
readExactWs t pending n d w
	| size pending >= n = (ROk (pending % (0, n - 1), pending % (n, size pending - 1)), w)
	# (r, w) = transportRead t 4096 d w
	= case r of
		RErr e = (RErr e, w)
		ROk "" = (RErr "connection closed mid-frame", w)
		ROk chunk = readExactWs t (pending +++ chunk) n d w

be16 :: !String -> Int
be16 s = (toInt s.[0] << 8) bitor toInt s.[1]

be64 :: !String -> Int
be64 s = fold 0 0
where
	fold i acc
		| i == 8 = acc
		= fold (i + 1) ((acc << 8) bitor toInt s.[i])

readOneFrame :: !Transport !String !Deadline !*World -> (!Result RawFrame, !*World)
readOneFrame t pending d w
	# (headResult, w) = readExactWs t pending 2 d w
	= case headResult of
		RErr e = (RErr e, w)
		ROk (head, pending2) = afterHead t head pending2 d w

afterHead :: !Transport !String !String !Deadline !*World -> (!Result RawFrame, !*World)
afterHead t head pending2 d w
	# b0 = toInt head.[0]
	# b1 = toInt head.[1]
	# fin = (b0 bitand 0x80) <> 0
	# opByte = b0 bitand 0x0f
	# masked = (b1 bitand 0x80) <> 0
	# plenBits = b1 bitand 0x7f
	| masked = (RErr "server frame was unexpectedly masked", w)
	= case byteToOpcode opByte of
		Nothing = (RErr "unknown WebSocket opcode", w)
		Just opcode = resolveLength t fin opcode plenBits pending2 d w

resolveLength :: !Transport !Bool !WsOpcode !Int !String !Deadline !*World -> (!Result RawFrame, !*World)
resolveLength t fin opcode plenBits pending2 d w
	| plenBits == 126
		# (extResult, w) = readExactWs t pending2 2 d w
		= case extResult of
			RErr e = (RErr e, w)
			ROk (ext, pending3) = withLength t fin opcode (be16 ext) pending3 d w
	| plenBits == 127
		# (extResult, w) = readExactWs t pending2 8 d w
		= case extResult of
			RErr e = (RErr e, w)
			ROk (ext, pending3) = withLength t fin opcode (be64 ext) pending3 d w
	= withLength t fin opcode plenBits pending2 d w

withLength :: !Transport !Bool !WsOpcode !Int !String !Deadline !*World -> (!Result RawFrame, !*World)
withLength t fin opcode plen pending3 d w
	| plen > maxWsMessage = (RErr "WebSocket frame exceeded the maximum size", w)
	# (payloadResult, w) = readExactWs t pending3 plen d w
	= case payloadResult of
		RErr e = (RErr e, w)
		ROk (payload, pending4) = (ROk {rfFin = fin, rfOpcode = opcode, rfPayload = payload, rfPending = pending4}, w)

// --- message reassembly --------------------------------------------------

firstOpcode :: !WsOpcode -> WsOpcode
firstOpcode WsContinuation = WsText
firstOpcode other = other

// A pragmatic UTF-8 well-formedness check: every leading byte's declared
// sequence length must be followed by exactly that many `10xxxxxx`
// continuation bytes. This rejects truncated and structurally malformed
// sequences (the overwhelming majority of real malformed input) but, unlike
// a full RFC 3629 validator, does not additionally reject overlong
// encodings, surrogate code points, or codepoints above U+10FFFF — a
// deliberate scope cut given how much of this client is still unbuilt.
isValidUtf8 :: !String -> Bool
isValidUtf8 s = go 0
where
	n = size s
	go i
		| i >= n = True
		# b0 = toInt s.[i]
		| b0 < 0x80 = go (i + 1)
		| b0 >= 0xC2 && b0 <= 0xDF = checkContinuation i 1
		| b0 >= 0xE0 && b0 <= 0xEF = checkContinuation i 2
		| b0 >= 0xF0 && b0 <= 0xF4 = checkContinuation i 3
		= False

	checkContinuation i extra
		| i + extra >= n = False
		| and [isContinuationByte s.[i + 1 + k] \\ k <- [0 .. extra - 1]] = go (i + extra + 1)
		= False

	isContinuationByte c = (toInt c bitand 0xC0) == 0x80

validateIfText :: !WsOpcode !String -> Result ()
validateIfText WsText payload
	| isValidUtf8 payload = ROk ()
	= RErr "WebSocket text message was not valid UTF-8"
validateIfText _ _ = ROk ()

wsReadMessage :: !WsConn !Deadline !*World -> (!Result (!WsMessage, !WsConn), !*World)
wsReadMessage conn d w = loop conn.wcTransport conn.wcPending "" WsText False d w

loop :: !Transport !String !String !WsOpcode !Bool !Deadline !*World -> (!Result (!WsMessage, !WsConn), !*World)
loop t pending acc finalOpcode assembling d w
	# (frameResult, w) = readOneFrame t pending d w
	= case frameResult of
		RErr e = (RErr e, w)
		ROk frame = handleFrame t frame acc finalOpcode assembling d w

handleFrame :: !Transport !RawFrame !String !WsOpcode !Bool !Deadline !*World -> (!Result (!WsMessage, !WsConn), !*World)
handleFrame t frame acc finalOpcode assembling d w = case frame.rfOpcode of
	WsPing = afterPingSent t frame acc finalOpcode assembling d w
	WsPong = loop t frame.rfPending acc finalOpcode assembling d w
	WsClose = (ROk ({wsOpcode = WsClose, wsPayload = frame.rfPayload}, {wcTransport = t, wcPending = frame.rfPending}), w)
	_ = continueAssembly t frame acc finalOpcode assembling d w

afterPingSent :: !Transport !RawFrame !String !WsOpcode !Bool !Deadline !*World -> (!Result (!WsMessage, !WsConn), !*World)
afterPingSent t frame acc finalOpcode assembling d w
	# (sendResult, w) = wsWriteFrame t WsPong frame.rfPayload d w
	= case sendResult of
		RErr e = (RErr e, w)
		ROk _ = loop t frame.rfPending acc finalOpcode assembling d w

continueAssembly :: !Transport !RawFrame !String !WsOpcode !Bool !Deadline !*World -> (!Result (!WsMessage, !WsConn), !*World)
continueAssembly t frame acc finalOpcode assembling d w
	# newFinal = if assembling finalOpcode (firstOpcode frame.rfOpcode)
	# newAcc = acc +++ frame.rfPayload
	| size newAcc > maxWsMessage = (RErr "WebSocket message exceeded the maximum size", w)
	| frame.rfFin = finish t newFinal newAcc frame.rfPending w
	= loop t frame.rfPending newAcc newFinal True d w

finish :: !Transport !WsOpcode !String !String !*World -> (!Result (!WsMessage, !WsConn), !*World)
finish t finalOpcode payload pending w = case validateIfText finalOpcode payload of
	RErr e = (RErr e, w)
	ROk _ = (ROk ({wsOpcode = finalOpcode, wsPayload = payload}, {wcTransport = t, wcPending = pending}), w)

wsClose :: !WsConn !*World -> *World
wsClose conn w = transportClose conn.wcTransport w
