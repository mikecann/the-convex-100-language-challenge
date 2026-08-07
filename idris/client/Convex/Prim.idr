||| Raw bindings to the transport shim in `client/support/convex_support.c`.
|||
||| Every declaration crosses the FFI with `Int` and `String` only. Idris2's
||| RefC backend only knows how to marshal a handful of foreign types --
||| notably `Int` (which it maps to a 64-bit `int64_t`), not the sized `Int64`
||| type -- so `Int` is what every primitive below uses, matching the 64-bit
||| integers `convex_support.c` already expects. Nothing Convex-specific
||| belongs in this module.
module Convex.Prim

%foreign "C:convex_init,libconvexsupport"
prim__init : PrimIO Int

%foreign "C:convex_now_ms,libconvexsupport"
prim__nowMs : PrimIO Int

%foreign "C:convex_random_bytes,libconvexsupport"
prim__randomBytes : Int -> Int -> Int -> PrimIO Int

%foreign "C:convex_buf_new,libconvexsupport"
prim__bufNew : Int -> PrimIO Int

%foreign "C:convex_buf_free,libconvexsupport"
prim__bufFree : Int -> PrimIO Int

%foreign "C:convex_buf_capacity,libconvexsupport"
prim__bufCapacity : Int -> PrimIO Int

%foreign "C:convex_buf_get,libconvexsupport"
prim__bufGet : Int -> Int -> PrimIO Int

%foreign "C:convex_buf_set,libconvexsupport"
prim__bufSet : Int -> Int -> Int -> PrimIO Int

%foreign "C:convex_buf_copy,libconvexsupport"
prim__bufCopy : Int -> Int -> Int -> Int -> Int -> PrimIO Int

%foreign "C:convex_text_size,libconvexsupport"
prim__textSize : String -> PrimIO Int

%foreign "C:convex_buf_put_text,libconvexsupport"
prim__bufPutText : Int -> Int -> String -> PrimIO Int

%foreign "C:convex_buf_take_text,libconvexsupport"
prim__bufTakeText : Int -> Int -> Int -> PrimIO String

%foreign "C:convex_buf_valid_utf8,libconvexsupport"
prim__bufValidUtf8 : Int -> Int -> Int -> PrimIO Int

%foreign "C:convex_tcp_connect,libconvexsupport"
prim__tcpConnect : String -> Int -> Int -> PrimIO Int

%foreign "C:convex_tcp_listen,libconvexsupport"
prim__tcpListen : String -> Int -> PrimIO Int

%foreign "C:convex_tcp_port,libconvexsupport"
prim__tcpPort : Int -> PrimIO Int

%foreign "C:convex_tcp_accept,libconvexsupport"
prim__tcpAccept : Int -> Int -> PrimIO Int

%foreign "C:convex_set_nonblocking,libconvexsupport"
prim__setNonBlocking : Int -> PrimIO Int

%foreign "C:convex_dup2,libconvexsupport"
prim__dup2 : Int -> Int -> PrimIO Int

%foreign "C:convex_close_fd,libconvexsupport"
prim__closeFd : Int -> PrimIO Int

%foreign "C:convex_shutdown_write,libconvexsupport"
prim__shutdownWrite : Int -> PrimIO Int

%foreign "C:convex_pollset_reset,libconvexsupport"
prim__pollsetReset : PrimIO Int

%foreign "C:convex_pollset_add,libconvexsupport"
prim__pollsetAdd : Int -> Int -> PrimIO Int

%foreign "C:convex_pollset_wait,libconvexsupport"
prim__pollsetWait : Int -> PrimIO Int

%foreign "C:convex_pollset_ready,libconvexsupport"
prim__pollsetReady : Int -> PrimIO Int

%foreign "C:convex_stream_plain,libconvexsupport"
prim__streamPlain : Int -> PrimIO Int

%foreign "C:convex_stream_tls_client,libconvexsupport"
prim__streamTlsClient : Int -> String -> String -> PrimIO Int

%foreign "C:convex_stream_tls_server,libconvexsupport"
prim__streamTlsServer : Int -> String -> String -> PrimIO Int

%foreign "C:convex_stream_handshake,libconvexsupport"
prim__streamHandshake : Int -> PrimIO Int

%foreign "C:convex_stream_read,libconvexsupport"
prim__streamRead : Int -> Int -> Int -> Int -> PrimIO Int

%foreign "C:convex_stream_write,libconvexsupport"
prim__streamWrite : Int -> Int -> Int -> Int -> PrimIO Int

