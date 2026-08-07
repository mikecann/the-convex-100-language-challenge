/*
 * Reviewed native extension for the educational COBOL Convex client.
 *
 * Scope rule: this file exposes only operating-system and cryptographic
 * primitives that the GnuCOBOL runtime cannot express safely on its own --
 * a monotonic clock, a CSPRNG, a SHA-1 digest, and deadline-aware stream
 * I/O over TCP and TLS. It contains no HTTP parsing, no WebSocket framing,
 * no JSON, and no Convex protocol knowledge. Every one of those layers is
 * implemented in COBOL under client/.
 *
 * Linkage: COBOL reaches these entry points through literal CALL names
 * compiled with cobc -fstatic-call, which emits a direct C call using the
 * literal spelling. Every name below must therefore stay lowercase and must
 * match the CALL literal in the COBOL sources exactly.
 *
 * Status codes and buffer bounds are mirrored for COBOL in cvx-limits.cpy.
 * The two files are a single contract; changing a value in one without the
 * other silently changes what the COBOL layer believes a return code means.
 */

#ifndef CONVEX_NATIVE_H
#define CONVEX_NATIVE_H

/* Status codes shared with COBOL through client/cvx-limits.cpy. */
#define CVX_OK 0
#define CVX_ERR (-1)
#define CVX_TIMEOUT (-2)
#define CVX_EOF (-3)
#define CVX_TLS (-4)
#define CVX_HANDLE (-5)
#define CVX_LIMIT (-6)
/* No bytes were available on a non-blocking stream, but the peer is still
 * connected. Distinct from CVX_TIMEOUT so the adapter loop can keep pumping
 * without treating an empty poll as a deadline breach. */
#define CVX_AGAIN (-7)

/* Maximum simultaneously open transport handles. One Live socket, one HTTP
 * socket, one controller socket, and headroom for deterministic tests.
 * cvx_net_open and cvx_net_register_fd return CVX_LIMIT once the table is
 * full; neither ever grows it. */
#define CVX_MAX_HANDLES 16

/* Milliseconds since an unspecified monotonic origin. Deadlines in this
 * client are absolute values on this clock, never per-call durations. */
int cvx_now_ms(long long *out_ms);

/* Cryptographically secure random bytes. Used for WebSocket masking keys,
 * the Sec-WebSocket-Key nonce, and session identifiers. */
int cvx_random_bytes(unsigned char *out, int len);

/* Raw SHA-1 digest of len bytes into a 20-byte buffer. Only needed for the
 * RFC 6455 Sec-WebSocket-Accept check; the base64 wrapping around it and the
 * comparison itself are done in COBOL. */
int cvx_sha1(const unsigned char *in, int len, unsigned char *out20);

/* Open a TCP (secure == 0) or TLS (secure == 1) stream to host:port and
 * return a handle, or a negative status.
 *
 * For secure == 1 the peer chain is verified against the default trust store
 * and the certificate identity is matched against the same host string used
 * to connect, which is also sent as the SNI name. Connection host and
 * verified host are deliberately not separable: a split would let a caller
 * verify a name it never dialled. */
int cvx_net_open(const char *host, int host_len, int port, int secure,
                 long long deadline_ms);

/* Adopt an already-connected file descriptor as a transport handle. Used for
 * the accepted ADAPTER_LISTEN controller socket and by the fixture harness.
 * Returns CVX_LIMIT when the handle table is full. */
int cvx_net_register_fd(int fd);

/* Read up to cap bytes, returning the count in *got. Returns CVX_TIMEOUT with
 * *got == 0 when the absolute deadline passes with nothing buffered, and
 * CVX_EOF at a clean peer close. Never blocks past deadline_ms. */
int cvx_net_read(int handle, unsigned char *out, int cap,
                 long long deadline_ms, int *got);

/* Write exactly len bytes or fail. *sent always reports how many bytes
 * reached the peer, so a caller can retire a connection that was left in a
 * partially written state rather than resuming mid-message. */
int cvx_net_write(int handle, const unsigned char *in, int len,
                  long long deadline_ms, int *sent);

/* 1 when the handle can yield at least one byte without blocking, 0 on
 * timeout.
 *
 * For a TLS handle this MUST consult the decrypted-record buffer before it
 * polls the socket. OpenSSL routinely decrypts a whole record into its own
 * buffer, leaving the file descriptor with nothing readable while a complete
 * WebSocket frame is already in hand. A poll-only implementation reports 0
 * forever and stalls the single-threaded COBOL Live owner. */
int cvx_net_readable(int handle, int timeout_ms);

/* Send a TLS close_notify (or shut down the write side of a plain socket)
 * and wait for the peer acknowledgement until deadline_ms. Kept separate
 * from cvx_net_close so the Live owner can retire a socket abruptly on a
 * fault path without paying for a graceful handshake. */
int cvx_net_shutdown(int handle, long long deadline_ms);

/* Release the handle and its file descriptor. Always succeeds for a live
 * handle; returns CVX_HANDLE for one that was never open. */
int cvx_net_close(int handle);

/* Last errno or OpenSSL error text for the handle, for diagnostics only. */
int cvx_net_error(int handle, char *out, int cap, int *len);

/* Poll file descriptor 0 (adapter stdin) for readability. */
int cvx_std_readable(int timeout_ms);

/* Read from file descriptor 0. Returns CVX_EOF at end of input and CVX_AGAIN
 * when the descriptor is non-blocking and momentarily empty. */
int cvx_std_read(unsigned char *out, int cap, int *got);

/* Write exactly len bytes to fd 1 or 2; any other descriptor is rejected
 * with CVX_ERR so this cannot become a general-purpose write primitive.
 * Retries short writes, so the adapter never splits a protocol event. */
int cvx_std_write(int fd, const unsigned char *in, int len);

/* Bind host:port, accept exactly one controller connection, close the
 * listener, and return the accepted connection as a transport handle. */
int cvx_listen_accept(const char *hostport, int len, long long deadline_ms);

/* Resident-set size of this process in bytes. /proc/self/statm reports its
 * resident field in pages, so an implementation must scale it by
 * sysconf(_SC_PAGESIZE); returning the raw field understates memory by the
 * page size and would make the accounting test pass for the wrong reason.
 * The adapter memory-accounting test asserts against the shared 128 MiB
 * limit with a stopped reader, so it needs a real measurement. */
int cvx_rss_bytes(long long *out_bytes);

#endif /* CONVEX_NATIVE_H */
