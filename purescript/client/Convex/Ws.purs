-- | RFC 6455 WebSocket client framing, written in PureScript.
-- |
-- | Convex's sync protocol runs over a WebSocket, so the framing is part of
-- | what this demonstration has to show rather than something to hide behind a
-- | library. Two behaviours matter beyond "it works":
-- |
-- | * Fragmented messages are reassembled before any text is decoded, so a
-- |   multi-byte character split across two frames is never mangled.
-- | * The decoder is a value, not a process. Its buffer and partial-message
-- |   state survive a read timeout, so a slow peer cannot make the reader
-- |   restart at a byte that only looks like a frame boundary.
module Convex.Ws
  ( Message(..)
  , Decoder
  , Step(..)
  , newDecoder
  , feed
  , isMidMessage
  , next
  , textFrame
  , pongFrame
  , closeFrame
  , handshake
  , validateUpgrade
  , expectedAccept
  , maxMessageBytes
  ) where

import Convex.Prelude
import Convex.Bytes (Bytes)
import Convex.Bytes as Bytes
import Convex.Http (Header)
import Convex.Http as Http
import Convex.Sys (Socket)
import Convex.Sys as Sys

-- | The fixed value RFC 6455 appends to the client key before hashing.
handshakeGuid :: String
handshakeGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

-- | Largest single message this client will reassemble. Convex transitions in
-- | this demonstration are kilobytes; the bound turns a hostile or broken peer
-- | into a clear protocol error instead of unbounded growth.
maxMessageBytes :: Int
maxMessageBytes = 8388608

data Message
  = TextMessage String
  | BinaryMessage Bytes
  | Ping Bytes
  | Pong Bytes
  | Close Int String

-- | Incremental frame decoder. `fragment` holds the opcode and bytes of a
-- | message that is still arriving as continuation frames.
type Decoder =
  { buffer :: Bytes
  , fragment :: Maybe (Tuple Int Bytes)
  }

-- | One step of decoding: a complete message, a request for more bytes, or a
-- | protocol failure that must retire the connection.
data Step
  = Decoded Message Decoder
  | NeedMore Decoder
  | Failed String

newDecoder :: Decoder
newDecoder = { buffer: Bytes.empty, fragment: Nothing }

-- | Add freshly read bytes. Buffered bytes are kept, which is what makes a
-- | read timeout harmless part-way through a frame.
feed :: Decoder -> Bytes -> Decoder
feed decoder bytes = decoder { buffer = Bytes.append decoder.buffer bytes }

-- | True when the decoder holds bytes of a frame it has not finished. A caller
-- | that wants to abandon a stalled connection can tell "idle" from
-- | "mid-frame" and apply a deadline only to the second.
isMidMessage :: Decoder -> Boolean
isMidMessage decoder =
  isJust decoder.fragment || Bytes.size decoder.buffer > 0

-- | Pull the next complete message out of the buffer.
next :: Decoder -> Step
next decoder = case parseFrame decoder.buffer of
  Left reason -> Failed reason
  Right Nothing -> NeedMore decoder
  Right (Just frame) ->
    applyFrame (decoder { buffer = frame.rest }) frame.final frame.opcode
      frame.payload

type Frame =
  { final :: Boolean
  , opcode :: Int
  , payload :: Bytes
  , rest :: Bytes
  }

-- | Fold one frame into the decoder. Control frames are always complete and
-- | may legally arrive in the middle of a fragmented data message.
applyFrame :: Decoder -> Boolean -> Int -> Bytes -> Step
applyFrame decoder final opcode payload =
  if opcode == 0x9 then Decoded (Ping payload) decoder
  else if opcode == 0xA then Decoded (Pong payload) decoder
  else if opcode == 0x8 then decodeClose payload decoder
  else if opcode == 0x0 then case decoder.fragment of
    Nothing -> Failed "continuation frame without a started message"
    Just (Tuple started bytes) ->
      finish decoder final started (Bytes.append bytes payload)
  else if opcode == 0x1 || opcode == 0x2 then case decoder.fragment of
    Just _ -> Failed "new data frame while a message was still arriving"
    Nothing -> finish decoder final opcode payload
  else Failed "unknown WebSocket opcode"

