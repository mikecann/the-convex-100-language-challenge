||| RFC 6455 framing for the Convex sync socket.
|||
||| The framing is written out here rather than delegated, because the Live
||| acceptance criteria are mostly framing criteria: fragmented UTF-8 must
||| decode correctly, control frames must be answered while a message is still
||| being assembled, oversized frames must be refused rather than buffered, and
||| a read that stops after any byte of a frame has been consumed must abandon
||| the connection rather than resynchronise on a false boundary.
module Convex.Ws

import Data.Bits
import Data.IORef
import Data.List
import Data.String

import Convex.Codec
import Convex.Net
import Convex.Prim

||| The RFC 6455 handshake GUID, fixed by the specification.
handshakeGuid : String
handshakeGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

||| The largest assembled message the client accepts. Convex transitions for
||| the demonstration schema are a few kilobytes; the bound keeps a hostile or
||| drifting peer from growing the process.
export
maximumMessageBytes : Int
maximumMessageBytes = 2 * 1024 * 1024

||| The largest frame payload the client will send.
export
maximumSendBytes : Int
maximumSendBytes = 256 * 1024

readBufferBytes : Int
readBufferBytes = 65536

||| What a completed read produced.
public export
data WsEvent
  = ||| A whole text message, already validated as UTF-8.
    WsMessage String
  | ||| Nothing for the caller yet: a control frame was answered, or a
    ||| fragment was appended. The owner loop simply reads again.
    WsAgain
  | ||| The peer sent a close frame with this code and reason.
    WsPeerClose Int String

||| A live WebSocket. `poisoned` records that part of a frame was consumed and
||| the byte stream can no longer be trusted, which forces the owner to retire
||| the connection instead of resuming at an arbitrary offset.
export
record WsConnection where
  constructor MkWsConnection
  link : Connection
  assembly : Int
  assemblyLength : IORef Int
  assembling : IORef Bool
  assemblyOpcode : IORef Int
  control : Int
  outbound : Int
  poisoned : IORef Bool
  wsFrameBudget : Int

export
wsLink : WsConnection -> Connection
wsLink = link

export
wsPoisoned : WsConnection -> IO Bool
wsPoisoned socket = readIORef (poisoned socket)

||| Bytes that are already in hand, counting both the read buffer and anything
||| OpenSSL decrypted into its own. The owner loop services these before it
||| waits, or a message delivered inside an earlier TLS record would sit unread.
export
wsReadable : WsConnection -> IO Int
wsReadable socket =
  do inner <- buffered (link socket)
     decrypted <- pendingDecrypted (link socket)
     pure (inner + decrypted)

xorByte : Int -> Int -> Int
xorByte left right = cast (xor (the Bits8 (cast left)) (the Bits8 (cast right)))

nthByte : List Int -> Int -> Int
nthByte bytes index =
  case drop (cast index) bytes of
       (value :: _) => value
       [] => 0

--------------------------------------------------------------------------------
-- Handshake
--------------------------------------------------------------------------------

||| The `Sec-WebSocket-Accept` value the server must return for a given key.
export covering
expectedAccept : String -> String
expectedAccept key =
  base64Encode (sha1 (map ord (unpack (key ++ handshakeGuid))))

headerName : String -> String
headerName line = toLower (fst (span (/= ':') line))

headerValue : String -> String
headerValue line =
  let rest = snd (span (/= ':') line) in
  if rest == "" then "" else trim (substr 1 (length rest) rest)

covering
readHandshakeHeaders : Connection -> String -> Int -> Int -> Bool -> Bool
                    -> IO (Either String ())
readHandshakeHeaders connection accept deadline remaining sawAccept sawUpgrade =
  if remaining <= 0
     then pure (Left "WebSocket handshake has too many headers")
     else do line <- readLine connection 8192 deadline
             case line of
                  Left problem => pure (Left problem)
                  Right "" =>
                    pure (if sawAccept && sawUpgrade
                             then Right ()
                             else Left "WebSocket handshake is missing required headers")
                  Right text => inspect text
  where
    covering
    inspect : String -> IO (Either String ())
    inspect text =
      do let name = headerName text
         let value = headerValue text
         if name == "sec-websocket-accept"
            then if value == accept
                    then readHandshakeHeaders connection accept deadline (remaining - 1)
                                              True sawUpgrade
                    else pure (Left "WebSocket accept key did not match")
            else if name == "upgrade"
                    then if toLower value == "websocket"
                            then readHandshakeHeaders connection accept deadline
                                                      (remaining - 1) sawAccept True
                            else pure (Left "WebSocket upgrade header is wrong")
                    else readHandshakeHeaders connection accept deadline (remaining - 1)
                                              sawAccept sawUpgrade

