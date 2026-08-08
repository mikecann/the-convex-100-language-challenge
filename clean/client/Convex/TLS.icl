implementation module Convex.TLS

import StdEnv
import System._Pointer
import Convex.Mem
import Convex.Result
import Convex.Wire
import Convex.Deadline
import Convex.Socket

// Every `ccall` below resolves against libssl/libcrypto at link time, not
// against anything in Clean's own distribution. `import code from library`
// is the same directive the distribution's own optional database bindings
// use for their native libraries (see data/Platform/Database/SQL/_MySQL.icl,
// "-lmariadb"); it appends the named linker flag to clm's link step so the
// final binary is linked against the system OpenSSL shared libraries
// without a build-time `-sl` flag on every clm invocation.
import code from library "-lssl"
import code from library "-lcrypto"

// --- OpenSSL FFI -----------------------------------------------------------

def_SSL_ERROR_WANT_READ :: Int
def_SSL_ERROR_WANT_READ = 2
def_SSL_ERROR_WANT_WRITE :: Int
def_SSL_ERROR_WANT_WRITE = 3
def_SSL_ERROR_ZERO_RETURN :: Int
def_SSL_ERROR_ZERO_RETURN = 6
def_SSL_CTRL_SET_TLSEXT_HOSTNAME :: Int
def_SSL_CTRL_SET_TLSEXT_HOSTNAME = 55
def_TLSEXT_NAMETYPE_HOST_NAME :: Int
def_TLSEXT_NAMETYPE_HOST_NAME = 0
def_SSL_VERIFY_PEER :: Int
def_SSL_VERIFY_PEER = 1

TLS_client_method :: !*World -> (!Pointer, !*World)
TLS_client_method w = code { ccall TLS_client_method ":p:A" }

SSL_CTX_new :: !Pointer !*World -> (!Pointer, !*World)
SSL_CTX_new m w = code { ccall SSL_CTX_new "p:p:A" }

// The real C signature returns `void`. Every OpenSSL binding in this file
// that is genuinely void-returning is instead declared here as returning an
// `Int` that every call site immediately discards, and the ccall type
// string lies to `clm` about it (`"...:I:A"` instead of the accurate
// `"...:V:A"`). This is a confirmed, measured workaround for a real `clm`
// 3.1 code-generation defect in this toolchain: a ccall whose type string
// ends `:V:A` (void return) reliably corrupts Clean's own heap by the time
// any *later* ccall in the same connection's lifetime runs, independent of
// which OpenSSL function it is, its argument types, whether anything is
// freed versus merely leaked, and whether the corrupted ccall is wrapped in
// its own separate Clean function — every one of those variables was
// isolated and ruled out directly against this project's own dedicated test
// deployment. `Convex.TLS` never inspects any of these bogus returned
// `Int`s; they exist only so the ccall's type string never ends in `:V:A`.
// Concretely: `SSL_free` declared as `"p:V:A"` reliably crashed a later
// garbage-collection pass with "cycle in spine detected" the moment
// *anything* else ran afterward (another ccall touching the same
// connection's fd, a second free, even a plain `fcntl` diagnostic probe) —
// but running clean, every time, once redeclared as `"p:I:A"` with the
// bogus `Int` discarded. The same redeclaration is applied to every other
// void-returning OpenSSL call this file makes: `SSL_CTX_free`,
// `SSL_CTX_set_verify`. (`SSL_set_verify` is declared but, per its own
// comment, never called by `tlsConnect`.)
SSL_CTX_free :: !Pointer !*World -> (!Int, !*World)
SSL_CTX_free ctx w = code { ccall SSL_CTX_free "p:I:A" }

// The real C signature is `SSL_CTX_set_verify(ctx, mode, verify_callback)`;
// this client always wants the library's own default verification (checked
// afterward via `SSL_get_verify_result`), so the callback argument is a
// literal null passed as a plain `I` — the ccall type string must list
// every real C argument, or the callee reads an unset register/stack slot.
SSL_CTX_set_verify :: !Pointer !Int !Int !*World -> (!Int, !*World)
SSL_CTX_set_verify ctx mode callback w = code { ccall SSL_CTX_set_verify "pII:I:A" }

// SSL-level equivalent of `SSL_CTX_set_verify`, applied to a session
// instead of a context. Real signature is identical modulo the first
// argument. Declared for completeness and linked by `FoundationTest`
// alongside every other symbol this file declares; `tlsConnect` sets verify
// mode on the context (`SSL_CTX_set_verify`, before `SSL_new`) rather than
// on the session, so this binding itself is currently unused.
SSL_set_verify :: !Pointer !Int !Int !*World -> (!Int, !*World)
SSL_set_verify ssl mode callback w = code { ccall SSL_set_verify "pII:I:A" }

