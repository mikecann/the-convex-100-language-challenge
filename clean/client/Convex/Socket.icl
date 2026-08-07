implementation module Convex.Socket

import StdEnv
import StdMaybe
import System._Pointer
import System._Posix
import Convex.Mem
import Convex.Result
import Convex.Wire

// --- raw libc bindings -------------------------------------------------

socketCcall :: !Int !Int !Int !*World -> (!Int, !*World)
socketCcall d t p w = code {
	ccall socket "III:I:A"
}

connectCcall :: !Int !Pointer !Int !*World -> (!Int, !*World)
connectCcall fd addr len w = code {
	ccall connect "IpI:I:A"
}

closeCcall :: !Int !*World -> (!Int, !*World)
closeCcall fd w = code {
	ccall close "I:I:A"
}

sendCcall :: !Int !String !Int !Int !*World -> (!Int, !*World)
sendCcall fd buf len flags w = code {
	ccall send "IsII:I:A"
}

recvCcall :: !Int !Pointer !Int !Int !*World -> (!Int, !*World)
recvCcall fd buf len flags w = code {
	ccall recv "IpII:I:A"
}

// `gethostbyname` (rather than `getaddrinfo`) is used deliberately: it
// returns its result as a plain function return value (a single `p`), not
// through a `struct addrinfo **` out-parameter. See `Convex.Mem`'s module
// comment for the measured hazard with reading a `ccall`-populated
// out-parameter buffer; a returned pointer has no such hazard, since the
// pointer's own value cannot exist before the call returns it, and every
// other pointer-returning `ccall` in this client (`TLS_client_method`,
// `SSL_new`, and so on) already uses this same, reliable shape.
gethostbynameCcall :: !String !*World -> (!Pointer, !*World)
gethostbynameCcall name w = code {
	ccall gethostbyname "s:p:A"
}

htonsCcall :: !Int -> Int
htonsCcall a = code {
	ccall htons "I:I"
}

pollCcall :: !Pointer !Int !Int !*World -> (!Int, !*World)
pollCcall fds nfds timeoutMs w = code {
	ccall poll "pII:I:A"
}

// --- helpers -------------------------------------------------------------

// Reads `n` bytes at `p` into a Clean `String`. Threaded through `*World`
// for the same reason as every other post-`ccall` read in this module (see
// `Convex.Mem`): `recv`'s destination buffer is allocated before the call
// that fills it.
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

// Parses a literal dotted-quad IPv4 address ("93.184.215.14"), without
// touching the resolver at all.
parseLiteralIPv4 :: !String -> Maybe (Int, Int, Int, Int)
parseLiteralIPv4 s = case splitOn '.' s of
	[a, b, c, d] = case (octet a, octet b, octet c, octet d) of
		(Just oa, Just ob, Just oc, Just od) = Just (oa, ob, oc, od)
		_ = Nothing
	_ = Nothing
where
	octet t
		# n = size t
		| n == 0 || n > 3 = Nothing
		= digitsOnly t 0 n 0

	digitsOnly t i n acc
		| i == n = if (acc > 255) Nothing (Just acc)
		| t.[i] < '0' || t.[i] > '9' = Nothing
		= digitsOnly t (i + 1) n (acc * 10 + (toInt t.[i] - toInt '0'))

splitOn :: !Char !String -> [String]
splitOn sep s = splitFrom 0 0
where
	n = size s
	splitFrom start i
		| i == n = [s % (start, n - 1)]
		| s.[i] == sep = [s % (start, i - 1) : splitFrom (i + 1) (i + 1)]
		= splitFrom start (i + 1)

