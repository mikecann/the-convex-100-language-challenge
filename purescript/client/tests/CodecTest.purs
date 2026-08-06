-- | Language-local coverage for everything decided without a socket.
-- |
-- | These are the parts a happy-path run against a real deployment would not
-- | exercise: the JSON spellings Convex is allowed to use, the response
-- | envelopes it produces on failure, the HTTP head shapes a proxy can return,
-- | and the WebSocket frames a hostile peer can send.
module Convex.Test.Codec (main) where

import Convex.Prelude
import Convex as Convex
import Convex.Bytes (Bytes)
import Convex.Bytes as Bytes
import Convex.Error as Error
import Convex.Http as Http
import Convex.Json (Json(..))
import Convex.Json as Json
import Convex.Live as Live
import Convex.Test.Check as Check
import Convex.Ws as Ws

main :: Effect Unit
main = do
  jsonRoundTrips
  jsonRejections
  integerSpellings
  responseEnvelopes
  errorSerialisation
  urlParsing
  headParsing
  requestRendering
  frameDecoding
  frameEncoding
  timestampDecoding
  Check.done "convex_test_codec"

-- ---------------------------------------------------------------------------
-- JSON
-- ---------------------------------------------------------------------------

jsonRoundTrips :: Effect Unit
jsonRoundTrips = do
  roundTrip "null" "null"
  roundTrip "true" "true"
  roundTrip "false" "false"
  roundTrip "an integer" "42"
  roundTrip "a negative integer" "-7"
  roundTrip "a float" "42.5"
  -- Convex may spell a whole number with a fraction, and re-encoding must not
  -- quietly turn it into an integer: that would change the wire value.
  roundTrip "an integral float" "1.0"
  roundTrip "an empty object" "{}"
  roundTrip "an empty array" "[]"
  roundTrip "a nested document"
    "{\"a\":[1,2,{\"b\":null}],\"c\":{\"d\":true}}"
  roundTrip "raw UTF-8 text" "\"Hello, 世界\""

  Check.equalString "object key order survives a round trip"
    (encodeAgain "{\"z\":1,\"a\":2,\"m\":3}")
    "{\"z\":1,\"a\":2,\"m\":3}"

  -- A `\u` pair is the only way an astral character can arrive escaped, so the
  -- decoder has to recombine it before it can produce a codepoint.
  Check.equalString "a surrogate pair decodes to one emoji"
    (decodeString "\"\\ud83d\\ude00\"")
    "😀"
  Check.equalString "short escapes decode"
    (decodeString "\"a\\nb\\tc\\\\d\\\"e\\u0041\"")
    "a\nb\tc\\d\"eA"
  Check.equalString "control characters are escaped on the way out"
    (Json.toString (JsonString ("a" <> controlByte <> "b")))
    "\"a\\u0001b\""

  Check.ok "an absent field is distinguishable from a null one"
    ( not (Json.hasField (object "{\"a\":1}") "b")
        && Json.hasField (object "{\"b\":null}") "b"
    )
  Check.ok "logLines defaults to empty"
    (listNull (fromMaybe (listSingleton "x") (Json.logLines (object "{}"))))
  Check.ok "logLines rejects a non-string entry"
    (isNothing (Json.logLines (object "{\"logLines\":[1]}")))
  Check.ok "onlyFields accepts an exact shape"
    (Json.onlyFields (object "{\"id\":\"a\",\"op\":\"close\"}") (listPair "id" "op"))
  Check.ok "onlyFields rejects an extra member"
    ( not
        ( Json.onlyFields (object "{\"id\":\"a\",\"op\":\"close\",\"x\":1}")
            (listPair "id" "op")
        )
    )
  Check.equalInt "u32Field accepts the ceiling"
    (fromMaybe noValue (Json.u32Field (object "{\"v\":4294967295}") "v"))
    maxUnsigned32
  Check.ok "u32Field rejects a negative value"
    (isNothing (Json.u32Field (object "{\"v\":-1}") "v"))

