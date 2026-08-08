/-
Foreign declarations for `shim/convex_shim.c`.

This is the only place the Lean client leaves the language. Everything below
this module -- HTTP, RFC 6455, the Convex sync profile, deadlines, and every
bound -- is ordinary Lean code.
-/

namespace Convex.Ffi

/-- A socket, optionally wrapped in TLS. Freed by the shim's finalizer if a
caller forgets, but every path in this client closes it explicitly. -/
private opaque ConnPointed : NonemptyType

def Conn : Type := ConnPointed.type

instance : Nonempty Conn := ConnPointed.property

/-- `poll` uses this to mean "there is no descriptor in this slot". -/
def noDescriptor : UInt32 := 0xFFFFFFFF

/-- Monotonic milliseconds. Every deadline in the client is an absolute value
on this clock, so a slow peer cannot extend a bound by trickling bytes. -/
@[extern "convex_shim_now_ms"]
opaque nowMs : IO UInt64

@[extern "convex_shim_random_bytes"]
opaque randomBytes (count : UInt32) : IO ByteArray

@[extern "convex_shim_sha1"]
opaque sha1 (data : ByteArray) : IO ByteArray

@[extern "convex_shim_set_nonblocking"]
opaque setNonblocking (fd : UInt32) : IO Unit

/-- Shrink a socket's kernel send and receive buffers to a fixed size. Only a
test fixture needs this, to make "nobody reads this socket" backpressure
scenarios deterministic instead of depending on the host's autotuned TCP
buffer sizes. -/
@[extern "convex_shim_set_socket_buffer_size"]
opaque setSocketBufferSize (fd : UInt32) (bytes : UInt32) : IO Unit

/-- Poll at most three descriptors. In each `events` argument bit 0 requests
readability and bit 1 requests writability. Each slot owns three result bits --
readable, writable, error -- starting at bit `3 * slot`. -/
@[extern "convex_shim_poll"]
opaque poll (fd0 : UInt32) (events0 : UInt32) (fd1 : UInt32) (events1 : UInt32)
    (fd2 : UInt32) (events2 : UInt32) (timeoutMs : UInt32) : IO UInt32

/-- Readability, writability, and error bits for poll slot `slot`. -/
def pollReadable (slot : Nat) : UInt32 := (1 : UInt32) <<< UInt32.ofNat (slot * 3)
def pollWritable (slot : Nat) : UInt32 := (2 : UInt32) <<< UInt32.ofNat (slot * 3)
def pollFailed (slot : Nat) : UInt32 := (4 : UInt32) <<< UInt32.ofNat (slot * 3)

def wantRead : UInt32 := 1
def wantWrite : UInt32 := 2
def wantReadWrite : UInt32 := 3
def wantNothing : UInt32 := 0

/-- `none` is end of stream. `some` with no bytes means "not ready yet". -/
@[extern "convex_shim_read_fd"]
opaque readFd (fd : UInt32) (limit : UInt32) : IO (Option ByteArray)

/-- Returns the number of bytes accepted, which is zero when the reader has
stopped. The caller keeps the remainder and its own byte accounting. -/
@[extern "convex_shim_write_fd"]
opaque writeFd (fd : UInt32) (data : ByteArray) (offset : UInt32) : IO UInt32

/-- Connect, and when `tls` is set complete a verified TLS handshake against
`verifyHost`. An empty `caFile` uses the system trust store. -/
@[extern "convex_shim_connect"]
opaque connect (host : String) (port : UInt32) (tls : Bool) (verifyHost : String)
    (caFile : String) (deadline : UInt64) : IO Conn

@[extern "convex_shim_conn_fd"]
opaque connFd (conn : Conn) : IO UInt32

/-- A TLS record may already hold another message, so descriptor readiness is
not the whole answer. -/
@[extern "convex_shim_conn_pending"]
opaque connPending (conn : Conn) : IO Bool

@[extern "convex_shim_conn_eof"]
opaque connEof (conn : Conn) : IO Bool

@[extern "convex_shim_conn_read"]
opaque connRead (conn : Conn) (limit : UInt32) (deadline : UInt64) : IO (Option ByteArray)

@[extern "convex_shim_conn_read_available"]
opaque connReadAvailable (conn : Conn) (limit : UInt32) : IO (Option ByteArray)

@[extern "convex_shim_conn_write"]
opaque connWrite (conn : Conn) (data : ByteArray) (deadline : UInt64) : IO Unit

@[extern "convex_shim_conn_close"]
opaque connClose (conn : Conn) : IO Unit

@[extern "convex_shim_conn_shutdown_write"]
opaque connShutdownWrite (conn : Conn) : IO Unit

@[extern "convex_shim_listen"]
opaque listen (host : String) (port : UInt32) : IO Conn

@[extern "convex_shim_listen_port"]
opaque listenPort (conn : Conn) : IO UInt32

@[extern "convex_shim_accept"]
opaque accept (conn : Conn) (deadline : UInt64) : IO Conn

@[extern "convex_shim_server_handshake"]
opaque serverHandshake (conn : Conn) (certificate : String) (key : String)
    (deadline : UInt64) : IO Unit

end Convex.Ffi
