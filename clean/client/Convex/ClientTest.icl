module ClientTest

// Language-local unit coverage for Convex.Client's own logic (endpoint
// parsing failure, auth token get/clear). Everything else Client does is
// a thin pass-through to Convex.HTTP/Convex.Live, already covered by
// ConvexCallTest.icl and ConvexLiveTest.icl's real end-to-end regressions.

import StdEnv
import Convex.Result
import Convex.Client

Start :: *World -> *World
Start w
	# (initResult, w) = clientInit "not-a-valid-url" w
	| isROk initResult = abort "clientInit accepted a URL with no http(s):// scheme"
	# (initResult2, w) = clientInit "http://127.0.0.1:3210" w
	| not (isROk initResult2) = abort "clientInit rejected a well-formed local deployment URL"
	# (initResult3, w) = clientInit "http://127.0.0.1:3210" w
	= case initResult3 of
		RErr e = abort ("clientInit unexpectedly failed on the second call: " +++ e)
		ROk c
			# authed = clientSetAuth "a-token" c
			# cleared = clientSetAuth "" authed
			| clientConnectionCount cleared <> 0 = abort "a freshly initialised client should report connectionCount 0"
			| clientLastCloseReason cleared <> "InitialConnect" = abort "a freshly initialised client should report lastCloseReason InitialConnect"
			= w
