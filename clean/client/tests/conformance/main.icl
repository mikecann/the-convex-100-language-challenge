module main

// The NDJSON adapter protocol v1 executable. This is test infrastructure
// for the shared conformance harness, not part of the educational
// Convex.Client API: it decodes one command per input line, calls the real
// client in client/, and encodes one event per output line. Everything
// Convex-specific (HTTP calls, the Live/WebSocket sync protocol,
// reconnects) is delegated to Convex.Client; this file only speaks the
// adapter's own wire protocol, plus the handful of raw POSIX bindings
// (read/write/socket/bind/listen/accept) it needs to do that over either
// stdin/stdout or one accepted ADAPTER_LISTEN TCP connection — matching
// this project's other native clients (see
// hare/client/tests/conformance/main.ha).
//
// The combined-fds poll Hare's adapter uses to wait on both the command
// input and the Live socket at once is simplified here to a single poll on
// the input fd (bounded to 100ms, so the loop never busy-spins) followed
// unconditionally by one non-blocking `clientStep 0` per iteration: Client
// is an abstract type with no exposed file descriptor, and a 100ms upper
// bound on noticing either a new command or a new Live frame is the same
// order of latency Hare's own poll timeout uses.

import StdEnv
import StdMaybe
from System._Pointer import :: Pointer
from System._Posix import exit
import System.Environment
import Convex.Result
import Convex.Deadline
import Convex.Mem
import Convex.Socket
import Convex.Wire
import Convex.HTTP
import Convex.Live
import Convex.Client

adapterLanguage :: String
adapterLanguage = "clean"
adapterImplementation :: String
adapterImplementation = "native-clean-openssl-c-abi"
adapterRuntime :: String
adapterRuntime = "clean-3.1"

// --- raw POSIX bindings (adapter-only; not part of the public client) ----

readCcall :: !Int !Pointer !Int !*World -> (!Int, !*World)
readCcall fd buf n w = code {
	ccall read "IpI:I:A"
}

writeCcall :: !Int !String !Int !*World -> (!Int, !*World)
writeCcall fd buf n w = code {
	ccall write "IsI:I:A"
}

socketCcall :: !Int !Int !Int !*World -> (!Int, !*World)
socketCcall d t p w = code {
	ccall socket "III:I:A"
}

bindCcall :: !Int !Pointer !Int !*World -> (!Int, !*World)
bindCcall fd addr len w = code {
	ccall bind "IpI:I:A"
}

listenCcall :: !Int !Int !*World -> (!Int, !*World)
listenCcall fd backlog w = code {
	ccall listen "II:I:A"
}

acceptCcall :: !Int !Pointer !Pointer !*World -> (!Int, !*World)
acceptCcall fd addr addrlen w = code {
	ccall accept "Ipp:I:A"
}

htonsCcall :: !Int -> Int
htonsCcall a = code {
	ccall htons "I:I"
}

def_AF_INET :: Int
def_AF_INET = 2
def_SOCK_STREAM :: Int
def_SOCK_STREAM = 1

// --- setting up stdin/stdout or one accepted ADAPTER_LISTEN connection ---

findChar :: !Char !String !Int -> Maybe Int
findChar c s start = go start
where
	n = size s
	go i
		| i == n = Nothing
		| s.[i] == c = Just i
		= go (i + 1)

lastColonIndex :: !String -> Maybe Int
lastColonIndex s = go (size s - 1)
where
	go i
		| i < 0 = Nothing
		| s.[i] == ':' = Just i
		= go (i - 1)

strToIntLocal :: !String -> Maybe Int
strToIntLocal s
	| size s == 0 = Nothing
	= digits 0 0
where
	n = size s
	digits i acc
		| i == n = Just acc
		| s.[i] < '0' || s.[i] > '9' = Nothing
		= digits (i + 1) (acc * 10 + (toInt s.[i] - toInt '0'))

// Binding is always to INADDR_ANY (0.0.0.0) regardless of the host this
// project's own harness always passes in ADAPTER_LISTEN ("0.0.0.0:<port>",
// see ./run's run_pilot_controller): only the port is actually parsed out.
setupIO :: !*World -> (!Int, !Int, !*World)
setupIO w
	# (listenOpt, w) = getEnvironmentVariable "ADAPTER_LISTEN" w
	= case listenOpt of
		?None = (0, 1, w)
		?Just addr = tcpListenAndAccept addr w