finish :: Decoder -> Boolean -> Int -> Bytes -> Step
finish decoder final opcode bytes =
  if Bytes.size bytes > maxMessageBytes then
    Failed "WebSocket message exceeds the client limit"
  else if not final then
    NeedMore (decoder { fragment = Just (Tuple opcode bytes) })
  else if opcode == 0x1 then
    -- Text is decoded only once the whole message is present, so a character
    -- split across frames still decodes correctly.
    case Bytes.toStringChecked bytes of
      Just text -> Decoded (TextMessage text) (decoder { fragment = Nothing })
      Nothing -> Failed "WebSocket text message is not valid UTF-8"
  else Decoded (BinaryMessage bytes) (decoder { fragment = Nothing })

decodeClose :: Bytes -> Decoder -> Step
decodeClose payload decoder =
  let
    size = Bytes.size payload
  in
    if size == 0 then Decoded (Close 1005 "") decoder
    else if size == 1 then Failed "malformed WebSocket close frame"
    else
      let
        code = Bytes.readUint16BE payload 0
      in
        if not (validCloseCode code) then
          Failed "WebSocket close code is invalid"
        else case Bytes.toStringChecked (Bytes.drop 2 payload) of
          Nothing -> Failed "WebSocket close reason is not valid UTF-8"
          Just reason -> Decoded (Close code reason) decoder

validCloseCode :: Int -> Boolean
validCloseCode code =
  code >= 1000
    && code < 5000
    && code /= 1004
    && code /= 1005
    && code /= 1006
    && code /= 1015
    && not (code >= 1016 && code < 3000)

-- | Split one frame off the front of the buffer. `Right Nothing` means the
-- | frame is still incomplete, which is not an error.
parseFrame :: Bytes -> Either String (Maybe Frame)
parseFrame input =
  let
    first = Bytes.byteAt input 0
    second = Bytes.byteAt input 1
  in
    if first < 0 || second < 0 then Right Nothing
    else
      let
        final = bitAnd first 0x80 == 0x80
        reserved = bitAnd first 0x70
        opcode = bitAnd first 0x0F
        masked = bitAnd second 0x80 == 0x80
        short = bitAnd second 0x7F
      in
        if reserved /= 0 then Left "reserved WebSocket bits are set"
        else if not (controlFrameIsValid opcode final short) then
          Left "fragmented or oversized control frame"
        else if masked then
          -- A server must not mask, and accepting a masked frame would hide a
          -- peer that is not speaking the client half of the protocol.
          Left "server sent a masked WebSocket frame"
        else eitherThen (extendedLength input short) \measured ->
          case measured of
            Nothing -> Right Nothing
            Just sized ->
              if sized.length > maxMessageBytes then
                Left "WebSocket frame exceeds the client limit"
              else if Bytes.size input < sized.headerSize + sized.length then
                Right Nothing
              else Right
                ( Just
                    { final: final
                    , opcode: opcode
                    , payload: Bytes.slice input sized.headerSize sized.length
                    , rest: Bytes.drop (sized.headerSize + sized.length) input
                    }
                )

-- | Control frames carry at most 125 bytes and are never fragmented.
controlFrameIsValid :: Int -> Boolean -> Int -> Boolean
controlFrameIsValid opcode final short =
  if opcode < 0x8 then true else final && short <= 125

type Sized =
  { length :: Int
  , headerSize :: Int
  }

-- | Resolve the payload length, rejecting a length that is spelled in more
-- | bytes than it needs. A non-minimal length is how a peer smuggles two
-- | readings of the same frame past a lax decoder.
extendedLength :: Bytes -> Int -> Either String (Maybe Sized)
extendedLength input short =
  if short == 126 then
    let
      extended = Bytes.readUint16BE input 2
    in
      if extended < 0 then Right Nothing
      else if extended < 126 then
        Left "WebSocket length is not minimally encoded"
      else Right (Just { length: extended, headerSize: 4 })
  else if short == 127 then
    let
      extended = Bytes.readUint64BE input 2
    in
      if extended < 0 then Right Nothing
      else if extended < 65536 then
        Left "WebSocket length is not minimally encoded"
      else if extended > maxMessageBytes then
        Left "WebSocket frame exceeds the client limit"
      else Right (Just { length: extended, headerSize: 10 })
  else Right (Just { length: short, headerSize: 2 })

-- ---------------------------------------------------------------------------
-- Encoding
-- ---------------------------------------------------------------------------

-- | Encode a client text frame. Every client frame is masked with a fresh
-- | random key, as RFC 6455 requires.
textFrame :: String -> Effect Bytes
textFrame text = encode 0x1 (Bytes.fromString text)

pongFrame :: Bytes -> Effect Bytes
pongFrame payload = encode 0xA payload

