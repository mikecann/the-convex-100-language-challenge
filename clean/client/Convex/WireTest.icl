module WireTest

// Language-local unit coverage for Convex.Wire's hand-written JSON codec.
// Run by the `test` Docker stage; not part of the public client or the
// conformance adapter. Every check is a pure function of a literal input,
// so this needs no network and no running backend.

import StdEnv
import StdMaybe
import Data.List
import Convex.Wire

Start :: *World -> *World
Start w
	| not checkRoundtripObject = abort "encodeJSON/parseJSON: object round-trip failed"
	| not checkRoundtripNested = abort "encodeJSON/parseJSON: nested array/object round-trip failed"
	| not checkEscaping = abort "encodeJSON: control characters, quote, and backslash were not escaped"
	| not checkWholeIntFromInt = abort "jsonAsWholeInt: a JInt was not accepted"
	| not checkWholeIntFromIntegralReal = abort "jsonAsWholeInt: an integral JReal (e.g. 1.0) was not accepted"
	| not checkWholeIntRejectsFractional = abort "jsonAsWholeInt: a fractional JReal was wrongly accepted"
	| not checkWholeIntRejectsOutOfRange = abort "jsonAsWholeInt: an out-of-range JReal was wrongly accepted"
	| not checkLookupMissing = abort "jsonLookup: a missing key or non-object value should yield Nothing"
	| not checkMalformedRejected = abort "parseJSON: malformed input should yield Nothing, not a partial value"
	= w

checkRoundtripObject :: Bool
checkRoundtripObject = case parseJSON (encodeJSON original) of
	Just (JObject [("a", JInt 1), ("b", JBool True)]) = True
	_ = False
where
	original = JObject [("a", JInt 1), ("b", JBool True)]

checkRoundtripNested :: Bool
checkRoundtripNested = case parseJSON (encodeJSON original) of
	Just decoded = decoded === original
	Nothing = False
where
	original = JArray [JObject [("x", JArray [JInt 1, JInt 2, JNull])], JString "hi"]

// `JSON` has no derived `==`; this direct structural comparison keeps the
// round-trip checks above from silently degrading into "parsing succeeded
// at all" once a value gets nested enough to need it.
(===) infix 4 :: !JSON !JSON -> Bool
(===) JNull JNull = True
(===) (JBool a) (JBool b) = a == b
(===) (JInt a) (JInt b) = a == b
(===) (JReal a) (JReal b) = a == b
(===) (JString a) (JString b) = a == b
(===) (JArray a) (JArray b) = length a == length b && and (zipWith (===) a b)
(===) (JObject a) (JObject b) = length a == length b && and (zipWith entryEq a b)
where
	entryEq (ka, va) (kb, vb) = ka == kb && va === vb
(===) _ _ = False

checkEscaping :: Bool
checkEscaping = encodeJSON (JString "a\"b\\c\nd") == "\"a\\\"b\\\\c\\nd\""

checkWholeIntFromInt :: Bool
checkWholeIntFromInt = jsonAsWholeInt (JInt 42) === Just 42
where
	(===) (Just a) (Just b) = a == b
	(===) Nothing Nothing = True
	(===) _ _ = False

checkWholeIntFromIntegralReal :: Bool
checkWholeIntFromIntegralReal = jsonAsWholeInt (JReal 1.0) === Just 1 && jsonAsWholeInt (JReal 0.0) === Just 0
where
	(===) (Just a) (Just b) = a == b
	(===) Nothing Nothing = True
	(===) _ _ = False

checkWholeIntRejectsFractional :: Bool
checkWholeIntRejectsFractional = case jsonAsWholeInt (JReal 1.5) of
	Nothing = True
	Just _ = False

checkWholeIntRejectsOutOfRange :: Bool
checkWholeIntRejectsOutOfRange = case jsonAsWholeInt (JReal 1.0E30) of
	Nothing = True
	Just _ = False

checkLookupMissing :: Bool
checkLookupMissing
	= isNothing (jsonLookup "missing" (JObject [("a", JInt 1)]))
	&& isNothing (jsonLookup "a" (JArray [JInt 1]))
where
	isNothing Nothing = True
	isNothing (Just _) = False

checkMalformedRejected :: Bool
checkMalformedRejected
	= isNothing (parseJSON "{\"a\":}")
	&& isNothing (parseJSON "{\"a\": 1")
	&& isNothing (parseJSON "not json")
where
	isNothing Nothing = True
	isNothing (Just _) = False
