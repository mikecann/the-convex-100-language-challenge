implementation module Convex.HTTP

import StdEnv
import StdMaybe
import Convex.Result
import Convex.Transport
import Convex.Deadline
import Convex.Wire

// --- small string helpers ---------------------------------------------

// Searches `hay` for `needle`, starting the search at or after `start`.
findSubstrFrom :: !String !String !Int -> Maybe Int
findSubstrFrom needle hay start
	| start + nlen > hlen = Nothing
	| matchesAt start = Just start
	= findSubstrFrom needle hay (start + 1)
where
	nlen = size needle
	hlen = size hay
	matchesAt at = and [hay.[at + i] == needle.[i] \\ i <- [0 .. nlen - 1]]

findChar :: !Char !String -> Maybe Int
findChar c s = go 0
where
	n = size s
	go i
		| i == n = Nothing
		| s.[i] == c = Just i
		= go (i + 1)

splitOnStr :: !String !String -> [String]
splitOnStr sep s = go 0
where
	slen = size sep
	go start = case findSubstrFrom sep s start of
		Just i = [s % (start, i - 1) : go (i + slen)]
		Nothing = [s % (start, size s - 1)]

splitOnChar :: !Char !String -> [String]
splitOnChar sep s = go 0 0
where
	n = size s
	go start i
		| i == n = [s % (start, n - 1)]
		| s.[i] == sep = [s % (start, i - 1) : go (i + 1) (i + 1)]
		= go start (i + 1)

isSpaceChar :: !Char -> Bool
isSpaceChar c = c == ' ' || c == '\t'

trimStr :: !String -> String
trimStr s
	| start > end = ""
	= s % (start, end)
where
	n = size s
	start = firstNonSpace 0
	end = lastNonSpace (n - 1)
	firstNonSpace i
		| i == n = i
		| isSpaceChar s.[i] = firstNonSpace (i + 1)
		= i
	lastNonSpace i
		| i < 0 = i
		| isSpaceChar s.[i] = lastNonSpace (i - 1)
		= i

toLowerStr :: !String -> String
toLowerStr s = {toLower c \\ c <-: s}

strToInt :: !String -> Maybe Int
strToInt s
	| size s == 0 = Nothing
	= digits 0 0
where
	n = size s
	digits i acc
		| i == n = Just acc
		| s.[i] < '0' || s.[i] > '9' = Nothing
		= digits (i + 1) (acc * 10 + (toInt s.[i] - toInt '0'))

strToIntHex :: !String -> Maybe Int
strToIntHex s
	| size s == 0 = Nothing
	= digits 0 0
where
	n = size s
	digits i acc
		| i == n = Just acc
		| c >= '0' && c <= '9' = digits (i + 1) (acc * 16 + (toInt c - toInt '0'))
		| c >= 'a' && c <= 'f' = digits (i + 1) (acc * 16 + (toInt c - toInt 'a' + 10))
		| c >= 'A' && c <= 'F' = digits (i + 1) (acc * 16 + (toInt c - toInt 'A' + 10))
		= Nothing
	where
		c = s.[i]

// header lookups operate on `digits`'s enclosing scope, so re-derive `c`
// per call above rather than threading it separately.

// --- endpoint parsing ----------------------------------------------------

defaultPort :: !Bool -> Int
defaultPort True = 443
defaultPort False = 80

trimTrailingSlash :: !String -> String
trimTrailingSlash p
	| p == "/" = ""
	| size p > 0 && p.[size p - 1] == '/' = p % (0, size p - 2)
	= p

parseEndpoint :: !String -> Maybe Endpoint
parseEndpoint url = case findSubstrFrom "://" url 0 of
	Nothing = Nothing
	Just i = parseAfterScheme (url % (0, i - 1)) (url % (i + 3, size url - 1))

parseAfterScheme :: !String !String -> Maybe Endpoint
parseAfterScheme scheme rest
	| scheme == "https" = parseHostPort True rest
	| scheme == "http" = parseHostPort False rest
	= Nothing

parseHostPort :: !Bool !String -> Maybe Endpoint
parseHostPort isTls rest = case findChar '/' rest of
	Nothing = hostPortToEndpoint isTls rest ""
	Just si = hostPortToEndpoint isTls (rest % (0, si - 1)) (trimTrailingSlash (rest % (si, size rest - 1)))

hostPortToEndpoint :: !Bool !String !String -> Maybe Endpoint
hostPortToEndpoint isTls hostPort basePath = case findChar ':' hostPort of
	Nothing
		| size hostPort == 0 = Nothing
		= Just {epTls = isTls, epHost = hostPort, epPort = defaultPort isTls, epBasePath = basePath}
	Just ci
		# host = hostPort % (0, ci - 1)
		# portStr = hostPort % (ci + 1, size hostPort - 1)
		| size host == 0 = Nothing
		= Just {epTls = isTls, epHost = host, epPort = fromMaybe (defaultPort isTls) (strToInt portStr), epBasePath = basePath}