closeFrame :: Int -> String -> Effect Bytes
closeFrame code reason =
  encode 0x8 (Bytes.append (Bytes.uint16BE code) (Bytes.fromString reason))

encode :: Int -> Bytes -> Effect Bytes
encode opcode payload = do
  key <- Sys.randomBytes 4
  let
    length = Bytes.size payload
    first = Bytes.singleByte (bitOr 0x80 opcode)
    header =
      if length < 126 then
        Bytes.append first (Bytes.singleByte (bitOr 0x80 length))
      else if length < 65536 then
        Bytes.append (Bytes.append first (Bytes.singleByte (bitOr 0x80 126)))
          (Bytes.uint16BE length)
      else
        Bytes.append (Bytes.append first (Bytes.singleByte (bitOr 0x80 127)))
          (Bytes.uint64BE length)
  pure
    ( Bytes.append (Bytes.append header key)
        (Bytes.xorRepeating payload key)
    )

-- ---------------------------------------------------------------------------
-- Handshake
-- ---------------------------------------------------------------------------

-- | Perform the opening handshake on an already connected socket.
-- |
-- | Returns any bytes that arrived after the response head; the server may
-- | legally start sending frames in the same packet, and dropping those bytes
-- | would lose the first Convex transition.
handshake
  :: Socket
  -> String
  -> String
  -> List Header
  -> Int
  -> Effect (Either String Bytes)
handshake socket authority path headers deadline = do
  keyBytes <- Sys.randomBytes 16
  let
    key = Bytes.base64Encode keyBytes
    fixed = Cons ("GET " <> path <> " HTTP/1.1")
      ( Cons ("host: " <> authority)
          ( Cons "upgrade: websocket"
              ( Cons "connection: Upgrade"
                  ( Cons ("sec-websocket-key: " <> key)
                      (listSingleton "sec-websocket-version: 13")
                  )
              )
          )
      )
    rendered = listMap (\(Tuple name value) -> name <> ": " <> value) headers
    request = stringJoin (listAppend fixed rendered) "\r\n" <> "\r\n\r\n"
  timeLeft <- Sys.remainingMs deadline
  written <- Sys.send socket (Bytes.fromString request) timeLeft
  case written of
    Left reason -> pure (Left reason)
    Right _ -> do
      -- The upgrade response is an ordinary HTTP head, so it is read and
      -- parsed by the HTTP client rather than by a second parser here.
      headRead <- Http.readHead socket Bytes.empty deadline
      case headRead of
        Left reason -> pure (Left ("WebSocket upgrade: " <> reason))
        Right (Tuple raw leftover) -> case validateUpgrade raw key of
          Left reason -> pure (Left reason)
          Right _ -> pure (Right leftover)

-- | Validate the response. The accept header proves the peer processed this
-- | client's key rather than replaying a cached upgrade, and an unrequested
-- | extension or subprotocol is rejected because this client cannot honour one.
validateUpgrade :: Bytes -> String -> Either String Unit
validateUpgrade raw key = case Http.parseHead raw of
  Left reason -> Left ("WebSocket upgrade: " <> reason)
  Right head ->
    if head.status /= 101 then Left "WebSocket upgrade did not return HTTP 101"
    else case Http.header head "upgrade" of
      Nothing -> Left "WebSocket Upgrade token is missing"
      Just upgrade ->
        if not (hasToken upgrade "websocket") then
          Left "WebSocket Upgrade token is missing"
        else case Http.header head "connection" of
          Nothing -> Left "WebSocket Connection token is missing"
          Just connection ->
            if not (hasToken connection "upgrade") then
              Left "WebSocket Connection token is missing"
            else case Http.header head "sec-websocket-accept" of
              Nothing -> Left "WebSocket upgrade has no accept header"
              Just accept ->
                if accept /= expectedAccept key then
                  Left "WebSocket accept header does not match the key"
                else if isJust (Http.header head "sec-websocket-extensions") then
                  Left "WebSocket selected an unrequested extension"
                else if isJust (Http.header head "sec-websocket-protocol") then
                  Left "WebSocket selected an unrequested subprotocol"
                else Right unit

-- | base64(sha1(key <> GUID)), the value RFC 6455 requires the server to echo.
expectedAccept :: String -> String
expectedAccept key =
  Bytes.base64Encode (Bytes.sha1 (Bytes.fromString (key <> handshakeGuid)))

hasToken :: String -> String -> Boolean
hasToken value token =
  listAny (\part -> stringLowercase (stringTrim part) == token)
    (stringSplit value ",")
