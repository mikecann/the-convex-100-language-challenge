||| Convex's documented JSON HTTP API.
|||
||| The request and response envelopes are written and read here rather than
||| delegated to an HTTP library, so this module owns the parts a Convex client
||| has to get right: the `format: "json"` request shape, the distinction
||| between a successful value and a structured function error, the separation
||| of `logLines` from the returned value, and the status codes Convex uses.
|||
||| Convex answers a function that threw with HTTP 560 and an ordinary error
||| envelope. A 400 is a malformed request and a 500 is a deployment failure;
||| neither is allowed to arrive as a function result even when the body
||| happens to parse as an error envelope.
module Convex.Http

import Data.List
import Data.String

import Convex.Error
import Convex.Json
import Convex.Net
import Convex.Prim

||| Everything an HTTP call needs that does not change between calls.
public export
record HttpConfig where
  constructor MkHttpConfig
  endpoint : Endpoint
  ||| A specific CA bundle, or "" to use the system trust store.
  caFile : String
  ||| Sent as `Convex-Client`, which is how a deployment attributes traffic.
  clientVersion : String
  ||| Whole-call budget in milliseconds, applied as one absolute deadline.
  requestBudgetMs : Int

public export
record CallResult where
  constructor MkCallResult
  resultValue : Json
  resultLogs : List String

||| The largest response body the client will read. A Convex demonstration
||| payload is far smaller; the bound exists so a runaway or hostile response
||| cannot grow the process without limit.
export
maximumResponseBytes : Int
maximumResponseBytes = 4 * 1024 * 1024

maximumHeaderBytes : Int
maximumHeaderBytes = 8192

maximumHeaderCount : Int
maximumHeaderCount = 64

readBufferBytes : Int
readBufferBytes = 65536

||| A Convex function path is `module:function`, and the shared schema already
||| refuses anything shorter than three characters.
export
validPath : String -> Bool
validPath path =
  case span (/= ':') path of
       (moduleName, rest) =>
         moduleName /= "" && isPrefixOf ":" rest && length rest > 1

apiPath : Endpoint -> String -> String
apiPath target operation =
  let base = path target
      trimmed = if base == "/" then "" else base in
  trimmed ++ "/api/" ++ operation

--------------------------------------------------------------------------------
-- Response reading
--------------------------------------------------------------------------------

||| Parse `HTTP/1.1 200 OK` into its numeric status. Anything that is not a
||| three-digit code on a recognised version line is a protocol failure.
export
parseStatusLine : String -> Maybe Int
parseStatusLine line =
  if not (isPrefixOf "HTTP/1.1 " line) && not (isPrefixOf "HTTP/1.0 " line)
     then Nothing
     else let rest = substr 9 (length line) line
              digits = substr 0 3 rest in
          if length digits /= 3 || not (all isDigit (unpack digits))
             then Nothing
             else Just (cast digits)

record Headers where
  constructor MkHeaders
  contentLength : Maybe Int
  chunked : Bool

covering
readHeaders : Connection -> Int -> Int -> Headers -> IO (Either String Headers)
readHeaders connection deadline remaining acc =
  if remaining <= 0
     then pure (Left "HTTP response has too many headers")
     else do line <- readLine connection maximumHeaderBytes deadline
             case line of
                  Left problem => pure (Left problem)
                  Right "" => pure (Right acc)
                  Right text => header text
  where
    covering
    header : String -> IO (Either String Headers)
    header text =
      case span (/= ':') text of
           (_, "") => pure (Left "HTTP header line has no colon")
           (name, rest) =>
             do let value = trim (substr 1 (length rest) rest)
                let lowered = toLower name
                if lowered == "content-length"
                   then if value == "" || not (all isDigit (unpack value))
                           then pure (Left "HTTP Content-Length is not numeric")
                           else readHeaders connection deadline (remaining - 1)
                                            ({ contentLength := Just (cast value) } acc)
                   else if lowered == "transfer-encoding"
                           then readHeaders connection deadline (remaining - 1)
                                            ({ chunked := toLower value == "chunked" } acc)
                           else readHeaders connection deadline (remaining - 1) acc

||| Read a body of known length straight into the body buffer.
covering
readSizedBody : Connection -> Int -> Int -> Int -> IO (Either String Int)
readSizedBody connection body size deadline =
  if size > maximumResponseBytes
     then pure (Left "HTTP response exceeds the client's byte budget")
     else do result <- readExact connection body 0 size deadline
             case result of
                  Left problem => pure (Left problem)
                  Right () => pure (Right size)

hexDigit : Char -> Maybe Int
hexDigit character =
  let point = ord character in
  if point >= 48 && point <= 57 then Just (point - 48)
  else if point >= 97 && point <= 102 then Just (point - 87)
  else if point >= 65 && point <= 70 then Just (point - 55)
  else Nothing

