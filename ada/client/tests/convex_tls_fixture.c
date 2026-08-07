/*
 * Test-only TLS peer for the Ada client's hostname-verification evidence.
 *
 * Proving that the client checks the certificate *name* separately from the
 * certificate *chain* needs a certificate the client trusts as its own anchor
 * whose name does not match the host it dialled. This repository must never
 * carry a private key in a fixture, so every key here is minted at test time,
 * lives only in this process, and dies with it. The one thing written to disk
 * is the CA certificate, which the Docker test stage installs as the only
 * trusted anchor for the duration of the test and then removes.
 *
 * Two ports are served in order, from one CA:
 *   argv[2]  a leaf whose subjectAltName is DNS:localhost   -> must be trusted
 *   argv[3]  a leaf whose subjectAltName is DNS:wrong.invalid -> must be refused
 *
 * The only difference between them is the name, so a client that accepts the
 * first and rejects the second has demonstrated hostname verification rather
 * than chain verification.
 *
 * This is a test peer. The Convex client under test remains native Ada.
 */

#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>

#define REQUEST_LIMIT 65536

static void fail(const char *what)
{
    fprintf(stderr, "convex_tls_fixture: %s\n", what);
    ERR_print_errors_fp(stderr);
    exit(1);
}

static EVP_PKEY *generate_key(void)
{
    EVP_PKEY *key = EVP_RSA_gen(2048);

    if (key == NULL) {
        fail("key generation failed");
    }
    return key;
}

static void add_extension(X509 *certificate, X509 *issuer, int nid,
                          const char *value)
{
    X509V3_CTX context;
    X509_EXTENSION *extension;

    X509V3_set_ctx_nodb(&context);
    X509V3_set_ctx(&context, issuer == NULL ? certificate : issuer,
                   certificate, NULL, NULL, 0);
    extension = X509V3_EXT_conf_nid(NULL, &context, nid, value);
    if (extension == NULL) {
        fail("extension encoding failed");
    }
    if (X509_add_ext(certificate, extension, -1) != 1) {
        fail("extension could not be added");
    }
    X509_EXTENSION_free(extension);
}

/*
 * One certificate builder for both roles. Passing a NULL issuer produces the
 * self-signed CA; passing the CA produces a leaf signed by it.
 */
static X509 *make_certificate(EVP_PKEY *key, const char *common_name,
                              const char *subject_alt_name, X509 *issuer,
                              EVP_PKEY *issuer_key, long serial)
{
    X509 *certificate = X509_new();
    X509_NAME *subject;

    if (certificate == NULL) {
        fail("certificate allocation failed");
    }
    /* Value 2 is an X.509 v3 certificate; v3 is required for extensions. */
    if (X509_set_version(certificate, 2) != 1) {
        fail("certificate version could not be set");
    }
    if (ASN1_INTEGER_set(X509_get_serialNumber(certificate), serial) != 1) {
        fail("certificate serial could not be set");
    }
    if (X509_gmtime_adj(X509_getm_notBefore(certificate), -3600) == NULL
        || X509_gmtime_adj(X509_getm_notAfter(certificate), 3600) == NULL) {
        fail("certificate validity could not be set");
    }
    if (X509_set_pubkey(certificate, key) != 1) {
        fail("certificate public key could not be set");
    }
    subject = X509_get_subject_name(certificate);
    if (X509_NAME_add_entry_by_txt(subject, "CN", MBSTRING_ASC,
                                   (const unsigned char *)common_name, -1, -1,
                                   0) != 1) {
        fail("certificate subject could not be set");
    }
    if (X509_set_issuer_name(certificate,
                             issuer == NULL ? subject
                                            : X509_get_subject_name(issuer))
        != 1) {
        fail("certificate issuer could not be set");
    }
    if (issuer == NULL) {
        add_extension(certificate, NULL, NID_basic_constraints,
                      "critical,CA:TRUE");
        add_extension(certificate, NULL, NID_key_usage,
                      "critical,keyCertSign,cRLSign");
    } else {
        add_extension(certificate, issuer, NID_basic_constraints,
                      "critical,CA:FALSE");
        add_extension(certificate, issuer, NID_key_usage,
                      "critical,digitalSignature,keyEncipherment");
        add_extension(certificate, issuer, NID_ext_key_usage, "serverAuth");
        add_extension(certificate, issuer, NID_subject_alt_name,
                      subject_alt_name);
    }
    if (X509_sign(certificate, issuer_key == NULL ? key : issuer_key,
                  EVP_sha256())
        == 0) {
        fail("certificate could not be signed");
    }
    return certificate;
}

/*
 * The trust store is replaced with this file before the Ada test starts, so
 * publish it atomically: a reader must never see a half-written anchor.
 */
static void write_certificate(const char *path, X509 *certificate)
{
    char partial[4096];
    FILE *out;

    if (snprintf(partial, sizeof partial, "%s.partial", path)
        >= (int)sizeof partial) {
        fail("certificate path is too long");
    }
    out = fopen(partial, "w");
    if (out == NULL) {
        fail("certificate file could not be opened");
    }
    if (PEM_write_X509(out, certificate) != 1) {
        fail("certificate file could not be written");
    }
    if (fclose(out) != 0) {
        fail("certificate file could not be flushed");
    }
    if (rename(partial, path) != 0) {
        fail("certificate file could not be published");
    }
}

