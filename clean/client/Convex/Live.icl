implementation module Convex.Live

import StdEnv
import StdMaybe
import Convex.Result
import Convex.Deadline
import Convex.Wire
import Convex.HTTP
import Convex.Transport
import Convex.WebSocket
import Convex.Socket
import Text.Encodings.Base64

connectDeadlineMs :: Int
connectDeadlineMs = 10000
frameDeadlineMs :: Int
frameDeadlineMs = 5000
maxLiveSubscriptions :: Int
maxLiveSubscriptions = 16
maxCounter :: Int
maxCounter = 0xffffffff

// --- data ------------------------------------------------------------------

:: ActiveQuery =
	{ aqId :: !Int
	, aqSubscriptionId :: !String
	, aqPath :: !String
	, aqArgs :: !JSON
	, aqLastValueJson :: !Maybe String
	, aqLastSuccess :: !Bool
	, aqAwaitingRehydration :: !Bool
	}

:: StateVersion = {svQuerySet :: !Int, svIdentity :: !Int, svTimestamp :: !String}

:: LiveManager =
	{ lmEndpoint :: !Endpoint
	, lmAuthToken :: !Maybe String
	, lmConn :: !Maybe WsConn
	, lmQuerySetVersion :: !Int
	, lmRemoteVersion :: !StateVersion
	, lmNextQueryId :: !Int
	, lmConnectionCount :: !Int
	, lmLastCloseReason :: !String
	, lmMaxTimestamp :: !Maybe String
	, lmActive :: ![ActiveQuery]
	, lmPending :: ![SyncEvent]
	}

zeroTimestamp :: String
zeroTimestamp = {toChar 0 \\ i <- [1 .. 8]}

zeroStateVersion :: StateVersion
zeroStateVersion = {svQuerySet = 0, svIdentity = 0, svTimestamp = zeroTimestamp}

liveManagerNew :: !Endpoint !(Maybe String) -> LiveManager
liveManagerNew ep authToken =
	{ lmEndpoint = ep
	, lmAuthToken = authToken
	, lmConn = Nothing
	, lmQuerySetVersion = 0
	, lmRemoteVersion = zeroStateVersion
	, lmNextQueryId = 0
	, lmConnectionCount = 0
	, lmLastCloseReason = "InitialConnect"
	, lmMaxTimestamp = Nothing
	, lmActive = []
	, lmPending = []
	}

liveConnectionCount :: !LiveManager -> Int
liveConnectionCount lm = lm.lmConnectionCount

liveLastCloseReason :: !LiveManager -> String
liveLastCloseReason lm = lm.lmLastCloseReason

liveMaxObservedTimestampBase64 :: !LiveManager -> Maybe String
liveMaxObservedTimestampBase64 lm = case lm.lmMaxTimestamp of
	Nothing = Nothing
	Just ts = Just (base64Encode ts)

// --- small list helpers over ActiveQuery ----------------------------------

updateAt :: !Int !(ActiveQuery -> ActiveQuery) ![ActiveQuery] -> [ActiveQuery]
updateAt idx f list = [pick i q \\ q <- list & i <- [0 ..]]
where
	pick i q = if (i == idx) (f q) q

removeAt :: !Int ![ActiveQuery] -> [ActiveQuery]
removeAt idx list = [q \\ q <- list & i <- [0 ..] | i <> idx]

findIndexBy :: !(ActiveQuery -> Bool) ![ActiveQuery] -> Maybe Int
findIndexBy pred list = go list 0
where
	go [] _ = Nothing
	go [x : xs] i = if (pred x) (Just i) (go xs (i + 1))

matchesSub :: !String !ActiveQuery -> Bool
matchesSub subId q = q.aqSubscriptionId == subId

matchesId :: !Int !ActiveQuery -> Bool
matchesId qid q = q.aqId == qid

isEmptyList :: ![a] -> Bool
isEmptyList [] = True
isEmptyList _ = False