jsonRejections :: Effect Unit
jsonRejections = do
  rejects "trailing content" "{} {}"
  rejects "a duplicate key" "{\"a\":1,\"a\":2}"
  rejects "an unterminated string" "\"abc"
  rejects "a raw control character in a string"
    ("\"a" <> controlByte <> "b\"")
  rejects "an unknown escape" "\"\\q\""
  rejects "a truncated escape" "\"\\u00\""
  rejects "an unpaired high surrogate" "\"\\ud83d\""
  rejects "an unpaired low surrogate" "\"\\ude00\""
  rejects "a leading zero" "01"
  rejects "a bare fraction point" "1."
  rejects "a missing integer part" ".5"
  rejects "an empty exponent" "1e"
  rejects "an explicit plus sign" "+1"
  rejects "a single quote string" "'a'"
  rejects "a trailing comma in an array" "[1,]"
  rejects "a trailing comma in an object" "{\"a\":1,}"
  rejects "an unquoted key" "{a:1}"
  rejects "a missing colon" "{\"a\" 1}"
  rejects "empty input" ""
  -- 65 opening braces is one past the nesting bound.
  rejects "over-deep nesting" (stringRepeat "[" 65 <> stringRepeat "]" 65)

integerSpellings :: Effect Unit
integerSpellings = do
  Check.equalInt "an integer decodes" (integral (JsonInt 0)) 0
  Check.equalInt "an integral float decodes" (integral (JsonNumber 1.0)) 1
  Check.equalInt "a larger integral float decodes" (integral (JsonNumber 42.0))
    42
  Check.equalInt "a negative integral float decodes"
    (integral (JsonNumber (negateNumber 3.0)))
    (negateInt 3)
  Check.ok "a fractional value is rejected"
    (isNothing (Json.integralInt (JsonNumber 1.5)))
  Check.ok "a quoted number is rejected"
    (isNothing (Json.integralInt (JsonString "1")))
  Check.ok "a boolean is rejected"
    (isNothing (Json.integralInt (JsonBool true)))
  Check.ok "a value beyond the signed 64-bit range is rejected"
    (isNothing (Json.integralInt (JsonNumber 1.0e30)))

-- ---------------------------------------------------------------------------
-- Convex envelopes
-- ---------------------------------------------------------------------------

responseEnvelopes :: Effect Unit
responseEnvelopes = do
  let
    success =
      "{\"status\":\"success\",\"value\":{\"count\":1},\"logLines\":[\"hi\"]}"
  case Convex.decodeResponse 200 (bytes success) of
    Right result -> do
      Check.equalJson "a success envelope decodes its value" result.value
        (object "{\"count\":1}")
      Check.equalInt "a success envelope keeps its log lines"
        (listLength result.logs)
        1
    Left _ -> Check.ok "a success envelope decodes" false

  let
    structured =
      "{\"status\":\"error\",\"errorMessage\":\"boom\",\"errorData\":{\"code\":\"X\"}}"
  case Convex.decodeResponse 200 (bytes structured) of
    Left problem -> do
      Check.equalString "a function error is named" problem.name "FunctionError"
      Check.equalString "a function error keeps its message" problem.message
        "boom"
      Check.ok "a function error keeps its data" (isJust problem.errorData)
    Right _ -> Check.ok "an error envelope is an error" false

  let
    bare = "{\"status\":\"error\",\"errorMessage\":\"boom\"}"
  case Convex.decodeResponse 200 (bytes bare) of
    Left problem ->
      -- Convex distinguishes an absent `errorData` from an explicit null, and
      -- the adapter must not serialise the absent case as null.
      Check.ok "an absent errorData stays absent" (isNothing problem.errorData)
    Right _ -> Check.ok "an error envelope without data is an error" false

  case Convex.decodeResponse 500 (bytes "{\"status\":\"success\",\"value\":1}") of
    Left problem -> Check.equalString
      "a success envelope under a 500 is drift"
      problem.name
      "ProtocolError"
    Right _ -> Check.ok "a success envelope under a 500 is rejected" false

  case Convex.decodeResponse 200 (bytes "not json") of
    Left problem -> Check.equalString "an unparsable body is drift" problem.name
      "ProtocolError"
    Right _ -> Check.ok "an unparsable body is rejected" false

  case Convex.decodeResponse 200 (bytes "{\"status\":\"weird\"}") of
    Left problem -> Check.equalString "an unknown status is drift" problem.name
      "ProtocolError"
    Right _ -> Check.ok "an unknown status is rejected" false

