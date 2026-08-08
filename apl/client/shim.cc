/*
 * Convex transport shim for GNU APL.
 *
 * GNU APL's own ⎕FIO already exposes raw byte sockets natively --
 * socket/bind/listen/accept/connect/send/recv/select are ⎕FIO[32..47],
 * built into the apl binary itself (see Quad_FIO.cc upstream). Plain
 * (ws://, http://) transport in client/convex.apl calls those directly;
 * nothing in this file duplicates them.
 *
 * What ⎕FIO does not offer is TLS. GNU APL's documented way to add a
 * primitive it doesn't have is a "native function": a small shared
 * library compiled against the interpreter's own internal headers
 * (Native_interface.hh and friends) and loaded at runtime with dyadic
 * ⎕FX ('lib.so' ⎕FX 'NAME'), exactly like the interpreter's own shipped
 * lib_file_io.so. That is what this file is: it wraps OpenSSL's
 * SSL_connect/SSL_read/SSL_write/SSL_shutdown behind one native
 * function, CONVEXTLS, selected by axis the same way file_io.cc's own
 * FUN[n] dispatch works. It also exposes three non-transport primitives:
 * SHA-1 (axis 5), needed only for the RFC 6455 handshake's
 * Sec-WebSocket-Accept response -- delegated to OpenSSL (already linked
 * in for TLS) rather than hand-rolled 32-bit modular arithmetic, on the
 * same reasoning that puts TLS itself here instead of in APL -- DNS
 * resolution (axis 6), because ⎕FIO[36]'s own connect() takes an
 * already-resolved 32-bit address and GNU APL has no getaddrinfo of its
 * own; the plain (non-TLS) path resolves a hostname here and then calls
 * ⎕FIO's real socket/connect/send/recv itself -- and CSPRNG bytes
 * (axis 7), needed for the Sec-WebSocket-Key and every frame's masking
 * key, since GNU APL has no random-bytes primitive of its own either.
 * Base64, HTTP, JSON, RFC 6455 framing/masking/fragmentation, and the
 * whole Convex sync protocol are not delegated: every one of those
 * lives in client/convex.apl and client/convexlive.apl, in APL.
 *
 * Wire convention (mirrors the byte-vector convention ⎕FIO[37]/[38]
 * already use for recv/send, and the tagged-return convention proven in
 * ../../icon/client/shim.c and ../../rexx/client/shim.c): every call
 * returns a UCS_string whose first character is a one-letter tag ('K'
 * ok/handle, 'D' data, 'T' timed out, 'C' closed, 'E' error) followed by
 * a colon and the payload. Payload bytes are carried one raw byte per
 * APL character (codepoints 0-255), never routed through UTF-8 decoding
 * -- multi-byte UTF-8 in a Convex JSON payload is reassembled by
 * client/convex.apl itself, the same layering ../../icon/client/shim.c
 * uses.
 *
 * Handles are small integers indexing a fixed table of TLS connection
 * slots (this shim only ever holds TLS connections; plain sockets stay
 * entirely in ⎕FIO's own handle space and never pass through here).
 */
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <openssl/ssl.h>

#include "Native_interface.hh"
#include "Value.hh"

class NativeFunction;

#define MAX_SLOTS 64
#define MAX_MESSAGE 8388608 /* 8 MiB: comfortably above one Convex frame. */

typedef struct {
    int inUse;
    int fd;
    SSL *ssl;
} slot_t;

static slot_t slots[MAX_SLOTS];
static SSL_CTX *sharedCtx = NULL;
static int initialised = 0;

static void ensure_init(void) {
    if (initialised) return;
    initialised = 1;
    signal(SIGPIPE, SIG_IGN);
    memset(slots, 0, sizeof(slots));
    SSL_library_init();
    SSL_load_error_strings();
}

static int find_free_slot(void) {
    for (int i = 0; i < MAX_SLOTS; i++) {
        if (!slots[i].inUse) return i;
    }
    return -1;
}

/* Builds a UCS_string "<tag>:<payload>" where payload is one raw byte
 * per codepoint (0-255), never UTF-8-interpreted. */
static Token ret_tagged(char tag, const unsigned char *data, size_t n) {
    if (n > MAX_MESSAGE) n = MAX_MESSAGE;
    std::vector<Unicode> cps;
    cps.reserve(n + 2);
    cps.push_back(Unicode((unsigned char)tag));
    cps.push_back(Unicode((unsigned char)':'));
    for (size_t i = 0; i < n; i++) cps.push_back(Unicode(data[i]));
    UCS_string ucs(cps.data(), cps.size());
    Value_P Z(ucs, LOC);
    Z->check_value(LOC);
    return Token(TOK_APL_VALUE1, Z);
}

