||| Deterministic wire-format tests: JSON, Base64, SHA-1, Convex timestamps,
||| HTTP envelopes, and URL parsing. Nothing here opens a socket, so these
||| failures always point at encoding rather than at the network.
module Main

import Data.IORef
import Data.List
import Data.Maybe
import Data.String
import System
import System.File

import Convex.Codec
import Convex.Error
import Convex.Http
import Convex.Json
import Convex.Net
import Convex.Prim
import Convex.Ws

check : IORef Int -> String -> Bool -> IO ()
check failures label ok =
  if ok
     then putStrLn ("ok   " ++ label)
     else do modifyIORef failures (+ 1)
             ignore $ fPutStrLn stderr ("FAIL " ++ label)
             putStrLn ("FAIL " ++ label)

covering
parsesTo : String -> Json -> IO Bool
parsesTo text expected =
  do parsed <- parseJsonText text
     pure (case parsed of
                Right value => value == expected
                Left _ => False)

covering
rejects : String -> IO Bool
rejects text =
  do parsed <- parseJsonText text
     pure (case parsed of
                Left _ => True
                Right _ => False)

covering
roundTrips : String -> IO Bool
roundTrips text =
  do parsed <- parseJsonText text
     case parsed of
          Left _ => pure False
          Right value =>
            do rendered <- renderJson value
               case rendered of
                    Left _ => pure False
                    Right output =>
                      do again <- parseJsonText output
                         pure (case again of
                                    Right second => second == value
                                    Left _ => False)

covering
renderedText : Json -> IO String
renderedText value =
  do rendered <- renderJson value
     pure (either (const "<render failed>") id rendered)

covering
jsonTests : IORef Int -> IO ()
jsonTests failures =
  do check failures "null, booleans, and an empty object parse"
       !(parsesTo "{\"a\":null,\"b\":true,\"c\":{}}"
           (JObject [("a", JNull), ("b", JBool True), ("c", JObject [])]))
     check failures "a nested array parses" !(parsesTo "[1,[2,[3]]]"
       (JArray [jsonInt 1, JArray [jsonInt 2, JArray [jsonInt 3]]]))
     check failures "a leading zero is rejected" !(rejects "01")
     check failures "a bare fraction is rejected" !(rejects ".5")
     check failures "a trailing decimal point is rejected" !(rejects "1.")
     check failures "a leading plus is rejected" !(rejects "+1")
     check failures "an empty exponent is rejected" !(rejects "1e")
     check failures "NaN is rejected" !(rejects "NaN")
     check failures "trailing content is rejected" !(rejects "{} {}")
     check failures "a duplicate key is rejected"
       !(rejects "{\"a\":1,\"a\":2}")
     check failures "a trailing comma is rejected" !(rejects "[1,]")
     -- Built from character codes rather than a source escape, so the test
     -- does not depend on how the compiler spells a control character.
     check failures "a raw control byte is rejected"
       !(rejects (pack ['"', chr 1, '"']))
     check failures "an unknown escape is rejected" !(rejects "\"\\x\"")
     check failures "a lone high surrogate is rejected" !(rejects "\"\\ud83d\"")
     check failures "a lone low surrogate is rejected" !(rejects "\"\\ude00\"")
     check failures "a surrogate pair round-trips as one scalar"
       !(roundTrips "\"\\ud83d\\ude00\"")
     -- RefC treats a string as bytes, so a multi-byte value must survive the
     -- parse and render path untouched rather than through a character list.
     -- The escapes live in the JSON text, not in Idris source, so the test
     -- exercises the decoder rather than the compiler's literal syntax.
     check failures "multi-byte UTF-8 round-trips"
       !(roundTrips "{\"greeting\":\"Hello, \\u4e16\\u754c \\ud83d\\udc4b\"}")
     check failures "an escaped value round-trips"
       !(roundTrips "{\"t\":\"line\\nbreak\\ttab\\\"quote\\\\slash\"}")
     -- Convex sends Float64. Re-emitting the received token means an echoed
     -- value returns exactly as it arrived, whatever the runtime prints.
     rendered <- do parsed <- parseJsonText "{\"n\":42.500}"
                    case parsed of
                         Right value => renderedText value
                         Left _ => pure "<parse failed>"
     check failures "a number keeps its original token"
       (rendered == "{\"n\":42.500}")
     escaped <- renderedText (JString (pack ['a', chr 1, 'b']))
     check failures "a control character is escaped on output"
       (escaped == "\"a\\u0001b\"")
     check failures "a non-finite number cannot be encoded"
       (isNothing (jsonDouble (0.0 / 0.0)))

