||| Deadline-bounded byte transport.
|||
||| Every read and write in the client takes an absolute deadline in the shim's
||| monotonic milliseconds. The deadline is computed once, before the first
||| byte moves, and is never extended by progress. That is what makes a peer
||| that dribbles one byte at a time, or a reader that has stopped consuming,
||| bounded rather than merely slow.
|||
||| A connection can be an ordinary socket, an OpenSSL stream, or a pair of raw
||| descriptors such as the adapter's stdin and stdout. Unifying them here means
||| the protocol code above never branches on transport.
module Convex.Net

import Data.IORef
import Data.List
import Data.String

import Convex.Prim

||| Where a deployment lives, split out of its URL once at client construction.
public export
record Endpoint where
  constructor MkEndpoint
  secure : Bool
  host : String
  port : Int
  path : String

||| A bounded byte transport with its own read buffer.
|||
||| `stream` is the shim stream handle, or a negative value when the connection
||| is a raw descriptor pair. `readFd` and `writeFd` differ only in that raw
||| case, which is how stdin and stdout become one connection.
export
record Connection where
  constructor MkConnection
  stream : Int
  readFd : Int
  writeFd : Int
  inbox : Int
  inboxCapacity : Int
  readStart : IORef Int
  readEnd : IORef Int
  closed : IORef Bool

export
connectionReadFd : Connection -> Int
connectionReadFd = readFd

export
connectionWriteFd : Connection -> Int
connectionWriteFd = writeFd

||| Record field projections live in an implicit namespace that stays
||| private regardless of the record's own `export` modifier, so Convex.Ws
||| needs this explicit accessor to read a connection's inbox buffer handle
||| directly (for its own byte-level WebSocket frame decoding).
export
connectionInbox : Connection -> Int
connectionInbox = inbox

--------------------------------------------------------------------------------
-- URLs
--------------------------------------------------------------------------------

-- `prefix` is a reserved word in Idris2 (prefix operator fixity
-- declarations), so the parameter below is named `pathPrefix` instead.
dropPrefix : String -> String -> Maybe String
dropPrefix pathPrefix text =
  if isPrefixOf pathPrefix text
     then Just (substr (length pathPrefix) (length text) text)
     else Nothing

digitsOnly : String -> Bool
digitsOnly text =
  let characters = unpack text in
  not (null characters) && all (\c => c >= '0' && c <= '9') characters