// --- session id --------------------------------------------------------

hexDigit :: !Int -> Char
hexDigit n
	| n < 10 = toChar (toInt '0' + n)
	= toChar (toInt 'a' + n - 10)

hexByte :: !Int -> String
hexByte n = {hexDigit ((n >> 4) bitand 15), hexDigit (n bitand 15)}

formatUuid :: !String -> String
formatUuid raw =
	hexByte (toInt raw.[0]) +++ hexByte (toInt raw.[1]) +++ hexByte (toInt raw.[2]) +++ hexByte (toInt raw.[3]) +++ "-" +++
	hexByte (toInt raw.[4]) +++ hexByte (toInt raw.[5]) +++ "-" +++
	hexByte b6 +++ hexByte (toInt raw.[7]) +++ "-" +++
	hexByte b8 +++ hexByte (toInt raw.[9]) +++ "-" +++
	hexByte (toInt raw.[10]) +++ hexByte (toInt raw.[11]) +++ hexByte (toInt raw.[12]) +++ hexByte (toInt raw.[13]) +++ hexByte (toInt raw.[14]) +++ hexByte (toInt raw.[15])
where
	b6 = (toInt raw.[6] bitand 0x0f) bitor 0x40
	b8 = (toInt raw.[8] bitand 0x3f) bitor 0x80

// --- state version helpers -----------------------------------------------

sameVersion :: !StateVersion !StateVersion -> Bool
sameVersion a b = a.svQuerySet == b.svQuerySet && a.svIdentity == b.svIdentity && a.svTimestamp == b.svTimestamp

// Little-endian per the pinned sync profile, matching this project's other
// native clients: the most significant byte to compare first is the last
// one.
compareTimestamp :: !String !String -> Int
compareTimestamp a b = go 7
where
	go i
		| i < 0 = 0
		| toInt a.[i] < toInt b.[i] = -1
		| toInt a.[i] > toInt b.[i] = 1
		= go (i - 1)

decodeStateVersion :: !JSON -> Maybe StateVersion
decodeStateVersion v = case jsonLookup "querySet" v of
	Nothing = Nothing
	Just qsJson = case jsonAsWholeInt qsJson of
		Nothing = Nothing
		Just qs = decodeIdentity qs v

decodeIdentity :: !Int !JSON -> Maybe StateVersion
decodeIdentity qs v = case jsonLookup "identity" v of
	Nothing = Nothing
	Just idJson = case jsonAsWholeInt idJson of
		Nothing = Nothing
		Just ident = decodeTimestamp qs ident v

decodeTimestamp :: !Int !Int !JSON -> Maybe StateVersion
decodeTimestamp qs ident v = case jsonLookup "ts" v of
	Nothing = Nothing
	Just tsJson = case jsonAsString tsJson of
		Nothing = Nothing
		Just tsText
			# decoded = base64Decode tsText
			| size decoded <> 8 = Nothing
			= Just {svQuerySet = qs, svIdentity = ident, svTimestamp = decoded}

// --- sending -------------------------------------------------------------

sendRawJson :: !JSON !LiveManager !Deadline !*World -> (!Result (), !*World)
sendRawJson payload lm d w = case lm.lmConn of
	Nothing = (RErr "no active Live connection", w)
	Just conn = wsWriteFrame conn.wcTransport WsText (encodeJSON payload) d w

sendConnect :: !LiveManager !Deadline !*World -> (!Result LiveManager, !*World)
sendConnect lm d w
	# (sessionBytes, w) = randomBytesStr 16 w
	# sessionId = formatUuid sessionBytes
	# maxTsField = case lm.lmMaxTimestamp of
		Just ts = [("maxObservedTimestamp", JString (base64Encode ts))]
		Nothing = []
	# payload = JObject ([("type", JString "Connect"), ("sessionId", JString sessionId), ("connectionCount", JInt lm.lmConnectionCount), ("lastCloseReason", JString lm.lmLastCloseReason), ("clientTs", JInt 0)] ++ maxTsField)
	# (sendResult, w) = sendRawJson payload lm d w
	= case sendResult of
		RErr e = (RErr e, w)
		ROk _ = (ROk lm, w)

