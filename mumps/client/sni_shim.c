/*
 * sni_shim.c -- LD_PRELOAD interposer that adds TLS Server Name Indication
 * (SNI) to every outgoing client TLS connection this process makes.
 *
 * This is pure transport plumbing, not a Convex client: it contains no
 * Convex, HTTP, JSON, or WebSocket logic, matching the same narrow-shim
 * pattern this project already uses elsewhere (see icon/client/shim.c) for
 * a language runtime missing exactly one native primitive.
 *
 * Why this exists: YottaDB's own TLS plugin (YDBEncrypt's gtm_tls_impl.c,
 * confirmed by reading its source) never calls SSL_set_tlsext_host_name,
 * and the WRITE /TLS command's documented configuration-file options
 * (CAFile, CApath, cipher-list, crl, format, cert, key, session-id-hex,
 * session-timeout, ssl-options, verify-depth, verify-level, verify-mode --
 * see YottaDB's "Creating a TLS Configuration File" appendix) have no
 * SNI-related knob either. A modern TLS-terminating front that selects a
 * certificate by SNI -- which is exactly what a real Convex hosted
 * deployment sits behind -- rejects a ClientHello with no server name with
 * a generic "handshake failure" alert. This was reproduced directly with
 * `openssl s_client -noservername` against the same hosted deployment this
 * client's own connection was failing against, confirming SNI (not a cipher
 * or protocol-version mismatch) was the exact cause.
 *
 * This interposes SSL_connect(): before delegating to the real OpenSSL
 * implementation (found via dlsym(RTLD_NEXT, ...), the standard technique
 * for a preload shim that still needs the symbol it overrides), it sets the
 * SNI hostname from CONVEX_URL, which is already how every client
 * connection in this process picks its target host. The parse is
 * deliberately the same shape as convex.m's own parseUrl: skip an optional
 * "scheme://" prefix, then stop at the first '/' or ':'.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <openssl/ssl.h>

typedef int (*ssl_connect_fn)(SSL *);

int SSL_connect(SSL *ssl) {
    static ssl_connect_fn real_connect = NULL;
    static char hostname[256];
    static int hostname_ready = 0;

    if (real_connect == NULL) {
        real_connect = (ssl_connect_fn)dlsym(RTLD_NEXT, "SSL_connect");
    }

    /* CONVEX_URL never changes for the life of this process, so the host
     * only needs parsing out once, on the first TLS connection attempt. */
    if (!hostname_ready) {
        hostname_ready = 1;
        hostname[0] = '\0';
        const char *url = getenv("CONVEX_URL");
        if (url != NULL) {
            const char *scheme_end = strstr(url, "://");
            const char *host_start = (scheme_end != NULL) ? scheme_end + 3 : url;
            size_t i = 0;
            while (host_start[i] != '\0' && host_start[i] != '/' && host_start[i] != ':' &&
                   i < sizeof(hostname) - 1) {
                hostname[i] = host_start[i];
                i++;
            }
            hostname[i] = '\0';
        }
    }

    if (hostname[0] != '\0') {
        SSL_set_tlsext_host_name(ssl, hostname);
    }

    return real_connect(ssl);
}