// Resolves a hostname to one IPv4 address. A literal dotted-quad is parsed
// directly; anything else goes through `gethostbyname`, which (unlike
// `getaddrinfo` with `AF_UNSPEC` hints) only ever returns `AF_INET`
// addresses on this glibc, sidestepping the "resolved an IPv6 address on an
// IPv6-disabled Docker bridge" failure mode by construction rather than by
// filtering a mixed result list.
resolveHost :: !String !*World -> (!Maybe (Int, Int, Int, Int), !*World)
resolveHost host w = case parseLiteralIPv4 host of
	Just quad = (Just quad, w)
	Nothing
		# (hp, w) = gethostbynameCcall (toCString host) w
		| hp == 0 = (Nothing, w)
		# (addrListPtr, w) = readWordW hp 24 w
		| addrListPtr == 0 = (Nothing, w)
		# (firstAddrPtr, w) = readWordW addrListPtr 0 w
		| firstAddrPtr == 0 = (Nothing, w)
		# (b0, w) = readByteW firstAddrPtr 0 w
		# (b1, w) = readByteW firstAddrPtr 1 w
		# (b2, w) = readByteW firstAddrPtr 2 w
		# (b3, w) = readByteW firstAddrPtr 3 w
		= (Just (b0, b1, b2, b3), w)

// --- public API ------------------------------------------------------------

def_AF_INET :: Int
def_AF_INET = 2
def_SOCK_STREAM :: Int
def_SOCK_STREAM = 1

connectTcp :: !String !Int !*World -> (!Result Int, !*World)
connectTcp host port w
	# (resolved, w) = resolveHost host w
	= case resolved of
		Nothing = (RErr "could not resolve the deployment's hostname", w)
		Just (b0, b1, b2, b3)
			# (addr, w) = mallocW 16 w
			# (addr, w) = zeroBytesW addr 0 16 w
			# (addr, w) = writeU16LEW addr 0 def_AF_INET w
			# (addr, w) = writeU16LEW addr 2 (htonsCcall port) w
			# (addr, w) = writeByteW addr 4 b0 w
			# (addr, w) = writeByteW addr 5 b1 w
			# (addr, w) = writeByteW addr 6 b2 w
			# (addr, w) = writeByteW addr 7 b3 w
			# (fd, w) = socketCcall def_AF_INET def_SOCK_STREAM 0 w
			| fd == -1
				# w = freeW addr w
				= (RErr "socket() failed", w)
			# (cr, w) = connectCcall fd addr 16 w
			# w = freeW addr w
			| cr == -1
				# w = closeRaw fd w
				= (RErr "could not connect to the deployment", w)
			= (ROk fd, w)

sendRaw :: !Int !String !*World -> (!Result Int, !*World)
sendRaw fd data w
	# (n, w) = sendCcall fd data (size data) 0 w
	| n == -1 = (RErr "send() failed", w)
	= (ROk n, w)

recvRaw :: !Int !Int !*World -> (!Result String, !*World)
recvRaw fd maxLen w
	# (buf, w) = mallocW maxLen w
	# (n, w) = recvCcall fd buf maxLen 0 w
	| n == -1
		# w = freeW buf w
		= (RErr "recv() failed", w)
	# (s, w) = bytesToStringW buf n w
	# w = freeW buf w
	= (ROk s, w)

closeRaw :: !Int !*World -> *World
closeRaw fd w
	# (_, w) = closeCcall fd w
	= w

def_POLLIN :: Int
def_POLLIN = 1
def_POLLOUT :: Int
def_POLLOUT = 4

pollReady :: !Int !Bool !Int !*World -> (!Result Bool, !*World)
pollReady fd forWrite timeoutMs w
	# (buf, w) = mallocW 8 w
	# (buf, w) = writeU32LEW buf 0 fd w
	# events = if forWrite def_POLLOUT def_POLLIN
	# (buf, w) = writeU16LEW buf 4 events w
	# (buf, w) = writeU16LEW buf 6 0 w
	# (rc, w) = pollCcall buf 1 timeoutMs w
	# (revents, w) = readU16LEW buf 6 w
	# w = freeW buf w
	| rc < 0 = (RErr "poll() failed", w)
	| rc == 0 = (ROk False, w)
	= (ROk (revents <> 0), w)
