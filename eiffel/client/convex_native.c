/* See convex_native.h. */
#include "convex_native.h"

#include <sys/select.h>
#include <sys/socket.h>
#include <string.h>
#include <errno.h>

#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>

#include <time.h>
#include <unistd.h>
#include <signal.h>

void *
convex_tls_connect (int fd, const char *hostname)
{
	const SSL_METHOD *method;
	SSL_CTX *ctx;
	SSL *ssl;
	long verify_result;
	int rc;

	OPENSSL_init_ssl (0, NULL);
	method = TLS_client_method ();
	ctx = SSL_CTX_new (method);
	if (ctx == NULL) {
		return NULL;
	}
	SSL_CTX_set_verify (ctx, SSL_VERIFY_PEER, NULL);
	SSL_CTX_set_default_verify_paths (ctx);
	SSL_CTX_set_min_proto_version (ctx, TLS1_2_VERSION);

	ssl = SSL_new (ctx);
	/* SSL_new bumps ctx's refcount; drop ours immediately so the context
	 * is freed automatically when SSL_free later drops the last
	 * reference. */
	SSL_CTX_free (ctx);
	if (ssl == NULL) {
		return NULL;
	}
	SSL_set_fd (ssl, fd);
	SSL_set_tlsext_host_name (ssl, hostname);
	SSL_set1_host (ssl, hostname);

	{
		int ssl_error;
		do {
			rc = SSL_connect (ssl);
			if (rc == 1) {
				break;
			}
			ssl_error = SSL_get_error (ssl, rc);
		} while (ssl_error == SSL_ERROR_SYSCALL && errno == EINTR);
	}
	if (rc != 1) {
		SSL_free (ssl);
		return NULL;
	}

	verify_result = SSL_get_verify_result (ssl);
	if (verify_result != X509_V_OK) {
		SSL_shutdown (ssl);
		SSL_free (ssl);
		return NULL;
	}

	return ssl;
}

const char *
convex_tls_last_error (void)
{
	static char buf[256];
	unsigned long code = ERR_get_error ();
	if (code == 0) {
		return "no TLS error recorded";
	}
	ERR_error_string_n (code, buf, sizeof (buf));
	return buf;
}

int
convex_tls_write (void *ssl, const void *data, int count)
{
	int rc;
	int ssl_error;
	do {
		rc = SSL_write ((SSL *) ssl, data, count);
		if (rc > 0) {
			return rc;
		}
		ssl_error = SSL_get_error ((SSL *) ssl, rc);
	} while (ssl_error == SSL_ERROR_SYSCALL && errno == EINTR);
	return rc;
}

int
convex_tls_read (void *ssl, void *buffer, int max)
{
	int rc;
	int ssl_error;
	do {
		rc = SSL_read ((SSL *) ssl, buffer, max);
		if (rc > 0) {
			return rc;
		}
		ssl_error = SSL_get_error ((SSL *) ssl, rc);
	} while (ssl_error == SSL_ERROR_SYSCALL && errno == EINTR);
	return rc;
}

int
convex_tls_pending (void *ssl)
{
	return SSL_pending ((SSL *) ssl);
}

void
convex_tls_close (void *ssl)
{
	SSL_shutdown ((SSL *) ssl);
	SSL_free ((SSL *) ssl);
}

int
convex_raw_write (int fd, const void *data, int count)
{
	int rc;
	do {
		rc = (int) send (fd, data, (size_t) count, 0);
	} while (rc < 0 && errno == EINTR);
	return rc;
}

int
convex_raw_read (int fd, void *buffer, int max)
{
	int rc;
	do {
		rc = (int) recv (fd, buffer, (size_t) max, 0);
	} while (rc < 0 && errno == EINTR);
	return rc;
}

int
convex_generic_write (int fd, const void *data, int count)
{
	int rc;
	do {
		rc = (int) write (fd, data, (size_t) count);
	} while (rc < 0 && errno == EINTR);
	return rc;
}

int
convex_generic_read (int fd, void *buffer, int max)
{
	int rc;
	do {
		rc = (int) read (fd, buffer, (size_t) max);
	} while (rc < 0 && errno == EINTR);
	return rc;
}

int
convex_select_one (int fd, int timeout_ms)
{
	fd_set readfds;
	struct timeval tv;
	int rc;

	/* EiffelStudio's runtime (GC, thread scheduling) can deliver signals
	 * that legitimately interrupt a blocking syscall; POSIX select(2)
	 * reports that as EINTR, not a real error. Retrying (with a fresh
	 * deadline, since a signal-handling implementation may leave *tv in
	 * an unspecified state) is the correct response, not surfacing it as
	 * a failure to Eiffel, whose own runtime would otherwise misreport
	 * an ordinary interrupted wait as a trapped "operating system
	 * signal" exception and kill the process. */
	do {
		FD_ZERO (&readfds);
		FD_SET (fd, &readfds);
		tv.tv_sec = timeout_ms / 1000;
		tv.tv_usec = (timeout_ms % 1000) * 1000;
		rc = select (fd + 1, &readfds, NULL, NULL, &tv);
	} while (rc < 0 && errno == EINTR);
	if (rc <= 0) {
		return 0;
	}
	return FD_ISSET (fd, &readfds) ? 1 : 0;
}

unsigned int
convex_random_seed (void)
{
	return ((unsigned int) getpid () * 2654435761u) ^ (unsigned int) time (NULL);
}

void
convex_ignore_sigpipe (void)
{
	signal (SIGPIPE, SIG_IGN);
}

int
convex_select_two (int fd_one, int fd_two, int timeout_ms)
{
	fd_set readfds;
	struct timeval tv;
	int max_fd;
	int rc;
	int result;

	do {
		FD_ZERO (&readfds);
		max_fd = 0;
		if (fd_one >= 0) {
			FD_SET (fd_one, &readfds);
			if (fd_one > max_fd) max_fd = fd_one;
		}
		if (fd_two >= 0) {
			FD_SET (fd_two, &readfds);
			if (fd_two > max_fd) max_fd = fd_two;
		}
		tv.tv_sec = timeout_ms / 1000;
		tv.tv_usec = (timeout_ms % 1000) * 1000;
		rc = select (max_fd + 1, &readfds, NULL, NULL, &tv);
	} while (rc < 0 && errno == EINTR);
	if (rc <= 0) {
		return 0;
	}
	result = 0;
	if (fd_one >= 0 && FD_ISSET (fd_one, &readfds)) result |= 1;
	if (fd_two >= 0 && FD_ISSET (fd_two, &readfds)) result |= 2;
	return result;
}
