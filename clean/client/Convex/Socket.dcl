definition module Convex.Socket

// A minimal raw TCP socket layer reached directly through Clean's `ccall`
// foreign-function mechanism (the same mechanism the Clean distribution's
// own `System.Socket` library uses under the hood, in
// `data/Platform/System/_Socket.icl`). This client writes its own thin
// binding rather than that library so it can hold the raw file descriptor
// itself, which `System.Socket`'s abstract `Socket` type does not expose,
// and which the TLS layer needs to hand to OpenSSL's `SSL_set_fd`.
//
// DNS resolution goes through `getaddrinfo` with `ai_family` pinned to
// `AF_INET`: Docker's default bridge network has IPv6 disabled, so letting
// glibc's usual dual-stack ordering hand back an IPv6 address first would
// connect to nothing.

from Convex.Result import :: Result

// Resolves `host` and connects a blocking TCP socket to `host:port`.
// Returns the raw file descriptor on success.
connectTcp :: !String !Int !*World -> (!Result Int, !*World)

sendRaw :: !Int !String !*World -> (!Result Int, !*World)
recvRaw :: !Int !Int !*World -> (!Result String, !*World)
closeRaw :: !Int !*World -> *World

// Waits up to `timeoutMs` for `fd` to become readable (`forWrite = False`)
// or writable (`forWrite = True`). `ROk True` means ready, `ROk False` means
// the timeout elapsed with nothing ready.
pollReady :: !Int !Bool !Int !*World -> (!Result Bool, !*World)