static int listen_on(unsigned short port)
{
    struct sockaddr_in address;
    int enabled = 1;
    int listener = socket(AF_INET, SOCK_STREAM, 0);

    if (listener < 0) {
        fail("listening socket could not be created");
    }
    if (setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &enabled,
                   sizeof enabled)
        != 0) {
        fail("listening socket could not be configured");
    }
    memset(&address, 0, sizeof address);
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(listener, (struct sockaddr *)&address, sizeof address) != 0) {
        fail("listening socket could not be bound");
    }
    if (listen(listener, 1) != 0) {
        fail("listening socket could not listen");
    }
    return listener;
}

/*
 * Consume the complete request before answering. Closing on unread request
 * bytes can reset the connection before the client has read the response,
 * which would look like a transport failure in the case that must succeed.
 */
static void read_request(SSL *connection)
{
    char request[REQUEST_LIMIT];
    size_t filled = 0;
    size_t needed = 0;

    while (filled < sizeof request - 1) {
        char *separator;
        int received = SSL_read(connection, request + filled,
                                (int)(sizeof request - 1 - filled));

        if (received <= 0) {
            return;
        }
        filled += (size_t)received;
        request[filled] = '\0';
        separator = strstr(request, "\r\n\r\n");
        if (separator != NULL) {
            const char *header = strstr(request, "Content-Length: ");

            if (needed == 0) {
                needed = (size_t)(separator - request) + 4;
                if (header != NULL && header < separator) {
                    needed += (size_t)atol(header + strlen("Content-Length: "));
                }
            }
            if (filled >= needed) {
                return;
            }
        }
    }
}

static void write_all(SSL *connection, const char *text)
{
    size_t sent = 0;
    size_t length = strlen(text);

    while (sent < length) {
        int written = SSL_write(connection, text + sent, (int)(length - sent));

        if (written <= 0) {
            return;
        }
        sent += (size_t)written;
    }
}

static void serve_once(int listener, X509 *certificate, EVP_PKEY *key,
                       int must_handshake)
{
    static const char envelope[] = "{\"status\":\"success\",\"value\":11}";
    char response[512];
    SSL_CTX *context = SSL_CTX_new(TLS_server_method());
    SSL *connection;
    int client = accept(listener, NULL, NULL);

    if (client < 0) {
        fail("connection could not be accepted");
    }
    if (context == NULL) {
        fail("server context could not be created");
    }
    if (SSL_CTX_use_certificate(context, certificate) != 1) {
        fail("server certificate could not be installed");
    }
    if (SSL_CTX_use_PrivateKey(context, key) != 1) {
        fail("server key could not be installed");
    }
    connection = SSL_new(context);
    if (connection == NULL) {
        fail("server connection could not be created");
    }
    if (SSL_set_fd(connection, client) != 1) {
        fail("server connection could not take the socket");
    }
    if (SSL_accept(connection) == 1) {
        /*
         * On the mismatched port the client is the side that refuses, and a
         * TLS server can regard its own half of the handshake as finished
         * before that refusal arrives. Nothing is asserted here: the client
         * is the thing under test, and it is asserted in the Ada test.
         */
        if (must_handshake) {
            read_request(connection);
            snprintf(response, sizeof response,
                     "HTTP/1.1 200 OK\r\n"
                     "Content-Type: application/json\r\n"
                     "Content-Length: %u\r\n"
                     "Connection: close\r\n"
                     "\r\n"
                     "%s",
                     (unsigned)strlen(envelope), envelope);
            write_all(connection, response);
            SSL_shutdown(connection);
        }
    } else if (must_handshake) {
        fail("the trusted certificate was refused");
    } else {
        /* The rejection under test. Clear the queued error and carry on. */
        ERR_clear_error();
    }
    SSL_free(connection);
    close(client);
    SSL_CTX_free(context);
}

int main(int argc, char **argv)
{
    EVP_PKEY *authority_key;
    EVP_PKEY *matching_key;
    EVP_PKEY *mismatched_key;
    X509 *authority;
    X509 *matching;
    X509 *mismatched;
    int matching_listener;
    int mismatched_listener;

    if (argc != 4) {
        fprintf(stderr,
                "usage: convex_tls_fixture <ca-path> <match-port>"
                " <mismatch-port>\n");
        return 2;
    }
    /* No test peer of this repository may outlive the build step. */
    alarm(120);

    authority_key = generate_key();
    authority = make_certificate(authority_key, "convex-ada-ephemeral-test-ca",
                                 NULL, NULL, NULL, 1);
    matching_key = generate_key();
    matching = make_certificate(matching_key, "localhost", "DNS:localhost",
                                authority, authority_key, 2);
    mismatched_key = generate_key();
    mismatched = make_certificate(mismatched_key, "wrong.invalid",
                                  "DNS:wrong.invalid", authority, authority_key,
                                  3);

    /* Listen before publishing the anchor: the caller treats the anchor file
       as the signal that both ports are ready to accept. */
    matching_listener = listen_on((unsigned short)atoi(argv[2]));
    mismatched_listener = listen_on((unsigned short)atoi(argv[3]));
    write_certificate(argv[1], authority);

    serve_once(matching_listener, matching, matching_key, 1);
    serve_once(mismatched_listener, mismatched, mismatched_key, 0);

    close(matching_listener);
    close(mismatched_listener);
    X509_free(matching);
    X509_free(mismatched);
    X509_free(authority);
    EVP_PKEY_free(matching_key);
    EVP_PKEY_free(mismatched_key);
    EVP_PKEY_free(authority_key);
    return 0;
}
