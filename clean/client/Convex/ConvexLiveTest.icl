module ConvexLiveTest

// A real end-to-end regression against a live Convex backend, proving the
// whole Live stack: the WebSocket handshake, the Connect/ModifyQuerySet/
// Transition wire protocol, the initial value, a live update after a
// plain-HTTP mutation, and five real debugDisconnect-driven reconnects
// that resend the active Add and keep delivering updates on each new
// connection — matching hare/client/live.ha's
// `live_subscribe_update_and_reconnect_against_the_local_backend`, and the
// exact five-reconnect sequence AGENTS.md's Live acceptance section asks
// for. Per this project's test-layer split, the offline `test` Docker
// stage never sets CONVEX_URL, so `Start` below is a no-op there.

import StdEnv
import StdMaybe
import System.Environment
import Convex.Deadline
import Convex.Result
import Convex.Wire
import Convex.HTTP
import Convex.Live

Start :: *World -> *World
Start w
	# (urlOpt, w) = getEnvironmentVariable "CONVEX_URL" w
	= case urlOpt of
		?None = w
		?Just url = runLiveTest url w

runLiveTest :: !String !*World -> *World
runLiveTest url w = case parseEndpoint url of
	Nothing = abort "ConvexLiveTest: CONVEX_URL did not parse as a valid endpoint"
	Just ep = startSubscription ep w

startSubscription :: !Endpoint !*World -> *World
startSubscription ep w
	# (now, w) = nowMs w
	# room = "clean-live-test-" +++ toString now
	# lm = liveManagerNew ep Nothing
	# (d, w) = deadlineIn 10000 w
	# (subResult, w) = liveSubscribe "room-sub" "demo:state" (JObject [("room", JString room)]) lm d w
	= case subResult of
		RErr e = abort ("ConvexLiveTest: liveSubscribe failed: " +++ e)
		ROk lm1 = afterSubscribe ep room lm1 w

afterSubscribe :: !Endpoint !String !LiveManager !*World -> *World
afterSubscribe ep room lm w
	# (initialResult, lm1, w) = waitForEvent lm 10000 w
	= case initialResult of
		RErr e = abort ("ConvexLiveTest: " +++ e)
		ROk event = checkInitial ep room lm1 event w

checkInitial :: !Endpoint !String !LiveManager !SyncEvent !*World -> *World
checkInitial ep room lm event w
	| event.seSubscriptionId <> "room-sub" = abort "ConvexLiveTest: initial event was for the wrong subscription"
	= case event.seKind of
		SeFailed = abort "ConvexLiveTest: expected an initial UPDATED event, got FAILED"
		SeUpdated
			# count = countFromEvent event
			| count <> 0 = abort "ConvexLiveTest: initial count was not 0 for a fresh room"
			= triggerMutation 0 ep room lm w

// A single helper drives both the very first mutation (attempt = -1) and
// each of the five reconnect-round mutations (attempt = 0..4), since the
// two only differ in the runId's suffix and, for the reconnect rounds,
// having debugDisconnect'd and quietly drained first.
triggerMutation :: !Int !Endpoint !String !LiveManager !*World -> *World
triggerMutation attempt ep room lm w
	# (d, w) = deadlineIn 10000 w
	# runId = if (attempt == 0) room (room +++ "-r" +++ toString attempt)
	# args = JObject [("room", JString room), ("language", JString "Clean"), ("runId", JString runId)]
	# (mutResult, w) = httpCall ep Nothing "mutation" "demo:increment" args d w
	= case mutResult of
		RErr e = abort ("ConvexLiveTest: mutation failed: " +++ e)
		ROk cr = case cr.crFailure of
			Just (msg, _) = abort ("ConvexLiveTest: mutation returned a function error: " +++ msg)
			Nothing = afterMutation attempt ep room lm w

afterMutation :: !Int !Endpoint !String !LiveManager !*World -> *World
afterMutation attempt ep room lm w
	# (nextResult, lm1, w) = waitForEvent lm 10000 w
	= case nextResult of
		RErr e = abort ("ConvexLiveTest: " +++ e)
		ROk event = checkUpdated attempt ep room lm1 event w

checkUpdated :: !Int !Endpoint !String !LiveManager !SyncEvent !*World -> *World
checkUpdated attempt ep room lm event w = case event.seKind of
	SeFailed = abort "ConvexLiveTest: expected UPDATED after a mutation, got FAILED"
	SeUpdated
		# count = countFromEvent event
		# expectedCount = attempt + 1
		| count <> expectedCount = abort "ConvexLiveTest: count after a mutation did not match the expected running total"
		| attempt > 0 && liveConnectionCount lm <> expectedCount = abort "ConvexLiveTest: connectionCount did not match 1 + reconnect attempts"
		= continueAfterUpdate attempt ep room lm w

continueAfterUpdate :: !Int !Endpoint !String !LiveManager !*World -> *World
continueAfterUpdate attempt ep room lm w
	| attempt >= 5 = w
	# (ddResult, w) = liveDebugDisconnect lm w
	= case ddResult of
		RErr e = abort ("ConvexLiveTest: debugDisconnect failed: " +++ e)
		ROk lm1 = afterDisconnect attempt ep room lm1 w

afterDisconnect :: !Int !Endpoint !String !LiveManager !*World -> *World
afterDisconnect attempt ep room lm w
	// Rehydration of an unchanged value must not surface as a new event;
	// only the genuine change from the next mutation should.
	# (lm1, w) = drainQuietly lm 500 w
	= triggerMutation (attempt + 1) ep room lm1 w

waitForEvent :: !LiveManager !Int !*World -> (!Result SyncEvent, !LiveManager, !*World)
waitForEvent lm budgetMs w
	# (d, w) = deadlineIn budgetMs w
	= waitLoop lm d w
where
	waitLoop lm d w
		# (expiredNow, w) = isExpired d w
		| expiredNow = (RErr "timed out waiting for a Live event", lm, w)
		# (eventOpt, lm1, w) = liveStep 100 lm w
		= case eventOpt of
			Just event = (ROk event, lm1, w)
			Nothing = waitLoop lm1 d w

drainQuietly :: !LiveManager !Int !*World -> (!LiveManager, !*World)
drainQuietly lm windowMs w
	# (d, w) = deadlineIn windowMs w
	= drainLoop lm d w
where
	drainLoop lm d w
		# (expiredNow, w) = isExpired d w
		| expiredNow = (lm, w)
		# (eventOpt, lm1, w) = liveStep 50 lm w
		= case eventOpt of
			Just event = abort "ConvexLiveTest: unexpected Live event during a quiet reconnect window"
			Nothing = drainLoop lm1 d w

countFromEvent :: !SyncEvent -> Int
countFromEvent event = case event.seValue of
	Nothing = abort "ConvexLiveTest: UPDATED event had no value"
	Just v = case jsonLookup "count" v of
		Nothing = abort "ConvexLiveTest: UPDATED event value had no count field"
		Just countJson = case jsonAsWholeInt countJson of
			Nothing = abort "ConvexLiveTest: count was not a whole integer"
			Just n = n