static Token ret_ok_text(const char *payload) {
    return ret_tagged('K', (const unsigned char *)payload, strlen(payload));
}

static Token ret_err(const char *message) {
    return ret_tagged('E', (const unsigned char *)message, strlen(message));
}

/* Converts an APL integer/char vector argument into a plain byte buffer.
 * client/convex.apl always passes plain ASCII character vectors for
 * host/port/handle-as-text arguments here, so a straightforward
 * codepoint-truncating copy is exact for those; for payload bytes
 * (CONVEXTLS[2] send) each element is already a 0-255 codepoint written
 * by convex.apl's own byte-vector helpers. */
static size_t value_to_bytes(Value_P B, unsigned char *out, size_t outCap) {
    size_t n = B->element_count();
    if (n > outCap) n = outCap;
    for (size_t i = 0; i < n; i++) {
        const Cell &cell = B->get_cravel(i);
        long v = cell.is_character_cell() ? (long)(uint32_t)cell.get_char_value()
                                           : (long)cell.get_int_value();
        out[i] = (unsigned char)(v & 0xFF);
    }
    return n;
}

static Fun_signature get_signature() { return SIG_Z_A_F2_B; }

static bool close_fun(Cause cause, const NativeFunction *caller) {
    (void)cause;
    (void)caller;
    return true;
}

/* CONVEXTLS[1] Bs : connect(host:port packed as "host port") -> "K:<handle>" */
static Token op_connect(Value_P B) {
    ensure_init();
    unsigned char raw[512];
    size_t n = value_to_bytes(B, raw, sizeof(raw) - 1);
    raw[n] = 0;
    char host[256], port[16];
    if (sscanf((const char *)raw, "%255s %15s", host, port) != 2) {
        return ret_err("expected \"host port\"");
    }

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *res = NULL;
    if (getaddrinfo(host, port, &hints, &res) != 0 || res == NULL) {
        return ret_err("dns resolution failed");
    }

    int fd = -1;
    for (struct addrinfo *rp = res; rp != NULL; rp = rp->ai_next) {
        fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (fd < 0) continue;
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        int rc = connect(fd, rp->ai_addr, rp->ai_addrlen);
        if (rc == 0) {
            fcntl(fd, F_SETFL, flags);
            break;
        }
        if (errno == EINPROGRESS) {
            struct pollfd pfd;
            pfd.fd = fd;
            pfd.events = POLLOUT;
            int pollRc = poll(&pfd, 1, 10000);
            int soErr = 0;
            socklen_t soErrLen = sizeof(soErr);
            if (pollRc > 0 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &soErrLen) == 0 && soErr == 0) {
                fcntl(fd, F_SETFL, flags);
                break;
            }
        }
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) return ret_err("connect failed or timed out");

    int slotIdx = find_free_slot();
    if (slotIdx < 0) {
        close(fd);
        return ret_err("no free TLS slots");
    }

    if (sharedCtx == NULL) {
        sharedCtx = SSL_CTX_new(TLS_client_method());
        SSL_CTX_set_verify(sharedCtx, SSL_VERIFY_PEER, NULL);
        SSL_CTX_set_default_verify_paths(sharedCtx);
    }
    SSL *ssl = SSL_new(sharedCtx);
    SSL_set_fd(ssl, fd);
    SSL_set_tlsext_host_name(ssl, host);
    SSL_set1_host(ssl, host);
    if (SSL_connect(ssl) != 1) {
        SSL_free(ssl);
        close(fd);
        return ret_err("tls handshake failed");
    }

    slots[slotIdx].inUse = 1;
    slots[slotIdx].fd = fd;
    slots[slotIdx].ssl = ssl;

    char handleBuf[16];
    snprintf(handleBuf, sizeof(handleBuf), "%d", slotIdx);
    return ret_ok_text(handleBuf);
}

static int handle_of(Value_P B) {
    unsigned char raw[32];
    size_t n = value_to_bytes(B, raw, sizeof(raw) - 1);
    raw[n] = 0;
    return atoi((const char *)raw);
}