sendModifyQuerySet :: !JSON !LiveManager !Deadline !*World -> (!Result LiveManager, !*World)
sendModifyQuerySet modification lm d w
	# base = lm.lmQuerySetVersion
	# next = base + 1
	# payload = JObject [("type", JString "ModifyQuerySet"), ("baseVersion", JInt base), ("newVersion", JInt next), ("modifications", JArray [modification])]
	# (sendResult, w) = sendRawJson payload lm d w
	= case sendResult of
		RErr e = (RErr e, w)
		ROk _ = (ROk {lm & lmQuerySetVersion = next}, w)

sendModifyAdd :: !Int !LiveManager !Deadline !*World -> (!Result LiveManager, !*World)
sendModifyAdd idx lm d w
	# q = lm.lmActive !! idx
	# modification = JObject [("type", JString "Add"), ("queryId", JInt q.aqId), ("udfPath", JString q.aqPath), ("args", JArray [q.aqArgs])]
	= sendModifyQuerySet modification lm d w

sendModifyRemove :: !Int !LiveManager !Deadline !*World -> (!Result LiveManager, !*World)
sendModifyRemove qid lm d w
	# modification = JObject [("type", JString "Remove"), ("queryId", JInt qid)]
	= sendModifyQuerySet modification lm d w

// --- connect / retire / subscribe -----------------------------------------

closeSocket :: !String !LiveManager !*World -> (!LiveManager, !*World)
closeSocket reason lm w = case lm.lmConn of
	Nothing = (lm, w)
	Just conn
		# w = wsClose conn w
		= ({lm & lmConn = Nothing, lmLastCloseReason = reason}, w)

syncPath :: !Endpoint -> String
syncPath ep = ep.epBasePath +++ "/api/sync"

ensureConnected :: !LiveManager !Deadline !*World -> (!Result LiveManager, !*World)
ensureConnected lm d w
	# (connResult, w) = connectTransport lm.lmEndpoint.epTls lm.lmEndpoint.epHost lm.lmEndpoint.epPort d w
	= case connResult of
		RErr e = (RErr e, w)
		ROk t = afterTcpConnect t lm d w

afterTcpConnect :: !Transport !LiveManager !Deadline !*World -> (!Result LiveManager, !*World)
afterTcpConnect t lm d w
	# (hsResult, w) = wsHandshake t lm.lmEndpoint.epHost (syncPath lm.lmEndpoint) [("Convex-Client", "clean-0.1.0")] d w
	= case hsResult of
		RErr e
			# w = transportClose t w
			= (RErr e, w)
		ROk conn = afterHandshake conn lm d w

afterHandshake :: !WsConn !LiveManager !Deadline !*World -> (!Result LiveManager, !*World)
afterHandshake conn lm d w
	# lm1 = {lm & lmConn = Just conn, lmQuerySetVersion = 0, lmRemoteVersion = zeroStateVersion}
	# (sendResult, w) = sendConnect lm1 d w
	= case sendResult of
		RErr e = (RErr e, w)
		ROk lm2 = afterSendConnect lm2 d w

afterSendConnect :: !LiveManager !Deadline !*World -> (!Result LiveManager, !*World)
afterSendConnect lm d w
	# lm1 = if (lm.lmConnectionCount < maxCounter) {lm & lmConnectionCount = lm.lmConnectionCount + 1} lm
	# (replayResult, w) = replayActive 0 lm1 d w
	= case replayResult of
		RErr e = (RErr e, w)
		ROk lm2 = afterReplay lm2 d w

