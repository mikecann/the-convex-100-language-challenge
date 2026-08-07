(*
** convex_transport: the byte-transport boundary.
**
** ATS has no HTTP, TLS, or WebSocket library, so this is the delegated-
** library equivalent every other native client in this project reaches
** for. It is plain C, reached through ATS's foreign-language interface --
** the natural FFI route for a language that itself compiles through C,
** the same role a socket/TLS/WebSocket package plays for every other
** native client here. Nothing here knows about Convex; convex.dats
** supplies that.
**
** This module is deliberately NOT where this client's dependent-typing
** claim lives: growable receive buffers (an HTTP body, a WebSocket frame)
** are malloc'd and realloc'd in C and cross into ATS only once fully
** assembled, as a `string`, because giving every intermediate realloc a
** dependent size proof is a materially bigger undertaking than this
** client's scope affords honestly. The real claim is in convex.dats: the
** safe-integer decode that turns a Convex JSON number into a Mercury-safe
** ATS int is a refinement-typed function that cannot return a value
** outside the proven range, and the sync protocol's version/queryId
** arithmetic is typed as `nat` throughout, so a negative version number
** is a compile error in the caller, not a runtime possibility guarded by
** a check someone could forget.
*)

typedef sslconn = ptr  (* opaque ConvexTls* handle *)

(* status codes shared with the C shim *)
#define TLS_OK 0
#define TLS_ERR 1

fun tls_open(host: string, port: int, use_tls: bool): (sslconn, int, string)
  (* returns (conn, status, errmsg); conn is only valid when status = TLS_OK *)

fun tls_close(conn: sslconn): void
fun tls_fd(conn: sslconn): int

fun tls_write(conn: sslconn, text: string): (int, string)  (* status, errmsg *)

(* status, httpStatus, body, errmsg *)
fun tls_read_http_response(conn: sslconn): (int, int, string, string)

fun ws_handshake(conn: sslconn, host: string, path: string): (int, string)
fun ws_send_text(conn: sslconn, text: string): (int, string)

#define WS_TIMEOUT 0
#define WS_TEXT 1
#define WS_PEER_CLOSED 2
#define WS_ERROR 3

(* kind, text-or-error *)
fun ws_recv(conn: sslconn, timeout_ms: int): (int, string)

fun tcp_listen(address: string, port: int): (int, int, string)  (* status, fd, errmsg *)
fun tcp_accept(listen_fd: int): (int, int, string)              (* status, fd, errmsg *)

#define LINE_OK 0
#define LINE_EOF 1
#define LINE_ERROR 2

fun read_line(fd: int): (int, string)   (* kind, line-or-errmsg *)
fun write_line(fd: int, text: string): int  (* 0 on success *)

#define POLL_NONE 0
#define POLL_CONTROL 1
#define POLL_LIVE 2
#define POLL_BOTH 3

fun poll_control(control_fd: int, live_fd: int, timeout_ms: int): int
  (* live_fd < 0 means "no live connection" *)

fun base64_decode_ts8(encoded: string): (bool, lint)  (* ok, little-endian value *)
fun random_hex(nbytes: int): string