errorSerialisation :: Effect Unit
errorSerialisation = do
  Check.equalString "a transport error omits data and logs"
    (Json.toString (Error.toJson (Error.transportError "gone")))
    "{\"name\":\"TransportError\",\"message\":\"gone\"}"
  Check.equalString "an explicit null errorData is preserved"
    ( Json.toString
        (Error.toJson (Error.functionError "boom" (Just JsonNull) Nil))
    )
    "{\"name\":\"FunctionError\",\"message\":\"boom\",\"data\":null}"
  Check.equalString "log lines are attached when present"
    ( Json.toString
        ( Error.toJson
            (Error.functionError "boom" Nothing (listSingleton "line"))
        )
    )
    "{\"name\":\"FunctionError\",\"message\":\"boom\",\"logs\":[\"line\"]}"

-- ---------------------------------------------------------------------------
-- HTTP
-- ---------------------------------------------------------------------------

urlParsing :: Effect Unit
urlParsing = do
  case Http.parseUrl "https://example.convex.cloud" of
    Right url -> do
      Check.ok "https selects TLS" url.secure
      Check.equalInt "https defaults to 443" url.port 443
      Check.equalString "the host is extracted" url.host "example.convex.cloud"
      Check.equalString "the base path is empty" url.basePath ""
    Left _ -> Check.ok "a hosted URL parses" false

  case Http.parseUrl "http://127.0.0.1:3210/" of
    Right url -> do
      Check.ok "http is plain TCP" (not url.secure)
      Check.equalInt "an explicit port is used" url.port 3210
      Check.equalString "a trailing slash is not a path segment" url.basePath ""
      Check.equalString "the authority carries the port" url.authority
        "127.0.0.1:3210"
    Left _ -> Check.ok "a local URL parses" false

  case Http.parseUrl "http://proxy.internal/convex" of
    Right url -> Check.equalString "a base path is kept" url.basePath "/convex"
    Left _ -> Check.ok "a URL with a base path parses" false

  rejectsUrl "an unsupported scheme" "ftp://example.com"
  rejectsUrl "credentials" "https://user@example.com"
  rejectsUrl "a query string" "https://example.com?a=1"
  rejectsUrl "a fragment" "https://example.com#a"
  rejectsUrl "a zero port" "https://example.com:0"
  rejectsUrl "an out-of-range port" "https://example.com:70000"
  rejectsUrl "surrounding whitespace" " https://example.com"
  rejectsUrl "a missing host" "https://"

headParsing :: Effect Unit
headParsing = do
  let
    head =
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Thing:  spaced  "
  case Http.parseHead (bytes head) of
    Right head -> do
      Check.equalInt "the status is decoded" head.status 200
      Check.equalString "header names are lowercased"
        (fromMaybe "" (Http.header head "content-type"))
        "application/json"
      Check.equalString "header values are trimmed"
        (fromMaybe "" (Http.header head "x-thing"))
        "spaced"
    Left _ -> Check.ok "an ordinary head parses" false

  Check.ok "a repeated header is rejected"
    ( not
        ( isRight
            ( Http.parseHead
                (bytes "HTTP/1.1 200 OK\r\na: 1\r\na: 2")
            )
        )
    )
  Check.ok "a malformed status line is rejected"
    (not (isRight (Http.parseHead (bytes "HTTP/1.1 20 OK"))))
  Check.ok "an unknown HTTP version is rejected"
    (not (isRight (Http.parseHead (bytes "HTTP/2 200 OK"))))
  Check.ok "a headerless line is rejected"
    (not (isRight (Http.parseHead (bytes "HTTP/1.1 200 OK\r\nnocolon"))))

requestRendering :: Effect Unit
requestRendering = do
  case Http.parseUrl "http://backend:3210" of
    Right url -> do
      let
        rendered = Http.renderRequest url "POST" "/api/query"
          (listSingleton (Tuple "convex-client" "purescript-0.1.0"))
          17
      Check.ok "the request line carries the target"
        (stringContains rendered "POST /api/query HTTP/1.1\r\n")
      Check.ok "the host header carries the authority"
        (stringContains rendered "host: backend:3210\r\n")
      Check.ok "the content length is declared"
        (stringContains rendered "content-length: 17\r\n")
      Check.ok "the connection is not reused"
        (stringContains rendered "connection: close\r\n")
      Check.ok "supplied headers are appended"
        (stringContains rendered "convex-client: purescript-0.1.0\r\n")
      Check.ok "the head is terminated by a blank line"
        (stringContains rendered "\r\n\r\n")
    Left _ -> Check.ok "a local URL parses" false

-- ---------------------------------------------------------------------------
-- WebSocket framing
-- ---------------------------------------------------------------------------