afterReplay :: !LiveManager !Deadline !*World -> (!Result LiveManager, !*World)
afterReplay lm d w
	# (expiredNow, w) = isExpired d w
	| expiredNow = (RErr "Live connection bring-up timed out", w)
	= (ROk lm, w)

replayActive :: !Int !LiveManager !Deadline !*World -> (!Result LiveManager, !*World)
replayActive idx lm d w
	| idx >= length lm.lmActive = (ROk lm, w)
	# lm1 = {lm & lmActive = updateAt idx markAwaitingRehydration lm.lmActive}
	# (sendResult, w) = sendModifyAdd idx lm1 d w
	= case sendResult of
		RErr e = (RErr e, w)
		ROk lm2 = replayActive (idx + 1) lm2 d w

markAwaitingRehydration :: !ActiveQuery -> ActiveQuery
markAwaitingRehydration q = {q & aqAwaitingRehydration = q.aqLastSuccess}

retireActive :: !Int !LiveManager !Deadline !*World -> (!LiveManager, !*World)
retireActive idx lm d w
	# qid = (lm.lmActive !! idx).aqId
	# lm1 = {lm & lmActive = removeAt idx lm.lmActive}
	= case lm1.lmConn of
		Nothing = (lm1, w)
		Just _ = afterRemoveSend qid lm1 d w

afterRemoveSend :: !Int !LiveManager !Deadline !*World -> (!LiveManager, !*World)
afterRemoveSend qid lm d w
	# (sendResult, w) = sendModifyRemove qid lm d w
	= case sendResult of
		RErr e = closeSocket e lm w
		ROk lm2 = (lm2, w)

liveSubscribe :: !String !String !JSON !LiveManager !Deadline !*World -> (!Result LiveManager, !*World)
liveSubscribe subId path args lm d w = case findIndexBy (matchesSub subId) lm.lmActive of
	Just idx
		# (lm1, w) = retireActive idx lm d w
		= continueSubscribe subId path args lm1 d w
	Nothing = continueSubscribe subId path args lm d w

continueSubscribe :: !String !String !JSON !LiveManager !Deadline !*World -> (!Result LiveManager, !*World)
continueSubscribe subId path args lm d w
	| length lm.lmActive >= maxLiveSubscriptions = (RErr "too many active Live subscriptions", w)
	| lm.lmNextQueryId == maxCounter = (RErr "too many queries have been added over this client's lifetime", w)
	# newQuery = {aqId = lm.lmNextQueryId, aqSubscriptionId = subId, aqPath = path, aqArgs = args, aqLastValueJson = Nothing, aqLastSuccess = False, aqAwaitingRehydration = False}
	# lm1 = {lm & lmActive = lm.lmActive ++ [newQuery], lmNextQueryId = lm.lmNextQueryId + 1}
	= afterRegister lm1 d w

afterRegister :: !LiveManager !Deadline !*World -> (!Result LiveManager, !*World)
afterRegister lm d w = case lm.lmConn of
	Nothing = ensureConnected lm d w
	Just _
		# (sendResult, w) = sendModifyAdd (length lm.lmActive - 1) lm d w
		= case sendResult of
			RErr e
				# (lm2, w) = closeSocket e lm w
				= (ROk lm2, w)
			ROk lm2 = (ROk lm2, w)

liveUnsubscribe :: !String !LiveManager !Deadline !*World -> (!Result LiveManager, !*World)
liveUnsubscribe subId lm d w = case findIndexBy (matchesSub subId) lm.lmActive of
	Nothing = (ROk lm, w)
	Just idx
		# (lm2, w) = retireActive idx lm d w
		= (ROk lm2, w)

liveDebugDisconnect :: !LiveManager !*World -> (!Result LiveManager, !*World)
liveDebugDisconnect lm w = case lm.lmConn of
	Nothing = (RErr "no active Live connection", w)
	Just _
		# (lm2, w) = closeSocket "DebugDisconnect" lm w
		= (ROk lm2, w)

