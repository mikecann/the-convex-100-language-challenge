module FoundationTest

// Language-local unit coverage for the transport foundation: Convex.Result,
// Convex.Deadline, Convex.Mem, and Convex.Socket's network-free behaviour.
// Run by the `test` Docker stage; not part of the public client or the
// conformance adapter.
//
// Convex.TLS is imported (but never called) purely so its `.o` is part of
// this executable too: Clean links whole per-module object files rather
// than individual functions, so building and running this binary is what
// proves the `import code from library "-lssl"/"-lcrypto"` directives in
// TLS.icl actually resolve against this runtime's OpenSSL, without this
// test needing a real TLS peer to connect to.

import StdEnv
import Convex.Result
import Convex.Deadline
import Convex.Mem
import Convex.Socket
import Convex.TLS

Start :: *World -> *World
Start w
	# (ok1, w) = checkResultMap w
	| not ok1 = abort "Result.resultMap/isROk behaved unexpectedly"
	# (ok2, w) = checkDeadlineCountsDown w
	| not ok2 = abort "Deadline.remainingMs did not count down toward zero"
	# (ok3, w) = checkDeadlineAlreadyExpired w
	| not ok3 = abort "Deadline.isExpired did not report an already-past deadline as expired"
	# (ok4, w) = checkMallocFreeRoundtrips w
	| not ok4 = abort "Mem.mallocW/writeByteW/readByteW/freeW round-trip failed"
	# (ok5, w) = checkPollReadyNonBlocking w
	= if ok5 w (abort "Socket.pollReady with a zero timeout on an unready descriptor did not return promptly")

checkResultMap :: !*World -> (!Bool, !*World)
checkResultMap w = (isROk (resultMap (\x -> x + 1) (ROk 41)) && not (isROk (resultMap (\x -> x + 1) (RErr "boom"))), w)

// `deadlineIn 0` is already due the instant it is created; a deadline
// created with a positive horizon has not yet elapsed. This does not
// assert an exact millisecond value (real wall-clock reads are inherently
// a little noisy under a loaded build host), only the qualitative
// ordering the rest of this client actually depends on.
checkDeadlineCountsDown :: !*World -> (!Bool, !*World)
checkDeadlineCountsDown w
	# (d, w) = deadlineIn 60000 w
	# (remaining, w) = remainingMs d w
	= (remaining > 0, w)

checkDeadlineAlreadyExpired :: !*World -> (!Bool, !*World)
checkDeadlineAlreadyExpired w
	# (d, w) = deadlineIn 0 w
	# (expired, w) = isExpired d w
	= (expired, w)

checkMallocFreeRoundtrips :: !*World -> (!Bool, !*World)
checkMallocFreeRoundtrips w
	# (p, w) = mallocW 8 w
	# (p, w) = writeByteW p 0 0xAB w
	# (p, w) = writeU32LEW p 4 0x01020304 w
	# (b, w) = readByteW p 0 w
	# (u, w) = readU32LEW p 4 w
	# w = freeW p w
	= (b == 0xAB && u == 0x01020304, w)

// A negative fd with a zero-millisecond timeout must return "not ready"
// immediately (see Convex.Socket's own comment on why `poll` still waits
// out the timeout for a negative fd, just without ever reporting it
// ready) rather than block or error.
checkPollReadyNonBlocking :: !*World -> (!Bool, !*World)
checkPollReadyNonBlocking w
	# (result, w) = pollReady (-1) False 0 w
	= (isROk result, w)