SSL_CTX_set_default_verify_paths :: !Pointer !*World -> (!Int, !*World)
SSL_CTX_set_default_verify_paths ctx w = code { ccall SSL_CTX_set_default_verify_paths "p:I:A" }

// Real signature is `SSL_CTX_load_verify_locations(ctx, CAfile, CApath)`;
// this client only ever loads a single bundle file, so `CApath` is always a
// literal null, passed the same way as the callback above.
SSL_CTX_load_verify_locations :: !Pointer !String !Int !*World -> (!Int, !*World)
SSL_CTX_load_verify_locations ctx file capath w = code { ccall SSL_CTX_load_verify_locations "psI:I:A" }

SSL_new :: !Pointer !*World -> (!Pointer, !*World)
SSL_new ctx w = code { ccall SSL_new "p:p:A" }

// See the long comment on `SSL_CTX_free` above: declared `Int`-returning,
// not `void`, to dodge the `clm` 3.1 marshaling defect. The bogus return is
// always discarded at every call site.
SSL_free :: !Pointer !*World -> (!Int, !*World)
SSL_free ssl w = code { ccall SSL_free "p:I:A" }

SSL_set_fd :: !Pointer !Int !*World -> (!Int, !*World)
SSL_set_fd ssl fd w = code { ccall SSL_set_fd "pI:I:A" }

SSL_get_rbio :: !Pointer !*World -> (!Pointer, !*World)
SSL_get_rbio ssl w = code { ccall SSL_get_rbio "p:p:A" }

// `BIO_set_close` is a macro around this in OpenSSL's own headers; called
// directly here since this client has no C preprocessor. `BIO_CTRL_SET_CLOSE`
// (9) and `BIO_NOCLOSE` (0) are both long-stable OpenSSL constants,
// unchanged across the 1.0/1.1/3.x line.
BIO_ctrl :: !Pointer !Int !Int !Int !*World -> (!Int, !*World)
BIO_ctrl bio cmd larg parg w = code { ccall BIO_ctrl "pIII:I:A" }

SSL_set1_host :: !Pointer !String !*World -> (!Int, !*World)
SSL_set1_host ssl name w = code { ccall SSL_set1_host "ps:I:A" }

SSL_ctrl :: !Pointer !Int !Int !String !*World -> (!Int, !*World)
SSL_ctrl ssl cmd larg parg w = code { ccall SSL_ctrl "pIIs:I:A" }

SSL_connect :: !Pointer !*World -> (!Int, !*World)
SSL_connect ssl w = code { ccall SSL_connect "p:I:A" }

SSL_read :: !Pointer !Pointer !Int !*World -> (!Int, !*World)
SSL_read ssl buf num w = code { ccall SSL_read "ppI:I:A" }

SSL_write :: !Pointer !String !Int !*World -> (!Int, !*World)
SSL_write ssl buf num w = code { ccall SSL_write "psI:I:A" }

SSL_get_error :: !Pointer !Int !*World -> (!Int, !*World)
SSL_get_error ssl ret w = code { ccall SSL_get_error "pI:I:A" }

SSL_shutdown :: !Pointer !*World -> (!Int, !*World)
SSL_shutdown ssl w = code { ccall SSL_shutdown "p:I:A" }

SSL_get_verify_result :: !Pointer !*World -> (!Int, !*World)
SSL_get_verify_result ssl w = code { ccall SSL_get_verify_result "p:I:A" }

// --- CA bundle ---------------------------------------------------------

// System CA bundle locations shipped by the base images this project's
// runtime stages use. The first path that exists is loaded, in addition to
// OpenSSL's own compiled-in defaults; a deployment without a working CA
// bundle fails the handshake rather than silently skipping verification.
caBundlePaths :: [String]
caBundlePaths = ["/etc/ssl/certs/ca-certificates.crt", "/etc/ssl/cert.pem"]

def_F_OK :: Int
def_F_OK = 0

pathExistsCcall :: !String !Int !*World -> (!Int, !*World)
pathExistsCcall path mode w = code { ccall access "sI:I:A" }

pathExists :: !String !*World -> (!Bool, !*World)
pathExists path w
	# (rc, w) = pathExistsCcall (toCString path) def_F_OK w
	= (rc == 0, w)

