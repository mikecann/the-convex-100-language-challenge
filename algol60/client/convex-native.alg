comment convex-native.alg - ALGOL 60 headings for the C transport boundary.
   Standard ALGOL 60 has no sockets, no TLS, no monotonic clock, no entropy
   source, no environment access and no process exit status. Each procedure
   below is a code procedure - its heading is ordinary ALGOL 60, but its
   body is implemented in client slash convexrt dot c and linked in
   natively. Every other file under client slash is pure ALGOL 60 and calls
   only these fourteen primitives to reach outside the language - HTTP
   slash 1 dot 1, JSON, RFC 6455 WebSocket framing and the Convex slash api
   slash sync state machine are all ALGOL 60.
   Byte buffers are passed as integer array, one element per byte from 0
   to 255, because ALGOL 60 has no byte or character array type. cap and
   length parameters describe how many elements of that array are in
   play, and the callee never reads or writes outside them.
   Two sentinel results are shared with convexrt dot c - negative one
   means the stream is open but not ready yet, try again later - negative
   two means the stream is unusable and must be closed;

integer procedure cxopen(host, hostlen, port, portlen, tls, deadlinems);
   comment opens a TCP stream to host colon port, optionally wrapped in a
   verified TLS session, before an absolute monotonic deadline given in
   milliseconds. Returns a handle, or negative two on failure;
   value hostlen, portlen, tls, deadlinems;
   integer array host;
   integer array port;
   integer hostlen, portlen, tls, deadlinems;
code;

integer procedure cxadopt(fd);
   comment adopts an already open file descriptor, zero for stdin or one
   for stdout, as a non-blocking handle in the same table as cxopen;
   value fd;
   integer fd;
code;

integer procedure cxlisten(host, hostlen, port, portlen);
   comment opens a non-blocking listening socket bound to host colon port;
   value hostlen, portlen;
   integer array host;
   integer array port;
   integer hostlen, portlen;
code;

integer procedure cxaccept(handle, timeoutms);
   comment accepts one pending connection on a listening handle, waiting
   up to timeoutms. Returns negative one if none arrived in time;
   value handle, timeoutms;
   integer handle, timeoutms;
code;

integer procedure cxread(handle, buf, cap);
   comment reads at most cap bytes into buf, starting at buf of zero.
   Returns the byte count, zero at end of stream, negative one if
   nothing is ready yet;
   value handle, cap;
   integer array buf;
   integer handle, cap;
code;

integer procedure cxwrite(handle, buf, offset, length);
   comment writes length bytes from buf, starting at buf of offset.
   Returns the accepted byte count, which may be less than length, or
   negative one if the stream is not ready to accept any bytes right now;
   value handle, offset, length;
   integer array buf;
   integer handle, offset, length;
code;

integer procedure cxpoll(h0, w0, h1, w1, h2, w2, timeoutms);
   comment waits up to timeoutms for up to three handles to become
   ready. Each want flag is zero for readable or one for writable, and a
   handle of negative one is ignored. Returns a bit mask - bit zero for
   the first handle, bit one for the second, bit two for the third;
   value h0, w0, h1, w1, h2, w2, timeoutms;
   integer h0, w0, h1, w1, h2, w2, timeoutms;
code;

integer procedure cxnowms;
   comment a monotonic millisecond clock, relative to an arbitrary epoch;
code;

integer procedure cxerrtext(buf, cap);
   comment writes the last transport error message into buf as bytes,
   truncated to cap. Returns the byte count written;
   value cap;
   integer array buf;
   integer cap;
code;

integer procedure cxclose(handle);
   comment closes a handle opened by cxopen, cxadopt, cxlisten or
   cxaccept. Closing an already closed handle is harmless;
   value handle;
   integer handle;
code;

integer procedure cxexit(exitcode);
   comment flushes output and terminates the process with the given exit
   status. ALGOL 60 has no other portable way to set it;
   value exitcode;
   integer exitcode;
code;

integer procedure cxrandom(buf, n);
   comment fills the first n elements of buf with cryptographically
   random bytes. Used only for the Live session id;
   value n;
   integer array buf;
   integer n;
code;

integer procedure cxstrbytes(s, buf, cap);
   comment the one primitive that touches a genuine ALGOL 60 string
   value rather than only a byte buffer. ALGOL 60 has no operation that
   reads a string apart from passing it on, so this copies the bytes of
   a quoted string literal, or a formal string parameter that ultimately
   traces back to one, into buf. Every bound and every byte of protocol
   text built from the result stays visible in ALGOL 60 source -- this
   primitive only bridges the missing string-to-bytes step. Returns the
   byte count written, truncated to cap;
   value cap;
   string s;
   integer array buf;
   integer cap;
code;

integer procedure cxgetenv(name, namelen, buf, cap);
   comment reads an environment variable named by the first namelen
   bytes of name into buf, truncated to cap. Returns negative one if the
   variable is unset, otherwise the byte count written, which is zero
   for a variable set to the empty string;
   value namelen, cap;
   integer array name;
   integer array buf;
   integer namelen, cap;
code;
