-- | HTTP/1.1 for Convex, spoken directly over a socket.
-- |
-- | Convex's HTTP API is one POST with a JSON body, so the client writes the
-- | request and reads the response itself instead of pulling in a general HTTP
-- | stack. The same head parser is reused by the WebSocket handshake, which is
-- | an HTTP request whose connection deliberately stays open.
-- |
-- | Reading is bounded in three independent ways: a head limit, a body limit,
-- | and an absolute deadline shared by every socket call in the exchange. A
-- | server that stalls half way through a response therefore fails as a
-- | transport error rather than holding the caller open.
module Convex.Http
  ( Url
  , Header
  , Head
  , Response
  , parseUrl
  , request
  , renderRequest
  , readHead
  , parseHead
  , header
  , maxHeadBytes
  , maxBodyBytes
  ) where

import Convex.Prelude
import Convex.Bytes (Bytes)
import Convex.Bytes as Bytes
import Convex.Sys (RecvResult(..), Socket)
import Convex.Sys as Sys

-- | Largest response head this client will read before giving up. A server
-- | that never finishes its headers must not be able to grow the process.
maxHeadBytes :: Int
maxHeadBytes = 65536

-- | Largest response body. Convex query results in this demonstration are
-- | tiny; the bound turns a runaway response into a clear error.
maxBodyBytes :: Int
maxBodyBytes = 8388608

-- | A deployment origin, split into the parts a request needs.
-- |
-- | `authority` is the value for the `host` header, including the port when it
-- | is not the default for the scheme. `basePath` is the prefix for every
-- | request target, and is empty for a bare origin.
type Url =
  { secure :: Boolean
  , host :: String
  , port :: Int
  , authority :: String
  , basePath :: String
  }

type Header = Tuple String String

-- | The status line and headers of a response, before any body is read.
type Head =
  { status :: Int
  , headers :: List Header
  }

type Response =
  { status :: Int
  , headers :: List Header
  , body :: Bytes
  }

headTerminator :: Bytes
headTerminator = Bytes.fromString "\r\n\r\n"

lineTerminator :: Bytes
lineTerminator = Bytes.fromString "\r\n"

-- ---------------------------------------------------------------------------
-- URLs
-- ---------------------------------------------------------------------------

-- | Parse a Convex deployment URL such as `https://example.convex.cloud`.
parseUrl :: String -> Either String Url
parseUrl text =
  if not (validUrlText text) then
    Left
      "Convex URL contains whitespace, control characters, or unsupported components"
  else
    eitherThen (splitScheme text) \scheme ->
      let
        rest = scheme.rest
        slash = stringIndexOf rest "/"
        authority = if slash < 0 then rest else stringSlice 0 slash rest
        path = if slash < 0 then "" else stringDropStart slash rest
      in
        eitherThen (splitPort authority scheme.defaultPort) \hostPort ->
          if hostPort.host == "" then Left "Convex URL has no host"
          else Right
            { secure: scheme.secure
            , host: hostPort.host
            , port: hostPort.port
            , authority: authority
            , basePath: if path == "/" then "" else path
            }

-- | Reject anything that is not a plain origin before it reaches the socket:
-- | credentials, queries, fragments, whitespace, and control characters.
validUrlText :: String -> Boolean
validUrlText text =
  stringByteLength text <= 4096
    && text == stringTrim text
    && not (stringContains text "@")
    && not (stringContains text "?")
    && not (stringContains text "#")
    && noControlBytes (Bytes.fromString text) 0

noControlBytes :: Bytes -> Int -> Boolean
noControlBytes bytes index =
  let
    byte = Bytes.byteAt bytes index
  in
    if byte < 0 then true
    else if byte <= 0x20 || byte == 0x7F then false
    else noControlBytes bytes (index + 1)

type Scheme =
  { secure :: Boolean
  , defaultPort :: Int
  , rest :: String
  }