chunkSize : String -> Maybe Int
chunkSize text =
  let characters = unpack (trim text) in
  if null characters || length characters > 8
     then Nothing
     -- `total` is a reserved word in Idris2 (totality annotations), so the
     -- running hex accumulator is named `accumulated` instead.
     else foldl (\acc, character =>
                   do accumulated <- acc
                      digit <- hexDigit character
                      Just (accumulated * 16 + digit))
                (Just 0) characters

||| Read a `Transfer-Encoding: chunked` body, bounding both each chunk and the
||| assembled total.
covering
readChunkedBody : Connection -> Int -> Int -> Int -> IO (Either String Int)
readChunkedBody connection body written deadline =
  do header <- readLine connection maximumHeaderBytes deadline
     case header of
          Left problem => pure (Left problem)
          Right line =>
            case chunkSize (fst (span (/= ';') line)) of
                 Nothing => pure (Left "HTTP chunk size is not hexadecimal")
                 Just size => chunk size
  where
    covering
    finish : IO (Either String Int)
    finish =
      do trailer <- readLine connection maximumHeaderBytes deadline
         case trailer of
              Left problem => pure (Left problem)
              Right _ => pure (Right written)

    covering
    chunk : Int -> IO (Either String Int)
    chunk size =
      if size == 0
         then finish
         else if written + size > maximumResponseBytes
                 then pure (Left "HTTP response exceeds the client's byte budget")
                 else do copied <- readExact connection body written size deadline
                         case copied of
                              Left problem => pure (Left problem)
                              Right () =>
                                do terminator <- readLine connection 8 deadline
                                   case terminator of
                                        Left problem => pure (Left problem)
                                        Right "" => readChunkedBody connection body
                                                                    (written + size)
                                                                    deadline
                                        Right _ =>
                                          pure (Left "HTTP chunk is not terminated")

||| Read whatever remains until the peer closes. The client sends
||| `Connection: close`, so this is the ordinary path for a response without a
||| declared length.
covering
readUntilClose : Connection -> Int -> Int -> Int -> IO (Either String Int)
-- `total` is a reserved word in Idris2 (totality annotations), so the
-- running byte count read below is named `totalRead` instead.
readUntilClose connection body written deadline =
  do moved <- drainBuffered connection body written (maximumResponseBytes - written)
     let totalRead = written + moved
     leftover <- buffered connection
     if leftover > 0
        then pure (Left "HTTP response exceeds the client's byte budget")
        else do added <- refill connection
                if added == -1
                   then pure (Right totalRead)
                   else if added == -2
                           then do detail <- lastError
                                   pure (Left ("transport read failed: " ++ detail))
                           else if added > 0
                                   then readUntilClose connection body totalRead deadline
                                   else waitMore totalRead

  where
    covering
    waitMore : Int -> IO (Either String Int)
    waitMore totalRead =
      do ready <- awaitDescriptor (connectionReadFd connection) pollRead deadline
         if ready == 0
            then pure (Left "read exceeded its deadline")
            else readUntilClose connection body totalRead deadline

--------------------------------------------------------------------------------
-- Envelope decoding
--------------------------------------------------------------------------------

||| Map a status code that carried no usable Convex function result onto a
||| typed failure. A 5xx other than Convex's 560 is a deployment problem, so it
||| is reported as a transport failure and stays eligible for a retry decision
||| by the caller; everything else is protocol drift.
export
statusFailure : String -> Int -> List String -> String -> ConvexError
statusFailure operation statusCode logs reason =
  let kind' = if statusCode >= 500 && statusCode /= 560
                 then TransportFailure
                 else ProtocolFailure in
  MkConvexError kind' ("HTTP " ++ show statusCode ++ " " ++ reason) JNull logs operation

||| Turn a decoded body into a result or a typed failure.
|||
||| `status: "success"` must carry a value and arrive with 200. `status:
||| "error"` is a Convex function failure only on 200 or Convex's function-error
||| code 560; on 400 or 500 the same body describes a request or deployment
||| problem instead. `logLines` must be an array of strings either way, so a
||| malformed log list cannot slip through attached to a value.
export
decodeEnvelope : String -> Int -> Json -> Either ConvexError CallResult
decodeEnvelope operation statusCode payload =
  case field "logLines" payload of
       Just logsValue =>
         case stringList logsValue of
              Nothing => Left (protocolError operation
                                 "Convex logLines must be an array of strings")
              Just logs => withLogs logs
       Nothing => withLogs []
  where
    errorMessageText : String
    errorMessageText =
      case map asString (field "errorMessage" payload) of
           Just (Just text) => text
           _ => "Convex function failed"

    errorDataValue : Json
    errorDataValue =
      case field "errorData" payload of
           Just value => value
           Nothing => JNull

    withLogs : List String -> Either ConvexError CallResult
    withLogs logs =
      case map asString (field "status" payload) of
           Just (Just "success") =>
             if statusCode /= 200
                then Left (statusFailure operation statusCode logs
                             "carried a success envelope")
                else case field "value" payload of
                          Nothing => Left (statusFailure operation statusCode logs
                                             "success envelope has no value")
                          Just value => Right (MkCallResult value logs)
           Just (Just "error") =>
             if statusCode == 200 || statusCode == 560
                then Left (MkConvexError FunctionFailure errorMessageText errorDataValue
                                         logs operation)
                else Left (statusFailure operation statusCode logs
                             ("reported: " ++ errorMessageText))
           _ => Left (statusFailure operation statusCode logs
                        "response has no recognised status")

