implementation module Convex.Wire

import StdEnv
import StdMaybe

encodeJSON :: !JSON -> String
encodeJSON JNull = "null"
encodeJSON (JBool True) = "true"
encodeJSON (JBool False) = "false"
encodeJSON (JInt i) = toString i
encodeJSON (JReal r) = encodeReal r
encodeJSON (JString s) = encodeStringLit s
encodeJSON (JArray items) = "[" +++ joinWith "," (map encodeJSON items) +++ "]"
encodeJSON (JObject members) = "{" +++ joinWith "," (map encodeMember members) +++ "}"

encodeMember :: !(String, JSON) -> String
encodeMember (k, v) = encodeStringLit k +++ ":" +++ encodeJSON v

joinWith :: !String ![String] -> String
joinWith sep [] = ""
joinWith sep [x] = x
joinWith sep [x:xs] = x +++ sep +++ joinWith sep xs

encodeReal :: !Real -> String
encodeReal r
	# t = toString r
	| containsChar t '.' || containsChar t 'e' || containsChar t 'E' = t
	= t +++ ".0"

encodeStringLit :: !String -> String
encodeStringLit s = "\"" +++ escapeFrom s 0 (size s) +++ "\""

escapeFrom :: !String !Int !Int -> String
escapeFrom s i n
	| i >= n = ""
	= escapeChar s.[i] +++ escapeFrom s (i + 1) n

escapeChar :: !Char -> String
escapeChar c
	| c == '"' = "\\\""
	| c == '\\' = "\\\\"
	| c == '\n' = "\\n"
	| c == '\r' = "\\r"
	| c == '\t' = "\\t"
	| toInt c < 0x20 = "\\u00" +++ hex2 (toInt c)
	= toString c

hex2 :: !Int -> String
hex2 v = toString (hexDigit (v / 16)) +++ toString (hexDigit (v - (v / 16) * 16))

hexDigit :: !Int -> Char
hexDigit d
	| d < 10 = toChar (toInt '0' + d)
	= toChar (toInt 'a' + d - 10)

// --- parsing ---------------------------------------------------------------

parseJSON :: !String -> Maybe JSON
parseJSON s
	# n = size s
	# start = skipWs s 0 n
	= case parseValue s start n of
		Nothing = Nothing
		Just (v, i)
			# end = skipWs s i n
			| end == n = Just v
			= Nothing

skipWs :: !String !Int !Int -> Int
skipWs s i n
	| i < n && isWsChar s.[i] = skipWs s (i + 1) n
	= i

isWsChar :: !Char -> Bool
isWsChar c = c == ' ' || c == '\t' || c == '\n' || c == '\r'

isDigit :: !Char -> Bool
isDigit c = c >= '0' && c <= '9'

parseValue :: !String !Int !Int -> Maybe (JSON, Int)
parseValue s i n
	| i >= n = Nothing
	# c = s.[i]
	| c == '{' = parseObject s (i + 1) n
	| c == '[' = parseArray s (i + 1) n
	| c == '"' = parseStringLit s (i + 1) n
	| c == 't' = parseLiteral s i n "true" (JBool True)
	| c == 'f' = parseLiteral s i n "false" (JBool False)
	| c == 'n' = parseLiteral s i n "null" JNull
	| c == '-' || isDigit c = parseNumber s i n
	= Nothing

parseLiteral :: !String !Int !Int !String !JSON -> Maybe (JSON, Int)
parseLiteral s i n lit val
	# len = size lit
	| i + len > n = Nothing
	| s % (i, i + len - 1) == lit = Just (val, i + len)
	= Nothing

parseObject :: !String !Int !Int -> Maybe (JSON, Int)
parseObject s i n
	# i = skipWs s i n
	| i < n && s.[i] == '}' = Just (JObject [], i + 1)
	= parseObjectMembers s i n []

parseObjectMembers :: !String !Int !Int ![(String, JSON)] -> Maybe (JSON, Int)
parseObjectMembers s i n acc
	# i = skipWs s i n
	| i >= n || s.[i] <> '"' = Nothing
	= case parseStringRaw s (i + 1) n of
		Nothing = Nothing
		Just (key, i1)
			# i1 = skipWs s i1 n
			| i1 >= n || s.[i1] <> ':' = Nothing
			# i2 = skipWs s (i1 + 1) n
			= case parseValue s i2 n of
				Nothing = Nothing
				Just (v, i3)
					# acc = acc ++ [(key, v)]
					# i3 = skipWs s i3 n
					| i3 >= n = Nothing
					| s.[i3] == ',' = parseObjectMembers s (i3 + 1) n acc
					| s.[i3] == '}' = Just (JObject acc, i3 + 1)
					= Nothing