liveStop :: !LiveManager !*World -> *World
liveStop lm w = case lm.lmConn of
	Nothing = w
	Just conn = wsClose conn w

// --- publish an owner-side (non-function) failure to every active query ---

publishOwnerError :: !String !String !LiveManager -> LiveManager
publishOwnerError name message lm = {lm & lmPending = lm.lmPending ++ map mkEvent lm.lmActive}
where
	mkEvent q = {seSubscriptionId = q.aqSubscriptionId, seKind = SeFailed, seValue = Nothing, seErrorName = name, seErrorMessage = message, seErrorData = Nothing, seLogs = Nothing}

// --- transition handling (pure: no *World, no network) --------------------

applyQueryUpdated :: !Int !JSON !LiveManager -> Result LiveManager
applyQueryUpdated idx mod lm = case jsonLookup "value" mod of
	Nothing = RErr "QueryUpdated modification is missing value"
	Just valueField = ROk (applyUpdateValue idx valueField mod lm)

applyUpdateValue :: !Int !JSON !JSON !LiveManager -> LiveManager
applyUpdateValue idx valueField mod lm
	# q = lm.lmActive !! idx
	# encoded = encodeJSON valueField
	# duplicate = q.aqAwaitingRehydration && q.aqLastSuccess && sameAsLast q.aqLastValueJson encoded
	| duplicate = {lm & lmActive = updateAt idx clearRehydration lm.lmActive}
	# updated = {q & aqAwaitingRehydration = False, aqLastValueJson = Just encoded, aqLastSuccess = True}
	# event = {seSubscriptionId = q.aqSubscriptionId, seKind = SeUpdated, seValue = Just valueField, seErrorName = "", seErrorMessage = "", seErrorData = Nothing, seLogs = jsonLookup "logLines" mod}
	= {lm & lmActive = updateAt idx (const updated) lm.lmActive, lmPending = lm.lmPending ++ [event]}

const :: !a !b -> a
const x _ = x

clearRehydration :: !ActiveQuery -> ActiveQuery
clearRehydration q = {q & aqAwaitingRehydration = False}

sameAsLast :: !(Maybe String) !String -> Bool
sameAsLast (Just s) encoded = s == encoded
sameAsLast Nothing encoded = False

applyQueryFailed :: !Int !JSON !LiveManager -> Result LiveManager
applyQueryFailed idx mod lm
	# q = lm.lmActive !! idx
	# message = case jsonLookup "errorMessage" mod of
		Just msgJson = case jsonAsString msgJson of
			Just s = s
			Nothing = "query failed"
		Nothing = "query failed"
	# dataField = jsonLookup "errorData" mod
	# updated = {q & aqAwaitingRehydration = False, aqLastSuccess = False}
	# event = {seSubscriptionId = q.aqSubscriptionId, seKind = SeFailed, seValue = Nothing, seErrorName = "FunctionError", seErrorMessage = message, seErrorData = dataField, seLogs = jsonLookup "logLines" mod}
	= ROk {lm & lmActive = updateAt idx (const updated) lm.lmActive, lmPending = lm.lmPending ++ [event]}

applyForQuery :: !Int !JSON !LiveManager -> Result LiveManager
applyForQuery qid mod lm = case findIndexBy (matchesId qid) lm.lmActive of
	Nothing = ROk lm
	Just idx = case jsonLookup "type" mod of
		Nothing = RErr "modification is missing type"
		Just typeJson = case jsonAsString typeJson of
			Nothing = RErr "modification type was not a string"
			Just "QueryUpdated" = applyQueryUpdated idx mod lm
			Just "QueryFailed" = applyQueryFailed idx mod lm
			Just "QueryRemoved" = ROk lm
			Just _ = RErr "unrecognized Live modification type"

applyModification :: !JSON !LiveManager -> Result LiveManager
applyModification mod lm = case jsonLookup "queryId" mod of
	Nothing = RErr "modification is missing queryId"
	Just idJson = case jsonAsWholeInt idJson of
		Nothing = RErr "modification queryId was not numeric"
		Just qid = applyForQuery qid mod lm