--------------------------------------------------------------------------------
-- Calls
--------------------------------------------------------------------------------

||| Build the request head and body. The declared length is the body's encoded
||| byte count, which is what the shim measures; a character count would
||| understate any multi-byte value and truncate the request.
export
buildRequest : HttpConfig -> (operation : String) -> (token : String)
            -> (body : String) -> IO String
buildRequest config operation token body =
  do size <- textSize body
     let target = endpoint config
     let authorization = if token == ""
                            then ""
                            else "Authorization: Bearer " ++ token ++ "\r\n"
     pure ("POST " ++ apiPath target operation ++ " HTTP/1.1\r\n"
             ++ "Host: " ++ host target ++ "\r\n"
             ++ "Content-Type: application/json\r\n"
             ++ "Accept: application/json\r\n"
             ++ "Connection: close\r\n"
             ++ "Convex-Client: " ++ clientVersion config ++ "\r\n"
             ++ authorization
             ++ "Content-Length: " ++ show size ++ "\r\n\r\n"
             ++ body)

covering
readResponse : Connection -> Int -> IO (Either String (Int, Int, Int))
readResponse connection deadline =
  do statusLine <- readLine connection maximumHeaderBytes deadline
     case statusLine of
          Left problem => pure (Left problem)
          Right line =>
            case parseStatusLine line of
                 Nothing => pure (Left "HTTP status line is invalid")
                 Just statusCode => afterStatus statusCode
  where
    covering
    readBody : Headers -> Int -> IO (Either String Int)
    readBody found body =
      if chunked found
         then readChunkedBody connection body 0 deadline
         else case contentLength found of
                   Just size => readSizedBody connection body size deadline
                   Nothing => readUntilClose connection body 0 deadline

    covering
    afterStatus : Int -> IO (Either String (Int, Int, Int))
    afterStatus statusCode =
      do headers <- readHeaders connection deadline maximumHeaderCount
                                (MkHeaders Nothing False)
         case headers of
              Left problem => pure (Left problem)
              Right found =>
                do body <- bufNew (maximumResponseBytes + 8)
                   if body < 0
                      then pure (Left "could not allocate a response buffer")
                      else do size <- readBody found body
                              case size of
                                   Left problem => do bufFree body
                                                      pure (Left problem)
                                   Right written =>
                                     pure (Right (statusCode, body, written))

||| Run one Convex HTTP call. The whole exchange -- connect, TLS handshake,
||| request, response, and body -- shares a single absolute deadline.
export covering
callConvex : HttpConfig -> (token : String) -> (operation : String)
          -> (path : String) -> (args : Json) -> IO (Either ConvexError CallResult)
callConvex config token operation path args =
  if not (validPath path)
     then pure (Left (protocolError operation "function path must be module:function"))
     else if not (isObject args)
             then pure (Left (protocolError operation
                                "arguments must be a named JSON object"))
             else do encoded <- renderJson (JObject [ ("path", JString path)
                                                    , ("args", args)
                                                    , ("format", JString "json")
                                                    ])
                     case encoded of
                          Left problem => pure (Left (protocolError operation problem))
                          Right body => exchange body
  where
    covering
    interpret : Int -> Int -> Int -> IO (Either ConvexError CallResult)
    interpret statusCode buffer written =
      do parsed <- parseJsonSlice buffer 0 written
         bufFree buffer
         case parsed of
              Left problem =>
                pure (Left (statusFailure operation statusCode []
                             ("returned non-Convex JSON: " ++ problem)))
              Right payload =>
                if not (isObject payload)
                   then pure (Left (statusFailure operation statusCode []
                                     "response was not a JSON object"))
                   else pure (decodeEnvelope operation statusCode payload)

    covering
    run : Connection -> String -> Int -> IO (Either ConvexError CallResult)
    run connection body deadline =
      do request <- buildRequest config operation token body
         sent <- writeText connection request deadline
         case sent of
              Left problem => pure (Left (transportError operation problem))
              Right () =>
                do response <- readResponse connection deadline
                   case response of
                        Left problem => pure (Left (transportError operation problem))
                        Right (statusCode, buffer, written) =>
                          interpret statusCode buffer written

    covering
    exchange : String -> IO (Either ConvexError CallResult)
    exchange body =
      do deadline <- deadlineIn (requestBudgetMs config)
         opened <- openConnection (endpoint config) (caFile config) deadline
                                  readBufferBytes
         case opened of
              Left problem => pure (Left (transportError operation problem))
              Right connection =>
                do outcome <- run connection body deadline
                   closeConnection connection
                   pure outcome