/* CONVEXTLS[2] Ai FUN Bh : send(Bh, Ai) -> "K:<bytesSent>" */
static Token op_send(Value_P A, Value_P B) {
    ensure_init();
    int handle = handle_of(B);
    if (handle < 0 || handle >= MAX_SLOTS || !slots[handle].inUse) return ret_err("bad handle");

    static unsigned char buf[MAX_MESSAGE];
    size_t len = value_to_bytes(A, buf, sizeof(buf));

    size_t sent = 0;
    while (sent < len) {
        int n = SSL_write(slots[handle].ssl, buf + sent, (int)(len - sent));
        if (n <= 0) {
            if (sent > 0) break;
            return ret_err("tls send failed");
        }
        sent += (size_t)n;
    }
    char lenBuf[24];
    snprintf(lenBuf, sizeof(lenBuf), "%zu", sent);
    return ret_ok_text(lenBuf);
}

/* CONVEXTLS[3] Ai FUN Bh : recv(Bh, maxBytes=A[1], timeoutMs=A[2])
 *   -> "D:<bytes>" | "T:" | "C:" | "E:<message>" */
static Token op_recv(Value_P A, Value_P B) {
    ensure_init();
    int handle = handle_of(B);
    if (handle < 0 || handle >= MAX_SLOTS || !slots[handle].inUse) return ret_err("bad handle");

    long params[2] = {4096, 5000};
    size_t pn = A->element_count();
    for (size_t i = 0; i < pn && i < 2; i++) {
        const Cell &cell = A->get_cravel(i);
        params[i] = cell.get_int_value();
    }
    long maxBytes = params[0];
    long timeoutMs = params[1];
    if (maxBytes > MAX_MESSAGE - 2) maxBytes = MAX_MESSAGE - 2;
    if (maxBytes < 1) maxBytes = 1;

    if (SSL_pending(slots[handle].ssl) <= 0) {
        struct pollfd pfd;
        pfd.fd = slots[handle].fd;
        pfd.events = POLLIN;
        int rc = poll(&pfd, 1, (int)timeoutMs);
        if (rc == 0) return ret_tagged('T', NULL, 0);
        if (rc < 0) return ret_err("poll failed while receiving");
    }

    static unsigned char buf[MAX_MESSAGE];
    int n = SSL_read(slots[handle].ssl, buf, (int)maxBytes);
    if (n <= 0) {
        int reason = SSL_get_error(slots[handle].ssl, n);
        if (reason == SSL_ERROR_ZERO_RETURN) return ret_tagged('C', NULL, 0);
        if (reason == SSL_ERROR_WANT_READ || reason == SSL_ERROR_WANT_WRITE) return ret_tagged('T', NULL, 0);
        return ret_err("tls recv failed");
    }
    return ret_tagged('D', buf, (size_t)n);
}

/* CONVEXTLS[5] Bb : sha1(Bb) -> "K:<20 raw digest bytes>"
 *
 * The one non-transport primitive this shim supplies: SHA-1, needed only
 * to compute the RFC 6455 Sec-WebSocket-Accept handshake response.
 * client/convex.apl implements RFC 6455 framing, masking, fragmentation,
 * control frames, JSON, HTTP, and the whole sync protocol itself; it
 * delegates just this one general-purpose digest primitive to OpenSSL
 * (already linked in for TLS) rather than hand-rolling 32-bit modular
 * arithmetic for it, the same way TLS itself is delegated here instead
 * of written in APL. */
static Token op_sha1(Value_P B) {
    ensure_init();
    static unsigned char buf[MAX_MESSAGE];
    size_t len = value_to_bytes(B, buf, sizeof(buf));
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int digestLen = 0;
    if (EVP_Digest(buf, len, digest, &digestLen, EVP_sha1(), NULL) != 1) {
        return ret_err("sha1 failed");
    }
    return ret_tagged('K', digest, digestLen);
}

/* CONVEXTLS[6] Bs : resolve(hostname) -> "K:<uint32 host-byte-order decimal>"
 *
 * client/convex.apl's plain (non-TLS) path needs this too: ⎕FIO[36]'s
 * own connect(Bh, Aa) takes Aa as (family ip32 port) with the IP
 * already resolved to a 32-bit integer -- GNU APL has no getaddrinfo
 * of its own to produce that. */
