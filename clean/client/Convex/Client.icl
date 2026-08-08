implementation module Convex.Client

import StdEnv
import StdMaybe
import Convex.Result
import Convex.Deadline
import Convex.Wire
import Convex.HTTP
import Convex.Live

httpDeadlineMs :: Int
httpDeadlineMs = 10000

:: Client =
	{ cEndpoint :: !Endpoint
	, cAuthToken :: !Maybe String
	, cLive :: !Maybe LiveManager
	}

clientInit :: !String !*World -> (!Result Client, !*World)
clientInit url w = case parseEndpoint url of
	Nothing = (RErr "invalid deployment URL", w)
	Just ep = (ROk {cEndpoint = ep, cAuthToken = Nothing, cLive = Nothing}, w)

clientSetAuth :: !String !Client -> Client
clientSetAuth token c = {c & cAuthToken = if (size token == 0) Nothing (Just token)}

clientClose :: !Client !*World -> *World
clientClose c w = case c.cLive of
	Nothing = w
	Just lm = liveStop lm w

clientCall :: !String !String !JSON !Client !*World -> (!Result CallResult, !*World)
clientCall operation path args c w
	# (d, w) = deadlineIn httpDeadlineMs w
	= httpCall c.cEndpoint c.cAuthToken operation path args d w

clientSubscribe :: !String !String !JSON !Client !*World -> (!Result Client, !*World)
clientSubscribe subId path args c w
	# (d, w) = deadlineIn httpDeadlineMs w
	# lm = case c.cLive of
		Just existing = existing
		Nothing = liveManagerNew c.cEndpoint c.cAuthToken
	# (subResult, w) = liveSubscribe subId path args lm d w
	= case subResult of
		RErr e = (RErr e, w)
		ROk lm2 = (ROk {c & cLive = Just lm2}, w)

clientUnsubscribe :: !String !Client !*World -> (!Result Client, !*World)
clientUnsubscribe subId c w = case c.cLive of
	Nothing = (ROk c, w)
	Just lm
		# (d, w) = deadlineIn httpDeadlineMs w
		# (result, w) = liveUnsubscribe subId lm d w
		= case result of
			RErr e = (RErr e, w)
			ROk lm2 = (ROk {c & cLive = Just lm2}, w)

clientDebugDisconnect :: !Client !*World -> (!Result Client, !*World)
clientDebugDisconnect c w = case c.cLive of
	Nothing = (RErr "no active Live connection", w)
	Just lm
		# (result, w) = liveDebugDisconnect lm w
		= case result of
			RErr e = (RErr e, w)
			ROk lm2 = (ROk {c & cLive = Just lm2}, w)

clientStep :: !Int !Client !*World -> (!Maybe SyncEvent, !Client, !*World)
clientStep pollTimeoutMs c w = case c.cLive of
	Nothing = (Nothing, c, w)
	Just lm
		# (eventOpt, lm2, w) = liveStep pollTimeoutMs lm w
		= (eventOpt, {c & cLive = Just lm2}, w)

clientConnectionCount :: !Client -> Int
clientConnectionCount c = case c.cLive of
	Nothing = 0
	Just lm = liveConnectionCount lm

clientLastCloseReason :: !Client -> String
clientLastCloseReason c = case c.cLive of
	Nothing = "InitialConnect"
	Just lm = liveLastCloseReason lm