||| Open a Convex sync socket. The TCP connect, TLS handshake, and HTTP upgrade
||| all share one absolute deadline so a half-open peer cannot stall the client.
export covering
wsConnect : Endpoint -> (caFile : String) -> (clientVersion : String)
         -> (connectBudgetMs : Int) -> (frameBudgetMs : Int)
         -> IO (Either String WsConnection)
wsConnect target caFile clientVersion connectBudgetMs frameBudget =
  do deadline <- deadlineIn connectBudgetMs
     nonce <- randomByteList 16
     case nonce of
          Nothing => pure (Left "could not generate a WebSocket key")
          Just bytes => negotiate deadline (base64Encode bytes)
  where
    request : String -> String
    request key =
      "GET " ++ path target ++ " HTTP/1.1\r\n"
        ++ "Host: " ++ host target ++ "\r\n"
        ++ "Upgrade: websocket\r\n"
        ++ "Connection: Upgrade\r\n"
        ++ "Sec-WebSocket-Key: " ++ key ++ "\r\n"
        ++ "Sec-WebSocket-Version: 13\r\n"
        ++ "Convex-Client: " ++ clientVersion ++ "\r\n\r\n"

    covering
    wrap : Connection -> IO (Either String WsConnection)
    wrap connection =
      do assemblyBuffer <- bufNew (maximumMessageBytes + 8)
         controlBuffer <- bufNew 256
         outboundBuffer <- bufNew (maximumSendBytes + 32)
         if assemblyBuffer < 0 || controlBuffer < 0 || outboundBuffer < 0
            then do closeConnection connection
                    pure (Left "could not allocate WebSocket buffers")
            else do assembled <- newIORef 0
                    inProgress <- newIORef False
                    opcode <- newIORef 0
                    broken <- newIORef False
                    pure (Right (MkWsConnection connection assemblyBuffer assembled
                                                inProgress opcode controlBuffer
                                                outboundBuffer broken frameBudget))

    -- Idris2 `where` blocks require a sibling to be declared above the
    -- point it is first called from (unlike a `mutual` block). `await` is
    -- defined here, before `upgrade`, because `upgrade` calls it.
    covering
    await : Connection -> String -> Int -> IO (Either String WsConnection)
    await connection key deadline =
      do statusLine <- readLine connection 8192 deadline
         case statusLine of
              Left problem => do closeConnection connection
                                 pure (Left problem)
              Right line =>
                if not (isPrefixOf "HTTP/1.1 101 " line)
                   then do closeConnection connection
                           pure (Left "WebSocket upgrade was rejected")
                   else do headers <- readHandshakeHeaders connection
                                        (expectedAccept key) deadline 64 False False
                           case headers of
                                Left problem => do closeConnection connection
                                                   pure (Left problem)
                                Right () => wrap connection

    covering
    upgrade : Connection -> String -> Int -> IO (Either String WsConnection)
    upgrade connection key deadline =
      do sent <- writeText connection (request key) deadline
         case sent of
              Left problem => do closeConnection connection
                                 pure (Left problem)
              Right () => await connection key deadline

    covering
    negotiate : Int -> String -> IO (Either String WsConnection)
    negotiate deadline key =
      do opened <- openConnection target caFile deadline readBufferBytes
         case opened of
              Left problem => pure (Left problem)
              Right connection => upgrade connection key deadline

--------------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------------

covering
pow256 : Int -> Int
pow256 index = if index <= 0 then 1 else 256 * pow256 (index - 1)

||| Build and send one masked frame. Every client frame must be masked, with a
||| fresh random key per frame rather than a reused constant.
export covering
sendFrame : WsConnection -> (opcode : Int) -> (source : Int) -> (at : Int)
         -> (count : Int) -> IO (Either String ())
