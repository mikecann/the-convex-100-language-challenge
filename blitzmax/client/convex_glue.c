/*
 * Tiny C shims for the BlitzMax Convex client.
 *
 * BlitzMax NG's Net.mbedtls module exposes mbedtls_ctr_drbg_random and
 * mbedtls_ssl_set_hostname only through its own Object-typed extern bindings,
 * used exclusively as pass-by-reference callback values for its own C calls.
 * This client also needs to call those two functions directly, with a plain
 * pointer, which is the type mbedtls's C API actually declares. Declaring a
 * second BlitzMax extern straight onto the same C symbol name would give
 * that one symbol two conflicting prototypes in one translation unit, which
 * is a hard error, not merely a warning, in every C compiler. These shims
 * exist under names of their own so that never happens: each one forwards to
 * the real mbedtls function using the one true C signature, so the
 * corresponding BlitzMax extern in transport.bmx only ever has to describe
 * the plain-pointer shim, never the library function itself.
 *
 * clock_gettime and setenv are the same story with a system header standing
 * in for the module: glibc's <time.h> already declares clock_gettime against
 * struct timespec, and <stdlib.h> already declares setenv's two names as
 * "const char *" rather than the "unsigned char *" a Byte Ptr parameter
 * generates, so a direct extern binding onto either symbol conflicts with
 * the declaration the standard header already provided. Both shims below
 * call the real function with its real signature and adapt the bytes at the
 * boundary instead.
 */

#include <stddef.h>
#include <stdlib.h>
#include <time.h>

extern int mbedtls_ctr_drbg_random(void *p_rng, unsigned char *output, size_t output_len);
extern int mbedtls_ssl_set_hostname(void *ssl, const char *hostname);

int convex_glue_ctr_drbg_random(void *context, unsigned char *output, size_t length) {
	return mbedtls_ctr_drbg_random(context, output, length);
}

int convex_glue_ssl_set_hostname(void *ssl, const char *hostname) {
	return mbedtls_ssl_set_hostname(ssl, hostname);
}

int convex_glue_clock_gettime(int clock_id, long long *out) {
	struct timespec ts;
	int rc = clock_gettime((clockid_t)clock_id, &ts);
	if (rc == 0) {
		out[0] = (long long)ts.tv_sec;
		out[1] = (long long)ts.tv_nsec;
	}
	return rc;
}

int convex_glue_setenv(const unsigned char *name, const unsigned char *value, int overwrite) {
	return setenv((const char *)name, (const char *)value, overwrite);
}