fromMaybe :: !a !(Maybe a) -> a
fromMaybe d Nothing = d
fromMaybe d (Just x) = x

// --- request framing -------------------------------------------------------

maxHeaderBytes :: Int
maxHeaderBytes = 64 * 1024

maxBodyBytes :: Int
maxBodyBytes = 4 * 1024 * 1024

buildRequest :: !String !Endpoint !(Maybe String) !String -> String
buildRequest path ep authHeaderLine bodyStr =
	"POST " +++ ep.epBasePath +++ path +++ " HTTP/1.1\r\n" +++
	"Host: " +++ ep.epHost +++ "\r\n" +++
	"Connection: close\r\n" +++
	"Accept: application/json\r\n" +++
	"Content-Type: application/json\r\n" +++
	"Convex-Client: clean-0.1.0\r\n" +++
	authPart +++
	"Content-Length: " +++ toString (size bodyStr) +++ "\r\n" +++
	"\r\n" +++ bodyStr
where
	authPart = case authHeaderLine of
		Just line = line
		Nothing = ""

// --- response reading --------------------------------------------------

// Reads until the blank-line header terminator is seen, returning the
// header text (status line plus each header line, each still separated by
// a bare "\r\n" with none trailing the last one — convenient for splitting
// directly on "\r\n") and whatever body bytes were already read past it.
readHeaders :: !Transport !String !Deadline !*World -> (!Result (!String, !String), !*World)
readHeaders t acc d w = case findSubstrFrom "\r\n\r\n" acc 0 of
	Just i = (ROk (acc % (0, i - 1), acc % (i + 4, size acc - 1)), w)
	Nothing
		| size acc > maxHeaderBytes = (RErr "response headers too large", w)
		# (r, w) = transportRead t 4096 d w
		= case r of
			RErr e = (RErr e, w)
			ROk "" = (RErr "connection closed before headers completed", w)
			ROk chunk = readHeaders t (acc +++ chunk) d w

readLine :: !Transport !String !Deadline !*World -> (!Result (!String, !String), !*World)
readLine t pending d w = case findSubstrFrom "\r\n" pending 0 of
	Just i = (ROk (pending % (0, i - 1), pending % (i + 2, size pending - 1)), w)
	Nothing
		# (r, w) = transportRead t 4096 d w
		= case r of
			RErr e = (RErr e, w)
			ROk "" = (RErr "connection closed while reading a line", w)
			ROk chunk = readLine t (pending +++ chunk) d w

readExact :: !Transport !String !Int !Deadline !*World -> (!Result (!String, !String), !*World)
readExact t pending n d w
	| size pending >= n = (ROk (pending % (0, n - 1), pending % (n, size pending - 1)), w)
	# (r, w) = transportRead t 4096 d w
	= case r of
		RErr e = (RErr e, w)
		ROk "" = (RErr "connection closed before body completed", w)
		ROk chunk = readExact t (pending +++ chunk) n d w

readChunkedBody :: !Transport !String !Deadline !*World -> (!Result String, !*World)
readChunkedBody t pending d w = loop pending "" w
where
	loop pending out w
		# (lineResult, w) = readLine t pending d w
		= case lineResult of
			RErr e = (RErr e, w)
			ROk (line, pending2) = afterLine line pending2 out w

	afterLine line pending2 out w
		# sizeText = case findChar ';' line of
			Just i = line % (0, i - 1)
			Nothing = line
		= case strToIntHex sizeText of
			Nothing = (RErr "invalid chunk size", w)
			Just 0
				# (trailResult, w) = readLine t pending2 d w
				= case trailResult of
					RErr e = (RErr e, w)
					ROk _ = (ROk out, w)
			Just chunkSize
				| size out + chunkSize > maxBodyBytes = (RErr "chunked response body too large", w)
				# (chunkResult, w) = readExact t pending2 chunkSize d w
				= case chunkResult of
					RErr e = (RErr e, w)
					ROk (chunk, pending3) = afterChunk chunk pending3 out w

	afterChunk chunk pending3 out w
		# (crlfResult, w) = readLine t pending3 d w
		= case crlfResult of
			RErr e = (RErr e, w)
			ROk (_, pending4) = loop pending4 (out +++ chunk) w