sendFrame socket opcode source at count =
  if count < 0 || count > maximumSendBytes
     then pure (Left "WebSocket frame exceeds the client's send budget")
     else do mask <- randomByteList 4
             case mask of
                  Nothing => pure (Left "could not generate a WebSocket mask")
                  Just keyBytes => assemble keyBytes
  where
    target : Int
    target = outbound socket

    covering
    writeBigLength : Int -> Int -> IO ()
    writeBigLength position index =
      if index < 0
         then pure ()
         else do ignore $ bufSet target (position + (7 - index))
                            (mod (div count (pow256 index)) 256)
                 writeBigLength position (index - 1)

    covering
    writeLength : Int -> IO Int
    writeLength position =
      if count < 126
         then do ignore $ bufSet target position (128 + count)
                 pure (position + 1)
         else if count < 65536
                 then do ignore $ bufSet target position 254
                         ignore $ bufSet target (position + 1) (div count 256)
                         ignore $ bufSet target (position + 2) (mod count 256)
                         pure (position + 3)
                 else do ignore $ bufSet target position 255
                         writeBigLength (position + 1) 7
                         pure (position + 9)

    covering
    writeMask : List Int -> Int -> Int -> IO ()
    writeMask keyBytes position index =
      if index >= 4
         then pure ()
         else do ignore $ bufSet target (position + index) (nthByte keyBytes index)
                 writeMask keyBytes position (index + 1)

    covering
    maskPayload : List Int -> Int -> Int -> IO ()
    maskPayload keyBytes position index =
      if index >= count
         then pure ()
         else do value <- bufGet source (at + index)
                 ignore $ bufSet target (position + index)
                            (xorByte value (nthByte keyBytes (mod index 4)))
                 maskPayload keyBytes position (index + 1)

    covering
    assemble : List Int -> IO (Either String ())
    assemble keyBytes =
      do ignore $ bufSet target 0 (128 + opcode)
         afterLength <- writeLength 1
         writeMask keyBytes afterLength 0
         maskPayload keyBytes (afterLength + 4) 0
         deadline <- deadlineIn (wsFrameBudget socket)
         writeAll (link socket) target 0 (afterLength + 4 + count) deadline

||| Send a text message. Convex sync frames are always text.
export covering
sendText : WsConnection -> String -> IO (Either String ())
sendText socket text =
  do size <- textSize text
     if size > maximumSendBytes
        then pure (Left "WebSocket message exceeds the client's send budget")
        else do scratch <- bufNew (size + 8)
                if scratch < 0
                   then pure (Left "could not allocate a WebSocket send buffer")
                   else do ignore $ bufPutText scratch 0 text
                           result <- sendFrame socket 1 scratch 0 size
                           bufFree scratch
                           pure result

||| Send a close frame. The write shares the ordinary frame deadline, so close
||| stays bounded against an idle, chatty, or stalled peer.
export covering
sendClose : WsConnection -> Int -> IO (Either String ())
sendClose socket code =
  do scratch <- bufNew 8
     if scratch < 0
        then pure (Left "could not allocate a WebSocket close buffer")
        else do ignore $ bufSet scratch 0 (div code 256)
                ignore $ bufSet scratch 1 (mod code 256)
                result <- sendFrame socket 8 scratch 0 2
                bufFree scratch
                pure result

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

record FrameHeader where
  constructor MkFrameHeader
  final : Bool
  opcode : Int
  masked : Bool
  payloadLength : Int
  headerSize : Int

closeCodeValid : Int -> Bool
closeCodeValid code =
  elem code [1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011]
    || (code >= 3000 && code <= 4999)