parseArray :: !String !Int !Int -> Maybe (JSON, Int)
parseArray s i n
	# i = skipWs s i n
	| i < n && s.[i] == ']' = Just (JArray [], i + 1)
	= parseArrayItems s i n []

parseArrayItems :: !String !Int !Int ![JSON] -> Maybe (JSON, Int)
parseArrayItems s i n acc
	# i = skipWs s i n
	= case parseValue s i n of
		Nothing = Nothing
		Just (v, i1)
			# acc = acc ++ [v]
			# i1 = skipWs s i1 n
			| i1 >= n = Nothing
			| s.[i1] == ',' = parseArrayItems s (i1 + 1) n acc
			| s.[i1] == ']' = Just (JArray acc, i1 + 1)
			= Nothing

parseStringLit :: !String !Int !Int -> Maybe (JSON, Int)
parseStringLit s i n = case parseStringRaw s i n of
	Nothing = Nothing
	Just (str, i1) = Just (JString str, i1)

parseStringRaw :: !String !Int !Int -> Maybe (String, Int)
parseStringRaw s i n = parseStringChars s i n []

// Accumulates decoded characters in reverse (O(1) prepend) and reverses once
// at the end; `\uXXXX` escapes are re-encoded to UTF-8 bytes here, matching
// this module's byte-oriented `String` convention.
parseStringChars :: !String !Int !Int ![Char] -> Maybe (String, Int)
parseStringChars s i n acc
	| i >= n = Nothing
	# c = s.[i]
	| c == '"' = Just ({c \\ c <- reverse acc}, i + 1)
	| c == '\\'
		| i + 1 >= n = Nothing
		# e = s.[i + 1]
		| e == 'u'
			| i + 5 >= n = Nothing
			= case hex4 s (i + 2) of
				Nothing = Nothing
				Just cp = parseStringChars s (i + 6) n (reverse (utf8Bytes cp) ++ acc)
		= case decodeEscape e of
			Nothing = Nothing
			Just ec = parseStringChars s (i + 2) n [ec : acc]
	= parseStringChars s (i + 1) n [c : acc]

decodeEscape :: !Char -> Maybe Char
decodeEscape c
	| c == '"' = Just '"'
	| c == '\\' = Just '\\'
	| c == '/' = Just '/'
	| c == 'b' = Just (toChar 8)
	| c == 'f' = Just (toChar 12)
	| c == 'n' = Just '\n'
	| c == 'r' = Just '\r'
	| c == 't' = Just '\t'
	= Nothing

hex4 :: !String !Int -> Maybe Int
hex4 s i
	# d0 = hexVal s.[i]
	# d1 = hexVal s.[i + 1]
	# d2 = hexVal s.[i + 2]
	# d3 = hexVal s.[i + 3]
	| d0 < 0 || d1 < 0 || d2 < 0 || d3 < 0 = Nothing
	= Just (((d0 * 16 + d1) * 16 + d2) * 16 + d3)

hexVal :: !Char -> Int
hexVal c
	| c >= '0' && c <= '9' = toInt c - toInt '0'
	| c >= 'a' && c <= 'f' = toInt c - toInt 'a' + 10
	| c >= 'A' && c <= 'F' = toInt c - toInt 'A' + 10
	= -1

// Encodes one Unicode code point (from a `\uXXXX` escape, so at most 16
// bits) as UTF-8 bytes.
utf8Bytes :: !Int -> [Char]
utf8Bytes cp
	| cp < 0x80 = [toChar cp]
	| cp < 0x800 =
		[ toChar (0xC0 bitor (cp / 64))
		, toChar (0x80 bitor (cp - (cp / 64) * 64))
		]
	=	[ toChar (0xE0 bitor (cp / 4096))
		, toChar (0x80 bitor ((cp / 64) - (cp / 4096) * 64))
		, toChar (0x80 bitor (cp - (cp / 64) * 64))
		]

containsChar :: !String !Char -> Bool
containsChar s c = containsCharFrom s c 0 (size s)

containsCharFrom :: !String !Char !Int !Int -> Bool
containsCharFrom s c i n
	| i >= n = False
	| s.[i] == c = True
	= containsCharFrom s c (i + 1) n

parseNumber :: !String !Int !Int -> Maybe (JSON, Int)
parseNumber s i n
	# j = scanNumberEnd s i n
	| j == i = Nothing
	# text = s % (i, j - 1)
	| containsChar text '.' || containsChar text 'e' || containsChar text 'E' = case toRealMaybe text of
		Nothing = Nothing
		Just r = Just (JReal r, j)
	= case toIntMaybe text of
		Nothing = Nothing
		Just v = Just (JInt v, j)

scanDigits :: !String !Int !Int -> Int
scanDigits s i n
	| i < n && isDigit s.[i] = scanDigits s (i + 1) n
	= i