tcpListenAndAccept :: !String !*World -> (!Int, !Int, !*World)
tcpListenAndAccept addr w
	# port = case lastColonIndex addr of
		Nothing = abort "ADAPTER_LISTEN must be host:port"
		Just i = case strToIntLocal (addr % (i + 1, size addr - 1)) of
			Nothing = abort "ADAPTER_LISTEN has an invalid port"
			Just p = p
	# (listenFd, w) = socketCcall def_AF_INET def_SOCK_STREAM 0 w
	| listenFd == -1 = abort "could not create the adapter listen socket"
	# (sockaddrBuf, w) = mallocW 16 w
	# (sockaddrBuf, w) = zeroBytesW sockaddrBuf 0 16 w
	# (sockaddrBuf, w) = writeU16LEW sockaddrBuf 0 def_AF_INET w
	# (sockaddrBuf, w) = writeU16LEW sockaddrBuf 2 (htonsCcall port) w
	# (bindResult, w) = bindCcall listenFd sockaddrBuf 16 w
	# w = freeW sockaddrBuf w
	| bindResult == -1 = abort "could not bind the adapter listen socket"
	# (listenResult, w) = listenCcall listenFd 1 w
	| listenResult == -1 = abort "could not listen on the adapter socket"
	# (clientFd, w) = acceptCcall listenFd 0 0 w
	| clientFd == -1 = abort "could not accept a connection on the adapter socket"
	= (clientFd, clientFd, w)

// --- line-buffered input ---------------------------------------------

bytesToStringLocal :: !Pointer !Int !*World -> (!String, !*World)
bytesToStringLocal p n w
	# (chars, w) = walk 0 w
	= ({c \\ c <- chars}, w)
where
	walk i w
		| i == n = ([], w)
		# (b, w) = readByteW p i w
		# (rest, w) = walk (i + 1) w
		= ([toChar b : rest], w)

stripCR :: !String -> String
stripCR s
	| size s > 0 && s.[size s - 1] == '\r' = s % (0, size s - 2)
	= s

// Reads one line (splitting on `pending`'s already-buffered bytes first),
// or `Nothing` on end of input.
readLineFd :: !Int !String !*World -> (!Maybe (!String, !String), !*World)
readLineFd fd pending w = case findChar '\n' pending 0 of
	Just i = (Just (stripCR (pending % (0, i - 1)), pending % (i + 1, size pending - 1)), w)
	Nothing
		# (buf, w) = mallocW 4096 w
		# (n, w) = readCcall fd buf 4096 w
		= afterRead fd pending buf n w

afterRead :: !Int !String !Pointer !Int !*World -> (!Maybe (!String, !String), !*World)
afterRead fd pending buf n w
	| n <= 0
		# w = freeW buf w
		= (Nothing, w)
	# (chunk, w) = bytesToStringLocal buf n w
	# w = freeW buf w
	= readLineFd fd (pending +++ chunk) w

writeAllFd :: !Int !String !*World -> *World
writeAllFd fd data w = loop 0 (size data) w
where
	loop sent total w
		| sent >= total = w
		# (n, w) = writeCcall fd (data % (sent, total - 1)) (total - sent) w
		| n <= 0 = abort "adapter output write failed"
		= loop (sent + n) total w

writeLineFd :: !Int !String !*World -> *World
writeLineFd fd text w = writeAllFd fd (text +++ "\n") w

// --- small JSON/value helpers -------------------------------------------

fromMaybeJ :: !(Maybe JSON) !JSON -> JSON
fromMaybeJ (Just v) _ = v
fromMaybeJ Nothing d = d

fromMaybeInt :: !Int !(Maybe Int) -> Int
fromMaybeInt d Nothing = d
fromMaybeInt d (Just x) = x

stringField :: !JSON !String !String -> String
stringField v key def = case jsonLookup key v of
	Nothing = def
	Just j = case jsonAsString j of
		Nothing = def
		Just s = s

// --- event encoding --------------------------------------------------

emitJson :: !Int !JSON !*World -> *World
emitJson writeFd v w = writeLineFd writeFd (encodeJSON v) w

