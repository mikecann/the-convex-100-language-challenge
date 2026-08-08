implementation module Convex.Transport

import StdEnv
import Convex.Result
import Convex.Deadline
import Convex.Socket
import Convex.TLS

connectTransport :: !Bool !String !Int !Deadline !*World -> (!Result Transport, !*World)
connectTransport tls host port d w
	# (connected, w) = connectTcp host port w
	= case connected of
		RErr e = (RErr e, w)
		ROk fd
			| not tls = (ROk (TPlain fd), w)
			# (session, w) = tlsConnect fd host w
			= case session of
				RErr e
					# w = closeRaw fd w
					= (RErr e, w)
				ROk conn = (ROk (TTls conn), w)

transportFd :: !Transport -> Int
transportFd (TPlain fd) = fd
transportFd (TTls conn) = tlsFd conn

// TLS reads and writes already retry internally against OpenSSL's own
// WANT_READ/WANT_WRITE signal (see Convex.TLS), bounded by that module's own
// fixed per-operation wait; only the plain path needs an explicit poll
// against the deadline threaded through here.
transportRead :: !Transport !Int !Deadline !*World -> (!Result String, !*World)
transportRead (TPlain fd) maxLen d w
	# (remaining, w) = remainingMs d w
	| remaining == 0 = (RErr "read timed out", w)
	# (ready, w) = pollReady fd False remaining w
	= case ready of
		RErr e = (RErr e, w)
		ROk False = (RErr "read timed out", w)
		ROk True = recvRaw fd maxLen w
transportRead (TTls conn) maxLen d w = tlsRead conn maxLen w

transportWriteAll :: !Transport !String !Deadline !*World -> (!Result Int, !*World)
transportWriteAll (TPlain fd) data d w = writeLoop fd data 0 (size data) d w
where
	writeLoop fd data sent total d w
		| sent >= total = (ROk total, w)
		# (remaining, w) = remainingMs d w
		| remaining == 0 = (RErr "write timed out", w)
		# (ready, w) = pollReady fd True remaining w
		= case ready of
			RErr e = (RErr e, w)
			ROk False = (RErr "write timed out", w)
			ROk True
				# chunk = data % (sent, total - 1)
				# (sentResult, w) = sendRaw fd chunk w
				= case sentResult of
					RErr e = (RErr e, w)
					ROk n = writeLoop fd data (sent + n) total d w
transportWriteAll (TTls conn) data d w = tlsWriteAll conn data w

transportClose :: !Transport !*World -> *World
transportClose (TPlain fd) w = closeRaw fd w
transportClose (TTls conn) w = tlsClose conn w