processModifications :: ![JSON] !LiveManager -> Result LiveManager
processModifications mods lm = foldModifications mods (ROk lm)
where
	foldModifications [] acc = acc
	foldModifications _ (RErr e) = RErr e
	foldModifications [m : ms] (ROk lmOk) = foldModifications ms (applyModification m lmOk)

finishTransition :: !StateVersion ![JSON] !LiveManager -> Result LiveManager
finishTransition end mods lm = processModifications mods {lm & lmRemoteVersion = end, lmMaxTimestamp = newMaxTimestamp}
where
	newMaxTimestamp = case lm.lmMaxTimestamp of
		Nothing = Just end.svTimestamp
		Just cur = if (compareTimestamp end.svTimestamp cur > 0) (Just end.svTimestamp) (Just cur)

validateAndApply :: !StateVersion !StateVersion !JSON !LiveManager -> Result LiveManager
validateAndApply start end parsed lm
	| not (sameVersion start lm.lmRemoteVersion) = RErr "Live transition did not chain from the known state version"
	| end.svQuerySet < start.svQuerySet || end.svQuerySet > lm.lmQuerySetVersion = RErr "Live transition query set version out of range"
	| end.svIdentity < start.svIdentity || compareTimestamp end.svTimestamp start.svTimestamp < 0 = RErr "Live transition moved backward in time"
	= case jsonLookup "modifications" parsed of
		Nothing = RErr "Live transition is missing modifications"
		Just modsJson = case jsonAsArray modsJson of
			Nothing = RErr "Live transition modifications was not an array"
			Just mods = finishTransition end mods lm

handleTransition :: !JSON !LiveManager -> Result LiveManager
handleTransition parsed lm = case jsonLookup "startVersion" parsed of
	Nothing = RErr "Live transition is missing startVersion"
	Just startJson = case decodeStateVersion startJson of
		Nothing = RErr "Live transition startVersion was malformed"
		Just start = case jsonLookup "endVersion" parsed of
			Nothing = RErr "Live transition is missing endVersion"
			Just endJson = case decodeStateVersion endJson of
				Nothing = RErr "Live transition endVersion was malformed"
				Just end = validateAndApply start end parsed lm

// --- the step loop -------------------------------------------------------

liveStep :: !Int !LiveManager !*World -> (!Maybe SyncEvent, !LiveManager, !*World)
liveStep pollTimeoutMs lm w = case lm.lmPending of
	[event : rest] = (Just event, {lm & lmPending = rest}, w)
	[] = stepNoPending pollTimeoutMs lm w

stepNoPending :: !Int !LiveManager !*World -> (!Maybe SyncEvent, !LiveManager, !*World)
stepNoPending pollTimeoutMs lm w = case lm.lmConn of
	Nothing = handleNoConn lm w
	Just conn = handleWithConn pollTimeoutMs conn lm w

handleNoConn :: !LiveManager !*World -> (!Maybe SyncEvent, !LiveManager, !*World)
handleNoConn lm w
	| isEmptyList lm.lmActive = (Nothing, lm, w)
	# (d, w) = deadlineIn connectDeadlineMs w
	# (connected, w) = ensureConnected lm d w
	= case connected of
		ROk lm2 = (Nothing, lm2, w)
		RErr e = liveStep 0 (publishOwnerError "TransportError" e lm) w

handleWithConn :: !Int !WsConn !LiveManager !*World -> (!Maybe SyncEvent, !LiveManager, !*World)
handleWithConn pollTimeoutMs conn lm w
	# (readyResult, w) = pollReadyFd (transportFd conn.wcTransport) pollTimeoutMs w
	= case readyResult of
		RErr e = afterTransportError e lm w
		ROk False = (Nothing, lm, w)
		ROk True = readAndHandleFrame conn lm w