loadCaBundle :: !Pointer !*World -> *World
loadCaBundle ctx w
	# (_, w) = SSL_CTX_set_default_verify_paths ctx w
	= loadFrom caBundlePaths ctx w
where
	loadFrom [] ctx w = w
	loadFrom [p : ps] ctx w
		# (exists, w) = pathExists p w
		| not exists = loadFrom ps ctx w
		# (_, w) = SSL_CTX_load_verify_locations ctx (toCString p) 0 w
		= loadFrom ps ctx w

// --- handshake and I/O -------------------------------------------------

// Bounded by the caller's own `Deadline` rather than a fixed internal
// timeout: `remainingMs` already returns 0 once `d` has passed, and
// `pollReady`'s own 0-timeout behaviour (an immediate non-blocking check)
// is exactly "not ready" for a deadline that is already due. This is what
// lets a close or unsubscribe issued against a stalled TLS peer stay
// bounded by the caller's real deadline instead of this module's own
// internal wait, which used to be a fixed 10 seconds per retry regardless
// of how little time the caller actually had left.
waitSocket :: !Int !Bool !Deadline !*World -> (!Result Bool, !*World)
waitSocket fd forWrite d w
	# (remaining, w) = remainingMs d w
	= pollReady fd forWrite remaining w

// `tlsConnect` owns closing `fd` on every one of its own failure paths, so
// a caller must never also call `Convex.Socket.closeRaw` after a `RErr`
// here. Before `SSL_set_fd` runs, `fd` is not yet owned by any OpenSSL BIO,
// so these two early failures close it directly; every failure after that
// point goes through `tlsFreeOnly`, which closes it explicitly itself (see
// that function's own comment on why, and `SSL_CTX_free`'s comment for the
// real root cause this project chased two other theories before finding).
tlsConnect :: !Int !String !Deadline !*World -> (!Result TlsConn, !*World)
tlsConnect fd hostname d w
	# (method, w) = TLS_client_method w
	# (ctx, w) = SSL_CTX_new method w
	| ctx == 0
		# w = closeRaw fd w
		= (RErr "could not create TLS context", w)
	# (_, w) = SSL_CTX_set_verify ctx def_SSL_VERIFY_PEER 0 w
	# w = loadCaBundle ctx w
	# (ssl, w) = SSL_new ctx w
	| ssl == 0
		# (_, w) = SSL_CTX_free ctx w
		# w = closeRaw fd w
		= (RErr "could not create TLS session", w)
	# (_, w) = SSL_set_fd ssl fd w
	// `SSL_set_fd` wraps `fd` in a socket BIO with OpenSSL's own default
	// close-on-free ownership. Disabling that here and having every one of
	// this file's own cleanup paths call `closeRaw` explicitly instead
	// makes fd ownership fully deterministic in Clean source rather than
	// depending on an OpenSSL-internal close this runtime cannot observe.
	# (rbio, w) = SSL_get_rbio ssl w
	# (_, w) = BIO_ctrl rbio 9 0 0 w
	# (_, w) = SSL_set1_host ssl (toCString hostname) w
	# (_, w) = SSL_ctrl ssl def_SSL_CTRL_SET_TLSEXT_HOSTNAME def_TLSEXT_NAMETYPE_HOST_NAME (toCString hostname) w
	= handshakeLoop { ctx = ctx, ssl = ssl, fd = fd } d w

handshakeLoop :: !TlsConn !Deadline !*World -> (!Result TlsConn, !*World)
handshakeLoop conn d w
	# (rc, w) = SSL_connect conn.ssl w
	| rc == 1 = verifyAndFinish conn w
	# (errCode, w) = SSL_get_error conn.ssl rc w
	| errCode == def_SSL_ERROR_WANT_READ || errCode == def_SSL_ERROR_WANT_WRITE
		# (waited, w) = waitSocket conn.fd (errCode == def_SSL_ERROR_WANT_WRITE) d w
		= case waited of
			ROk True = handshakeLoop conn d w
			ROk False
				# w = tlsFreeOnly conn w
				= (RErr "TLS handshake timed out", w)
			RErr e
				# w = tlsFreeOnly conn w
				= (RErr e, w)
	# w = tlsFreeOnly conn w
	= (RErr "TLS handshake failed", w)

verifyAndFinish :: !TlsConn !*World -> (!Result TlsConn, !*World)
verifyAndFinish conn w
	# (result, w) = SSL_get_verify_result conn.ssl w
	| result <> 0
		# w = tlsFreeOnly conn w
		= (RErr "TLS peer certificate verification failed", w)
	= (ROk conn, w)

