(* ConvexTransport - one small interface unifying the two ways this
   client moves bytes: a plain connection through Modula-3's own
   standard-library TCP/IP sockets (the "tcp" package), and a TLS
   connection layered over the same kind of socket through the narrow
   OpenSSL EXTERNAL-procedure shim (TlsShim.i3/shim.c). HTTP and
   WebSocket framing above this interface never know which one they are
   using. *)
INTERFACE ConvexTransport;

TYPE T <: ROOT;

EXCEPTION Error(TEXT);

(* Resolve "host" and connect on "port". When "useTls" is set, perform a
   TLS handshake immediately (with certificate and hostname
   verification) before returning. *)
PROCEDURE Connect(host: TEXT; port: INTEGER; useTls: BOOLEAN): T RAISES {Error};

(* Read at least one byte (up to "maxBytes"), waiting at most
   "timeoutMs" milliseconds for data to arrive. Returns the bytes read,
   or "" (empty TEXT) on a clean peer close. Raises Error on a timeout
   or any transport failure -- callers that want to distinguish a
   timeout from a hard failure should catch Error and inspect its
   message, which always starts with "timeout:" for a timeout. *)
PROCEDURE Read(t: T; maxBytes: INTEGER; timeoutMs: INTEGER): TEXT RAISES {Error};

(* Write every byte of "data", blocking until all of it is sent or an
   error occurs. *)
PROCEDURE Write(t: T; data: TEXT) RAISES {Error};

PROCEDURE Close(t: T);

END ConvexTransport.
