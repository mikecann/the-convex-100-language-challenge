implementation module Convex.Deadline

import StdEnv
from System._Pointer import :: Pointer
import Convex.Mem

def_CLOCK_MONOTONIC :: Int
def_CLOCK_MONOTONIC = 1

clockGettimeRaw :: !Int !Pointer !*World -> (!Int, !*World)
clockGettimeRaw clockId buf w = code {
	ccall clock_gettime "Ip:I:A"
}

nowMs :: !*World -> (!Int, !*World)
nowMs w
	# (buf, w) = mallocW 16 w
	# (rc, w) = clockGettimeRaw def_CLOCK_MONOTONIC buf w
	# (sec, w) = readWordW buf 0 w
	# (nsec, w) = readWordW buf 8 w
	# w = freeW buf w
	= (sec * 1000 + nsec / 1000000, w)

deadlineIn :: !Int !*World -> (!Deadline, !*World)
deadlineIn ms w
	# (n, w) = nowMs w
	= ({atMs = n + ms}, w)

remainingMs :: !Deadline !*World -> (!Int, !*World)
remainingMs d w
	# (n, w) = nowMs w
	# r = d.atMs - n
	= (if (r < 0) 0 r, w)

isExpired :: !Deadline !*World -> (!Bool, !*World)
isExpired d w
	# (r, w) = remainingMs d w
	= (r == 0, w)