afterTransportError :: !String !LiveManager !*World -> (!Maybe SyncEvent, !LiveManager, !*World)
afterTransportError e lm w
	# (lm1, w) = closeSocket "TransportError" lm w
	= liveStep 0 (publishOwnerError "TransportError" e lm1) w

readAndHandleFrame :: !WsConn !LiveManager !*World -> (!Maybe SyncEvent, !LiveManager, !*World)
readAndHandleFrame conn lm w
	# (d, w) = deadlineIn frameDeadlineMs w
	# (msgResult, w) = wsReadMessage conn d w
	= case msgResult of
		RErr e = afterTransportError e lm w
		ROk (msg, newConn) = dispatchMessage msg newConn d lm w

dispatchMessage :: !WsMessage !WsConn !Deadline !LiveManager !*World -> (!Maybe SyncEvent, !LiveManager, !*World)
dispatchMessage msg conn d lm w = case msg.wsOpcode of
	WsClose
		# (lm1, w) = closeSocket "ServerClose" lm w
		= liveStep 0 lm1 w
	WsText = handleTextFrame msg.wsPayload conn d lm w
	_
		# (lm1, w) = closeSocket "unexpected Live frame opcode" lm w
		= liveStep 0 (publishOwnerError "ProtocolError" "unexpected Live frame opcode" lm1) w

handleTextFrame :: !String !WsConn !Deadline !LiveManager !*World -> (!Maybe SyncEvent, !LiveManager, !*World)
handleTextFrame payload conn d lm w
	# lm1 = {lm & lmConn = Just conn}
	= case parseJSON payload of
		Nothing = protocolError "malformed Live JSON frame" lm1 w
		Just parsed = dispatchParsed parsed d lm1 w

dispatchParsed :: !JSON !Deadline !LiveManager !*World -> (!Maybe SyncEvent, !LiveManager, !*World)
dispatchParsed parsed d lm w = case jsonLookup "type" parsed of
	Nothing = protocolError "malformed Live JSON frame" lm w
	Just typeJson = case jsonAsString typeJson of
		Nothing = protocolError "malformed Live JSON frame" lm w
		Just "Ping" = respondPong d lm w
		Just "Transition" = applyTransitionFrame parsed lm w
		Just _ = protocolError "unexpected Live message type" lm w

respondPong :: !Deadline !LiveManager !*World -> (!Maybe SyncEvent, !LiveManager, !*World)
respondPong d lm w = case lm.lmConn of
	Nothing = liveStep 0 lm w
	Just conn = afterPongAttempt conn d lm w

afterPongAttempt :: !WsConn !Deadline !LiveManager !*World -> (!Maybe SyncEvent, !LiveManager, !*World)
afterPongAttempt conn d lm w
	# (sendResult, w) = wsWriteFrame conn.wcTransport WsPong "" d w
	= case sendResult of
		RErr e = afterTransportError e lm w
		ROk _ = liveStep 0 lm w

applyTransitionFrame :: !JSON !LiveManager !*World -> (!Maybe SyncEvent, !LiveManager, !*World)
applyTransitionFrame parsed lm w = case handleTransition parsed lm of
	RErr e = protocolError e lm w
	ROk lm2 = liveStep 0 lm2 w

protocolError :: !String !LiveManager !*World -> (!Maybe SyncEvent, !LiveManager, !*World)
protocolError msg lm w
	# (lm1, w) = closeSocket msg lm w
	= liveStep 0 (publishOwnerError "ProtocolError" msg lm1) w

// `Convex.Socket.pollReady`'s own `Bool` argument selects read- vs
// write-readiness; a Live connection is only ever polled for
// read-readiness here (writes go through the same bounded
// transportWriteAll/wsWriteFrame path every other send in this client
// already uses).
pollReadyFd :: !Int !Int !*World -> (!Result Bool, !*World)
pollReadyFd fd timeoutMs w = pollReady fd False timeoutMs w