emitReady :: !Int !String !*World -> *World
emitReady writeFd id w = emitJson writeFd (JObject
	[ ("protocolVersion", JInt 1), ("id", JString id), ("type", JString "ready")
	, ("language", JString adapterLanguage), ("implementation", JString adapterImplementation)
	, ("runtime", JString adapterRuntime)
	]) w

emitSimple :: !Int !String !String !*World -> *World
emitSimple writeFd id kind w = emitJson writeFd (JObject [("id", JString id), ("type", JString kind)]) w

emitResult :: !Int !String !JSON !JSON !*World -> *World
emitResult writeFd id value logs w = emitJson writeFd (JObject [("id", JString id), ("type", JString "result"), ("value", value), ("logs", logs)]) w

emitFunctionError :: !Int !String !String !(Maybe JSON) !JSON !*World -> *World
emitFunctionError writeFd id msg dataOpt logs w = emitJson writeFd (JObject [("id", JString id), ("type", JString "error"), ("error", errorJson), ("logs", logs)]) w
where
	errorJson = JObject ([("name", JString "FunctionError"), ("message", JString msg)] ++ dataField)
	dataField = case dataOpt of
		Just d = [("data", d)]
		Nothing = []

// `subId` is "" for a plain (non-subscription) error; a non-empty
// `subId` emits a subscription-shaped error instead, matching the schema's
// "event" definition (a subscription error carries subscriptionId, not id).
emitError :: !Int !String !String !String !String !*World -> *World
emitError writeFd id subId name message w
	| size subId > 0 = emitJson writeFd (JObject [("type", JString "subscription"), ("subscriptionId", JString subId), ("error", errorJson)]) w
	| size id > 0 = emitJson writeFd (JObject [("type", JString "error"), ("id", JString id), ("error", errorJson)]) w
	= emitJson writeFd (JObject [("type", JString "error"), ("error", errorJson)]) w
where
	errorJson = JObject [("name", JString name), ("message", JString message)]

emitSyncEvent :: !Int !SyncEvent !*World -> *World
emitSyncEvent writeFd event w = case event.seKind of
	SeUpdated = emitJson writeFd (JObject (updatedFields ++ logsField)) w
	SeFailed = emitJson writeFd (JObject ([("type", JString "subscription"), ("subscriptionId", JString event.seSubscriptionId), ("error", errorJson)] ++ logsField)) w
where
	updatedFields = [("type", JString "subscription"), ("subscriptionId", JString event.seSubscriptionId), ("value", fromMaybeJ event.seValue JNull)]
	errorJson = JObject ([("name", JString event.seErrorName), ("message", JString event.seErrorMessage)] ++ dataField)
	dataField = case event.seErrorData of
		Just d = [("data", d)]
		Nothing = []
	logsField = case event.seLogs of
		Just l = [("logs", l)]
		Nothing = []

// --- command dispatch --------------------------------------------------

ensureClient :: !(Maybe Client) !*World -> (!Result Client, !Maybe Client, !*World)
ensureClient (Just c) w = (ROk c, Just c, w)
ensureClient Nothing w
	# (urlOpt, w) = getEnvironmentVariable "CONVEX_URL" w
	= case urlOpt of
		?None = (RErr "CONVEX_URL is required", Nothing, w)
		?Just url = initClient url w

initClient :: !String !*World -> (!Result Client, !Maybe Client, !*World)
initClient url w
	# (initResult, w) = clientInit url w
	= case initResult of
		RErr e = (RErr e, Nothing, w)
		ROk c0
			# (authOpt, w) = getEnvironmentVariable "CONVEX_AUTH_TOKEN" w
			# c1 = case authOpt of
				?Just token = clientSetAuth token c0
				?None = c0
			= (ROk c1, Just c1, w)

handleHello :: !JSON !String !Int !(Maybe Client) !*World -> (!Maybe Client, !Bool, !*World)
handleHello parsed id writeFd client w
	# version = protocolVersionOf parsed
	| version <> 1
		# w = emitError writeFd id "" "ProtocolError" "unsupported adapter protocol version" w
		= (client, False, w)
	# w = emitReady writeFd id w
	= (client, False, w)

protocolVersionOf :: !JSON -> Int
protocolVersionOf parsed = case jsonLookup "protocolVersion" parsed of
	Nothing = -1
	Just v = fromMaybeInt (-1) (jsonAsWholeInt v)