readResponse :: !Transport !Deadline !*World -> (!Result (!Int, !String), !*World)
readResponse t d w
	# (headersResult, w) = readHeaders t "" d w
	= case headersResult of
		RErr e = (RErr e, w)
		ROk (headerText, leftover) = afterHeaders headerText leftover w
where
	afterHeaders headerText leftover w = case parseStatusLine headerText of
		Nothing = (RErr "malformed status line", w)
		Just status
			| isChunked headerText
				# (bodyResult, w) = readChunkedBody t leftover d w
				= (statusAndBody status bodyResult, w)
			# want = fromMaybe 0 (strToInt (fromMaybe "0" (headerValue headerText "content-length")))
			| want > maxBodyBytes = (RErr "response body too large", w)
			# (bodyResult, w) = readExact t leftover want d w
			= (statusAndExactBody status bodyResult, w)

	statusAndBody status (ROk body) = ROk (status, body)
	statusAndBody status (RErr e) = RErr e

	statusAndExactBody status (ROk (body, _)) = ROk (status, body)
	statusAndExactBody status (RErr e) = RErr e

isChunked :: !String -> Bool
isChunked headerText = case headerValue headerText "transfer-encoding" of
	Nothing = False
	Just v = case findSubstrFrom "chunked" (toLowerStr v) 0 of
		Just _ = True
		Nothing = False

parseStatusLine :: !String -> Maybe Int
parseStatusLine headerText = case splitOnStr "\r\n" headerText of
	[] = Nothing
	[statusLine : _] = case splitOnChar ' ' statusLine of
		[_, codeStr : _] = strToInt codeStr
		_ = Nothing

headerValue :: !String !String -> Maybe String
headerValue headerText name = case splitOnStr "\r\n" headerText of
	[] = Nothing
	[_ : lines] = search lines
where
	nameLower = toLowerStr name
	search [] = Nothing
	search [line : rest] = case findChar ':' line of
		Nothing = search rest
		Just c
			| toLowerStr (trimStr (line % (0, c - 1))) == nameLower = Just (trimStr (line % (c + 1, size line - 1)))
			= search rest

// --- the public call ---------------------------------------------------

encodeAuthHeader :: !(Maybe String) -> Maybe String
encodeAuthHeader Nothing = Nothing
encodeAuthHeader (Just token) = Just ("Authorization: Bearer " +++ token +++ "\r\n")

httpCall :: !Endpoint !(Maybe String) !String !String !JSON !Deadline !*World -> (!Result CallResult, !*World)
httpCall ep authToken operation path args d w
	# (connResult, w) = connectTransport ep.epTls ep.epHost ep.epPort d w
	= case connResult of
		RErr e = (RErr e, w)
		ROk t = afterConnect t w
where
	body = encodeJSON (JObject [("path", JString path), ("args", args), ("format", JString "json")])
	request = buildRequest ("/api/" +++ operation) ep (encodeAuthHeader authToken) body

	afterConnect t w
		# (sent, w) = transportWriteAll t request d w
		= case sent of
			RErr e
				# w = transportClose t w
				= (RErr e, w)
			ROk _ = afterSend t w

	afterSend t w
		# (respResult, w) = readResponse t d w
		# w = transportClose t w
		= case respResult of
			RErr e = (RErr e, w)
			ROk (status, respBody) = decodeResponse status respBody w

	decodeResponse status respBody w
		| status <> 200 = (RErr ("unexpected HTTP status " +++ toString status +++ " from the deployment"), w)
		= case parseJSON respBody of
			Nothing = (RErr "response body was not valid JSON", w)
			Just parsed = (decodeCallResult parsed, w)

decodeCallResult :: !JSON -> Result CallResult
decodeCallResult parsed = case jsonAsString (fromMaybe JNull (jsonLookup "status" parsed)) of
	Nothing = RErr "malformed response: missing or non-string status"
	Just "success" = decodeSuccess parsed
	Just "error" = decodeError parsed
	Just _ = RErr "malformed response: unrecognized status"

decodeSuccess :: !JSON -> Result CallResult
decodeSuccess parsed = case jsonLookup "value" parsed of
	Nothing = RErr "malformed response: missing value"
	Just v = ROk {crValue = v, crLogs = logsOf parsed, crFailure = Nothing}

decodeError :: !JSON -> Result CallResult
decodeError parsed = case jsonAsString (fromMaybe JNull (jsonLookup "errorMessage" parsed)) of
	Nothing = RErr "malformed error response: missing errorMessage"
	Just msg = ROk {crValue = JNull, crLogs = logsOf parsed, crFailure = Just (msg, jsonLookup "errorData" parsed)}

logsOf :: !JSON -> JSON
logsOf parsed = fromMaybe (JArray []) (jsonLookup "logLines" parsed)