splitScheme :: String -> Either String Scheme
splitScheme text =
  let
    lowered = stringLowercase text
  in
    if stringStartsWith lowered "https://" then
      Right { secure: true, defaultPort: 443, rest: stringDropStart 8 text }
    else if stringStartsWith lowered "http://" then
      Right { secure: false, defaultPort: 80, rest: stringDropStart 7 text }
    else Left "Convex URL must use http or https"

splitPort
  :: String -> Int -> Either String { host :: String, port :: Int }
splitPort authority defaultPort = case stringSplitOnce authority ":" of
  Nothing -> Right { host: authority, port: defaultPort }
  Just (Tuple host rawPort) -> case parseInt rawPort of
    Just port | port > 0 && port < 65536 -> Right { host: host, port: port }
    _ -> Left "Convex URL has an invalid port"

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------

-- | Perform one request and read the complete response.
-- |
-- | The connection is closed afterwards. Convex calls in this demonstration
-- | are occasional, and a fresh connection keeps failure handling simple:
-- | there is no pooled socket that the next caller can find stale.
request
  :: Url
  -> String
  -> String
  -> List Header
  -> Bytes
  -> Int
  -> Boolean
  -> Effect (Either String Response)
request url method path headers body timeout verifyPeer =
  if Bytes.size body > maxBodyBytes then
    pure (Left "HTTP request body is too large")
  else do
    now <- Sys.monotonicMs
    let deadline = now + timeout
    opened <- Sys.connect url.secure url.host url.port timeout verifyPeer
    case opened of
      Left reason -> pure (Left reason)
      Right socket -> do
        outcome <- exchange socket url method path headers body deadline
        Sys.close socket
        pure outcome

exchange
  :: Socket
  -> Url
  -> String
  -> String
  -> List Header
  -> Bytes
  -> Int
  -> Effect (Either String Response)
exchange socket url method path headers body deadline = do
  let
    payload = Bytes.append
      (Bytes.fromString (renderRequest url method path headers (Bytes.size body)))
      body
  timeLeft <- Sys.remainingMs deadline
  written <- Sys.send socket payload timeLeft
  case written of
    Left reason -> pure (Left reason)
    Right _ -> do
      headRead <- readHead socket Bytes.empty deadline
      case headRead of
        Left reason -> pure (Left reason)
        Right (Tuple rawHead leftover) -> case parseHead rawHead of
          Left reason -> pure (Left reason)
          Right head -> do
            bodyRead <- readBody socket head leftover deadline
            case bodyRead of
              Left reason -> pure (Left reason)
              Right decoded -> pure
                ( Right
                    { status: head.status
                    , headers: head.headers
                    , body: decoded
                    }
                )

-- | Build the request line and headers. `connection: close` is explicit so the
-- | server does not keep a socket open that this client will never reuse.
renderRequest :: Url -> String -> String -> List Header -> Int -> String
renderRequest url method path headers contentLength =
  let
    fixed = Cons (method <> " " <> url.basePath <> path <> " HTTP/1.1")
      ( Cons ("host: " <> url.authority)
          ( Cons ("content-length: " <> intToString contentLength)
              (listSingleton "connection: close")
          )
      )
    rendered = listMap (\(Tuple name value) -> name <> ": " <> value) headers
  in
    stringJoin (listAppend fixed rendered) "\r\n" <> "\r\n\r\n"

-- ---------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------

-- | Read until the blank line that ends the head, returning the head bytes and
-- | whatever body bytes arrived in the same read.
readHead
  :: Socket -> Bytes -> Int -> Effect (Either String (Tuple Bytes Bytes))
