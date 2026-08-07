%-----------------------------------------------------------------------------%
% convex_transport: the byte-transport boundary.
%
% Mercury ships no HTTP, TLS, or WebSocket library, so this module is the
% delegated-library equivalent every other native client in this project
% reaches for (Haskell uses http-client/websockets, Prolog uses SWI's
% library(http/websocket)): a small, hand-written C shim, reached through
% Mercury's foreign-language interface, that opens sockets, completes TLS
% handshakes with real certificate verification, and speaks raw HTTP/1.1 and
% RFC 6455 framing. It knows nothing about Convex. Every Convex-specific
% decision -- the sync protocol's message shapes, version validation,
% modification coalescing, the adapter's command dispatch -- lives in
% Mercury, in convex.m and the adapter, where determinism and mode
% declarations can say something real about it.
%
% The TLS connection is a genuine Mercury foreign type (`tls_conn`, wrapping
% an `SSL *`) rather than a bare integer handle, so the type checker rejects
% a socket fd passed where a TLS connection was expected.
%-----------------------------------------------------------------------------%
:- module convex_transport.
:- interface.

:- import_module io.

:- type tls_conn.

    % A connected, verified TLS 1.2+ connection to host:port. Verification
    % uses the system CA bundle and checks the peer certificate's hostname
    % against `Host`, exactly as a browser would.
:- pred tls_open(string::in, int::in, maybe_tls_conn::out, io::di, io::uo)
    is det.

:- type maybe_tls_conn
    --->    tls_ok(tls_conn)
    ;       tls_error(string).

:- pred tls_close(tls_conn::in, io::di, io::uo) is det.

    % Write the given text (already UTF-8, as every Mercury string is) in
    % full, or report the first transport failure.
:- pred tls_write(tls_conn::in, string::in, maybe_ok::out, io::di, io::uo)
    is det.

:- type maybe_ok
    --->    ok
    ;       transport_error(string).

    % Read one complete HTTP/1.1 response (status line, headers, body) and
    % return the decoded body. Handles both Content-Length and
    % chunked transfer-encoding bodies; the HTTP framing itself is
    % mechanical, not Convex-specific.
:- pred tls_read_http_response(tls_conn::in, maybe_http_response::out,
    io::di, io::uo) is det.

:- type maybe_http_response
    --->    http_response(int, string)     % status code, body
    ;       http_transport_error(string).

    % Perform the WebSocket opening handshake (the HTTP Upgrade request and
    % its validated 101 response, including the Sec-WebSocket-Accept check)
    % over an already-open TLS connection.
:- pred ws_handshake(tls_conn::in, string::in, string::in, maybe_ok::out,
    io::di, io::uo) is det.

    % Send one WebSocket text frame, masked as RFC 6455 requires of a
    % client.
:- pred ws_send_text(tls_conn::in, string::in, maybe_ok::out, io::di, io::uo)
    is det.

    % Wait up to TimeoutMs for one complete WebSocket message. Ping/Pong
    % control frames are answered and consumed internally without being
    % reported here, since they carry no Convex meaning.
:- pred ws_recv(tls_conn::in, int::in, ws_event::out, io::di, io::uo) is det.

:- type ws_event
    --->    ws_timeout
    ;       ws_text(string)
    ;       ws_peer_closed
    ;       ws_recv_error(string).

    % The raw file descriptor backing a TLS connection, for multiplexing
    % with poll_control below. Read-only: Mercury never touches the fd
    % directly, only hands it back to poll().
:- func tls_fd(tls_conn) = int.

    % --- Plain (non-TLS) descriptor operations, for the adapter's control
    % channel: stdin/stdout in the default mode, or the accepted TCP
    % connection when ADAPTER_LISTEN is set. ---

:- pred tcp_listen(string::in, int::in, maybe_fd::out, io::di, io::uo) is det.
:- pred tcp_accept(int::in, maybe_fd::out, io::di, io::uo) is det.

:- type maybe_fd
    --->    fd_ok(int)
    ;       fd_error(string).

    % Read one LF-terminated line (the trailing newline is stripped) from a
    % plain descriptor, buffering partial reads internally per fd so this
    % can be interleaved safely with poll_control.
:- pred read_line(int::in, line_event::out, io::di, io::uo) is det.

:- type line_event
    --->    line_ok(string)
    ;       line_eof
    ;       line_error(string).

:- pred write_line(int::in, string::in, maybe_ok::out, io::di, io::uo) is det.

    % Wait up to TimeoutMs for readability on the control fd and, if
    % present, the live TLS connection's fd. This is the adapter's entire
    % concurrency story: one reactor loop, one thread, no shared mutable
    % state to race on.
:- pred poll_control(int::in, maybe_tls_conn_fd::in, int::in,
    poll_result::out, io::di, io::uo) is det.

:- type maybe_tls_conn_fd
    --->    no_live_conn
    ;       live_conn(int).

:- type poll_result
    --->    poll_none
    ;       poll_control_ready
    ;       poll_live_ready
    ;       poll_both_ready.

    % --- Small primitives the sync protocol needs and Mercury has no
    % standard library support for. ---

    % Base64-encode arbitrary bytes held in a Mercury string (the string is
    % treated as a byte buffer of its own UTF-8 length; only ASCII-range
    % byte payloads -- hex digests and the like -- are ever passed here).
:- func base64_encode_bytes(string) = string.

    % Decode base64 text to raw bytes, failing on non-canonical or malformed
    % input. Convex's Live timestamps must round-trip exactly, so this is
    % strict rather than permissive.
    %
    % A Mercury `string` is a NUL-terminated C string, not a length-prefixed
    % byte buffer, so this must never be used where the decoded bytes may
    % contain an embedded zero byte (the all-zero initial Live timestamp
    % does exactly that) -- `base64_decode_ts8` below exists for that case.