%foreign "C:convex_stream_pending,libconvexsupport"
prim__streamPending : Int -> PrimIO Int

%foreign "C:convex_stream_shutdown,libconvexsupport"
prim__streamShutdown : Int -> PrimIO Int

%foreign "C:convex_stream_fd,libconvexsupport"
prim__streamFd : Int -> PrimIO Int

%foreign "C:convex_stream_free,libconvexsupport"
prim__streamFree : Int -> PrimIO Int

%foreign "C:convex_fd_read,libconvexsupport"
prim__fdRead : Int -> Int -> Int -> Int -> PrimIO Int

%foreign "C:convex_fd_write,libconvexsupport"
prim__fdWrite : Int -> Int -> Int -> Int -> PrimIO Int

%foreign "C:convex_write_stderr,libconvexsupport"
prim__writeStderr : String -> PrimIO Int

%foreign "C:convex_last_error,libconvexsupport"
prim__lastError : PrimIO String

%foreign "C:convex_fork,libconvexsupport"
prim__fork : PrimIO Int

%foreign "C:convex_waitpid,libconvexsupport"
prim__waitpid : Int -> Int -> PrimIO Int

%foreign "C:convex_kill,libconvexsupport"
prim__kill : Int -> PrimIO Int

%foreign "C:convex_exit,libconvexsupport"
prim__exit : Int -> PrimIO Int

||| A poll interest or readiness bit meaning "readable".
public export
pollRead : Int
pollRead = 1

||| A poll interest or readiness bit meaning "writable".
public export
pollWrite : Int
pollWrite = 2

||| A readiness bit meaning the peer hung up or the descriptor is invalid.
public export
pollError : Int
pollError = 4

||| Stream and descriptor read results below zero are non-fatal retry hints.
public export
ioWantRead : Int
ioWantRead = -1

public export
ioWantWrite : Int
ioWantWrite = -2

public export
ioFailed : Int
ioFailed = -3

||| Ignore SIGPIPE and prepare OpenSSL. Called once from every entry point.
export
initialise : HasIO io => io ()
initialise = ignore $ primIO prim__init

||| Monotonic milliseconds. Deadlines are computed from this exactly once so a
||| peer that dribbles bytes cannot keep pushing the deadline forward.
export
nowMs : HasIO io => io Int
nowMs = primIO prim__nowMs

||| The most recent failure the shim recorded, for stderr diagnostics only.
export
lastError : HasIO io => io String
lastError = primIO prim__lastError

export
randomBytes : HasIO io => Int -> Int -> Int -> io Int
randomBytes buffer offset length =
  primIO (prim__randomBytes buffer offset length)

export
bufNew : HasIO io => Int -> io Int
bufNew capacity = primIO (prim__bufNew capacity)

export
bufFree : HasIO io => Int -> io ()
bufFree buffer = ignore $ primIO (prim__bufFree buffer)

export
bufCapacity : HasIO io => Int -> io Int
bufCapacity buffer = primIO (prim__bufCapacity buffer)

export
bufGet : HasIO io => Int -> Int -> io Int
bufGet buffer index = primIO (prim__bufGet buffer index)

export
bufSet : HasIO io => Int -> Int -> Int -> io Int
bufSet buffer index value =
  primIO (prim__bufSet buffer index value)

export
bufCopy : HasIO io => Int -> Int -> Int -> Int -> Int -> io Int
bufCopy destination destinationOffset source sourceOffset length =
  primIO (prim__bufCopy destination destinationOffset source sourceOffset length)

||| The encoded UTF-8 length of a string, which is what the wire needs rather
||| than its character count.
export
textSize : HasIO io => String -> io Int
textSize text = primIO (prim__textSize text)

export
bufPutText : HasIO io => Int -> Int -> String -> io Int
bufPutText buffer offset text =
  primIO (prim__bufPutText buffer offset text)

export
bufValidUtf8 : HasIO io => Int -> Int -> Int -> io Bool
bufValidUtf8 buffer offset length =
  do result <- primIO (prim__bufValidUtf8 buffer offset length)
     pure (result == 0)

||| Decode a buffer slice. Returns `Nothing` for anything that is not clean
||| UTF-8 without embedded NULs, which the caller reports as a protocol error.
export
bufTakeText : HasIO io => Int -> Int -> Int -> io (Maybe String)
bufTakeText buffer offset length =
  do valid <- bufValidUtf8 buffer offset length
     if not valid
        then pure Nothing
        else do text <- primIO (prim__bufTakeText buffer offset length)
                pure (Just text)