readHead socket buffer deadline =
  let
    boundary = Bytes.indexOfBytes buffer headTerminator 0
  in
    if boundary >= 0 then
      if boundary > maxHeadBytes then
        pure (Left "HTTP response head is too large")
      else pure
        ( Right
            ( Tuple (Bytes.take boundary buffer)
                (Bytes.drop (boundary + Bytes.size headTerminator) buffer)
            )
        )
    else if Bytes.size buffer > maxHeadBytes then
      pure (Left "HTTP response head is too large")
    else do
      chunk <- readMore socket deadline
      case chunk of
        Left reason -> pure (Left reason)
        Right more -> readHead socket (Bytes.append buffer more) deadline

-- | Parse a status line and headers. Header names are lowercased once here so
-- | every later lookup is a plain comparison.
parseHead :: Bytes -> Either String Head
parseHead raw = case Bytes.toStringChecked raw of
  Nothing -> Left "HTTP response head is not valid UTF-8"
  Just text -> case stringSplit text "\r\n" of
    Nil -> Left "HTTP response has no status line"
    Cons statusLine headerLines ->
      eitherThen (parseStatus statusLine) \status ->
        eitherThen (listTraverseEither parseHeader headerLines) \headers ->
          if duplicateHeader headers then
            Left "HTTP response repeats a header"
          else Right { status: status, headers: headers }

parseStatus :: String -> Either String Int
parseStatus line = case stringSplit line " " of
  Cons version (Cons code _) ->
    if
      (version == "HTTP/1.0" || version == "HTTP/1.1")
        && stringByteLength code == 3 then
      case parseInt code of
        Just status | status >= 100 && status <= 999 -> Right status
        _ -> Left "HTTP response has a malformed status line"
    else Left "HTTP response has a malformed status line"
  _ -> Left "HTTP response has a malformed status line"

parseHeader :: String -> Either String Header
parseHeader line = case stringSplitOnce line ":" of
  Nothing -> Left "HTTP response has a malformed header"
  Just (Tuple rawName rawValue) ->
    let
      name = stringLowercase (stringTrim rawName)
    in
      if name == "" then Left "HTTP response has a malformed header"
      else Right (Tuple name (stringTrim rawValue))

duplicateHeader :: List Header -> Boolean
duplicateHeader headers = case headers of
  Nil -> false
  Cons (Tuple name _) rest ->
    listAny (\(Tuple other _) -> other == name) rest || duplicateHeader rest

-- | Look up a header that `parseHead` has already lowercased. A repeated
-- | header is rejected earlier, so a match is unambiguous.
header :: Head -> String -> Maybe String
header head name =
  maybeMap snd (listFind (\(Tuple other _) -> other == name) head.headers)

readBody :: Socket -> Head -> Bytes -> Int -> Effect (Either String Bytes)
readBody socket head buffer deadline =
  case header head "transfer-encoding", header head "content-length" of
    Just _, Just _ -> pure (Left "HTTP response has ambiguous framing")
    Just encoding, Nothing ->
      if stringLowercase (stringTrim encoding) == "chunked" then
        readChunked socket buffer Bytes.emptyChunks 0 deadline
      else pure (Left "unsupported HTTP transfer-encoding")
    Nothing, Just rawLength -> case parseInt (stringTrim rawLength) of
      Just length | length >= 0 && length <= maxBodyBytes ->
        readExactly socket buffer length deadline
      _ -> pure (Left "HTTP response has an invalid content-length")
    -- Without a length the body ends when the server closes, which is exactly
    -- what `connection: close` invites it to do.
    Nothing, Nothing -> readUntilClose socket
      (Bytes.pushChunk buffer Bytes.emptyChunks)
      deadline

readExactly :: Socket -> Bytes -> Int -> Int -> Effect (Either String Bytes)
readExactly socket buffer length deadline =
  if Bytes.size buffer >= length then pure (Right (Bytes.take length buffer))
  else do
    chunk <- readMore socket deadline
    case chunk of
      Left reason -> pure (Left reason)
      Right more -> readExactly socket (Bytes.append buffer more) length
        deadline

readUntilClose
  :: Socket -> Bytes.Chunks -> Int -> Effect (Either String Bytes)