covering
numberTests : IORef Int -> IO ()
numberTests failures =
  do integral <- parseJsonText "{\"count\":1.0}"
     fractional <- parseJsonText "{\"count\":0.5}"
     quoted <- parseJsonText "{\"count\":\"1\"}"
     huge <- parseJsonText "{\"count\":1e300}"
     zero <- parseJsonText "{\"count\":0.0}"
     let countOf = \value => either (const Nothing) (\json => field "count" json
                                                                >>= wholeNumber) value
     check failures "an integral decimal is a whole count" (countOf integral == Just 1)
     check failures "zero in decimal form is a whole count" (countOf zero == Just 0)
     check failures "a fractional value is not a whole count"
       (countOf fractional == Nothing)
     check failures "a quoted number is not a whole count" (countOf quoted == Nothing)
     check failures "an out-of-range value is not a whole count" (countOf huge == Nothing)

covering
codecTests : IORef Int -> IO ()
codecTests failures =
  do check failures "Base64 encodes with padding"
       (base64Encode [77, 97, 110] == "TWFu" && base64Encode [77, 97] == "TWE="
          && base64Encode [77] == "TQ==")
     check failures "Base64 round-trips" (base64Decode (base64Encode [0, 1, 254, 255])
                                            == Just [0, 1, 254, 255])
     check failures "Base64 rejects a wrong length" (base64Decode "TWF" == Nothing)
     check failures "Base64 rejects non-zero padding bits" (base64Decode "TQ=A" == Nothing)
     check failures "SHA-1 of the empty string"
       (hexEncode (sha1 []) == "da39a3ee5e6b4b0d3255bfef95601890afd80709")
     check failures "SHA-1 of abc"
       (hexEncode (sha1 [97, 98, 99]) == "a9993e364706816aba3e25717850c26c9cd0d89d")
     -- The worked example from RFC 6455 section 1.3.
     check failures "the WebSocket accept key matches RFC 6455"
       (expectedAccept "dGhlIHNhbXBsZSBub25jZQ==" == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
     check failures "the zero timestamp is canonical"
       (encodeTimestamp 0 == Just zeroTimestampText)
     check failures "a timestamp round-trips"
       (decodeTimestamp (fromMaybe "" (encodeTimestamp 1234567890123))
          == Just 1234567890123)
     check failures "a non-canonical timestamp is rejected"
       (decodeTimestamp "AAAAAAAAAAB=" == Nothing)
     check failures "a short timestamp is rejected" (decodeTimestamp "AAAA" == Nothing)
  where
    zeroTimestampText : String
    zeroTimestampText = "AAAAAAAAAAA="

envelopeOf : String -> Int -> String -> IO (Either ConvexError CallResult)
envelopeOf operation statusCode text =
  do parsed <- parseJsonText text
     case parsed of
          Left problem => pure (Left (protocolError operation problem))
          Right payload => pure (decodeEnvelope operation statusCode payload)

failureKind : Either ConvexError CallResult -> Maybe ErrorKind
failureKind (Left failure) = Just (kind failure)
failureKind (Right _) = Nothing

covering
httpTests : IORef Int -> IO ()
httpTests failures =
  do check failures "a status line parses" (parseStatusLine "HTTP/1.1 560 Error"
                                              == Just 560)
     check failures "a malformed status line is rejected"
       (parseStatusLine "HTTP/1.1 5x0 Error" == Nothing)
     check failures "a non-HTTP status line is rejected"
       (parseStatusLine "ICY 200 OK" == Nothing)

     success <- envelopeOf "query" 200
                  "{\"status\":\"success\",\"value\":{\"count\":1},\"logLines\":[\"a\"]}"
     check failures "a 200 success yields the value and its logs"
       (case success of
             Right result => resultValue result == JObject [("count", jsonInt 1)]
                               && resultLogs result == ["a"]
             Left _ => False)

     -- Convex answers a function that threw with 560 and an error envelope.
     functionError <- envelopeOf "query" 560
       ("{\"status\":\"error\",\"errorMessage\":\"boom\""
          ++ ",\"errorData\":{\"code\":\"X\"},\"logLines\":[]}")
     check failures "a 560 is a structured function error"
       (case functionError of
             Left failure => kind failure == FunctionFailure
                               && message failure == "boom"
                               && errorData failure == JObject [("code", JString "X")]
             Right _ => False)

     -- The same body on 400 or 500 describes a request or deployment problem,
     -- and must not be reported as a function result.
     badRequest <- envelopeOf "query" 400
       "{\"status\":\"error\",\"errorMessage\":\"bad args\"}"
     check failures "a 400 error envelope is a protocol failure"
       (failureKind badRequest == Just ProtocolFailure)

     serverError <- envelopeOf "query" 500
       "{\"status\":\"error\",\"errorMessage\":\"upstream\"}"
     check failures "a 500 error envelope is a transport failure"
       (failureKind serverError == Just TransportFailure)

     misplaced <- envelopeOf "query" 500 "{\"status\":\"success\",\"value\":1}"
     check failures "a success envelope on 500 is still a failure"
       (failureKind misplaced == Just TransportFailure)

     noValue <- envelopeOf "query" 200 "{\"status\":\"success\"}"
     check failures "a success envelope without a value is rejected"
       (failureKind noValue == Just ProtocolFailure)

     badLogs <- envelopeOf "query" 200
       "{\"status\":\"success\",\"value\":1,\"logLines\":[1]}"
     check failures "non-string log lines are rejected"
       (failureKind badLogs == Just ProtocolFailure)

     unknown <- envelopeOf "query" 200 "{\"status\":\"weird\"}"
     check failures "an unrecognised status is rejected"
       (failureKind unknown == Just ProtocolFailure)

     check failures "a function path must be module:function"
       (validPath "demo:state" && not (validPath "demo") && not (validPath ":state"))

covering
endpointTests : IORef Int -> IO ()
endpointTests failures =
  do check failures "https defaults to port 443"
       (case parseEndpoint "https://example.convex.cloud" of
             Right target => secure target && port target == 443 && path target == "/"
             Left _ => False)
     check failures "an explicit port and path parse"
       (case parseEndpoint "http://backend:3210/base" of
             Right target => not (secure target) && port target == 3210
                               && host target == "backend" && path target == "/base"
             Left _ => False)
     check failures "an unsupported scheme is rejected"
       (case parseEndpoint "ws://backend:3210" of
             Left _ => True
             Right _ => False)
     check failures "a non-numeric port is rejected"
       (case parseEndpoint "http://backend:http" of
             Left _ => True
             Right _ => False)
     check failures "an out-of-range port is rejected"
       (case parseEndpoint "http://backend:70000" of
             Left _ => True
             Right _ => False)

covering
main : IO ()
main =
  do initialise
     failures <- newIORef 0
     jsonTests failures
     numberTests failures
     codecTests failures
     httpTests failures
     endpointTests failures
     failureCount <- readIORef failures
     if failureCount == 0
        then putStrLn "wire tests passed"
        else do ignore $ fPutStrLn stderr ("wire tests failed: " ++ show failureCount)
                exitFailure