export
tcpConnect : HasIO io => String -> Int -> Int -> io Int
tcpConnect host port deadline =
  primIO (prim__tcpConnect host port deadline)

export
tcpListen : HasIO io => String -> Int -> io Int
tcpListen host port = primIO (prim__tcpListen host port)

export
tcpPort : HasIO io => Int -> io Int
tcpPort fd = primIO (prim__tcpPort fd)

export
tcpAccept : HasIO io => Int -> Int -> io Int
tcpAccept fd deadline = primIO (prim__tcpAccept fd deadline)

export
setNonBlocking : HasIO io => Int -> io Int
setNonBlocking fd = primIO (prim__setNonBlocking fd)

||| Redirect one descriptor onto another. Only fixtures use this, to put an
||| accepted socket on stdin and stdout.
export
duplicateFd : HasIO io => Int -> Int -> io Int
duplicateFd fromFd toFd = primIO (prim__dup2 fromFd toFd)

export
closeFd : HasIO io => Int -> io ()
closeFd fd = ignore $ primIO (prim__closeFd fd)

export
shutdownWrite : HasIO io => Int -> io ()
shutdownWrite fd = ignore $ primIO (prim__shutdownWrite fd)

export
pollsetReset : HasIO io => io ()
pollsetReset = ignore $ primIO prim__pollsetReset

export
pollsetAdd : HasIO io => Int -> Int -> io ()
pollsetAdd fd interest =
  ignore $ primIO (prim__pollsetAdd fd interest)

export
pollsetWait : HasIO io => Int -> io Int
pollsetWait timeout = primIO (prim__pollsetWait timeout)

export
pollsetReady : HasIO io => Int -> io Int
pollsetReady fd = primIO (prim__pollsetReady fd)

export
streamPlain : HasIO io => Int -> io Int
streamPlain fd = primIO (prim__streamPlain fd)

export
streamTlsClient : HasIO io => Int -> String -> String -> io Int
streamTlsClient fd hostname caFile =
  primIO (prim__streamTlsClient fd hostname caFile)

export
streamTlsServer : HasIO io => Int -> String -> String -> io Int
streamTlsServer fd certificateFile keyFile =
  primIO (prim__streamTlsServer fd certificateFile keyFile)

||| 0 finished, 1 wants readability, 2 wants writability, negative failed.
export
streamHandshake : HasIO io => Int -> io Int
streamHandshake stream = primIO (prim__streamHandshake stream)

export
streamRead : HasIO io => Int -> Int -> Int -> Int -> io Int
streamRead stream buffer offset length =
  primIO (prim__streamRead stream buffer offset length)

export
streamWrite : HasIO io => Int -> Int -> Int -> Int -> io Int
streamWrite stream buffer offset length =
  primIO (prim__streamWrite stream buffer offset length)

||| Bytes OpenSSL has already decrypted. Without this a record that arrived in
||| the same TCP segment would sit unread while poll reports nothing to do.
export
streamPending : HasIO io => Int -> io Int
streamPending stream = primIO (prim__streamPending stream)

export
streamShutdown : HasIO io => Int -> io Int
streamShutdown stream = primIO (prim__streamShutdown stream)

export
streamFd : HasIO io => Int -> io Int
streamFd stream = primIO (prim__streamFd stream)

export
streamFree : HasIO io => Int -> io ()
streamFree stream = ignore $ primIO (prim__streamFree stream)

export
fdRead : HasIO io => Int -> Int -> Int -> Int -> io Int
fdRead fd buffer offset length =
  primIO (prim__fdRead fd buffer offset length)

export
fdWrite : HasIO io => Int -> Int -> Int -> Int -> io Int
fdWrite fd buffer offset length =
  primIO (prim__fdWrite fd buffer offset length)

||| Diagnostics never go to stdout, which belongs to the NDJSON protocol and to
||| the canonical example transcript.
export
writeStderr : HasIO io => String -> io ()
writeStderr text = ignore $ primIO (prim__writeStderr text)

export
forkProcess : HasIO io => io Int
forkProcess = primIO prim__fork

export
waitProcess : HasIO io => Int -> Int -> io Int
waitProcess pid deadline = primIO (prim__waitpid pid deadline)

export
killProcess : HasIO io => Int -> io ()
killProcess pid = ignore $ primIO (prim__kill pid)

||| Immediate `_exit`, used by forked fixture children so they never run the
||| parent's remaining test code or flush its buffers a second time.
export
exitNow : HasIO io => Int -> io ()
exitNow code = ignore $ primIO (prim__exit code)
