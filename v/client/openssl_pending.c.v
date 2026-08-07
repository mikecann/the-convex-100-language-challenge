module convex

import net.ssl

#include <openssl/ssl.h>

fn C.SSL_pending(ssl voidptr) int

// This is deliberately a generic TLS-transport boundary, not a Convex or
// WebSocket boundary: it answers only whether OpenSSL has already-decrypted
// bytes. V owns every protocol decision above it. The V 0.4.9 Docker gate must
// still compile this against its pinned `net.ssl.SSLConn` layout before any
// capability is earned.
fn tls_transport_has_pending(handle voidptr) bool {
	return handle != unsafe { nil } && C.SSL_pending(handle) > 0
}

// OpenSSL may have decrypted bytes that are no longer visible as TCP
// readability. This wrapper keeps the V-library detail at the transport seam
// and prevents the Live owner from stranding an already-buffered frame.
fn openssl_has_pending(conn &ssl.SSLConn) bool {
	return tls_transport_has_pending(voidptr(conn.ssl))
}