static Token op_resolve(Value_P B) {
    ensure_init();
    unsigned char raw[256];
    size_t n = value_to_bytes(B, raw, sizeof(raw) - 1);
    raw[n] = 0;

    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *res = NULL;
    if (getaddrinfo((const char *)raw, NULL, &hints, &res) != 0 || res == NULL) {
        return ret_err("dns resolution failed");
    }
    struct sockaddr_in *sin = (struct sockaddr_in *)res->ai_addr;
    unsigned long hostOrder = ntohl(sin->sin_addr.s_addr);
    freeaddrinfo(res);

    char buf[24];
    snprintf(buf, sizeof(buf), "%lu", hostOrder);
    return ret_ok_text(buf);
}

/* CONVEXTLS[7] Bi : random(nBytes) -> "K:<nBytes raw bytes>"
 *
 * RFC 6455 needs unpredictable bytes twice: the Sec-WebSocket-Key sent
 * in the handshake and a fresh masking key on every client->server
 * frame. GNU APL has no CSPRNG of its own and this shim already links
 * OpenSSL for TLS, so RAND_bytes is the same "delegate the one
 * general-purpose primitive that isn't really transport" reasoning
 * already used for SHA-1 above -- everything about *how* those bytes
 * become a handshake key, an Accept check, or a masked frame stays in
 * client/convexlive.apl, in APL. */
static Token op_random(Value_P B) {
    ensure_init();
    long n = 16;
    if (B->element_count() > 0) n = B->get_cfirst().get_int_value();
    if (n < 1) n = 1;
    if (n > 4096) n = 4096;
    unsigned char buf[4096];
    if (RAND_bytes(buf, (int)n) != 1) return ret_err("random bytes failed");
    return ret_tagged('K', buf, (size_t)n);
}

/* CONVEXTLS[4] Bh : close(Bh) -> "K:" always */
static Token op_close(Value_P B) {
    ensure_init();
    int handle = handle_of(B);
    if (handle >= 0 && handle < MAX_SLOTS && slots[handle].inUse) {
        SSL_shutdown(slots[handle].ssl);
        SSL_free(slots[handle].ssl);
        close(slots[handle].fd);
        slots[handle].inUse = 0;
        slots[handle].ssl = NULL;
    }
    return ret_tagged('K', NULL, 0);
}

static Token list_functions() {
    return ret_ok_text(
        "CONVEXTLS: 'lib' (quad)FX 'CONVEXTLS'\n"
        "  Zh <- CONVEXTLS[1] Bs        connect, Bs = \"host port\"\n"
        "  Zi <- Ab CONVEXTLS[2] Bh     send byte-vector Ab\n"
        "  Zb <- Ai CONVEXTLS[3] Bh     recv, Ai = maxBytes timeoutMs\n"
        "  Zk <- CONVEXTLS[4] Bh        close\n"
        "  Zd <- CONVEXTLS[5] Bb        sha1 digest of byte-vector Bb\n"
        "  Zh <- CONVEXTLS[6] Bs        resolve hostname Bs to a uint32\n"
        "  Zb <- CONVEXTLS[7] Bi        nBytes of CSPRNG output\n");
}

static Token eval_B(Value_P B, const NativeFunction *caller) {
    (void)caller;
    (void)B;
    return list_functions();
}

static Token eval_XB(Value_P X, Value_P B, const NativeFunction *caller) {
    (void)caller;
    long op = X->get_cfirst().get_int_value();
    switch (op) {
        case 1: return op_connect(B);
        case 4: return op_close(B);
        case 5: return op_sha1(B);
        case 6: return op_resolve(B);
        case 7: return op_random(B);
        default: return ret_err("unknown axis (send/recv need a left argument)");
    }
}

static Token eval_AXB(Value_P A, Value_P X, Value_P B, const NativeFunction *caller) {
    (void)caller;
    long op = X->get_cfirst().get_int_value();
    switch (op) {
        case 2: return op_send(A, B);
        case 3: return op_recv(A, B);
        default: return ret_err("unknown axis");
    }
}

extern "C" void *get_function_mux(const char *function_name) {
    if (!strcmp(function_name, "get_signature")) return reinterpret_cast<void *>(&get_signature);
    if (!strcmp(function_name, "close_fun")) return reinterpret_cast<void *>(&close_fun);
    if (!strcmp(function_name, "eval_B")) return reinterpret_cast<void *>(&eval_B);
    if (!strcmp(function_name, "eval_XB")) return reinterpret_cast<void *>(&eval_XB);
    if (!strcmp(function_name, "eval_AXB")) return reinterpret_cast<void *>(&eval_AXB);
    return 0;
}
