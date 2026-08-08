module main

// A short tour of the native Clean Convex client: an HTTP query, a Live
// subscription started before a mutation so the initial snapshot cannot be
// missed, an idempotent mutation, and the resulting Live update. Every
// printed line is checked against the value Convex actually returned;
// `abort` (which reports to stderr and exits non-zero) fires if any of them
// disagree, so this program cannot silently print a wrong value.

import StdEnv
import StdMaybe
import System.Environment
import System.IO
from ArgEnv import getCommandLine
from System._Posix import exit
import Convex.Result
import Convex.Deadline
import Convex.Wire
import Convex.HTTP
import Convex.Live
import Convex.Client

printLine :: !String !*World -> *World
printLine text w = execIO (putStrLn text) w

// Convex's JSON-safe profile may represent a whole number as either an
// integer or a float (for example the literal `0.0`); `jsonAsWholeInt`
// (Convex.Wire) accepts both shapes but only when the value is finite,
// mathematically integral, and in range — see WireTest.icl for the
// regression covering that exact rule.
countOf :: !JSON -> Int
countOf v = case jsonLookup "count" v of
	Nothing = abort "demo state was missing count"
	Just countJson = case jsonAsWholeInt countJson of
		Nothing = abort "demo count was not numeric or not a whole integer"
		Just n = n

Start :: *World -> *World
Start w
	// Configure the deployment: the client reads the URL from CONVEX_URL,
	// same as this project's other native clients, and accepts a room name
	// as its first argument so the shared verifier can target a unique room
	// per run.
	# (urlOpt, w) = getEnvironmentVariable "CONVEX_URL" w
	# url = case urlOpt of
		?Just u = u
		?None = abort "CONVEX_URL is required"
	# commandLine = getCommandLine
	# room = if (size commandLine > 1) commandLine.[1] "clean-basic-example"
	// Create the native Clean client.
	# (clientResult, w) = clientInit url w
	= case clientResult of
		RErr e = abort ("could not create the client: " +++ e)
		ROk client = runExample room client w

runExample :: !String !Client !*World -> *World
runExample room client w
	// Query the counter through Convex's documented HTTP endpoint.
	# (queryResult, w) = clientCall "query" "demo:state" (JObject [("room", JString room)]) client w
	= case queryResult of
		RErr e = abort ("query failed: " +++ e)
		ROk cr = afterQuery room client cr w

afterQuery :: !String !Client !CallResult !*World -> *World
afterQuery room client cr w = case cr.crFailure of
	Just (msg, _) = abort ("query returned a function error: " +++ msg)
	Nothing
		# before = countOf cr.crValue
		# w = printLine ("current count: " +++ toString before) w
		= startLive room client before w

// Start Live before the mutation so the initial snapshot cannot be missed:
// subscribing after the mutation could race the server and deliver the
// post-mutation value as if it were the starting point.
startLive :: !String !Client !Int !*World -> *World
startLive room client before w
	# (subResult, w) = clientSubscribe "example" "demo:state" (JObject [("room", JString room)]) client w
	= case subResult of
		RErr e = abort ("subscribe failed: " +++ e)
		ROk client1 = afterSubscribe room client1 before w

// Wait for the actual initial Live value from the bounded event stream,
// rather than assuming the first step call already delivered it.
afterSubscribe :: !String !Client !Int !*World -> *World
afterSubscribe room client before w
	# (eventResult, client1, w) = waitForUpdate client "example" w
	= case eventResult of
		RErr e = abort e
		ROk event = afterInitialLive room client1 before event w

afterInitialLive :: !String !Client !Int !SyncEvent !*World -> *World
afterInitialLive room client before event w = case event.seValue of
	Nothing = abort "live initial event had no value"
	Just v
		| countOf v <> before = abort "live initial count did not match the query count"
		# w = printLine ("live initial count: " +++ toString before) w
		= runMutation room client before w

