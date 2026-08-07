/*
 * Small C support functions for CONVEX_SOCKET and CONVEX_POLL.
 *
 * EiffelStudio's own "C inline" feature bodies get bundled together with
 * many other classes' generated code into one large translation unit
 * ("big_file") once a project has enough classes, and that bundling step
 * has proven unreliable for a handful of sizeable inline bodies in this
 * project's toolchain (25.02.9.8732): the C compiler reports the last
 * bundled class's functions as redeclared with conflicting linkage. Moving
 * the actual logic into an ordinary, separately compiled C translation
 * unit and declaring plain (non-inline) externals for it sidesteps that
 * bundling path entirely, which is the same "normal HTTP, TLS" C-interop
 * allowance every native client in this project already relies on (see
 * fortran/client/curl_transport.c for the same pattern).
 */
#ifndef CONVEX_NATIVE_H
#define CONVEX_NATIVE_H

/* Complete a TLS client handshake over the already-connected socket
 * `fd', sending `hostname' as SNI and verifying the peer certificate
 * against the system trust store for that name. Returns the OpenSSL
 * `SSL *' handle, or NULL on failure (see convex_tls_last_error). */
void *convex_tls_connect(int fd, const char *hostname);

/* The most recent OpenSSL error-queue entry, rendered as text. Call
 * immediately after a failing TLS operation. */
const char *convex_tls_last_error(void);

int convex_tls_write(void *ssl, const void *data, int count);
int convex_tls_read(void *ssl, void *buffer, int max);
int convex_tls_pending(void *ssl);
void convex_tls_close(void *ssl);

int convex_raw_write(int fd, const void *data, int count);
int convex_raw_read(int fd, void *buffer, int max);

/* Plain POSIX read(2)/write(2), unlike convex_raw_read/write above which
 * call send(2)/recv(2) and therefore require an actual socket. The
 * adapter's control stream is stdin/stdout (ordinary pipes or a terminal)
 * unless ADAPTER_LISTEN is set, so it needs the descriptor-agnostic form;
 * a socket happens to work fine through read(2)/write(2) too, so the
 * accepted-TCP-connection case can share the same two functions. */
int convex_generic_write(int fd, const void *data, int count);
int convex_generic_read(int fd, void *buffer, int max);

/* 1 if `fd' is readable before `timeout_ms' elapses, else 0. */
int convex_select_one(int fd, int timeout_ms);

/* Bit 1 set if `fd_one' is readable, bit 2 set if `fd_two' is readable,
 * within `timeout_ms'. Pass -1 for a descriptor that should not be
 * watched. */
int convex_select_two(int fd_one, int fd_two, int timeout_ms);

/* A seed that varies across processes and over time (getpid() folded
 * together with the current time), used only to build a syntactically
 * valid, practically non-colliding sync-protocol session id. Nothing in
 * this project's threat model needs this to be cryptographically random:
 * the server treats a session id as an opaque, self-chosen conversation
 * label, not a credential. */
unsigned int convex_random_seed(void);

/* Writing to a socket after the peer has already closed its end raises
 * SIGPIPE, whose default disposition kills the whole process outright
 * (this is also true of send(2) on a peer-reset TCP connection, which a
 * transient real network path -- as opposed to a stable localhost
 * connection -- makes far more likely to actually happen in practice).
 * Call this once at startup so a broken pipe instead surfaces as an
 * ordinary EPIPE return from write/send, exactly like any other
 * transport error this client already handles. */
void convex_ignore_sigpipe(void);

#endif
