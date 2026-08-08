(* TlsShim - the only native code in the Modula-3 Convex client's transport.
   Modula-3's standard TCP/IP interfaces (TCP.i3, IP.i3) supply the plain
   socket; this narrow EXTERNAL boundary supplies exactly and only what the
   standard library does not: a TLS handshake with certificate AND hostname
   verification, layered over the file descriptor TCP already opened. *)
UNSAFE INTERFACE TlsShim;
FROM Ctypes IMPORT int, char_star;

(* Perform a TLS client handshake over an already-connected POSIX file
   descriptor "fd", verifying the peer certificate chain against the
   system trust store and the presented hostname "host" (a NUL-terminated
   C string). Returns an opaque handle on success, or NIL if the
   handshake or verification failed. *)
<*EXTERNAL "TlsShim__connect"*>
PROCEDURE Connect(fd: int; host: char_star): ADDRESS;

(* Read up to "len" bytes into "buf", waiting at most "timeoutMs"
   milliseconds for data to become available. Returns the number of
   bytes read (0 on a clean TLS close), -1 on timeout, -2 on error. *)
<*EXTERNAL "TlsShim__read"*>
PROCEDURE Read(h: ADDRESS; buf: ADDRESS; len: int; timeoutMs: int): int;

(* Write exactly "len" bytes from "buf". Returns the number of bytes
   written, or -2 on error. *)
<*EXTERNAL "TlsShim__write"*>
PROCEDURE Write(h: ADDRESS; buf: ADDRESS; len: int): int;

(* Close the TLS session and the underlying file descriptor. *)
<*EXTERNAL "TlsShim__close"*>
PROCEDURE Close(h: ADDRESS);

(* Fill "buf" with "len" cryptographically unpredictable bytes (OpenSSL's
   RAND_bytes), for WebSocket frame masking keys and the sync protocol's
   sessionId. Returns FALSE on the vanishingly rare entropy failure. *)
<*EXTERNAL "TlsShim__randomBytes"*>
PROCEDURE RandomBytes(buf: ADDRESS; len: int): int;

END TlsShim.