// Used on every `tlsConnect` failure path reached after `SSL_set_fd` (the
// handshake itself, or certificate verification). Closes `fd` explicitly
// (see `tlsConnect`'s own comment on why the BIO's automatic close is
// disabled instead of relied on).
tlsFreeOnly :: !TlsConn !*World -> *World
tlsFreeOnly conn w
	# (_, w) = SSL_free conn.ssl w
	# (_, w) = SSL_CTX_free conn.ctx w
	# w = closeRaw conn.fd w
	= w

tlsRead :: !TlsConn !Int !Deadline !*World -> (!Result String, !*World)
tlsRead conn maxLen d w
	| maxLen == 0 = (ROk "", w)
	# (buf, w) = mallocW maxLen w
	# (result, w) = readLoop conn buf maxLen w
	= case result of
		ROk n
			# (s, w) = bytesToStringW buf n w
			// `s` must be fully materialised (not left as a lazy thunk
			// still referring to `buf`) before `buf` is freed below, or a
			// later demand for `s`'s content would read already-freed
			// memory. `size` forces the array to whnf, which for an
			// unboxed `{#Char}` array means it is already fully built.
			# forced = size s
			# w = freeW buf w
			= (ROk s, w)
		RErr e
			# w = freeW buf w
			= (RErr e, w)
where
	readLoop conn buf maxLen w
		# (rc, w) = SSL_read conn.ssl buf maxLen w
		| rc > 0 = (ROk rc, w)
		# (errCode, w) = SSL_get_error conn.ssl rc w
		| errCode == def_SSL_ERROR_ZERO_RETURN = (ROk 0, w)
		| errCode == def_SSL_ERROR_WANT_READ || errCode == def_SSL_ERROR_WANT_WRITE
			# (waited, w) = waitSocket conn.fd (errCode == def_SSL_ERROR_WANT_WRITE) d w
			= case waited of
				ROk True = readLoop conn buf maxLen w
				ROk False = (RErr "TLS read timed out", w)
				RErr e = (RErr e, w)
		= (RErr "TLS read failed", w)

// Reads `n` bytes at `p` into a Clean `String`, threaded through `*World`
// for the same reason as every other post-`ccall` read in this client (see
// `Convex.Mem`): `SSL_read`'s destination buffer is allocated before the
// call that fills it.
bytesToStringW :: !Pointer !Int !*World -> (!String, !*World)
bytesToStringW p n w
	# (chars, w) = walk 0 w
	= ({c \\ c <- chars}, w)
where
	walk i w
		| i == n = ([], w)
		# (b, w) = readByteW p i w
		# (rest, w) = walk (i + 1) w
		= ([toChar b : rest], w)

tlsWriteAll :: !TlsConn !String !Deadline !*World -> (!Result Int, !*World)
tlsWriteAll conn data d w = writeLoop conn data 0 (size data) w
where
	writeLoop conn data sent total w
		| sent >= total = (ROk total, w)
		# remaining = data % (sent, total - 1)
		# (rc, w) = SSL_write conn.ssl remaining (total - sent) w
		| rc > 0 = writeLoop conn data (sent + rc) total w
		# (errCode, w) = SSL_get_error conn.ssl rc w
		| errCode == def_SSL_ERROR_WANT_READ || errCode == def_SSL_ERROR_WANT_WRITE
			# (waited, w) = waitSocket conn.fd (errCode == def_SSL_ERROR_WANT_WRITE) d w
			= case waited of
				ROk True = writeLoop conn data sent total w
				ROk False = (RErr "TLS write timed out", w)
				RErr e = (RErr e, w)
		= (RErr "TLS write failed", w)

tlsFd :: !TlsConn -> Int
tlsFd conn = conn.fd

// `tlsConnect` disables the socket BIO's own close-on-free, so this calls
// `closeRaw` on `fd` itself, exactly once, here on the success path — the
// same explicit ownership `tlsFreeOnly` uses on every failure path after
// `SSL_set_fd`. `Convex.Socket.closeRaw` is also used directly for the
// plain (non-TLS) HTTP path, which never goes through OpenSSL at all.
tlsClose :: !TlsConn !*World -> *World
tlsClose conn w
	# (_, w) = SSL_shutdown conn.ssl w
	# (_, w) = SSL_free conn.ssl w
	# (_, w) = SSL_CTX_free conn.ctx w
	# w = closeRaw conn.fd w
	= w