handleCall :: !String !String !JSON !Int !(Maybe Client) !*World -> (!Maybe Client, !Bool, !*World)
handleCall op id parsed writeFd client w
	# (ensured, client1, w) = ensureClient client w
	= case ensured of
		RErr e
			# w = emitError writeFd id "" "TransportError" e w
			= (client1, False, w)
		ROk c
			# path = stringField parsed "path" ""
			# args = fromMaybeJ (jsonLookup "args" parsed) (JObject [])
			# (callResult, w) = clientCall op path args c w
			= afterCall id callResult client1 writeFd w

afterCall :: !String !(Result CallResult) !(Maybe Client) !Int !*World -> (!Maybe Client, !Bool, !*World)
afterCall id callResult client writeFd w = case callResult of
	RErr e
		# w = emitError writeFd id "" "TransportError" e w
		= (client, False, w)
	ROk cr = case cr.crFailure of
		Just (msg, dataOpt)
			# w = emitFunctionError writeFd id msg dataOpt cr.crLogs w
			= (client, False, w)
		Nothing
			# w = emitResult writeFd id cr.crValue cr.crLogs w
			= (client, False, w)

handleSetAuth :: !String !JSON !Int !(Maybe Client) !*World -> (!Maybe Client, !Bool, !*World)
handleSetAuth id parsed writeFd client w
	# (ensured, client1, w) = ensureClient client w
	= case ensured of
		RErr e
			# w = emitError writeFd id "" "ProtocolError" e w
			= (client1, False, w)
		ROk c
			# c1 = clientSetAuth (stringField parsed "token" "") c
			# w = emitSimple writeFd id "ack" w
			= (Just c1, False, w)

handleSubscribe :: !String !JSON !Int !(Maybe Client) !*World -> (!Maybe Client, !Bool, !*World)
handleSubscribe id parsed writeFd client w
	# (ensured, client1, w) = ensureClient client w
	= case ensured of
		RErr e
			# w = emitError writeFd id "" "TransportError" e w
			= (client1, False, w)
		ROk c
			# subId = stringField parsed "subscriptionId" ""
			# path = stringField parsed "path" ""
			# args = fromMaybeJ (jsonLookup "args" parsed) (JObject [])
			# (subResult, w) = clientSubscribe subId path args c w
			= afterSubscribe id subResult c writeFd w

afterSubscribe :: !String !(Result Client) !Client !Int !*World -> (!Maybe Client, !Bool, !*World)
afterSubscribe id subResult fallback writeFd w = case subResult of
	RErr e
		# w = emitError writeFd id "" "TransportError" e w
		= (Just fallback, False, w)
	ROk c1
		# w = emitSimple writeFd id "ack" w
		= (Just c1, False, w)

handleUnsubscribe :: !String !JSON !Int !(Maybe Client) !*World -> (!Maybe Client, !Bool, !*World)
handleUnsubscribe id parsed writeFd client w
	# (ensured, client1, w) = ensureClient client w
	= case ensured of
		RErr e
			# w = emitError writeFd id "" "ProtocolError" e w
			= (client1, False, w)
		ROk c
			# subId = stringField parsed "subscriptionId" ""
			# (unsubResult, w) = clientUnsubscribe subId c w
			= afterUnsubscribe id unsubResult c writeFd w

afterUnsubscribe :: !String !(Result Client) !Client !Int !*World -> (!Maybe Client, !Bool, !*World)
afterUnsubscribe id unsubResult fallback writeFd w = case unsubResult of
	RErr e
		# w = emitError writeFd id "" "ProtocolError" e w
		= (Just fallback, False, w)
	ROk c1
		# w = emitSimple writeFd id "ack" w
		= (Just c1, False, w)

handleDebugDisconnect :: !String !Int !(Maybe Client) !*World -> (!Maybe Client, !Bool, !*World)
handleDebugDisconnect id writeFd client w
	# (ensured, client1, w) = ensureClient client w
	= case ensured of
		RErr e
			# w = emitError writeFd id "" "ProtocolError" e w
			= (client1, False, w)
		ROk c
			# (ddResult, w) = clientDebugDisconnect c w
			= afterDebugDisconnect id ddResult c writeFd w