scanExponent :: !String !Int !Int -> Int
scanExponent s i n
	| i < n && (s.[i] == 'e' || s.[i] == 'E')
		# i2 = i + 1
		# i2 = if (i2 < n && (s.[i2] == '+' || s.[i2] == '-')) (i2 + 1) i2
		= scanDigits s i2 n
	= i

scanNumberEnd :: !String !Int !Int -> Int
scanNumberEnd s i n
	# i1 = if (i < n && s.[i] == '-') (i + 1) i
	# i2 = scanDigits s i1 n
	# i3 = if (i2 < n && s.[i2] == '.') (scanDigits s (i2 + 1) n) i2
	# i4 = scanExponent s i3 n
	= i4

toIntMaybe :: !String -> Maybe Int
toIntMaybe s
	# n = size s
	| n == 0 = Nothing
	# neg = s.[0] == '-'
	# start = if neg 1 0
	| start >= n = Nothing
	= case digitsToInt s start n 0 of
		Nothing = Nothing
		Just v = Just (if neg (0 - v) v)

digitsToInt :: !String !Int !Int !Int -> Maybe Int
digitsToInt s i n acc
	| i == n = Just acc
	| not (isDigit s.[i]) = Nothing
	= digitsToInt s (i + 1) n (acc * 10 + (toInt s.[i] - toInt '0'))

pow10 :: !Int -> Real
pow10 e
	| e < 0 = 1.0 / pow10 (0 - e)
	| e == 0 = 1.0
	= 10.0 * pow10 (e - 1)

scanRealPart :: !String !Int !Int !Real -> (Real, Int)
scanRealPart s i n acc
	| i < n && isDigit s.[i] = scanRealPart s (i + 1) n (acc * 10.0 + toReal (toInt s.[i] - toInt '0'))
	= (acc, i)

scanIntPart :: !String !Int !Int !Int -> (Int, Int)
scanIntPart s i n acc
	| i < n && isDigit s.[i] = scanIntPart s (i + 1) n (acc * 10 + (toInt s.[i] - toInt '0'))
	= (acc, i)

toRealMaybe :: !String -> Maybe Real
toRealMaybe s
	# n = size s
	| n == 0 = Nothing
	# neg = s.[0] == '-'
	# i0 = if neg 1 0
	# (ip, i1) = scanRealPart s i0 n 0.0
	# hasFrac = i1 < n && s.[i1] == '.'
	# fracStart = if hasFrac (i1 + 1) i1
	# (fp, i2) = if hasFrac (scanRealPart s fracStart n 0.0) (0.0, i1)
	# fracDigits = i2 - fracStart
	# hasExp = i2 < n && (s.[i2] == 'e' || s.[i2] == 'E')
	# expNeg = hasExp && i2 + 1 < n && s.[i2 + 1] == '-'
	# expPlus = hasExp && i2 + 1 < n && s.[i2 + 1] == '+'
	# expDigitsStart = if hasExp (if (expNeg || expPlus) (i2 + 2) (i2 + 1)) i2
	# (evInt, i3) = if hasExp (scanIntPart s expDigitsStart n 0) (0, expDigitsStart)
	| i3 <> n = Nothing
	# expSigned = if expNeg (0 - evInt) evInt
	# value = (ip + fp / pow10 fracDigits) * pow10 expSigned
	= Just (if neg (0.0 - value) value)

// --- lookups and conversions -------------------------------------------

jsonLookup :: !String !JSON -> Maybe JSON
jsonLookup key (JObject members) = lookupAssoc key members
jsonLookup key _ = Nothing

lookupAssoc :: !String ![(String, JSON)] -> Maybe JSON
lookupAssoc key [] = Nothing
lookupAssoc key [(k, v) : rest]
	| k == key = Just v
	= lookupAssoc key rest

jsonAsString :: !JSON -> Maybe String
jsonAsString (JString s) = Just s
jsonAsString _ = Nothing

jsonAsBool :: !JSON -> Maybe Bool
jsonAsBool (JBool b) = Just b
jsonAsBool _ = Nothing

jsonAsArray :: !JSON -> Maybe [JSON]
jsonAsArray (JArray xs) = Just xs
jsonAsArray _ = Nothing

jsonAsObject :: !JSON -> Maybe [(String, JSON)]
jsonAsObject (JObject m) = Just m
jsonAsObject _ = Nothing

jsonAsWholeInt :: !JSON -> Maybe Int
jsonAsWholeInt (JInt i) = Just i
jsonAsWholeInt (JReal r)
	| r <> r = Nothing
	| r < -9223372036854775808.0 = Nothing
	| r >= 9223372036854775808.0 = Nothing
	# asInt = toInt r
	| toReal asInt <> r = Nothing
	= Just asInt
jsonAsWholeInt _ = Nothing

toCString :: !String -> String
toCString s = s +++ {toChar 0}
