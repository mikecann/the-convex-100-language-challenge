/*
 * convexrt-tls.c - the only native code this client adds to pclu, beyond
 * the wordvec-64bit-word-size.patch fix. It is a brand-new C-implemented
 * CLU builtin cluster, added the same way pclu's own hand-written
 * primitives (_chan, _wordvec, ...) are added: _tls.spc is an interface
 * file with empty proc bodies that the compiler type-checks CLU source
 * against, and this file supplies the matching <type>OP<opname> C
 * functions that the linker resolves by name when it links
 * libpclu_opt.a. Nothing here is dynamically loaded; this is compiled
 * straight into the runtime archive -- the same "rebuild the
 * runtime/compiler with an extra builtin" shape as SETL's callskel and
 * SNOBOL4's client/convexrt.c in this repository.
 *
 * Unlike _chan (raw sockets, byte-packed by the CLU caller) everything
 * here -- DNS, socket(), connect(), the TLS handshake and certificate
 * verification -- is done in this one C file and exposed as a few
 * high-level CLU operations (connect/send/recv/close), because that is
 * the natural boundary for a capability pclu has no notion of at all:
 * TLS. It contains no HTTP, no WebSocket framing, no JSON and no Convex
 * protocol knowledge; every deadline, retry, and protocol decision for
 * the hosted profile is enforced in CLU source, in client/*.clu.
 */

#include "pclu_err.h"
#include "pclu_sys.h"

#include <errno.h>
#include <netdb.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>

#define TLS_MAX_HANDLES 16
#define TLS_RECV_CHUNK  16384

typedef struct {
    int used;
    int fd;
    SSL *ssl;
    SSL_CTX *ctx;
} tls_handle;

static tls_handle tls_handles[TLS_MAX_HANDLES];
static int tls_lib_ready = 0;

static void
tls_ensure_lib(void)
{
    if (tls_lib_ready)
	return;
    tls_lib_ready = 1;
    SSL_library_init();
    SSL_load_error_strings();
}

static int
tls_alloc_slot(void)
{
    for (int i = 0; i < TLS_MAX_HANDLES; i++)
	if (!tls_handles[i].used)
	    return i;
    return -1;
}

/* Builds a CLU string CLUREF from a raw C buffer, the same allocation
 * shape _wordvecOPcreate uses (a CT_STRING-tagged CLU_string). */
static CLUREF
tls_make_string(const char *buf, size_t n)
{
    size_t bufsz = CLU_roundup(offsetof(CLU_string, data) + n + 1, CLUREFSZ);
    CLUREF s;
    clu_alloc(bufsz, &s);
    CLUTYPE_set(s.str->typ, CT_STRING);
    s.str->size = (long)n;
    memcpy(s.str->data, buf, n);
    return s;
}

static void
tls_close_handle(tls_handle *h)
{
    if (h->ssl) {
	SSL_shutdown(h->ssl);
	SSL_free(h->ssl);
	h->ssl = NULL;
    }
    if (h->ctx) {
	SSL_CTX_free(h->ctx);
	h->ctx = NULL;
    }
    if (h->fd >= 0) {
	close(h->fd);
	h->fd = -1;
    }
    h->used = 0;
}

/*
 * connect = proc (host: string, port: int) returns (cvt)
 *				 signals (not_possible(string))
 */
