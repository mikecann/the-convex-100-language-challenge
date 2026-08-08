implementation module Convex.Mem

import StdEnv
import System._Pointer
import System._Posix

readByteW :: !Pointer !Int !*World -> (!Int, !*World)
readByteW p off w
	#! v = readInt1Z p off
	= (v, w)

// Returns the `Pointer` `writeInt1` itself returns (not necessarily
// numerically distinguishable from `p`, but a *fresh* value every caller
// must consume), so no write in a chain is ever unobserved dead code.
writeByteW :: !Pointer !Int !Int !*World -> (!Pointer, !*World)
writeByteW p off v w
	#! p2 = writeInt1 p off v
	= (p2, w)

readU16LEW :: !Pointer !Int !*World -> (!Int, !*World)
readU16LEW p off w
	# (lo, w) = readByteW p off w
	# (hi, w) = readByteW p (off + 1) w
	= (lo + hi * 256, w)

writeU16LEW :: !Pointer !Int !Int !*World -> (!Pointer, !*World)
writeU16LEW p off v w
	# (p, w) = writeByteW p off (v bitand 255) w
	# (p, w) = writeByteW p (off + 1) ((v >> 8) bitand 255) w
	= (p, w)

readU32LEW :: !Pointer !Int !*World -> (!Int, !*World)
readU32LEW p off w
	# (b0, w) = readByteW p off w
	# (b1, w) = readByteW p (off + 1) w
	# (b2, w) = readByteW p (off + 2) w
	# (b3, w) = readByteW p (off + 3) w
	= (b0 + b1 * 256 + b2 * 65536 + b3 * 16777216, w)

writeU32LEW :: !Pointer !Int !Int !*World -> (!Pointer, !*World)
writeU32LEW p off v w
	# (p, w) = writeByteW p off (v bitand 255) w
	# (p, w) = writeByteW p (off + 1) ((v >> 8) bitand 255) w
	# (p, w) = writeByteW p (off + 2) ((v >> 16) bitand 255) w
	# (p, w) = writeByteW p (off + 3) ((v >> 24) bitand 255) w
	= (p, w)

readWordW :: !Pointer !Int !*World -> (!Int, !*World)
readWordW p off w
	# (lo, w) = readU32LEW p off w
	# (hi, w) = readU32LEW p (off + 4) w
	= (lo + hi * 4294967296, w)

zeroBytesW :: !Pointer !Int !Int !*World -> (!Pointer, !*World)
zeroBytesW p off len w
	| len <= 0 = (p, w)
	# (p, w) = writeByteW p off 0 w
	= zeroBytesW p (off + 1) (len - 1) w

mallocW :: !Int !*World -> (!Pointer, !*World)
mallocW n w = mallocSt n w

freeW :: !Pointer !*World -> *World
freeW p w = freeSt p w
