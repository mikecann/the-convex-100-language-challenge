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

SSL_CTX_free :: !Pointer !*World -> *World
SSL_CTX_free ctx w = code { ccall SSL_CTX_free "p:V:A" }

// The real C signature is `SSL_CTX_set_verify(ctx, mode, verify_callback)`;
// this client always wants the library's own default verification (checked
// afterward via `SSL_get_verify_result`), so the callback argument is a
// literal null passed as a plain `I` — the ccall type string must list
// every real C argument, or the callee reads an unset register/stack slot.
SSL_CTX_set_verify :: !Pointer !Int !Int !*World -> *World
SSL_CTX_set_verify ctx mode callback w = code { ccall SSL_CTX_set_verify "pII:V:A" }

SSL_CTX_set_default_verify_paths :: !Pointer !*World -> (!Int, !*World)
SSL_CTX_set_default_verify_paths ctx w = code { ccall SSL_CTX_set_default_verify_paths "p:I:A" }

// Real signature is `SSL_CTX_load_verify_locations(ctx, CAfile, CApath)`;
// this client only ever loads a single bundle file, so `CApath` is always a
// literal null, passed the same way as the callback above.
SSL_CTX_load_verify_locations :: !Pointer !String !Int !*World -> (!Int, !*World)
SSL_CTX_load_verify_locations ctx file capath w = code { ccall SSL_CTX_load_verify_locations "psI:I:A" }

SSL_new :: !Pointer !*World -> (!Pointer, !*World)
SSL_new ctx w = code { ccall SSL_new "p:p:A" }

SSL_free :: !Pointer !*World -> *World
SSL_free ssl w = code { ccall SSL_free "p:V:A" }

SSL_set_fd :: !Pointer !Int !*World -> (!Int, !*World)
SSL_set_fd ssl fd w = code { ccall SSL_set_fd "pI:I:A" }

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

tlsConnect :: !Int !String !Deadline !*World -> (!Result TlsConn, !*World)
tlsConnect fd hostname d w
	# (method, w) = TLS_client_method w
	# (ctx, w) = SSL_CTX_new method w
	| ctx == 0 = (RErr "could not create TLS context", w)
	# w = SSL_CTX_set_verify ctx def_SSL_VERIFY_PEER 0 w
	# w = loadCaBundle ctx w
	# (ssl, w) = SSL_new ctx w
	| ssl == 0
		# w = SSL_CTX_free ctx w
		= (RErr "could not create TLS session", w)
	# (_, w) = SSL_set_fd ssl fd w
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

tlsFreeOnly :: !TlsConn !*World -> *World
tlsFreeOnly conn w
	# w = SSL_free conn.ssl w
	# w = SSL_CTX_free conn.ctx w
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

// Deliberately does NOT also call `closeRaw` on the underlying file
// descriptor: `SSL_set_fd` wraps it in a socket `BIO` with OpenSSL's
// default close-on-free ownership, so `SSL_free` already closes it.
// Measured directly against this toolchain: closing the same fd number a
// second time here did not fail loudly (`close` on an already-closed fd is
// harmless in isolation) but reliably corrupted a later Clean garbage
// collection into reporting "cycle in spine detected" and aborting —
// almost certainly because the fd number was already reissued to
// something the Clean runtime itself relies on internally by the time this
// function's own `close` ran. `Convex.Socket.closeRaw` is still used
// directly for the plain (non-TLS) HTTP path, which never goes through
// OpenSSL at all.
tlsClose :: !TlsConn !*World -> *World
tlsClose conn w
	# (_, w) = SSL_shutdown conn.ssl w
	# w = SSL_free conn.ssl w
	# w = SSL_CTX_free conn.ctx w
	= w