readUntilClose socket acc deadline =
  if Bytes.chunksSize acc > maxBodyBytes then
    pure (Left "HTTP response body is too large")
  else do
    timeLeft <- Sys.remainingMs deadline
    outcome <- Sys.recv socket 0 timeLeft
    case outcome of
      Received chunk ->
        readUntilClose socket (Bytes.pushChunk chunk acc) deadline
      RecvClosed -> pure (Right (Bytes.chunksToBytes acc))
      RecvTimeout -> pure (Left "HTTP response timed out")
      RecvFailed reason -> pure (Left reason)

readChunked
  :: Socket
  -> Bytes
  -> Bytes.Chunks
  -> Int
  -> Int
  -> Effect (Either String Bytes)
readChunked socket buffer acc total deadline =
  let
    boundary = Bytes.indexOfBytes buffer lineTerminator 0
  in
    if boundary < 0 then
      if Bytes.size buffer > 128 then
        pure (Left "HTTP chunk size line is too large")
      else do
        chunk <- readMore socket deadline
        case chunk of
          Left reason -> pure (Left reason)
          Right more ->
            readChunked socket (Bytes.append buffer more) acc total deadline
    else
      let
        line = Bytes.take boundary buffer
        rest = Bytes.drop (boundary + 2) buffer
      in
        case parseChunkSize line of
          Left reason -> pure (Left reason)
          Right 0 -> do
            ensured <- ensureBytes socket rest 2 deadline
            case ensured of
              Left reason -> pure (Left reason)
              Right tail ->
                if Bytes.take 2 tail == lineTerminator then
                  pure (Right (Bytes.chunksToBytes acc))
                else pure (Left "HTTP trailers are not supported")
          Right size ->
            if total + size > maxBodyBytes then
              pure (Left "HTTP response body is too large")
            else do
              -- Each chunk is followed by its own CRLF, which is consumed with
              -- the chunk before the next size line is read.
              ensured <- ensureBytes socket rest (size + 2) deadline
              case ensured of
                Left reason -> pure (Left reason)
                Right tail ->
                  if Bytes.slice tail size 2 /= lineTerminator then
                    pure (Left "malformed HTTP chunk terminator")
                  else readChunked socket (Bytes.drop (size + 2) tail)
                    (Bytes.pushChunk (Bytes.take size tail) acc)
                    (total + size)
                    deadline

parseChunkSize :: Bytes -> Either String Int
parseChunkSize line =
  -- A chunk size above seven hexadecimal digits already exceeds the body
  -- limit, so it is rejected before the value is used for anything.
  if Bytes.size line == 0 || Bytes.size line > 7 then
    Left "malformed HTTP chunk size"
  else case parseIntBase16 (Bytes.toStringOrEmpty line) of
    Just size | size >= 0 -> Right size
    _ -> Left "malformed HTTP chunk size"

ensureBytes :: Socket -> Bytes -> Int -> Int -> Effect (Either String Bytes)
ensureBytes socket buffer length deadline =
  if Bytes.size buffer >= length then pure (Right buffer)
  else do
    timeLeft <- Sys.remainingMs deadline
    outcome <- Sys.recv socket (length - Bytes.size buffer) timeLeft
    case outcome of
      Received chunk ->
        ensureBytes socket (Bytes.append buffer chunk) length deadline
      RecvClosed -> pure (Left "HTTP connection closed early")
      RecvTimeout -> pure (Left "HTTP response timed out")
      RecvFailed reason -> pure (Left reason)

readMore :: Socket -> Int -> Effect (Either String Bytes)
readMore socket deadline = do
  timeLeft <- Sys.remainingMs deadline
  outcome <- Sys.recv socket 0 timeLeft
  case outcome of
    Received chunk -> pure (Right chunk)
    RecvClosed -> pure (Left "HTTP connection closed early")
    RecvTimeout -> pure (Left "HTTP response timed out")
    RecvFailed reason -> pure (Left reason)