// Apply the mutation with a stable idempotency key, so retrying this
// example against the same room is always safe.
runMutation :: !String !Client !Int !*World -> *World
runMutation room client before w
	# args = JObject [("room", JString room), ("language", JString "Clean"), ("runId", JString (room +++ "-once"))]
	# (mutResult, w) = clientCall "mutation" "demo:increment" args client w
	= case mutResult of
		RErr e = abort ("mutation failed: " +++ e)
		ROk cr = afterMutation room client before cr w

afterMutation :: !String !Client !Int !CallResult !*World -> *World
afterMutation room client before cr w = case cr.crFailure of
	Just (msg, _) = abort ("mutation returned a function error: " +++ msg)
	Nothing = checkApplied room client before cr.crValue w

checkApplied :: !String !Client !Int !JSON !*World -> *World
checkApplied room client before value w
	# applied = case jsonLookup "applied" value of
		Just appliedJson = case jsonAsBool appliedJson of
			Just b = b
			Nothing = abort "mutation response's applied field was not a boolean"
		Nothing = abort "mutation response was missing applied"
	| not applied = abort "mutation was not applied"
	# newState = case jsonLookup "state" value of
		Just s = s
		Nothing = abort "mutation response was missing state"
	# after = countOf newState
	| after <> before + 1 = abort "mutation count did not advance by exactly one"
	# w = printLine "mutation applied: true" w
	# w = printLine ("mutation count: " +++ toString after) w
	= waitForFinalLive room client before after w

// Wait for the actual resulting Live value before printing the
// verification line, rather than assuming the mutation's own HTTP response
// implies Live has already caught up.
waitForFinalLive :: !String !Client !Int !Int !*World -> *World
waitForFinalLive room client before after w
	# (eventResult, client1, w) = waitForUpdate client "example" w
	= case eventResult of
		RErr e = abort e
		ROk event = finishExample client1 before after event w

finishExample :: !Client !Int !Int !SyncEvent !*World -> *World
finishExample client before after event w = case event.seValue of
	Nothing = abort "live updated event had no value"
	Just v
		| countOf v <> after = abort "live updated count did not match the mutation count"
		# w = printLine ("live updated count: " +++ toString after) w
		# w = printLine ("verified count: " +++ toString before +++ " -> " +++ toString after) w
		= cleanup client w

// Cleanup: drop the Live subscription, close the client, then exit
// explicitly. Clean's runtime otherwise auto-displays whatever `Start`
// returns (this is by design for a bare `Start :: Int`-style program, and
// is how the hello-world and every language-local test in this client
// prove their own result); for `*World -> *World` there is nothing
// meaningful left to show, but the runtime still prints the World token's
// own internal representation. An explicit `exit 0` (libc's `exit`, which
// flushes stdio same as a normal return) ends the process before that
// default display ever runs, keeping stdout exactly the transcript above
// and nothing else.
cleanup :: !Client !*World -> *World
cleanup client w
	# (unsubResult, w) = clientUnsubscribe "example" client w
	= case unsubResult of
		RErr e = abort ("unsubscribe failed: " +++ e)
		ROk client1
			# w = clientClose client1 w
			# (_, w) = exit 0 w
			= w

// Steps the Live connection until an UPDATED event arrives for the given
// subscription, or ten seconds pass without one.
waitForUpdate :: !Client !String !*World -> (!Result SyncEvent, !Client, !*World)
waitForUpdate client subId w
	# (d, w) = deadlineIn 10000 w
	= loop client d w
where
	loop client d w
		# (expiredNow, w) = isExpired d w
		| expiredNow = (RErr "timed out waiting for a Live update", client, w)
		# (eventOpt, client1, w) = clientStep 100 client w
		= case eventOpt of
			Nothing = loop client1 d w
			Just event = afterEvent client1 subId event d w

	afterEvent client1 subId event d w
		| event.seSubscriptionId <> subId = loop client1 d w
		= case event.seKind of
			SeFailed = (RErr ("subscription failed: " +++ event.seErrorMessage), client1, w)
			SeUpdated = (ROk event, client1, w)
