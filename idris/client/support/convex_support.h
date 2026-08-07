/*
 * Ordinary transport glue for the educational Idris 2 Convex client.
 *
 * Idris 2's RefC backend produces a native executable with no interpreter, but
 * it has no socket, poll, or TLS bindings of its own. This header is the entire
 * boundary the Idris code crosses: monotonic time, randomness, byte buffers,
 * TCP, poll, and OpenSSL byte transport. Every Convex behaviour -- HTTP
 * envelopes, WebSocket framing, the pinned sync protocol, JSON -- lives in
 * Idris, not here.
 *
 * The whole surface uses only int64_t and char* so that the prototypes RefC
 * generates for `%foreign "C:..."` cannot disagree with these definitions.
 * Pointers are never handed to Idris; buffers, streams, and sockets are opaque
 * non-negative integer handles owned by this translation unit.
 */

#ifndef CONVEX_SUPPORT_H
#define CONVEX_SUPPORT_H

#include <stdint.h>

/* Poll interest and readiness bits shared with the Idris event loop. */
#define CONVEX_POLL_READ 1
#define CONVEX_POLL_WRITE 2
#define CONVEX_POLL_ERROR 4

/* convex_stream_read / convex_stream_write status codes. */
#define CONVEX_IO_EOF 0
#define CONVEX_IO_WANT_READ (-1)
#define CONVEX_IO_WANT_WRITE (-2)
#define CONVEX_IO_ERROR (-3)

/* Install the process-wide settings the client depends on, most importantly
 * ignoring SIGPIPE so a stopped reader surfaces as EPIPE instead of a signal.
 * Safe to call more than once. */
int64_t convex_init(void);

/* Milliseconds from an arbitrary fixed origin. Absolute deadlines are computed
 * from this once per operation, so a dribbling peer cannot extend them. */
int64_t convex_now_ms(void);

/* Cryptographically strong bytes for WebSocket masking keys and handshake
 * nonces. Returns 0 on success and -1 when the system source failed. */
int64_t convex_random_bytes(int64_t buffer, int64_t offset, int64_t length);

/* Byte buffers. Idris never sees the address, only the handle. */
int64_t convex_buf_new(int64_t capacity);
int64_t convex_buf_free(int64_t buffer);
int64_t convex_buf_capacity(int64_t buffer);
int64_t convex_buf_get(int64_t buffer, int64_t index);
int64_t convex_buf_set(int64_t buffer, int64_t index, int64_t value);
int64_t convex_buf_copy(int64_t destination, int64_t destination_offset,
                        int64_t source, int64_t source_offset, int64_t length);

/* UTF-8 bridging. convex_text_size measures the encoded length before a write.
 * convex_buf_take_text yields the empty string for invalid UTF-8, an embedded
 * NUL, or a bad range, so callers check convex_buf_valid_utf8 first and treat a
 * decoding failure as a protocol error rather than a mangled value. */
int64_t convex_text_size(char *text);
int64_t convex_buf_put_text(int64_t buffer, int64_t offset, char *text);
char *convex_buf_take_text(int64_t buffer, int64_t offset, int64_t length);
int64_t convex_buf_valid_utf8(int64_t buffer, int64_t offset, int64_t length);

/* TCP. The connect deadline is absolute wall time in convex_now_ms units. */
int64_t convex_tcp_connect(char *host, int64_t port, int64_t deadline_ms);
int64_t convex_tcp_listen(char *host, int64_t port);
int64_t convex_tcp_port(int64_t fd);
int64_t convex_tcp_accept(int64_t fd, int64_t deadline_ms);
int64_t convex_set_nonblocking(int64_t fd);
/* Redirect a descriptor. Test fixtures use it to put an accepted socket on
 * stdin and stdout so the adapter's stdio transport is exercised for real. */
int64_t convex_dup2(int64_t from_fd, int64_t to_fd);
int64_t convex_close_fd(int64_t fd);
int64_t convex_shutdown_write(int64_t fd);

/* A reusable poll set. The Idris owner loop rebuilds it every iteration, so a
 * retired socket can never be waited on by accident. */
int64_t convex_pollset_reset(void);
int64_t convex_pollset_add(int64_t fd, int64_t interest);
int64_t convex_pollset_wait(int64_t timeout_ms);
int64_t convex_pollset_ready(int64_t fd);

/* Streams carry bytes over a plain socket or an OpenSSL connection. */
int64_t convex_stream_plain(int64_t fd);
int64_t convex_stream_tls_client(int64_t fd, char *hostname, char *ca_file);
int64_t convex_stream_tls_server(int64_t fd, char *certificate_file, char *key_file);
int64_t convex_stream_handshake(int64_t stream);
int64_t convex_stream_read(int64_t stream, int64_t buffer, int64_t offset, int64_t length);
int64_t convex_stream_write(int64_t stream, int64_t buffer, int64_t offset, int64_t length);
int64_t convex_stream_pending(int64_t stream);
int64_t convex_stream_shutdown(int64_t stream);
int64_t convex_stream_fd(int64_t stream);
int64_t convex_stream_free(int64_t stream);

/* Raw descriptor transport for stdin, stdout, and accepted controller sockets.
 * The adapter never uses buffered stdio, so its output deadline is real. */
int64_t convex_fd_read(int64_t fd, int64_t buffer, int64_t offset, int64_t length);
int64_t convex_fd_write(int64_t fd, int64_t buffer, int64_t offset, int64_t length);
int64_t convex_write_stderr(char *text);

/* The last failure recorded by this translation unit, for diagnostics only. */
char *convex_last_error(void);

/* Deterministic fixtures run a real peer in a forked child rather than a mock,
 * so the client exercises genuine sockets. These are used by tests only. */
int64_t convex_fork(void);
int64_t convex_waitpid(int64_t pid, int64_t deadline_ms);
int64_t convex_kill(int64_t pid);
int64_t convex_exit(int64_t code);

/* Idris 2's own RefC-generated code calls idris2_setenv (implemented in the
 * shipped idris_support.c) for System.setEnv, which the adapter test uses to
 * set up its own environment. The support library that ships alongside that
 * implementation, idris_support.h, does not itself declare the function, so
 * compiling with -Werror=implicit-function-declaration (which the RefC
 * backend's own build already does) fails on any use of System.setEnv,
 * independent of anything in this file. Since convex-cc's -include forces
 * this header into every translation unit RefC compiles, it is the
 * convenient place to supply the missing prototype rather than patching the
 * installed toolchain. The real implementation still comes from
 * libidris2_support at link time; this only satisfies the compiler. */
extern int idris2_setenv(const char *name, const char *value, int overwrite);

#endif /* CONVEX_SUPPORT_H */