||| Split a Convex deployment URL. Only `http` and `https` appear in the
||| manifest and the verifier; `ws` and `wss` are derived from them rather than
||| configured separately, so a client cannot end up pointing HTTP and Live at
||| different deployments.
export
parseEndpoint : String -> Either String Endpoint
parseEndpoint url =
  case classify of
       Nothing => Left "deployment URL must start with http:// or https://"
       Just (secure', rest) =>
         let (authority, path') = split rest
             (hostText, portText) = splitPort authority in
         if hostText == ""
            then Left "deployment URL has an empty host"
            else if portText == ""
                    then Right (MkEndpoint secure' hostText
                                           (if secure' then 443 else 80) path')
                    else if not (digitsOnly portText)
                            then Left "deployment URL port is not numeric"
                            else let value = the Int (cast portText) in
                                 if value <= 0 || value > 65535
                                    then Left "deployment URL port is out of range"
                                    else Right (MkEndpoint secure' hostText value path')
  where
    classify : Maybe (Bool, String)
    classify =
      case dropPrefix "https://" url of
           Just rest => Just (True, rest)
           Nothing => map (\rest => (False, rest)) (dropPrefix "http://" url)

    split : String -> (String, String)
    split rest =
      case span (/= '/') rest of
           (authority, "") => (authority, "/")
           (authority, path') => (authority, path')

    -- Only a host:port authority is supported. Bracketed IPv6 literals are out
    -- of scope for the demonstration deployments and are rejected above by the
    -- numeric port check rather than being half-parsed.
    splitPort : String -> (String, String)
    splitPort authority =
      case span (/= ':') authority of
           (hostText, "") => (hostText, "")
           (hostText, rest) => (hostText, substr 1 (length rest) rest)

--------------------------------------------------------------------------------
-- Deadlines
--------------------------------------------------------------------------------

||| An absolute deadline `budget` milliseconds from now.
export
deadlineIn : Int -> IO Int
deadlineIn budget =
  do now <- nowMs
     pure (now + budget)

export
expired : Int -> IO Bool
expired deadline =
  do now <- nowMs
     pure (now >= deadline)

||| Sleep without holding a descriptor. An empty poll set is the only timer the
||| client needs, and it keeps every wait in the same monotonic clock as the
||| deadlines.
export
sleepMs : Int -> IO ()
sleepMs milliseconds =
  if milliseconds <= 0
     then pure ()
     else do pollsetReset
             ignore $ pollsetWait milliseconds

||| Wait for readiness on one descriptor, never past the deadline. Returns the
||| readiness mask, or 0 when the deadline arrived first.
export covering
awaitDescriptor : Int -> Int -> Int -> IO Int
awaitDescriptor descriptor interest deadline =
  do now <- nowMs
     if now >= deadline
        then pure 0
        else do pollsetReset
                pollsetAdd descriptor interest
                ready <- pollsetWait (deadline - now)
                if ready < 0
                   then pure 0
                   else if ready == 0
                           then awaitDescriptor descriptor interest deadline
                           else pollsetReady descriptor

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

newConnection : Int -> Int -> Int -> Int -> IO (Either String Connection)
newConnection streamHandle readDescriptor writeDescriptor capacity =
  do buffer <- bufNew capacity
     if buffer < 0
        then pure (Left "could not allocate a read buffer")
        else do start <- newIORef 0
                end <- newIORef 0
                shut <- newIORef False
                pure (Right (MkConnection streamHandle readDescriptor writeDescriptor
                                          buffer capacity start end shut))

covering
completeHandshake : Int -> Int -> Int -> IO (Either String ())
completeHandshake streamHandle descriptor deadline =
  do status <- streamHandshake streamHandle
     if status == 0
        then pure (Right ())
        else if status < 0
                then do detail <- lastError
                        pure (Left ("TLS handshake failed: " ++ detail))
                else do let interest = if status == 1 then pollRead else pollWrite
                        ready <- awaitDescriptor descriptor interest deadline
                        if ready == 0
                           then pure (Left "TLS handshake exceeded its deadline")
                           else completeHandshake streamHandle descriptor deadline

||| Open a client connection, completing the TLS handshake inside the same
||| deadline as the TCP connect so a stalled server cannot hold the client open.
export covering
openConnection : Endpoint -> (caFile : String) -> (deadline : Int)
              -> (inboxSize : Int) -> IO (Either String Connection)
openConnection endpoint caFile deadline inboxSize =
  do descriptor <- tcpConnect (host endpoint) (port endpoint) deadline
     if descriptor < 0
        then do detail <- lastError
                pure (Left ("could not connect to " ++ host endpoint ++ ": " ++ detail))
        else do streamHandle <- if secure endpoint
                                   then streamTlsClient descriptor (host endpoint) caFile
                                   else streamPlain descriptor
                if streamHandle < 0
                   then do detail <- lastError
                           closeFd descriptor
                           pure (Left ("could not start a stream: " ++ detail))
                   else do shaken <- completeHandshake streamHandle descriptor deadline
                           case shaken of
                                Left problem => do streamFree streamHandle
                                                   pure (Left problem)
                                Right () =>
                                  do result <- newConnection streamHandle descriptor
                                                             descriptor inboxSize
                                     case result of
                                          Left problem => do streamFree streamHandle
                                                             pure (Left problem)
                                          Right connection => pure (Right connection)

||| Wrap an accepted descriptor. Test fixtures use this to serve a real peer.
export covering
acceptConnection : (listener : Int) -> (certificateFile : String)
                -> (keyFile : String) -> (deadline : Int) -> (inboxSize : Int)
                -> IO (Either String Connection)
acceptConnection listener certificateFile keyFile deadline inboxSize =
  do descriptor <- tcpAccept listener deadline
     if descriptor < 0
        then do detail <- lastError
                pure (Left ("accept failed: " ++ detail))
        else do streamHandle <- if certificateFile == ""
                                   then streamPlain descriptor
                                   else streamTlsServer descriptor certificateFile keyFile
                if streamHandle < 0
                   then do detail <- lastError
                           closeFd descriptor
                           pure (Left ("could not start a server stream: " ++ detail))
                   else do shaken <- completeHandshake streamHandle descriptor deadline
                           case shaken of
                                Left problem => do streamFree streamHandle
                                                   pure (Left problem)
                                Right () =>
                                  newConnection streamHandle descriptor descriptor
                                                inboxSize

||| Wrap a pair of raw descriptors, which is how the adapter treats stdin and
||| stdout when the controller does not provide a TCP address.
export
rawConnection : (readDescriptor : Int) -> (writeDescriptor : Int)
             -> (inboxSize : Int) -> IO (Either String Connection)
rawConnection readDescriptor writeDescriptor inboxSize =
  do ignore $ setNonBlocking readDescriptor
     ignore $ setNonBlocking writeDescriptor
     newConnection (-1) readDescriptor writeDescriptor inboxSize

export
closeConnection : Connection -> IO ()
closeConnection connection =
  do alreadyClosed <- readIORef (closed connection)
     if alreadyClosed
        then pure ()
        else do writeIORef (closed connection) True
                if stream connection >= 0
                   then streamFree (stream connection)
                   else pure ()
                bufFree (inbox connection)

||| Send a TLS close_notify, or shut down the write side of a plain socket,
||| without waiting for the peer to answer.
export
shutdownConnection : Connection -> IO ()
shutdownConnection connection =
  if stream connection >= 0
     then ignore $ streamShutdown (stream connection)
     else shutdownWrite (writeFd connection)

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

||| Bytes OpenSSL has decrypted but not yet handed over. Poll cannot see these,
||| so an owner loop must consult them before it decides to wait.
export
pendingDecrypted : Connection -> IO Int
pendingDecrypted connection =
  if stream connection >= 0
     then streamPending (stream connection)
     else pure (the Int 0)

export
buffered : Connection -> IO Int
buffered connection =
  do start <- readIORef (readStart connection)
     end <- readIORef (readEnd connection)
     pure (end - start)

||| Move any unread bytes to the front so a large frame can be assembled even
||| when the previous message ended mid-buffer.
compact : Connection -> IO ()
compact connection =
  do start <- readIORef (readStart connection)
     end <- readIORef (readEnd connection)
     if start == 0
        then pure ()
        else do ignore $ bufCopy (inbox connection) 0 (inbox connection) start (end - start)
                writeIORef (readStart connection) 0
                writeIORef (readEnd connection) (end - start)

||| One non-blocking refill. Returns the number of bytes added, 0 when the
||| transport would block, -1 at end of stream, and -2 on a transport failure.
export
refill : Connection -> IO Int
refill connection =
  do compact connection
     end <- readIORef (readEnd connection)
     let room = inboxCapacity connection - end
     if room <= 0
        then pure 0
        else do received <- if stream connection >= 0
                               then streamRead (stream connection) (inbox connection)
                                               end room
                               else fdRead (readFd connection) (inbox connection) end room
                if received > 0
                   then do writeIORef (readEnd connection) (end + received)
                           pure received
                   else if received == 0
                           then pure (-1)
                           else if received == ioWantRead || received == ioWantWrite
                                   then pure 0
                                   else pure (-2)

||| Refill at least once, waiting for readability but never past the deadline.
||| OpenSSL may already hold decrypted bytes that poll cannot see, so the
||| pending count is consulted before waiting.
export covering
refillBlocking : Connection -> Int -> IO (Either String Int)
refillBlocking connection deadline =
  do added <- refill connection
     if added > 0
        then pure (Right added)
        else if added == -1
                then pure (Left "the peer closed the connection")
                else if added == -2
                        then do detail <- lastError
                                pure (Left ("transport read failed: " ++ detail))
                        else do pending <- if stream connection >= 0
                                              then streamPending (stream connection)
                                              else pure (the Int 0)
                                if pending > 0
                                   then refillBlocking connection deadline
                                   else do
                                     ready <- awaitDescriptor (readFd connection) pollRead
                                                              deadline
                                     if ready == 0
                                        then pure (Left "read exceeded its deadline")
                                        else refillBlocking connection deadline

||| Ensure at least `count` bytes are buffered, returning the index of the first
||| of them.
export covering
demand : Connection -> Int -> Int -> IO (Either String Int)
demand connection count deadline =
  if count > inboxCapacity connection
     then pure (Left "message exceeds the connection read buffer")
     else do available <- buffered connection
             if available >= count
                then map Right (readIORef (readStart connection))
                else do added <- refillBlocking connection deadline
                        case added of
                             Left problem => pure (Left problem)
                             Right _ => demand connection count deadline

export
consume : Connection -> Int -> IO ()
consume connection count = modifyIORef (readStart connection) (+ count)

||| Move up to `count` already-buffered bytes into another buffer and consume
||| them. Never waits, so a caller that is draining a closing connection stays
||| in charge of its own deadline.
export
drainBuffered : Connection -> (destination : Int) -> (at : Int) -> (count : Int)
             -> IO Int
drainBuffered connection destination at count =
  do available <- buffered connection
     let takeCount = if available < count then available else count
     if takeCount <= 0
        then pure 0
        else do start <- readIORef (readStart connection)
                ignore $ bufCopy destination at (inbox connection) start takeCount
                consume connection takeCount
                pure takeCount

||| Read exactly `count` bytes into another buffer. The read buffer is refilled
||| as needed, and partial progress is preserved across refills so a fragmented
||| delivery never restarts at a false boundary.
export covering
readExact : Connection -> (destination : Int) -> (at : Int) -> (count : Int)
         -> (deadline : Int) -> IO (Either String ())
readExact connection destination at count deadline =
  if count <= 0
     then pure (Right ())
     else do available <- buffered connection
             if available <= 0
                then do added <- refillBlocking connection deadline
                        case added of
                             Left problem => pure (Left problem)
                             Right _ => readExact connection destination at count deadline
                else do start <- readIORef (readStart connection)
                        let takeCount = if available < count then available else count
                        ignore $ bufCopy destination at (inbox connection) start takeCount
                        consume connection takeCount
                        readExact connection destination (at + takeCount)
                                  (count - takeCount) deadline

||| Read one CRLF-terminated line, excluding the terminator. Used for HTTP and
||| WebSocket handshake headers, which are the only line-oriented traffic.
export covering
readLine : Connection -> (maximum : Int) -> (deadline : Int)
        -> IO (Either String String)
readLine connection maximum deadline = go 0
  where
    covering
    findNewline : Int -> Int -> Int -> IO Int
    findNewline start end index =
      if index >= end
         then pure (-1)
         else do value <- bufGet (inbox connection) index
                 if value == 10
                    then pure index
                    else findNewline start end (index + 1)

    covering
    go : Int -> IO (Either String String)
    go scanned =
      do start <- readIORef (readStart connection)
         end <- readIORef (readEnd connection)
         found <- findNewline start end (start + scanned)
         if found >= 0
            then do let hasReturn = found > start
                    lastByte <- if hasReturn
                                   then bufGet (inbox connection) (found - 1)
                                   else pure (the Int 0)
                    let stop = if lastByte == the Int 13 then found - 1 else found
                    text <- bufTakeText (inbox connection) start (stop - start)
                    consume connection (found - start + 1)
                    case text of
                         Nothing => pure (Left "header line was not valid UTF-8")
                         Just line => pure (Right line)
            else if end - start >= maximum
                    then pure (Left "header line exceeded its maximum length")
                    else do added <- refillBlocking connection deadline
                            case added of
                                 Left problem => pure (Left problem)
                                 Right _ => go (end - start)

||| Take one line if a whole one is already available, refilling only without
||| blocking. The adapter uses this so reading controller commands never stalls
||| the sync socket or the output queue.
|||
||| `Right Nothing` means "nothing yet, come back after polling".
export covering
tryReadLine : Connection -> (maximum : Int) -> IO (Either String (Maybe String))
tryReadLine connection maximum = scan
  where
    covering
    findNewline : Int -> Int -> Int -> IO Int
    findNewline start end index =
      if index >= end
         then pure (-1)
         else do value <- bufGet (inbox connection) index
                 if value == 10
                    then pure index
                    else findNewline start end (index + 1)

    -- Idris2 `where` blocks do not support forward references the way a
    -- `mutual` block does: a sibling must be declared above the point it is
    -- first called from. takeLine is defined here, before scan, because
    -- scan calls it. (It was also originally named `take'`, which the
    -- elaborator diffed against Prelude's `take` in its "Did you mean"
    -- suggestion; the new name avoids that ambiguity entirely.)
    covering
    takeLine : Int -> Int -> IO (Either String (Maybe String))
    takeLine start found =
      do lastByte <- if found > start
                        then bufGet (inbox connection) (found - 1)
                        else pure (the Int 0)
         let stop = if lastByte == the Int 13 then found - 1 else found
         text <- bufTakeText (inbox connection) start (stop - start)
         consume connection (found - start + 1)
         case text of
              Nothing => pure (Left "command line was not valid UTF-8")
              Just line => pure (Right (Just line))

    covering
    scan : IO (Either String (Maybe String))
    scan =
      do start <- readIORef (readStart connection)
         end <- readIORef (readEnd connection)
         found <- findNewline start end start
         if found >= 0
            then takeLine start found
            else if end - start >= maximum
                    then pure (Left "command line exceeded its maximum length")
                    else do added <- refill connection
                            if added > 0
                               then scan
                               else if added == -1
                                       then pure (Left "the controller closed the stream")
                                       else if added == -2
                                               then do detail <- lastError
                                                       pure (Left ("controller read failed: "
                                                                     ++ detail))
                                               else pure (Right Nothing)

--------------------------------------------------------------------------------
-- Writing
--------------------------------------------------------------------------------

||| Write every byte or fail. A stopped reader makes this return once the
||| deadline passes rather than blocking the process indefinitely.
export covering
writeAll : Connection -> (source : Int) -> (at : Int) -> (count : Int)
        -> (deadline : Int) -> IO (Either String ())
writeAll connection source at count deadline =
  if count <= 0
     then pure (Right ())
     else do sent <- if stream connection >= 0
                        then streamWrite (stream connection) source at count
                        else fdWrite (writeFd connection) source at count
             if sent > 0
                then writeAll connection source (at + sent) (count - sent) deadline
                else if sent == ioWantRead || sent == ioWantWrite
                        then do let interest = if sent == ioWantRead
                                                  then pollRead
                                                  else pollWrite
                                ready <- awaitDescriptor (writeFd connection) interest
                                                         deadline
                                if ready == 0
                                   then pure (Left "write exceeded its deadline")
                                   else writeAll connection source at count deadline
                        else do detail <- lastError
                                pure (Left ("transport write failed: " ++ detail))

||| Write a whole string. Staging it in a scratch buffer keeps the encoded byte
||| count exact rather than assuming one byte per character.
export covering
writeText : Connection -> String -> (deadline : Int) -> IO (Either String ())
writeText connection text deadline =
  do size <- textSize text
     scratch <- bufNew (size + 1)
     if scratch < 0
        then pure (Left "could not allocate a write buffer")
        else do ignore $ bufPutText scratch 0 text
                result <- writeAll connection scratch 0 size deadline
                bufFree scratch
                pure result
