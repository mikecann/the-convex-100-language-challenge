definition module Convex.Transport

// A transport is either a plain TCP socket (a local `http://` backend, used
// in development and by this project's own local conformance target) or a
// TLS connection (a hosted `https://` deployment). HTTP framing, the
// WebSocket handshake and frames, and the Convex sync protocol above this
// layer are all written once against this one small interface instead of
// being duplicated per scheme, mirroring this project's other native
// clients (see `hare/client/transport.ha`).

from Convex.Result import :: Result
from Convex.TLS import :: TlsConn
from Convex.Deadline import :: Deadline

:: Transport = TPlain !Int | TTls !TlsConn

// Resolves and connects, performing the TLS handshake when `tls` is True.
// Bounded by `d`.
connectTransport :: !Bool !String !Int !Deadline !*World -> (!Result Transport, !*World)

transportFd :: !Transport -> Int

// Reads at most `maxLen` bytes, waiting for the socket to become readable
// (respecting the remaining time on `d`) before each plain-socket `recv`.
// Returns `ROk ""` at end of stream, matching `Convex.Socket.recvRaw`.
transportRead :: !Transport !Int !Deadline !*World -> (!Result String, !*World)

transportWriteAll :: !Transport !String !Deadline !*World -> (!Result Int, !*World)

transportClose :: !Transport !*World -> *World
