module ConvexCallTest

// A real end-to-end regression against a live Convex backend, proving the
// whole HTTP stack (URL parsing, plain-socket transport, request framing,
// response parsing, and the Convex success/error envelope) against a real
// server rather than a mock — matching
// `hare/client/convex.ha`'s `http_query_and_mutation_against_the_local_backend`.
//
// Per this project's test-layer split, the offline `test` Docker stage
// never sets CONVEX_URL, so `Start` below is a no-op there; this only runs
// for real when CONVEX_URL is explicitly set, which is how `./run verify`
// and `./run verify-hosted` invoke every other client's equivalent
// regression.

import StdEnv
import StdMaybe
import System.Environment
import Convex.Deadline
import Convex.Result
import Convex.Wire
import Convex.HTTP

fromMaybe :: !a !(Maybe a) -> a
fromMaybe d Nothing = d
fromMaybe d (Just x) = x

Start :: *World -> *World
Start w
	# (urlOpt, w) = getEnvironmentVariable "CONVEX_URL" w
	= case urlOpt of
		?None = w
		?Just url = runAgainstBackend url w

runAgainstBackend :: !String !*World -> *World
runAgainstBackend url w = case parseEndpoint url of
	Nothing = abort "ConvexCallTest: CONVEX_URL did not parse as a valid endpoint"
	Just ep = queryInitialState ep w

// A fresh room name per run keeps this regression idempotent across repeat
// runs against the same persistent backend: demo:increment is itself
// idempotent per (room, runId), so a fixed room would only apply the
// mutation once and the after-count assertion would fail on every run
// after the first.
queryInitialState :: !Endpoint !*World -> *World
queryInitialState ep w
	# (now, w) = nowMs w
	# room = "clean-http-test-" +++ toString now
	# (d, w) = deadlineIn 10000 w
	# (queryResult, w) = httpCall ep Nothing "query" "demo:state" (JObject [("room", JString room)]) d w
	= afterQuery ep room queryResult w

afterQuery :: !Endpoint !String !(Result CallResult) !*World -> *World
afterQuery ep room (RErr e) w = abort ("ConvexCallTest: initial demo:state query failed: " +++ e)
afterQuery ep room (ROk cr) w = case cr.crFailure of
	Just (msg, _) = abort ("ConvexCallTest: demo:state returned a function error: " +++ msg)
	Nothing = afterQueryOk ep room cr.crValue w

afterQueryOk :: !Endpoint !String !JSON !*World -> *World
afterQueryOk ep room value w = case jsonAsWholeInt (fromMaybe JNull (jsonLookup "count" value)) of
	Nothing = abort "ConvexCallTest: demo:state's count was not a whole integer"
	Just before = applyIncrement ep room before w

applyIncrement :: !Endpoint !String !Int !*World -> *World
applyIncrement ep room before w
	# (d, w) = deadlineIn 10000 w
	# args = JObject [("room", JString room), ("language", JString "Clean"), ("runId", JString room)]
	# (mutResult, w) = httpCall ep Nothing "mutation" "demo:increment" args d w
	= afterMutation before mutResult w

afterMutation :: !Int !(Result CallResult) !*World -> *World
afterMutation before (RErr e) w = abort ("ConvexCallTest: demo:increment mutation failed: " +++ e)
afterMutation before (ROk cr) w = case cr.crFailure of
	Just (msg, _) = abort ("ConvexCallTest: demo:increment returned a function error: " +++ msg)
	Nothing = afterMutationOk before cr.crValue w

afterMutationOk :: !Int !JSON !*World -> *World
afterMutationOk before value w
	# applied = jsonAsBool (fromMaybe JNull (jsonLookup "applied" value))
	# newState = fromMaybe JNull (jsonLookup "state" value)
	# afterCount = jsonAsWholeInt (fromMaybe JNull (jsonLookup "count" newState))
	| not (eqMaybeBool applied (Just True)) = abort "ConvexCallTest: demo:increment did not report applied = true for a fresh runId"
	| not (eqMaybeInt afterCount (Just (before + 1))) = abort "ConvexCallTest: demo:increment's resulting count was not exactly one more than the initial query"
	= w

eqMaybeBool :: !(Maybe Bool) !(Maybe Bool) -> Bool
eqMaybeBool (Just a) (Just b) = a == b
eqMaybeBool Nothing Nothing = True
eqMaybeBool _ _ = False

eqMaybeInt :: !(Maybe Int) !(Maybe Int) -> Bool
eqMaybeInt (Just a) (Just b) = a == b
eqMaybeInt Nothing Nothing = True
eqMaybeInt _ _ = False