frameDecoding :: Effect Unit
frameDecoding = do
  case Ws.next (Ws.feed Ws.newDecoder (serverText "hello")) of
    Ws.Decoded (Ws.TextMessage text) _ ->
      Check.equalString "a whole text frame decodes" text "hello"
    _ -> Check.ok "a whole text frame decodes" false

  -- A frame delivered one byte short must leave the decoder waiting rather
  -- than resynchronising at a byte that only looks like a header.
  let whole = serverText "hello"
  case Ws.next (Ws.feed Ws.newDecoder (Bytes.take (Bytes.size whole - 1) whole)) of
    Ws.NeedMore partial -> do
      Check.ok "a partial frame keeps its parser state"
        (Ws.isMidMessage partial)
      case Ws.next (Ws.feed partial (Bytes.drop (Bytes.size whole - 1) whole)) of
        Ws.Decoded (Ws.TextMessage text) _ ->
          Check.equalString "the completed frame decodes" text "hello"
        _ -> Check.ok "the completed frame decodes" false
    _ -> Check.ok "a partial frame needs more bytes" false

  -- A multi-byte character split across two fragments must not be decoded
  -- until both halves have arrived.
  let
    emoji = Bytes.fromString "😀"
    firstHalf = serverFrame false 0x1 (Bytes.take 2 emoji)
    secondHalf = serverFrame true 0x0 (Bytes.drop 2 emoji)
  case Ws.next (Ws.feed Ws.newDecoder firstHalf) of
    Ws.NeedMore started -> case Ws.next (Ws.feed started secondHalf) of
      Ws.Decoded (Ws.TextMessage text) _ ->
        Check.equalString "a split character reassembles" text
          "😀"
      _ -> Check.ok "a split character reassembles" false
    _ -> Check.ok "a first fragment needs more bytes" false

  case Ws.next (Ws.feed Ws.newDecoder (serverFrame true 0x9 Bytes.empty)) of
    Ws.Decoded (Ws.Ping _) _ -> Check.ok "a ping decodes" true
    _ -> Check.ok "a ping decodes" false

  case Ws.next (Ws.feed Ws.newDecoder (serverClose 1000 "bye")) of
    Ws.Decoded (Ws.Close code reason) _ -> do
      Check.equalInt "a close code decodes" code 1000
      Check.equalString "a close reason decodes" reason "bye"
    _ -> Check.ok "a close frame decodes" false

  failsToDecode "a masked server frame" (maskedServerText "hello")
  failsToDecode "a reserved bit"
    (Bytes.append (Bytes.singleByte 0xC1) (Bytes.singleByte 0x00))
  failsToDecode "an unknown opcode" (serverFrame true 0x3 Bytes.empty)
  failsToDecode "a fragmented control frame" (serverFrame false 0x9 Bytes.empty)
  failsToDecode "a non-minimal 16-bit length"
    ( Bytes.append (Bytes.append (Bytes.singleByte 0x81) (Bytes.singleByte 126))
        (Bytes.uint16BE 5)
    )
  failsToDecode "a non-minimal 64-bit length"
    ( Bytes.append (Bytes.append (Bytes.singleByte 0x81) (Bytes.singleByte 127))
        (Bytes.uint64BE 5)
    )
  failsToDecode "an oversized declared length"
    ( Bytes.append (Bytes.append (Bytes.singleByte 0x81) (Bytes.singleByte 127))
        (Bytes.uint64BE (Ws.maxMessageBytes + 1))
    )
  failsToDecode "a reserved close code" (serverClose 1005 "")
  failsToDecode "a one-byte close payload"
    (serverFrame true 0x8 (Bytes.singleByte 3))
  failsToDecode "invalid UTF-8 text"
    (serverFrame true 0x1 (Bytes.singleByte 0xFF))

frameEncoding :: Effect Unit
frameEncoding = do
  frame <- Ws.textFrame "hello"
  Check.equalInt "a client text frame is masked and short-framed"
    (Bytes.byteAt frame 0)
    0x81
  Check.equalInt "the mask bit is set with the length"
    (Bytes.byteAt frame 1)
    (bitOr 0x80 5)
  Check.equalString "the payload unmasks to the original text"
    (unmaskShortFrame frame)
    "hello"

  medium <- Ws.textFrame (stringRepeat "x" 200)
  Check.equalInt "a 200-byte payload uses the 16-bit length form"
    (Bytes.byteAt medium 1)
    (bitOr 0x80 126)
  Check.equalInt "the 16-bit length is the payload size"
    (Bytes.readUint16BE medium 2)
    200

  closing <- Ws.closeFrame 1000 "bye"
  Check.equalInt "a close frame carries opcode 8" (Bytes.byteAt closing 0) 0x88

  Check.equalString "the RFC 6455 accept value is reproduced"
    (Ws.expectedAccept "dGhlIHNhbXBsZSBub25jZQ==")
    "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