afterDebugDisconnect :: !String !(Result Client) !Client !Int !*World -> (!Maybe Client, !Bool, !*World)
afterDebugDisconnect id ddResult fallback writeFd w = case ddResult of
	RErr e
		# w = emitError writeFd id "" "ProtocolError" e w
		= (Just fallback, False, w)
	ROk c1
		# w = emitSimple writeFd id "ack" w
		= (Just c1, False, w)

handleClose :: !String !Int !(Maybe Client) !*World -> (!Maybe Client, !Bool, !*World)
handleClose id writeFd client w
	# w = case client of
		Just c = clientClose c w
		Nothing = w
	# w = emitSimple writeFd id "closed" w
	= (Nothing, True, w)

dispatchOp :: !JSON !Int !(Maybe Client) !*World -> (!Maybe Client, !Bool, !*World)
dispatchOp parsed writeFd client w
	# id = stringField parsed "id" ""
	# op = stringField parsed "op" ""
	= case op of
		"hello" = handleHello parsed id writeFd client w
		"query" = handleCall op id parsed writeFd client w
		"mutation" = handleCall op id parsed writeFd client w
		"action" = handleCall op id parsed writeFd client w
		"setAuth" = handleSetAuth id parsed writeFd client w
		"subscribe" = handleSubscribe id parsed writeFd client w
		"unsubscribe" = handleUnsubscribe id parsed writeFd client w
		"debugDisconnect" = handleDebugDisconnect id writeFd client w
		"close" = handleClose id writeFd client w
		_
			# w = emitError writeFd id "" "ProtocolError" "unknown adapter operation" w
			= (client, False, w)

handleLine :: !String !Int !(Maybe Client) !*World -> (!Maybe Client, !Bool, !*World)
handleLine line writeFd client w = case parseJSON line of
	Nothing
		# w = emitError writeFd "" "" "ProtocolError" "malformed adapter command" w
		= (client, False, w)
	Just parsed = dispatchOp parsed writeFd client w

// --- the main loop -------------------------------------------------------

drainLiveStep :: !(Maybe Client) !*World -> (!Maybe SyncEvent, !Maybe Client, !*World)
drainLiveStep Nothing w = (Nothing, Nothing, w)
drainLiveStep (Just c) w
	# (eventOpt, c1, w) = clientStep 0 c w
	= (eventOpt, Just c1, w)

// `pollReady` returning "not ready" and `readLineFd` returning `Nothing`
// look similar (both are a `Maybe`-shaped "nothing this round") but mean
// opposite things for the loop: the former just means try again later, the
// latter is genuine end of input and must stop the adapter — conflating
// them earlier in this file's development produced a busy-loop at EOF
// (`pollReady` keeps reporting a closed/EOF fd as readable, so a version
// that treated "no line" as "continue" spun at 100% CPU forever instead of
// exiting). Kept as one explicit three-way case rather than routed through
// a shared "Maybe line" helper, specifically so this distinction stays
// visible here.
serveLoop :: !Int !Int !(Maybe Client) !String !*World -> *World
serveLoop readFd writeFd client pending w
	# (ready, w) = pollReady readFd False 100 w
	= case ready of
		RErr e = w
		ROk False = continueLoop readFd writeFd client pending w
		ROk True
			# (lineResult, w) = readLineFd readFd pending w
			= case lineResult of
				Nothing = w
				Just (line, pending2) = afterLine readFd writeFd client line pending2 w

afterLine :: !Int !Int !(Maybe Client) !String !String !*World -> *World
afterLine readFd writeFd client line pending2 w
	# (client1, stop, w) = handleLine line writeFd client w
	| stop = w
	= continueLoop readFd writeFd client1 pending2 w

continueLoop :: !Int !Int !(Maybe Client) !String !*World -> *World
continueLoop readFd writeFd client pending w
	# (eventOpt, client1, w) = drainLiveStep client w
	# w = case eventOpt of
		Nothing = w
		Just event = emitSyncEvent writeFd event w
	= serveLoop readFd writeFd client1 pending w

Start :: *World -> *World
Start w
	# (readFd, writeFd, w) = setupIO w
	# w = serveLoop readFd writeFd Nothing "" w
	# (_, w) = exit 0 w
	= w
