definition module Convex.WebSocket

// A hand-written RFC 6455 WebSocket client layer: the HTTP Upgrade
// handshake, masked frame encode, and unmasked frame decode with
// fragmentation and control-frame support, over `Convex.Transport`. Clean's
// distribution has no WebSocket implementation, so this is written directly
// against the transport abstraction, matching this project's other native
// clients (see `hare/client/ws.ha`). SHA-1 and Base64, both needed only for
// the handshake's Sec-WebSocket-Accept check, are the distribution's own
// `Crypto.Hash.SHA1` and `Text.Encodings.Base64` — ordinary libraries, not
// Convex-specific behaviour.

from Convex.Result import :: Result
from Convex.Transport import :: Transport
from Convex.Deadline import :: Deadline
from StdMaybe import :: Maybe

:: WsOpcode = WsContinuation | WsText | WsBinary | WsClose | WsPing | WsPong

:: WsMessage = {wsOpcode :: !WsOpcode, wsPayload :: !String}

// A WebSocket connection is a `Transport` plus whatever bytes have already
// been read off it but not yet consumed as a frame — carried explicitly
// because the handshake's own header read can, in principle, pull in the
// first bytes of the next frame in the same underlying `recv`/`SSL_read`.
:: WsConn = {wcTransport :: !Transport, wcPending :: !String}

// Performs the HTTP/1.1 Upgrade handshake for one WebSocket connection.
// `path` is the request target (Convex's sync endpoint is `/api/sync`).
wsHandshake :: !Transport !String !String ![(String, String)] !Deadline !*World -> (!Result WsConn, !*World)

// Writes one complete, masked WebSocket frame (client-to-server frames must
// be masked per RFC 6455 5.3). `payload` is not fragmented by this client:
// Convex's own sync messages are small enough that single-frame messages
// suffice, matching the pinned sync profile this client targets.
wsWriteFrame :: !Transport !WsOpcode !String !Deadline !*World -> (!Result (), !*World)

// Reads one logical WebSocket message, transparently reassembling
// continuation frames and transparently answering an interleaved Ping with
// a Pong (Convex sends Pings as a liveness probe; this client always
// answers them itself rather than surfacing them to the caller). A Close
// frame is returned to the caller as-is so the owner can log the peer's
// stated reason. A completed Text message's payload is validated as
// well-formed UTF-8 once fully reassembled, per RFC 6455 8.1.
wsReadMessage :: !WsConn !Deadline !*World -> (!Result (!WsMessage, !WsConn), !*World)

wsClose :: !WsConn !*World -> *World

// --- exposed only for WebSocketTest.icl's language-local unit coverage ---
// (frame I/O and the handshake itself need a real peer; these pure pieces
// don't, so this is where a network-free unit test can actually reach in).

opcodeByte :: !WsOpcode -> Int
byteToOpcode :: !Int -> Maybe WsOpcode
lengthBytes :: !Int -> String
maskPayload :: !String !String -> String
isValidUtf8 :: !String -> Bool
computeAcceptKey :: !String -> String

// Also reused by Convex.Live for its session-ID UUID.
randomBytesStr :: !Int !*World -> (!String, !*World)