timestampDecoding :: Effect Unit
timestampDecoding = do
  Check.equalInt "the zero timestamp decodes"
    (fromMaybe noValue (Live.timestampNumber "AAAAAAAAAAA="))
    0
  Check.equalInt "a non-zero timestamp decodes"
    (fromMaybe noValue (Live.timestampNumber (Bytes.base64Encode (Bytes.uint64LE 7))))
    7
  Check.ok "a short timestamp is rejected"
    (isNothing (Live.timestampNumber "AAAA"))
  Check.ok "a non-base64 timestamp is rejected"
    (isNothing (Live.timestampNumber "not base64!"))

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

bytes :: String -> Bytes
bytes = Bytes.fromString

-- | A sentinel for "the decoder answered nothing", chosen because every value
-- | these tests decode is non-negative.
noValue :: Int
noValue = negateInt 1

-- | A raw U+0001. JSON forbids it inside a string, and the encoder has to
-- | escape it on the way out. Building it from a byte avoids a source escape
-- | whose following character could be read as more hexadecimal digits.
controlByte :: String
controlByte = Bytes.toStringOrEmpty (Bytes.singleByte 0x01)

object :: String -> Json
object text = case Json.parse text of
  Right value -> value
  Left _ -> JsonNull

encodeAgain :: String -> String
encodeAgain text = Json.toString (object text)

roundTrip :: String -> String -> Effect Unit
roundTrip name text = Check.equalString (name <> " survives a round trip")
  (encodeAgain text)
  text

decodeString :: String -> String
decodeString text = case Json.parse text of
  Right (JsonString decoded) -> decoded
  _ -> ""

rejects :: String -> String -> Effect Unit
rejects name text =
  Check.ok (name <> " is rejected") (not (isRight (Json.parse text)))

rejectsUrl :: String -> String -> Effect Unit
rejectsUrl name text =
  Check.ok (name <> " is rejected") (not (isRight (Http.parseUrl text)))

integral :: Json -> Int
integral value = fromMaybe noValue (Json.integralInt value)

-- | Build the unmasked frame a server sends. Servers never mask, so the test
-- | fixtures write plain frames and the client's decoder must accept them.
serverFrame :: Boolean -> Int -> Bytes -> Bytes
serverFrame final opcode payload =
  let
    first = Bytes.singleByte (bitOr (if final then 0x80 else 0x00) opcode)
    size = Bytes.size payload
    header =
      if size < 126 then Bytes.append first (Bytes.singleByte size)
      else Bytes.append (Bytes.append first (Bytes.singleByte 126))
        (Bytes.uint16BE size)
  in
    Bytes.append header payload

serverText :: String -> Bytes
serverText text = serverFrame true 0x1 (Bytes.fromString text)

serverClose :: Int -> String -> Bytes
serverClose code reason = serverFrame true 0x8
  (Bytes.append (Bytes.uint16BE code) (Bytes.fromString reason))

-- | A server frame that wrongly sets the mask bit, which the client must
-- | refuse rather than silently unmask.
maskedServerText :: String -> Bytes
maskedServerText text =
  let
    payload = Bytes.fromString text
    key = Bytes.fromString "abcd"
    header = Bytes.append (Bytes.singleByte 0x81)
      (Bytes.singleByte (bitOr 0x80 (Bytes.size payload)))
  in
    Bytes.append (Bytes.append header key) (Bytes.xorRepeating payload key)

-- | Undo the client's own masking for a short frame, so the encoder is checked
-- | against the bytes a server would actually receive.
unmaskShortFrame :: Bytes -> String
unmaskShortFrame frame =
  let
    size = bitAnd (Bytes.byteAt frame 1) 0x7F
    key = Bytes.slice frame 2 4
    payload = Bytes.slice frame 6 size
  in
    Bytes.toStringOrEmpty (Bytes.xorRepeating payload key)

failsToDecode :: String -> Bytes -> Effect Unit
failsToDecode name input = case Ws.next (Ws.feed Ws.newDecoder input) of
  Ws.Failed _ -> Check.ok (name <> " is rejected") true
  _ -> Check.ok (name <> " is rejected") false