||| Read the frame header without consuming anything until all of it has
||| arrived, so a deadline that expires here leaves the stream exactly where it
||| was and the connection stays usable.
covering
peekHeader : WsConnection -> Int -> IO (Either String FrameHeader)
peekHeader socket deadline =
  do first <- demand (link socket) 2 deadline
     case first of
          Left problem => pure (Left problem)
          Right start => sized start
  where
    covering
    accumulate : Int -> Int -> Int -> Int -> IO (Either String Int)
    accumulate at index remaining acc =
      if index >= remaining
         then pure (Right acc)
         else do value <- bufGet (connectionInbox (link socket)) (at + index)
                 -- A 64-bit length whose top four bytes are set could overflow
                 -- the accumulator, and is far past the byte budget anyway.
                 if remaining == 8 && index < 4 && value /= 0
                    then pure (Left "WebSocket frame length is absurd")
                    else accumulate at (index + 1) remaining (acc * 256 + value)

    -- minimal is defined before build, which calls it, per the where-block
    -- ordering rule noted above (await/upgrade).
    minimal : Int -> Int -> Int -> Int -> Int -> IO (Either String FrameHeader)
    minimal byte0 byte1 marker extra size =
      if marker == 126 && size < 126
         then pure (Left "WebSocket length is not minimal")
         else if marker == 127 && size < 65536
                 then pure (Left "WebSocket length is not minimal")
                 else pure (Right (MkFrameHeader (byte0 >= 128) (mod byte0 16)
                                                 (byte1 >= 128) size (2 + extra)))

    covering
    build : Int -> Int -> Int -> Int -> Int -> IO (Either String FrameHeader)
    build at byte0 byte1 marker extra =
      do let reserved = mod (div byte0 16) 8
         if reserved /= 0
            then pure (Left "WebSocket frame sets a reserved bit")
            else do measured <- if extra == 0
                                   then pure (Right marker)
                                   else accumulate (at + 2) 0 extra 0
                    case measured of
                         Left problem => pure (Left problem)
                         Right size => minimal byte0 byte1 marker extra size

    covering
    sized : Int -> IO (Either String FrameHeader)
    sized start =
      do byte0 <- bufGet (connectionInbox (link socket)) start
         byte1 <- bufGet (connectionInbox (link socket)) (start + 1)
         let marker = mod byte1 128
         -- All three branches are bare numeral literals, which Idris2
         -- would otherwise default to Integer; `demand` below needs Int.
         let extra = the Int (if marker == 126 then 2 else if marker == 127 then 8 else 0)
         whole <- demand (link socket) (2 + extra) deadline
         case whole of
              Left problem => pure (Left problem)
              Right at => build at byte0 byte1 marker extra