:- pred base64_decode_strict(string::in, string::out) is semidet.

    % Decode exactly 8 canonical base64-encoded bytes -- the Live sync
    % protocol's `ts` field -- directly to the little-endian integer they
    % represent, without ever materialising the raw bytes as a Mercury
    % string (which would silently truncate at an embedded zero byte).
:- pred base64_decode_ts8(string::in, int::out) is semidet.

    % A random lowercase-hex string of the given byte length, used as the
    % sync protocol's per-connection sessionId.
:- pred random_hex(int::in, string::out, io::di, io::uo) is det.

:- implementation.

:- import_module int.
:- import_module require.
:- import_module string.

:- pragma foreign_decl("C", "
#define _GNU_SOURCE 1
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <netdb.h>
#include <poll.h>
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#include <openssl/evp.h>

/* One connected, verified TLS session plus the socket it owns. */
typedef struct ConvexTls {
    SSL_CTX *ctx;
    SSL *ssl;
    int fd;
} ConvexTls;

/* Per-fd line-buffering state for read_line/2. A handful of small fixed
   slots is enough: the adapter only ever reads from stdin or one accepted
   control connection at a time. */
#define CONVEX_LINE_SLOTS 8
#define CONVEX_LINE_BUF_CAP 1048576
typedef struct { int fd; char *buf; size_t len; size_t cap; int eof; } LineSlot;
static LineSlot convex_line_slots[CONVEX_LINE_SLOTS];
static int convex_line_slots_init = 0;

static LineSlot *convex_line_slot(int fd) {
    int i;
    if (!convex_line_slots_init) {
        for (i = 0; i < CONVEX_LINE_SLOTS; i++) convex_line_slots[i].fd = -1;
        convex_line_slots_init = 1;
    }
    for (i = 0; i < CONVEX_LINE_SLOTS; i++) {
        if (convex_line_slots[i].fd == fd) return &convex_line_slots[i];
    }
    for (i = 0; i < CONVEX_LINE_SLOTS; i++) {
        if (convex_line_slots[i].fd == -1) {
            convex_line_slots[i].fd = fd;
            convex_line_slots[i].cap = 4096;
            convex_line_slots[i].buf = malloc(convex_line_slots[i].cap);
            convex_line_slots[i].len = 0;
            convex_line_slots[i].eof = 0;
            return &convex_line_slots[i];
        }
    }
    return NULL; /* exhausted: the adapter never opens this many descriptors */
}

static char *convex_dup_mercury_string(const char *bytes, size_t len) {
    MR_Word tmp;
    MR_allocate_aligned_string_msg(tmp, (MR_Integer) len, MR_ALLOC_ID);
    memcpy((char *) tmp, bytes, len);
    ((char *) tmp)[len] = '\\0';
    return (char *) tmp;
}
").

%-----------------------------------------------------------------------------%
% TLS.
%-----------------------------------------------------------------------------%

:- pragma foreign_type("C", tls_conn, "ConvexTls *").

:- pragma foreign_proc("C",
    tls_open(Host::in, Port::in, Result::out, IO0::di, IO::uo),
    [will_not_call_mercury, promise_pure, tabled_for_io],
"
    struct addrinfo hints, *res = NULL, *rp;
    char portbuf[16];
    int sockfd = -1;
    char errbuf[256];
    errbuf[0] = '\\0';

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    snprintf(portbuf, sizeof(portbuf), \"%d\", (int) Port);

    if (getaddrinfo(Host, portbuf, &hints, &res) != 0) {
        Result = convex_transport_tls_error(\"DNS lookup failed\");
    } else {
        for (rp = res; rp != NULL; rp = rp->ai_next) {
            sockfd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
            if (sockfd < 0) continue;
            if (connect(sockfd, rp->ai_addr, rp->ai_addrlen) == 0) break;
            close(sockfd);
            sockfd = -1;
        }
        freeaddrinfo(res);
        if (sockfd < 0) {
            Result = convex_transport_tls_error(\"connect() failed\");
        } else {
            SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
            SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
            SSL_CTX_set_default_verify_paths(ctx);
            SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
            SSL *ssl = SSL_new(ctx);
            SSL_set_tlsext_host_name(ssl, Host);
            X509_VERIFY_PARAM *param = SSL_get0_param(ssl);
            X509_VERIFY_PARAM_set1_host(param, Host, 0);
            SSL_set_fd(ssl, sockfd);
            if (SSL_connect(ssl) != 1) {
                unsigned long code = ERR_get_error();
                ERR_error_string_n(code, errbuf, sizeof(errbuf));
                SSL_free(ssl);
                SSL_CTX_free(ctx);
                close(sockfd);
                Result = convex_transport_tls_error(
                    errbuf[0] ? errbuf : \"TLS handshake failed\");
            } else if (SSL_get_verify_result(ssl) != X509_V_OK) {
                SSL_shutdown(ssl);
                SSL_free(ssl);
                SSL_CTX_free(ctx);
                close(sockfd);
                Result = convex_transport_tls_error(
                    \"certificate verification failed\");
            } else {
                ConvexTls *conn = malloc(sizeof(ConvexTls));
                conn->ctx = ctx;
                conn->ssl = ssl;
                conn->fd = sockfd;
                Result = convex_transport_tls_ok(conn);
            }
        }
    }
    IO = IO0;
").

:- func convex_transport_tls_ok(tls_conn) = maybe_tls_conn.
:- pragma foreign_export("C", convex_transport_tls_ok(in) = out,
    "convex_transport_tls_ok").
convex_transport_tls_ok(Conn) = tls_ok(Conn).

:- func convex_transport_tls_error(string) = maybe_tls_conn.
:- pragma foreign_export("C", convex_transport_tls_error(in) = out,
    "convex_transport_tls_error").
convex_transport_tls_error(Msg) = tls_error(Msg).

:- pragma foreign_proc("C",
    tls_close(Conn::in, IO0::di, IO::uo),
    [will_not_call_mercury, promise_pure, tabled_for_io],
"
    SSL_shutdown(Conn->ssl);
    SSL_free(Conn->ssl);
    SSL_CTX_free(Conn->ctx);
    close(Conn->fd);
    free(Conn);
    IO = IO0;
").

:- pragma foreign_proc("C",
    tls_fd(Conn::in) = (Fd::out),
    [will_not_call_mercury, promise_pure],
"
    Fd = Conn->fd;
").

:- pragma foreign_proc("C",
    tls_write(Conn::in, Text::in, Result::out, IO0::di, IO::uo),
    [will_not_call_mercury, promise_pure, tabled_for_io],
"
    size_t total = strlen(Text);
    size_t sent = 0;
    int failed = 0;
    while (sent < total) {
        int n = SSL_write(Conn->ssl, Text + sent, (int) (total - sent));
        if (n <= 0) { failed = 1; break; }
        sent += (size_t) n;
    }
    Result = failed
        ? convex_transport_transport_error(\"TLS write failed\")
        : convex_transport_ok();
    IO = IO0;
").

:- func convex_transport_ok = maybe_ok.
:- pragma foreign_export("C", (convex_transport_ok = out),
    "convex_transport_ok").
convex_transport_ok = ok.

:- func convex_transport_transport_error(string) = maybe_ok.
:- pragma foreign_export("C", convex_transport_transport_error(in) = out,
    "convex_transport_transport_error").
convex_transport_transport_error(Msg) = transport_error(Msg).

%-----------------------------------------------------------------------------%
% HTTP/1.1 response reading. The request line and headers are built by the
% caller (convex.m knows the Convex-specific path and headers); this only
% reads and frames the response.
%-----------------------------------------------------------------------------%

:- pragma foreign_proc("C",
    tls_read_http_response(Conn::in, Result::out, IO0::di, IO::uo),
    [will_not_call_mercury, promise_pure, tabled_for_io],
"
    size_t cap = 65536, len = 0;
    char *buf = malloc(cap);
    char *header_end = NULL;
    int status = 0;
    long content_length = -1;
    int chunked = 0;
    int failed = 0;
    char errbuf[128];
    errbuf[0] = '\\0';

    /* Read until the blank line ending the headers is present. */
    for (;;) {
        if (len + 4096 > cap) { cap *= 2; buf = realloc(buf, cap); }
        int n = SSL_read(Conn->ssl, buf + len, (int) (cap - len));
        if (n <= 0) { failed = 1; snprintf(errbuf, sizeof(errbuf), \"connection closed before response headers\"); break; }
        len += (size_t) n;
        buf[len] = '\\0';
        header_end = strstr(buf, \"\\r\\n\\r\\n\");
        if (header_end != NULL) break;
        if (len > 262144) { failed = 1; snprintf(errbuf, sizeof(errbuf), \"response headers exceeded 256 KiB\"); break; }
    }

    if (!failed) {
        sscanf(buf, \"HTTP/1.%*d %d\", &status);
        char *cl = strcasestr(buf, \"\\r\\nContent-Length:\");
        if (cl != NULL) content_length = strtol(cl + 18, NULL, 10);
        char *te = strcasestr(buf, \"\\r\\nTransfer-Encoding:\");
        if (te != NULL && strcasestr(te, \"chunked\") != NULL
            && (cl == NULL || te < cl || strcasestr(te, \"chunked\") < strstr(cl, \"\\r\\n\"))) {
            chunked = 1;
        }
    }

    char *body_start = NULL;
    size_t body_have = 0;
    if (!failed) {
        body_start = header_end + 4;
        body_have = len - (size_t) (body_start - buf);
    }

    char *body = NULL;
    size_t body_len = 0;

    if (!failed && chunked) {
        /* Decode chunked transfer-encoding in place as more bytes arrive. */
        char *out = malloc(cap);
        size_t out_len = 0;
        char *cursor = body_start;
        for (;;) {
            char *line_end;
            while ((line_end = strstr(cursor, \"\\r\\n\")) == NULL) {
                if (len + 4096 > cap) { cap *= 2; buf = realloc(buf, cap); out = realloc(out, cap); }
                size_t cursor_off = (size_t) (cursor - buf);
                int n = SSL_read(Conn->ssl, buf + len, (int) (cap - len));
                if (n <= 0) { failed = 1; snprintf(errbuf, sizeof(errbuf), \"connection closed mid-chunk\"); break; }
                len += (size_t) n;
                buf[len] = '\\0';
                cursor = buf + cursor_off;
            }
            if (failed) break;
            long chunk_size = strtol(cursor, NULL, 16);
            cursor = line_end + 2;
            if (chunk_size == 0) break;
            while ((size_t) (cursor - buf) + (size_t) chunk_size + 2 > len) {
                if (len + 4096 > cap) { cap *= 2; buf = realloc(buf, cap); out = realloc(out, cap); }
                size_t cursor_off = (size_t) (cursor - buf);
                int n = SSL_read(Conn->ssl, buf + len, (int) (cap - len));
                if (n <= 0) { failed = 1; snprintf(errbuf, sizeof(errbuf), \"connection closed mid-chunk\"); break; }
                len += (size_t) n;
                buf[len] = '\\0';
                cursor = buf + cursor_off;
            }
            if (failed) break;
            if (out_len + (size_t) chunk_size + 1 > cap) { cap = out_len + (size_t) chunk_size + 4096; out = realloc(out, cap); }
            memcpy(out + out_len, cursor, (size_t) chunk_size);
            out_len += (size_t) chunk_size;
            cursor += chunk_size + 2;
        }
        body = out;
        body_len = out_len;
    } else if (!failed && content_length >= 0) {
        while (body_have < (size_t) content_length) {
            if (len + 4096 > cap) { cap *= 2; buf = realloc(buf, cap); }
            size_t body_off = (size_t) (body_start - buf);
            int n = SSL_read(Conn->ssl, buf + len, (int) (cap - len));
            if (n <= 0) { failed = 1; snprintf(errbuf, sizeof(errbuf), \"connection closed before full body\"); break; }
            len += (size_t) n;
            buf[len] = '\\0';
            body_start = buf + body_off;
            body_have = len - body_off;
        }
        body = body_start;
        body_len = (size_t) content_length;
    } else if (!failed) {
        /* Neither Content-Length nor chunked: read until the peer closes. */
        for (;;) {
            if (len + 4096 > cap) { cap *= 2; buf = realloc(buf, cap); }
            size_t body_off = (size_t) (body_start - buf);
            int n = SSL_read(Conn->ssl, buf + len, (int) (cap - len));
            if (n <= 0) break;
            len += (size_t) n;
            buf[len] = '\\0';
            body_start = buf + body_off;
        }
        body = body_start;
        body_len = len - (size_t) (body_start - buf);
    }

    if (failed) {
        Result = convex_transport_http_transport_error(errbuf);
    } else {
        char *body_copy = convex_dup_mercury_string(body, body_len);
        Result = convex_transport_http_response(status, body_copy);
    }
    free(buf);
    IO = IO0;
").

:- func convex_transport_http_response(int, string) = maybe_http_response.
:- pragma foreign_export("C", convex_transport_http_response(in, in) = out,
    "convex_transport_http_response").
convex_transport_http_response(Status, Body) = http_response(Status, Body).

:- func convex_transport_http_transport_error(string) = maybe_http_response.
:- pragma foreign_export("C", convex_transport_http_transport_error(in) = out,
    "convex_transport_http_transport_error").
convex_transport_http_transport_error(Msg) = http_transport_error(Msg).

%-----------------------------------------------------------------------------%
% WebSocket handshake and framing.
%-----------------------------------------------------------------------------%

:- pragma foreign_decl("C", "
static const char *CONVEX_WS_GUID = \"258EAFA5-E914-47DA-95CA-C5AB0DC85B11\";

static void convex_base64_encode(const unsigned char *data, size_t len, char *out) {
    EVP_EncodeBlock((unsigned char *) out, data, (int) len);
}
").

:- pragma foreign_proc("C",
    ws_handshake(Conn::in, Host::in, Path::in, Result::out, IO0::di, IO::uo),
    [will_not_call_mercury, promise_pure, tabled_for_io],
"
    unsigned char key_bytes[16];
    char key_b64[32];
    char request[1024];
    char accept_input[128];
    unsigned char accept_sha1[SHA_DIGEST_LENGTH];
    char accept_expected[64];

    RAND_bytes(key_bytes, sizeof(key_bytes));
    convex_base64_encode(key_bytes, sizeof(key_bytes), key_b64);

    snprintf(request, sizeof(request),
        \"GET %s HTTP/1.1\\r\\n\"
        \"Host: %s\\r\\n\"
        \"Upgrade: websocket\\r\\n\"
        \"Connection: Upgrade\\r\\n\"
        \"Sec-WebSocket-Key: %s\\r\\n\"
        \"Sec-WebSocket-Version: 13\\r\\n\"
        \"\\r\\n\",
        Path, Host, key_b64);

    int failed = 0;
    char errbuf[160];
    errbuf[0] = '\\0';
    size_t total = strlen(request), sent = 0;
    while (sent < total && !failed) {
        int n = SSL_write(Conn->ssl, request + sent, (int) (total - sent));
        if (n <= 0) { failed = 1; snprintf(errbuf, sizeof(errbuf), \"handshake write failed\"); }
        else sent += (size_t) n;
    }

    char buf[4096];
    size_t len = 0;
    char *header_end = NULL;
    if (!failed) {
        for (;;) {
            int n = SSL_read(Conn->ssl, buf + len, (int) (sizeof(buf) - 1 - len));
            if (n <= 0) { failed = 1; snprintf(errbuf, sizeof(errbuf), \"handshake read failed\"); break; }
            len += (size_t) n;
            buf[len] = '\\0';
            header_end = strstr(buf, \"\\r\\n\\r\\n\");
            if (header_end != NULL) break;
            if (len >= sizeof(buf) - 1) { failed = 1; snprintf(errbuf, sizeof(errbuf), \"handshake response too large\"); break; }
        }
    }

    if (!failed) {
        int status = 0;
        sscanf(buf, \"HTTP/1.%*d %d\", &status);
        char *accept_hdr = strcasestr(buf, \"\\r\\nSec-WebSocket-Accept:\");
        if (status != 101 || accept_hdr == NULL) {
            failed = 1;
            snprintf(errbuf, sizeof(errbuf), \"unexpected handshake response (status %d)\", status);
        } else {
            snprintf(accept_input, sizeof(accept_input), \"%s%s\", key_b64, CONVEX_WS_GUID);
            SHA1((const unsigned char *) accept_input, strlen(accept_input), accept_sha1);
            convex_base64_encode(accept_sha1, SHA_DIGEST_LENGTH, accept_expected);
            char actual[64];
            sscanf(accept_hdr + 24, \"%63s\", actual);
            if (strncmp(actual, accept_expected, strlen(accept_expected)) != 0) {
                failed = 1;
                snprintf(errbuf, sizeof(errbuf), \"Sec-WebSocket-Accept mismatch\");
            }
        }
    }

    Result = failed
        ? convex_transport_transport_error(errbuf)
        : convex_transport_ok();
    IO = IO0;
").

:- pragma foreign_proc("C",
    ws_send_text(Conn::in, Text::in, Result::out, IO0::di, IO::uo),
    [will_not_call_mercury, promise_pure, tabled_for_io],
"
    size_t payload_len = strlen(Text);
    size_t header_len;
    unsigned char header[14];
    unsigned char mask[4];
    size_t frame_len;
    unsigned char *frame;
    size_t i;
    int failed = 0;

    header[0] = 0x81; /* FIN + text opcode */
    if (payload_len <= 125) {
        header[1] = (unsigned char) (0x80 | payload_len);
        header_len = 2;
    } else if (payload_len <= 65535) {
        header[1] = 0x80 | 126;
        header[2] = (unsigned char) ((payload_len >> 8) & 0xFF);
        header[3] = (unsigned char) (payload_len & 0xFF);
        header_len = 4;
    } else {
        header[1] = 0x80 | 127;
        for (i = 0; i < 8; i++) {
            header[2 + i] = (unsigned char) ((payload_len >> (8 * (7 - i))) & 0xFF);
        }
        header_len = 10;
    }
    RAND_bytes(mask, 4);
    memcpy(header + header_len, mask, 4);
    header_len += 4;

    frame_len = header_len + payload_len;
    frame = malloc(frame_len);
    memcpy(frame, header, header_len);
    for (i = 0; i < payload_len; i++) {
        frame[header_len + i] = ((unsigned char) Text[i]) ^ mask[i % 4];
    }

    size_t sent = 0;
    while (sent < frame_len) {
        int n = SSL_write(Conn->ssl, frame + sent, (int) (frame_len - sent));
        if (n <= 0) { failed = 1; break; }
        sent += (size_t) n;
    }
    free(frame);

    Result = failed
        ? convex_transport_transport_error(\"WebSocket write failed\")
        : convex_transport_ok();
    IO = IO0;
").

    % One inbound-buffer slot per TLS connection's fd, mirroring the plain-fd
    % line slots above: reading a frame can require several TCP reads, and a
    % short SSL_read must not lose bytes already pulled off the wire.
:- pragma foreign_decl("C", "
#define CONVEX_WS_SLOTS 4
typedef struct { int fd; unsigned char *buf; size_t len; size_t cap; } WsSlot;
static WsSlot convex_ws_slots[CONVEX_WS_SLOTS];
static int convex_ws_slots_init = 0;

static WsSlot *convex_ws_slot(int fd) {
    int i;
    if (!convex_ws_slots_init) {
        for (i = 0; i < CONVEX_WS_SLOTS; i++) convex_ws_slots[i].fd = -1;
        convex_ws_slots_init = 1;
    }
    for (i = 0; i < CONVEX_WS_SLOTS; i++) if (convex_ws_slots[i].fd == fd) return &convex_ws_slots[i];
    for (i = 0; i < CONVEX_WS_SLOTS; i++) {
        if (convex_ws_slots[i].fd == -1) {
            convex_ws_slots[i].fd = fd;
            convex_ws_slots[i].cap = 65536;
            convex_ws_slots[i].buf = malloc(convex_ws_slots[i].cap);
            convex_ws_slots[i].len = 0;
            return &convex_ws_slots[i];
        }
    }
    return NULL;
}

/* Ensure at least `need` more bytes are buffered, reading from `ssl` (with a
   timeout in ms) as required. Returns 1 on success, 0 on timeout with no new
   bytes, -1 on error/peer-close. */
static int convex_ws_fill(WsSlot *slot, SSL *ssl, int fd, size_t need, int timeout_ms) {
    while (slot->len < need) {
        struct pollfd pfd = { fd, POLLIN, 0 };
        int pr = poll(&pfd, 1, timeout_ms);
        if (pr == 0) return (slot->len > 0) ? -1 : 0;
        if (pr < 0) return -1;
        if (slot->cap - slot->len < 4096) {
            slot->cap += 65536;
            slot->buf = realloc(slot->buf, slot->cap);
        }
        int n = SSL_read(ssl, slot->buf + slot->len, (int) (slot->cap - slot->len));
        if (n <= 0) return -1;
        slot->len += (size_t) n;
    }
    return 1;
}

static void convex_ws_consume(WsSlot *slot, size_t n) {
    memmove(slot->buf, slot->buf + n, slot->len - n);
    slot->len -= n;
}
").

:- pragma foreign_proc("C",
    ws_recv(Conn::in, TimeoutMs::in, Result::out, IO0::di, IO::uo),
    [will_not_call_mercury, promise_pure, tabled_for_io],
"
    WsSlot *slot = convex_ws_slot(Conn->fd);
    Result = convex_transport_ws_timeout();

    for (;;) {
        int fr = convex_ws_fill(slot, Conn->ssl, Conn->fd, 2, TimeoutMs);
        if (fr == 0) { Result = convex_transport_ws_timeout(); break; }
        if (fr < 0) { Result = convex_transport_ws_peer_closed(); break; }

        unsigned char b0 = slot->buf[0], b1 = slot->buf[1];
        int opcode = b0 & 0x0F;
        int masked = (b1 & 0x80) != 0;
        MR_Unsigned payload_len = b1 & 0x7F;
        size_t header_len = 2;

        if (payload_len == 126) {
            if (convex_ws_fill(slot, Conn->ssl, Conn->fd, 4, TimeoutMs) <= 0) { Result = convex_transport_ws_peer_closed(); break; }
            payload_len = ((MR_Unsigned) slot->buf[2] << 8) | slot->buf[3];
            header_len = 4;
        } else if (payload_len == 127) {
            if (convex_ws_fill(slot, Conn->ssl, Conn->fd, 10, TimeoutMs) <= 0) { Result = convex_transport_ws_peer_closed(); break; }
            payload_len = 0;
            int i;
            for (i = 0; i < 8; i++) payload_len = (payload_len << 8) | slot->buf[2 + i];
            header_len = 10;
        }
        size_t mask_len = masked ? 4 : 0;
        size_t total_len = header_len + mask_len + payload_len;
        if (total_len > 8 * 1024 * 1024) { Result = convex_transport_ws_error(\"frame exceeded 8 MiB\"); break; }

        if (convex_ws_fill(slot, Conn->ssl, Conn->fd, total_len, TimeoutMs) <= 0) { Result = convex_transport_ws_peer_closed(); break; }

        unsigned char *payload = slot->buf + header_len + mask_len;
        if (masked) {
            unsigned char *m = slot->buf + header_len;
            size_t i;
            for (i = 0; i < payload_len; i++) payload[i] ^= m[i % 4];
        }

        if (opcode == 0x1) { /* text */
            char *text = convex_dup_mercury_string((const char *) payload, payload_len);
            convex_ws_consume(slot, total_len);
            Result = convex_transport_ws_text(text);
            break;
        } else if (opcode == 0x8) { /* close */
            convex_ws_consume(slot, total_len);
            Result = convex_transport_ws_peer_closed();
            break;
        } else if (opcode == 0x9) { /* ping: reply pong with the same payload, keep waiting */
            unsigned char pong_header[10];
            size_t pong_header_len;
            unsigned char pong_mask[4];
            RAND_bytes(pong_mask, 4);
            pong_header[0] = 0x8A;
            if (payload_len <= 125) {
                pong_header[1] = (unsigned char) (0x80 | payload_len);
                pong_header_len = 2;
            } else {
                pong_header[1] = 0x80 | 126;
                pong_header[2] = (unsigned char) ((payload_len >> 8) & 0xFF);
                pong_header[3] = (unsigned char) (payload_len & 0xFF);
                pong_header_len = 4;
            }
            memcpy(pong_header + pong_header_len, pong_mask, 4);
            pong_header_len += 4;
            unsigned char *pong = malloc(pong_header_len + payload_len);
            memcpy(pong, pong_header, pong_header_len);
            size_t i;
            for (i = 0; i < payload_len; i++) pong[pong_header_len + i] = payload[i] ^ pong_mask[i % 4];
            size_t sent = 0;
            size_t pong_len = pong_header_len + payload_len;
            while (sent < pong_len) {
                int n = SSL_write(Conn->ssl, pong + sent, (int) (pong_len - sent));
                if (n <= 0) break;
                sent += (size_t) n;
            }
            free(pong);
            convex_ws_consume(slot, total_len);
            /* loop again for the next frame */
        } else {
            /* pong or an unsupported opcode (e.g. a continuation frame this
               minimal client does not reassemble): drop it and keep waiting. */
            convex_ws_consume(slot, total_len);
        }
    }
    IO = IO0;
").

:- func convex_transport_ws_timeout = ws_event.
:- pragma foreign_export("C", (convex_transport_ws_timeout = out),
    "convex_transport_ws_timeout").
convex_transport_ws_timeout = ws_timeout.

:- func convex_transport_ws_text(string) = ws_event.
:- pragma foreign_export("C", convex_transport_ws_text(in) = out,
    "convex_transport_ws_text").
convex_transport_ws_text(Text) = ws_text(Text).

:- func convex_transport_ws_peer_closed = ws_event.
:- pragma foreign_export("C", (convex_transport_ws_peer_closed = out),
    "convex_transport_ws_peer_closed").
convex_transport_ws_peer_closed = ws_peer_closed.

:- func convex_transport_ws_error(string) = ws_event.
:- pragma foreign_export("C", convex_transport_ws_error(in) = out,
    "convex_transport_ws_error").
convex_transport_ws_error(Msg) = ws_recv_error(Msg).

%-----------------------------------------------------------------------------%
% Plain descriptors: listen/accept, line reading, poll.
%-----------------------------------------------------------------------------%

:- pragma foreign_proc("C",
    tcp_listen(Address::in, Port::in, Result::out, IO0::di, IO::uo),
    [will_not_call_mercury, promise_pure, tabled_for_io],
"
    struct addrinfo hints, *res = NULL, *rp;
    char portbuf[16];
    int listenfd = -1;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;
    snprintf(portbuf, sizeof(portbuf), \"%d\", (int) Port);

    if (getaddrinfo(strlen(Address) ? Address : NULL, portbuf, &hints, &res) != 0) {
        Result = convex_transport_fd_error(\"listen address lookup failed\");
    } else {
        for (rp = res; rp != NULL; rp = rp->ai_next) {
            listenfd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
            if (listenfd < 0) continue;
            int one = 1;
            setsockopt(listenfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
            if (bind(listenfd, rp->ai_addr, rp->ai_addrlen) == 0) break;
            close(listenfd);
            listenfd = -1;
        }
        freeaddrinfo(res);
        if (listenfd < 0 || listen(listenfd, 1) != 0) {
            Result = convex_transport_fd_error(\"bind/listen failed\");
        } else {
            Result = convex_transport_fd_ok(listenfd);
        }
    }
    IO = IO0;
").

:- pragma foreign_proc("C",
    tcp_accept(ListenFd::in, Result::out, IO0::di, IO::uo),
    [will_not_call_mercury, promise_pure, tabled_for_io],
"
    int connfd = accept(ListenFd, NULL, NULL);
    Result = (connfd < 0)
        ? convex_transport_fd_error(\"accept() failed\")
        : convex_transport_fd_ok(connfd);
    IO = IO0;
").

:- func convex_transport_fd_ok(int) = maybe_fd.
:- pragma foreign_export("C", convex_transport_fd_ok(in) = out,
    "convex_transport_fd_ok").
convex_transport_fd_ok(Fd) = fd_ok(Fd).

:- func convex_transport_fd_error(string) = maybe_fd.
:- pragma foreign_export("C", convex_transport_fd_error(in) = out,
    "convex_transport_fd_error").
convex_transport_fd_error(Msg) = fd_error(Msg).

:- pragma foreign_proc("C",
    read_line(Fd::in, Result::out, IO0::di, IO::uo),
    [will_not_call_mercury, promise_pure, tabled_for_io],
"
    LineSlot *slot = convex_line_slot(Fd);
    char *nl;
    Result = convex_transport_line_error(\"too many concurrently buffered descriptors\");

    if (slot != NULL) {
        for (;;) {
            nl = memchr(slot->buf, '\\n', slot->len);
            if (nl != NULL) {
                size_t line_len = (size_t) (nl - slot->buf);
                size_t strip = (line_len > 0 && slot->buf[line_len - 1] == '\\r') ? 1 : 0;
                char *text = convex_dup_mercury_string(slot->buf, line_len - strip);
                size_t consumed = line_len + 1;
                memmove(slot->buf, slot->buf + consumed, slot->len - consumed);
                slot->len -= consumed;
                Result = convex_transport_line_ok(text);
                break;
            }
            if (slot->eof) {
                if (slot->len > 0) {
                    char *text = convex_dup_mercury_string(slot->buf, slot->len);
                    slot->len = 0;
                    Result = convex_transport_line_ok(text);
                } else {
                    Result = convex_transport_line_eof();
                }
                break;
            }
            if (slot->cap - slot->len < 4096) {
                if (slot->cap >= CONVEX_LINE_BUF_CAP) {
                    Result = convex_transport_line_error(\"line exceeded 1 MiB\");
                    break;
                }
                slot->cap += 65536;
                slot->buf = realloc(slot->buf, slot->cap);
            }
            int n = read(Fd, slot->buf + slot->len, slot->cap - slot->len);
            if (n < 0) {
                if (errno == EINTR) continue;
                Result = convex_transport_line_error(strerror(errno));
                break;
            } else if (n == 0) {
                slot->eof = 1;
            } else {
                slot->len += (size_t) n;
            }
        }
    }
    IO = IO0;
").

:- func convex_transport_line_ok(string) = line_event.
:- pragma foreign_export("C", convex_transport_line_ok(in) = out,
    "convex_transport_line_ok").
convex_transport_line_ok(Text) = line_ok(Text).

:- func convex_transport_line_eof = line_event.
:- pragma foreign_export("C", (convex_transport_line_eof = out),
    "convex_transport_line_eof").
convex_transport_line_eof = line_eof.

:- func convex_transport_line_error(string) = line_event.
:- pragma foreign_export("C", convex_transport_line_error(in) = out,
    "convex_transport_line_error").
convex_transport_line_error(Msg) = line_error(Msg).

:- pragma foreign_proc("C",
    write_line(Fd::in, Text::in, Result::out, IO0::di, IO::uo),
    [will_not_call_mercury, promise_pure, tabled_for_io],
"
    size_t total = strlen(Text);
    size_t sent = 0;
    int failed = 0;
    while (sent < total) {
        ssize_t n = write(Fd, Text + sent, total - sent);
        if (n < 0) { failed = 1; break; }
        sent += (size_t) n;
    }
    if (!failed) {
        if (write(Fd, \"\\n\", 1) != 1) failed = 1;
    }
    Result = failed
        ? convex_transport_transport_error(\"write failed\")
        : convex_transport_ok();
    IO = IO0;
").

:- pred poll_control_raw(int::in, int::in, int::in, poll_result::out,
    io::di, io::uo) is det.

:- pragma foreign_proc("C",
    poll_control_raw(ControlFd::in, LiveFd::in, TimeoutMs::in, Result::out,
        IO0::di, IO::uo),
    [will_not_call_mercury, promise_pure, tabled_for_io],
"
    struct pollfd fds[2];
    int nfds = 1;
    fds[0].fd = ControlFd;
    fds[0].events = POLLIN;
    fds[0].revents = 0;
    if (LiveFd >= 0) {
        fds[1].fd = LiveFd;
        fds[1].events = POLLIN;
        fds[1].revents = 0;
        nfds = 2;
    }
    poll(fds, nfds, TimeoutMs);
    int control_ready = (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) != 0;
    int live_ready = (nfds == 2) && (fds[1].revents & (POLLIN | POLLHUP | POLLERR)) != 0;
    if (control_ready && live_ready) Result = convex_transport_poll_both();
    else if (control_ready) Result = convex_transport_poll_control();
    else if (live_ready) Result = convex_transport_poll_live();
    else Result = convex_transport_poll_none();
    IO = IO0;
").

:- func convex_transport_poll_none = poll_result.
:- pragma foreign_export("C", (convex_transport_poll_none = out),
    "convex_transport_poll_none").
convex_transport_poll_none = poll_none.

:- func convex_transport_poll_control = poll_result.
:- pragma foreign_export("C", (convex_transport_poll_control = out),
    "convex_transport_poll_control").
convex_transport_poll_control = poll_control_ready.

:- func convex_transport_poll_live = poll_result.
:- pragma foreign_export("C", (convex_transport_poll_live = out),
    "convex_transport_poll_live").
convex_transport_poll_live = poll_live_ready.

:- func convex_transport_poll_both = poll_result.
:- pragma foreign_export("C", (convex_transport_poll_both = out),
    "convex_transport_poll_both").
convex_transport_poll_both = poll_both_ready.

poll_control(ControlFd, no_live_conn, TimeoutMs, Result, !IO) :-
    poll_control_raw(ControlFd, -1, TimeoutMs, Result, !IO).
poll_control(ControlFd, live_conn(LiveFd), TimeoutMs, Result, !IO) :-
    poll_control_raw(ControlFd, LiveFd, TimeoutMs, Result, !IO).

%-----------------------------------------------------------------------------%
% Base64 and random hex, via OpenSSL.
%-----------------------------------------------------------------------------%

:- pragma foreign_proc("C",
    base64_encode_bytes(Bytes::in) = (Encoded::out),
    [will_not_call_mercury, promise_pure],
"
    size_t inlen = strlen(Bytes);
    size_t outcap = ((inlen + 2) / 3) * 4 + 1;
    char *out = malloc(outcap);
    int n = EVP_EncodeBlock((unsigned char *) out, (const unsigned char *) Bytes, (int) inlen);
    Encoded = convex_dup_mercury_string(out, (size_t) n);
    free(out);
").

:- pragma foreign_proc("C",
    base64_decode_strict(Encoded::in, Bytes::out),
    [will_not_call_mercury, promise_pure],
"
    size_t inlen = strlen(Encoded);
    if (inlen % 4 != 0 || inlen == 0) {
        SUCCESS_INDICATOR = MR_FALSE;
        Bytes = MR_make_string_const(\"\");
    } else {
        size_t outcap = (inlen / 4) * 3 + 1;
        unsigned char *out = malloc(outcap);
        int n = EVP_DecodeBlock(out, (const unsigned char *) Encoded, (int) inlen);
        int pad = 0;
        if (Encoded[inlen - 1] == '=') pad++;
        if (Encoded[inlen - 2] == '=') pad++;
        if (n < 0) {
            SUCCESS_INDICATOR = MR_FALSE;
            Bytes = MR_make_string_const(\"\");
        } else {
            size_t real_len = (size_t) n - pad;
            /* Re-encode and compare to reject non-canonical input (stray bits
               in padding, alternate encodings of the same byte length). */
            char *recheck = malloc(outcap + 8);
            int rn = EVP_EncodeBlock((unsigned char *) recheck, out, (int) real_len);
            if ((size_t) rn == inlen && memcmp(recheck, Encoded, inlen) == 0) {
                SUCCESS_INDICATOR = MR_TRUE;
                Bytes = convex_dup_mercury_string((const char *) out, real_len);
            } else {
                SUCCESS_INDICATOR = MR_FALSE;
                Bytes = MR_make_string_const(\"\");
            }
            free(recheck);
        }
        free(out);
    }
").

:- pragma foreign_proc("C",
    base64_decode_ts8(Encoded::in, Value::out),
    [will_not_call_mercury, promise_pure],
"
    size_t inlen = strlen(Encoded);
    if (inlen != 12) {
        SUCCESS_INDICATOR = MR_FALSE;
        Value = 0;
    } else {
        unsigned char out[9];
        int n = EVP_DecodeBlock(out, (const unsigned char *) Encoded, (int) inlen);
        int pad = 0;
        if (Encoded[inlen - 1] == '=') pad++;
        if (Encoded[inlen - 2] == '=') pad++;
        if (n != 9 || pad != 1) {
            SUCCESS_INDICATOR = MR_FALSE;
            Value = 0;
        } else {
            char recheck[16];
            int rn = EVP_EncodeBlock((unsigned char *) recheck, out, 8);
            if (rn != (int) inlen || memcmp(recheck, Encoded, inlen) != 0) {
                SUCCESS_INDICATOR = MR_FALSE;
                Value = 0;
            } else {
                MR_Integer v = 0;
                int i;
                for (i = 7; i >= 0; i--) v = (v << 8) | out[i];
                Value = v;
                SUCCESS_INDICATOR = MR_TRUE;
            }
        }
    }
").

:- pragma foreign_proc("C",
    random_hex(NBytes::in, Hex::out, IO0::di, IO::uo),
    [will_not_call_mercury, promise_pure, tabled_for_io],
"
    unsigned char raw[64];
    char out[129];
    int n = (NBytes > 64) ? 64 : NBytes;
    int i;
    RAND_bytes(raw, n);
    for (i = 0; i < n; i++) snprintf(out + i * 2, 3, \"%02x\", raw[i]);
    Hex = convex_dup_mercury_string(out, (size_t) n * 2);
    IO = IO0;
").