errcode
_tlsOPconnect(CLUREF host, CLUREF port, CLUREF *ans)
{
    static char errbuf[256];
    char hostbuf[256];
    char portbuf[16];
    struct addrinfo hints, *res = NULL, *rp;
    int fd = -1;
    tls_handle *h;
    int slot;

    tls_ensure_lib();

    if ((size_t)host.str->size >= sizeof(hostbuf)) {
	elist[0] = tls_make_string("host name too long", 19);
	signal(ERR_not_possible);
    }
    memcpy(hostbuf, host.str->data, host.str->size);
    hostbuf[host.str->size] = '\0';
    snprintf(portbuf, sizeof(portbuf), "%ld", port.num);

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    int gai = getaddrinfo(hostbuf, portbuf, &hints, &res);
    if (gai != 0) {
	snprintf(errbuf, sizeof(errbuf), "getaddrinfo: %s", gai_strerror(gai));
	elist[0] = tls_make_string(errbuf, strlen(errbuf));
	signal(ERR_not_possible);
    }

    for (rp = res; rp != NULL; rp = rp->ai_next) {
	fd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
	if (fd < 0)
	    continue;
	if (connect(fd, rp->ai_addr, rp->ai_addrlen) == 0)
	    break;
	close(fd);
	fd = -1;
    }
    freeaddrinfo(res);

    if (fd < 0) {
	snprintf(errbuf, sizeof(errbuf), "connect: %s", strerror(errno));
	elist[0] = tls_make_string(errbuf, strlen(errbuf));
	signal(ERR_not_possible);
    }

    slot = tls_alloc_slot();
    if (slot < 0) {
	close(fd);
	elist[0] = tls_make_string("too many open _tls handles", 27);
	signal(ERR_not_possible);
    }
    h = &tls_handles[slot];
    memset(h, 0, sizeof(*h));
    h->fd = fd;

    h->ctx = SSL_CTX_new(TLS_client_method());
    if (!h->ctx) {
	close(fd);
	elist[0] = tls_make_string("SSL_CTX_new failed", 19);
	signal(ERR_not_possible);
    }
    SSL_CTX_set_min_proto_version(h->ctx, TLS1_2_VERSION);
    SSL_CTX_set_verify(h->ctx, SSL_VERIFY_PEER, NULL);
    if (!SSL_CTX_set_default_verify_paths(h->ctx)) {
	tls_close_handle(h);
	elist[0] = tls_make_string("SSL_CTX_set_default_verify_paths failed",
				    40);
	signal(ERR_not_possible);
    }

    h->ssl = SSL_new(h->ctx);
    if (!h->ssl) {
	tls_close_handle(h);
	elist[0] = tls_make_string("SSL_new failed", 14);
	signal(ERR_not_possible);
    }

    /* Hostname verification (RFC 6125) -- not just "a cert", *this* cert
     * for *this* name. Requires OpenSSL >= 1.0.2. */
    X509_VERIFY_PARAM *vpm = SSL_get0_param(h->ssl);
    X509_VERIFY_PARAM_set_hostflags(vpm, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
    if (!X509_VERIFY_PARAM_set1_host(vpm, hostbuf, 0)) {
	tls_close_handle(h);
	elist[0] = tls_make_string("X509_VERIFY_PARAM_set1_host failed", 35);
	signal(ERR_not_possible);
    }

    /* SNI */
    SSL_set_tlsext_host_name(h->ssl, hostbuf);

    SSL_set_fd(h->ssl, fd);

    int rc = SSL_connect(h->ssl);
    if (rc != 1) {
	unsigned long e = ERR_get_error();
	snprintf(errbuf, sizeof(errbuf), "SSL_connect failed: %s",
		 ERR_reason_error_string(e) ? ERR_reason_error_string(e)
					     : "unknown");
	tls_close_handle(h);
	elist[0] = tls_make_string(errbuf, strlen(errbuf));
	signal(ERR_not_possible);
    }

    long verify_result = SSL_get_verify_result(h->ssl);
    if (verify_result != X509_V_OK) {
	snprintf(errbuf, sizeof(errbuf), "certificate verify failed: %s",
		 X509_verify_cert_error_string(verify_result));
	tls_close_handle(h);
	elist[0] = tls_make_string(errbuf, strlen(errbuf));
	signal(ERR_not_possible);
    }

    h->used = 1;
    ans->num = slot + 1;	/* CLU-facing handle: 1-based small int */
    signal(ERR_ok);
}

/*
 * send = proc (t: cvt, s: string) signals (not_possible(string))
 */
errcode
_tlsOPsend(CLUREF t, CLUREF s)
{
    static char errbuf[128];
    int idx = (int)t.num - 1;

    if (idx < 0 || idx >= TLS_MAX_HANDLES || !tls_handles[idx].used) {
	elist[0] = tls_make_string("bad _tls handle", 15);
	signal(ERR_not_possible);
    }
    tls_handle *h = &tls_handles[idx];

    long off = 0;
    while (off < s.str->size) {
	int n = SSL_write(h->ssl, s.str->data + off, (int)(s.str->size - off));
	if (n <= 0) {
	    snprintf(errbuf, sizeof(errbuf), "SSL_write failed: %d",
		     SSL_get_error(h->ssl, n));
	    elist[0] = tls_make_string(errbuf, strlen(errbuf));
	    signal(ERR_not_possible);
	}
	off += n;
    }
    signal(ERR_ok);
}

/*
 * recv = proc (t: cvt, maxlen: int) returns (string)
 *				     signals (not_possible(string), end_of_file)
 */
errcode
_tlsOPrecv(CLUREF t, CLUREF maxlen, CLUREF *ans)
{
    static char errbuf[128];
    int idx = (int)t.num - 1;
    char buf[TLS_RECV_CHUNK];
    long want;

    if (idx < 0 || idx >= TLS_MAX_HANDLES || !tls_handles[idx].used) {
	elist[0] = tls_make_string("bad _tls handle", 15);
	signal(ERR_not_possible);
    }
    tls_handle *h = &tls_handles[idx];

    want = maxlen.num;
    if (want <= 0 || want > TLS_RECV_CHUNK)
	want = TLS_RECV_CHUNK;

    int n = SSL_read(h->ssl, buf, (int)want);
    if (n < 0) {
	snprintf(errbuf, sizeof(errbuf), "SSL_read failed: %d",
		 SSL_get_error(h->ssl, n));
	elist[0] = tls_make_string(errbuf, strlen(errbuf));
	signal(ERR_not_possible);
    }
    if (n == 0)
	signal(ERR_end_of_file);

    *ans = tls_make_string(buf, (size_t)n);
    signal(ERR_ok);
}

/*
 * close = proc (t: cvt) signals (not_possible(string))
 */
errcode
_tlsOPclose(CLUREF t)
{
    int idx = (int)t.num - 1;

    if (idx < 0 || idx >= TLS_MAX_HANDLES || !tls_handles[idx].used) {
	elist[0] = tls_make_string("bad _tls handle", 15);
	signal(ERR_not_possible);
    }
    tls_close_handle(&tls_handles[idx]);
    signal(ERR_ok);
}