||| Read one event: a whole assembled message, an internally handled control
||| frame, or the peer's close. A failure reports whether the parser is
||| poisoned, meaning part of a frame was consumed and the connection must be
||| retired rather than reused.
export covering
readEvent : WsConnection -> IO (Either (Bool, String) WsEvent)
readEvent socket =
  do broken <- readIORef (poisoned socket)
     if broken
        then pure (Left (True, "WebSocket parser state was abandoned"))
        else do deadline <- deadlineIn (wsFrameBudget socket)
                header <- peekHeader socket deadline
                case header of
                     Left problem => pure (Left (False, problem))
                     Right frame => validate frame deadline
  where
    poison : String -> IO (Either (Bool, String) WsEvent)
    poison reason =
      do writeIORef (poisoned socket) True
         pure (Left (True, reason))

    -- `total` is a reserved word in Idris2 (totality annotations), so the
    -- assembled message length threaded through here is named
    -- `assembledLength` instead.
    covering
    finish : Int -> IO (Either (Bool, String) WsEvent)
    finish assembledLength =
      do kind <- readIORef (assemblyOpcode socket)
         writeIORef (assembling socket) False
         writeIORef (assemblyLength socket) 0
         if kind /= 1
            then poison "WebSocket binary messages are outside the pinned profile"
            else do text <- bufTakeText (assembly socket) 0 assembledLength
                    case text of
                         Nothing => poison "WebSocket text message is not UTF-8"
                         Just message => pure (Right (WsMessage message))

    covering
    collect : FrameHeader -> Int -> Int -> Bool -> IO (Either (Bool, String) WsEvent)
    collect frame deadline written continuation =
      do when (not continuation) (writeIORef (assemblyOpcode socket) (opcode frame))
         writeIORef (assembling socket) True
         copied <- readExact (link socket) (assembly socket) written
                             (payloadLength frame) deadline
         case copied of
              Left problem => poison problem
              Right () =>
                do let assembledLength = written + payloadLength frame
                   writeIORef (assemblyLength socket) assembledLength
                   if final frame
                      then finish assembledLength
                      else pure (Right WsAgain)

    covering
    handleData : FrameHeader -> Int -> IO (Either (Bool, String) WsEvent)
    handleData frame deadline =
      do inProgress <- readIORef (assembling socket)
         written <- readIORef (assemblyLength socket)
         let continuation = opcode frame == 0
         if continuation && not inProgress
            then poison "WebSocket continuation without a started message"
            else if not continuation && inProgress
                    then poison "WebSocket started a message inside another"
                    else if written + payloadLength frame > maximumMessageBytes
                            then poison "WebSocket message exceeds the byte budget"
                            else collect frame deadline written continuation

    -- interpretClose is defined here, before handleClose, because
    -- handleClose calls it and Idris2 `where` blocks need the callee above
    -- the call site (see the `await`/`upgrade` note above).
    covering
    interpretClose : Int -> IO (Either (Bool, String) WsEvent)
    interpretClose size =
      if size == 0
         then pure (Right (WsPeerClose 1005 ""))
         else if size == 1
                 then poison "WebSocket close payload is one byte"
                 else do high <- bufGet (control socket) 0
                         low <- bufGet (control socket) 1
                         let code = high * 256 + low
                         reason <- bufTakeText (control socket) 2 (size - 2)
                         case reason of
                              Nothing => poison "WebSocket close reason is not UTF-8"
                              Just text =>
                                if closeCodeValid code
                                   then pure (Right (WsPeerClose code text))
                                   else poison "WebSocket close code is invalid"

    covering
    handleClose : FrameHeader -> Int -> IO (Either (Bool, String) WsEvent)
    handleClose frame deadline =
      do copied <- readExact (link socket) (control socket) 0 (payloadLength frame)
                             deadline
         case copied of
              Left problem => poison problem
              Right () => interpretClose (payloadLength frame)

    covering
    handlePing : FrameHeader -> Int -> IO (Either (Bool, String) WsEvent)
    handlePing frame deadline =
      do copied <- readExact (link socket) (control socket) 0 (payloadLength frame)
                             deadline
         case copied of
              Left problem => poison problem
              Right () =>
                do sent <- sendFrame socket 10 (control socket) 0 (payloadLength frame)
                   case sent of
                        Left problem => poison problem
                        Right () => pure (Right WsAgain)

    covering
    handlePong : FrameHeader -> Int -> IO (Either (Bool, String) WsEvent)
    handlePong frame deadline =
      do copied <- readExact (link socket) (control socket) 0 (payloadLength frame)
                             deadline
         case copied of
              Left problem => poison problem
              Right () => pure (Right WsAgain)

    covering
    controlFrame : FrameHeader -> Int -> IO (Either (Bool, String) WsEvent)
    controlFrame frame deadline =
      if not (final frame) || payloadLength frame > 125
         then pure (Left (False, "WebSocket control frame is malformed"))
         else do consume (link socket) (headerSize frame)
                 if opcode frame == 8
                    then handleClose frame deadline
                    else if opcode frame == 9
                            then handlePing frame deadline
                            else if opcode frame == 10
                                    then handlePong frame deadline
                                    else poison "WebSocket control opcode is unknown"

    covering
    validate : FrameHeader -> Int -> IO (Either (Bool, String) WsEvent)
    validate frame deadline =
      if masked frame
         then pure (Left (False, "server WebSocket frames must not be masked"))
         else if payloadLength frame > maximumMessageBytes
                 then pure (Left (False, "WebSocket frame exceeds the byte budget"))
                 else if opcode frame >= 8
                         then controlFrame frame deadline
                         else if opcode frame > 2
                                 then pure (Left (False,
                                             "WebSocket reserved opcode is not supported"))
                                 else do consume (link socket) (headerSize frame)
                                         handleData frame deadline

||| Release the descriptor and the buffers without writing anything.
|||
||| A connection being retired after a failure, or dropped by the adapter-only
||| disconnect hook, has nothing to say to its peer. Skipping the courtesy close
||| frame keeps retirement immediate instead of spending the frame budget on a
||| peer that may not be reading.
export covering
wsAbandon : WsConnection -> IO ()
wsAbandon socket =
  do writeIORef (poisoned socket) True
     shutdownConnection (link socket)
     closeConnection (link socket)
     bufFree (assembly socket)
     bufFree (control socket)
     bufFree (outbound socket)

||| Close the socket cleanly. The close frame is best effort; the descriptor and
||| the buffers are always released so a stalled peer cannot leak them.
export covering
wsClose : WsConnection -> Int -> IO ()
wsClose socket code =
  do broken <- readIORef (poisoned socket)
     when (not broken) (ignore (sendClose socket code))
     wsAbandon socket
