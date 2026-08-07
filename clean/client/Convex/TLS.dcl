definition module Convex.TLS

// A thin TLS wrapper over OpenSSL's `libssl`, reached through Clean's
// `ccall` C FFI — the one place this client crosses out of Clean, for
// exactly the same reason every other native client in this project
// reaches TLS through its own language's C interop. Everything
// Convex-specific (HTTP framing, WebSocket framing, and the sync protocol)
// stays in Clean.
//
// `TlsConn` itself is an ordinary (not `*`-forced) record: this client's
// genuine uniqueness-typing story lives in `Convex.Mem` (every byte read or
// write around a `ccall` is threaded through `*World`, which is what
// actually keeps the OpenSSL and socket FFI boundary safe — see that
// module's comment) and in `Convex.Live`'s connection state. Threading a
// forced-unique record through a retry loop that also projects its fields
// with `.` selection ran into uniqueness coercion errors that cost more
// debugging time than the extra safety was worth for a 3-field record
// (`ssl`, `ctx`, `fd`) that is never aliased in practice; every function
// here still takes and returns `*World` so real ordering against OpenSSL's
// own effects is enforced by the type checker regardless.

from Convex.Result import :: Result

:: TlsConn = { ctx :: Int, ssl :: Int, fd :: Int }

// Wraps an already-connected, blocking TCP file descriptor in a TLS session
// and performs the handshake, verifying the peer certificate against the
// system CA bundle and the given hostname (SNI and certificate hostname
// verification both use it).
tlsConnect :: !Int !String !*World -> (!Result TlsConn, !*World)

tlsRead :: !TlsConn !Int !*World -> (!Result String, !*World)
tlsWriteAll :: !TlsConn !String !*World -> (!Result Int, !*World)
tlsFd :: !TlsConn -> Int
tlsClose :: !TlsConn !*World -> *World
