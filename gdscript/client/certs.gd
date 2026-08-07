class_name ConvexCerts
extends RefCounted

# Godot only loads its compiled-in (or system) certificate authority bundle
# through Crypto::load_default_certificates(), a C++-only static method with
# no GDScript binding. The engine calls it exactly once, from the "game"
# branch of Main::start(), which only runs when Godot is started against a
# main scene. This client never is: the runtime images start the adapter and
# the example with --script (see the Dockerfile's --main-pack/--script
# comment - naming a global class through run/main_loop_type does not
# resolve when Godot is started with --main-pack alone, so --script names the
# entry point explicitly instead), and a bare --script SceneTree never takes
# that branch. Crypto::get_default_certificates() then returns null for the
# whole process, and every TLSOptions.client() connection - the client's
# default when no explicit trust chain is supplied - fails immediately with
# "SSL module failed to initialize!". Confirmed to reproduce identically,
# under this exact --script invocation, on every stable release from 4.2
# through 4.5 (4.1.4 was the one tested exception - its main.cpp reaches the
# certificate-loading call some other way this client does not depend on).
# It is not a version-specific engine regression, not an mbedTLS bug, and not
# a PSA-crypto bug: it is Main::start() never reaching the one line that
# loads a trust store for this launch shape.
#
# TLSOptions.client() also accepts an explicit trusted certificate chain,
# which is checked before Crypto::get_default_certificates() and bypasses it
# entirely (see modules/mbedtls/tls_context_mbedtls.cpp's init_client). This
# client supplies its own copy of the same trust store Godot would otherwise
# have loaded, so every TLS connection verifies certificates the same way a
# normal Godot game would.

const BUNDLE_PATH := "res://client/certs/ca-bundle.pem"

static var _chain: X509Certificate = null
static var _load_attempted := false


# The trust store loads once per process. Every client instance and every
# TLS connection they open share the same parsed X509Certificate chain.
# Returns null if the bundle failed to load, so a caller can fall back to
# Godot's own (non-functional, in this runtime) default rather than crash.
static func default_trusted_chain() -> X509Certificate:
	if _load_attempted:
		return _chain
	_load_attempted = true
	var chain := X509Certificate.new()
	if chain.load(BUNDLE_PATH) == OK:
		_chain = chain
	return _chain
