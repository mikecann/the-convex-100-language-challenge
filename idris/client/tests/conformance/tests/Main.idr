||| Tests for the NDJSON conformance adapter.
|||
||| Three things are covered here that shared conformance would otherwise be
||| the first to notice: strict command validation, the exact serialised shape
||| of every event, and the bounded output path with a reader that has stopped.
||| The last two phases run the real adapter over both of its transports.
module Main

import Data.IORef
import Data.List
import Data.Maybe
import Data.String
import System
import System.File

import Conformance.Adapter
import Convex
import Convex.Build
import Convex.Prim

check : IORef Int -> String -> Bool -> IO ()
check failures label ok =
  if ok
     then putStrLn ("ok   " ++ label)
     else do modifyIORef failures (+ 1)
             ignore $ fPutStrLn stderr ("FAIL " ++ label)
             putStrLn ("FAIL " ++ label)

--------------------------------------------------------------------------------
-- Command validation
--------------------------------------------------------------------------------

covering
accepts : String -> IO Bool
accepts text =
  do parsed <- parseJsonText text
     pure (case parsed of
                Left _ => False
                Right value => case parseCommand value of
                                    Right _ => True
                                    Left _ => False)

covering
refuses : String -> IO Bool
refuses text = map not (accepts text)

covering
commandTests : IORef Int -> IO ()
commandTests failures =
  do check failures "a well-formed hello is accepted"
       !(accepts "{\"protocolVersion\":1,\"id\":\"h1\",\"op\":\"hello\"}")
     check failures "an unsupported protocol version is refused"
       !(refuses "{\"protocolVersion\":2,\"id\":\"h1\",\"op\":\"hello\"}")
     check failures "an unknown field on hello is refused"
       !(refuses "{\"protocolVersion\":1,\"id\":\"h1\",\"op\":\"hello\",\"x\":1}")
     check failures "a call needs a path and args"
       !(refuses "{\"id\":\"q1\",\"op\":\"query\",\"path\":\"demo:state\"}")
     check failures "call args must be an object"
       !(refuses "{\"id\":\"q1\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":[]}")
     check failures "a two-character path is refused"
       !(refuses "{\"id\":\"q1\",\"op\":\"query\",\"path\":\"ab\",\"args\":{}}")
     check failures "a well-formed query is accepted"
       !(accepts "{\"id\":\"q1\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":{}}")
     check failures "an empty id is refused"
       !(refuses "{\"id\":\"\",\"op\":\"query\",\"path\":\"demo:state\",\"args\":{}}")
     check failures "a missing id is refused"
       !(refuses "{\"op\":\"query\",\"path\":\"demo:state\",\"args\":{}}")
     check failures "a subscribe needs a subscriptionId"
       !(refuses "{\"id\":\"s1\",\"op\":\"subscribe\",\"path\":\"demo:state\",\"args\":{}}")
     check failures "a well-formed subscribe is accepted"
       !(accepts ("{\"id\":\"s1\",\"op\":\"subscribe\",\"subscriptionId\":\"a\","
                    ++ "\"path\":\"demo:state\",\"args\":{}}"))
     check failures "an unsubscribe is accepted"
       !(accepts "{\"id\":\"u1\",\"op\":\"unsubscribe\",\"subscriptionId\":\"a\"}")
     check failures "setAuth needs a token"
       !(refuses "{\"id\":\"a1\",\"op\":\"setAuth\"}")
     check failures "an empty token clears authentication"
       !(accepts "{\"id\":\"a1\",\"op\":\"setAuth\",\"token\":\"\"}")
     check failures "a control command takes no extra field"
       !(refuses "{\"id\":\"c1\",\"op\":\"close\",\"token\":\"x\"}")
     check failures "close and debugDisconnect are accepted"
       (!(accepts "{\"id\":\"c1\",\"op\":\"close\"}")
          && !(accepts "{\"id\":\"d1\",\"op\":\"debugDisconnect\"}"))
     check failures "an unknown operation is refused"
       !(refuses "{\"id\":\"z1\",\"op\":\"teleport\"}")

--------------------------------------------------------------------------------
-- Event shapes
--------------------------------------------------------------------------------

covering
rendered : Json -> IO String
rendered value =
  do encoded <- renderJson value
     pure (either (const "<render failed>") id encoded)

covering
eventTests : IORef Int -> IO ()
eventTests failures =
  do ready <- rendered (readyEvent "h1")
     check failures "ready reports the version, language, provenance, and runtime"
       (ready == "{\"protocolVersion\":1,\"id\":\"h1\",\"type\":\"ready\",\"language\":\""
                   ++ languageId ++ "\",\"implementation\":\"" ++ implementationName
                   ++ "\",\"runtime\":\"" ++ runtimeVersion ++ "\"}")

     -- An absent optional field is omitted, never serialised as null: the
     -- shared controller validates every event against the adapter schema.
     quiet <- rendered (resultEvent "q1" (JObject [("count", jsonInt 1)]) [])
     check failures "a result with no logs omits the logs field"
       (quiet == "{\"id\":\"q1\",\"type\":\"result\",\"value\":{\"count\":1}}")

     noisy <- rendered (resultEvent "q2" JNull ["one"])
     check failures "a result with logs carries them separately from the value"
       (noisy == "{\"id\":\"q2\",\"type\":\"result\",\"value\":null,\"logs\":[\"one\"]}")

     failed <- rendered (errorEvent "q3"
                          (MkConvexError FunctionFailure "boom"
                             (JObject [("code", JString "BOOM")]) [] "query"))
     check failures "a structured function error keeps its name, message, and data"
       (failed == "{\"id\":\"q3\",\"type\":\"error\",\"error\":{\"name\":\"FunctionError\""
                    ++ ",\"message\":\"boom\",\"data\":{\"code\":\"BOOM\"}}}")

     transport <- rendered (errorEvent "q4" (transportError "query" "socket died"))
     check failures "a transport failure is not flattened into a value"
       (transport == "{\"id\":\"q4\",\"type\":\"error\",\"error\":{\"name\":\"TransportError\""
                       ++ ",\"message\":\"socket died\",\"data\":null}}")

     acked <- rendered (ackEvent "s1")
     check failures "an ack carries only its id" (acked == "{\"id\":\"s1\",\"type\":\"ack\"}")

     closed <- rendered (closedEvent "c1")
     check failures "a closed event carries only its id"
       (closed == "{\"id\":\"c1\",\"type\":\"closed\"}")

     update <- rendered (updateEvent "sub-a"
                          (MkLiveUpdate (Just (jsonInt 3)) [] Nothing))
     check failures "a subscription value event carries no id"
       (update == "{\"type\":\"subscription\",\"subscriptionId\":\"sub-a\",\"value\":3}")

     broken <- rendered (updateEvent "sub-b"
                          (MkLiveUpdate Nothing []
                             (Just (MkConvexError FunctionFailure "empty"
                                      (JObject [("code", JString "ROOM_EMPTY")]) []
                                      "subscription"))))
     check failures "a subscription error event carries no value"
       (broken == "{\"type\":\"subscription\",\"subscriptionId\":\"sub-b\",\"error\":"
                    ++ "{\"name\":\"FunctionError\",\"message\":\"empty\",\"data\":"
                    ++ "{\"code\":\"ROOM_EMPTY\"}}}")

     anonymous <- rendered (anonymousErrorEvent "command is not JSON")
     check failures "an unattributable failure omits the id rather than nulling it"
       (anonymous == "{\"type\":\"error\",\"error\":{\"name\":\"ProtocolError\","
                       ++ "\"message\":\"command is not JSON\",\"data\":null}}")

--------------------------------------------------------------------------------
-- The bounded output path
--------------------------------------------------------------------------------

filler : Int -> String
filler count = pack (replicate (cast count) 'x')

||| Build a socket pair by connecting to a local listener. The accepted end is
||| never read, which is exactly the stopped reader the budget exists for.
covering
stoppedPair : IO (Maybe (Int, Int, Int))
stoppedPair =
  do listener <- tcpListen "127.0.0.1" 0
     if listener < 0
        then pure Nothing
        else do portNumber <- tcpPort listener
                deadline <- deadlineIn 5000
                writer <- tcpConnect "127.0.0.1" portNumber deadline
                reader <- tcpAccept listener deadline
                closeFd listener
                if writer < 0 || reader < 0
                   then pure Nothing
                   else pure (Just (writer, reader, listener))

covering
outboxTests : IORef Int -> IO ()
outboxTests failures =
  do pair <- stoppedPair
     case pair of
          Nothing => check failures "the stopped-reader fixture was built" False
          Just (writer, reader, _) => exercise writer reader
  where
    covering
    fillUntilRefused : Outbox -> String -> Int -> IO (Maybe String)
    fillUntilRefused box payload remaining =
      if remaining <= 0
         then pure Nothing
         else do admitted <- admit box payload
                 case admitted of
                      Left problem => pure (Just problem)
                      -- Deliberately no flush: the queue has to grow for the
                      -- admission bounds to be the thing under test.
                      Right () => fillUntilRefused box payload (remaining - 1)

    covering
    drainUntilDeadline : Outbox -> Int -> IO (Maybe String)
    drainUntilDeadline box remaining =
      if remaining <= 0
         then pure Nothing
         else do flushed <- flushOutbox box
                 case flushed of
                      Left problem => pure (Just problem)
                      Right () => do sleepMs 20
                                     drainUntilDeadline box (remaining - 1)

    covering
    exercise : Int -> Int -> IO ()
    exercise writer reader =
      do link <- rawConnection writer writer 4096
         case link of
              Left _ => check failures "the stopped-reader connection was wrapped" False
              Right sink =>
                do -- A single event larger than the per-event bound is refused
                   -- before any memory is committed to the queue.
                   small <- newOutbox sink 400 8 65536 1024
                   tooBig <- admit small (filler 2048)
                   check failures "an event beyond the per-event bound is refused"
                     (case tooBig of
                           Left _ => True
                           Right () => False)

                   -- The count bound refuses admission before the byte bound
                   -- would, which keeps a flood of tiny events bounded too.
                   counted <- fillUntilRefused small (filler 16) 64
                   check failures "the event-count bound refuses admission"
                     (counted == Just "adapter output queue exceeds its event budget")

                   -- With a large count allowance the byte bound must stop it.
                   byteBound <- newOutbox sink 400 4096 65536 4096
                   bytes <- fillUntilRefused byteBound (filler 4000) 512
                   check failures "the byte bound refuses admission"
                     (bytes == Just "adapter output queue exceeds its byte budget")

                   -- Queue the shipped byte budget as near-maximum events with
                   -- nothing reading. That is far more than any socket buffer
                   -- absorbs, so the absolute output deadline has to fire
                   -- rather than the adapter waiting for ever.
                   stalling <- newOutbox sink 300 4096 defaultMaximumBytes (128 * 1024)
                   ignore $ fillUntilRefused stalling (filler 65536) 160
                   timed <- drainUntilDeadline stalling 100
                   check failures "a stopped reader hits the output deadline"
                     (timed == Just
                        "adapter output deadline expired with a stopped reader")

                   resident <- outboxQueuedBytes stalling
                   check failures "the stalled queue never exceeds its byte budget"
                     (resident <= defaultMaximumBytes)

                   -- The whole budget stays small enough that a real adapter
                   -- with the shipped bounds is far below the shared limit.
                   check failures "the shipped output budget is well under 128 MiB"
                     (defaultMaximumBytes + defaultMaximumEventBytes
                        < 32 * 1024 * 1024)

                   closeConnection sink
                   closeFd reader

--------------------------------------------------------------------------------
-- End-to-end over both transports
--------------------------------------------------------------------------------

covering
readEvent : Connection -> Int -> IO (Maybe Json)
readEvent link deadline =
  do line <- readLine link 65536 deadline
     case line of
          Left _ => pure Nothing
          Right text =>
            do parsed <- parseJsonText text
               pure (either (const Nothing) Just parsed)

textOf : String -> Maybe Json -> Maybe String
textOf name value = value >>= field name >>= asString

||| Drive one adapter over an already-connected transport.
covering
converse : IORef Int -> String -> Connection -> IO ()
converse failures label link =
  do deadline <- deadlineIn 20000
     ignore $ writeText link "{\"protocolVersion\":1,\"id\":\"h1\",\"op\":\"hello\"}\n"
                        deadline
     ready <- readEvent link deadline
     check failures (label ++ ": hello is answered with a ready event")
       (textOf "type" ready == Just "ready" && textOf "language" ready == Just languageId
          && textOf "id" ready == Just "h1")

     ignore $ writeText link "{\"id\":\"bad\",\"op\":\"teleport\"}\n" deadline
     refused <- readEvent link deadline
     check failures (label ++ ": an unknown operation is answered with an error")
       (textOf "type" refused == Just "error" && textOf "id" refused == Just "bad")

     ignore $ writeText link "{\"id\":\"c1\",\"op\":\"close\"}\n" deadline
     closed <- readEvent link deadline
     check failures (label ++ ": close is answered with a closed event")
       (textOf "type" closed == Just "closed" && textOf "id" closed == Just "c1")

||| The adapter never dials the deployment for `hello` or `close`, so a
||| placeholder URL keeps this phase about the protocol rather than the network.
placeholderUrl : String
placeholderUrl = "http://127.0.0.1:1"

covering
tcpPhase : IORef Int -> IO ()
tcpPhase failures =
  do probe <- tcpListen "127.0.0.1" 0
     if probe < 0
        then check failures "an adapter port was reserved" False
        else do portNumber <- tcpPort probe
                closeFd probe
                child <- forkProcess
                if child == 0
                   then do ignore $ setEnv "CONVEX_URL" placeholderUrl True
                           ignore $ setEnv "ADAPTER_LISTEN"
                                      ("127.0.0.1:" ++ show portNumber) True
                           runAdapter
                           exitNow 0
                   else parent child portNumber
  where
    covering
    connectWithRetry : Int -> Int -> IO (Maybe Connection)
    connectWithRetry portNumber attempts =
      if attempts <= 0
         then pure Nothing
         else do deadline <- deadlineIn 1000
                 descriptor <- tcpConnect "127.0.0.1" portNumber deadline
                 if descriptor < 0
                    then do sleepMs 100
                            connectWithRetry portNumber (attempts - 1)
                    else do link <- rawConnection descriptor descriptor 65536
                            pure (either (const Nothing) Just link)

    covering
    parent : Int -> Int -> IO ()
    parent child portNumber =
      do link <- connectWithRetry portNumber 50
         case link of
              Nothing => check failures "ADAPTER_LISTEN accepted a controller" False
              Just connected =>
                do converse failures "tcp" connected
                   closeConnection connected
         deadline <- deadlineIn 5000
         status <- waitProcess child deadline
         check failures "the adapter exits zero after close over TCP" (status == 0)
         when (status /= 0) (killProcess child)

covering
stdioPhase : IORef Int -> IO ()
stdioPhase failures =
  do listener <- tcpListen "127.0.0.1" 0
     if listener < 0
        then check failures "a stdio fixture socket was bound" False
        else do portNumber <- tcpPort listener
                deadline <- deadlineIn 5000
                controllerFd <- tcpConnect "127.0.0.1" portNumber deadline
                adapterFd <- tcpAccept listener deadline
                closeFd listener
                if controllerFd < 0 || adapterFd < 0
                   then check failures "a stdio fixture socket pair was made" False
                   else split controllerFd adapterFd
  where
    covering
    split : Int -> Int -> IO ()
    split controllerFd adapterFd =
      do child <- forkProcess
         if child == 0
            then do -- Put the socket on the adapter's stdin and stdout so the
                    -- default transport is exercised for real rather than
                    -- simulated.
                    ignore $ duplicateFd adapterFd 0
                    ignore $ duplicateFd adapterFd 1
                    ignore $ setEnv "CONVEX_URL" placeholderUrl True
                    ignore $ setEnv "ADAPTER_LISTEN" "" True
                    runAdapter
                    exitNow 0
            else do closeFd adapterFd
                    link <- rawConnection controllerFd controllerFd 65536
                    case link of
                         Left _ => check failures "the stdio controller was wrapped" False
                         Right connected =>
                           do converse failures "stdio" connected
                              closeConnection connected
                    deadline <- deadlineIn 5000
                    status <- waitProcess child deadline
                    check failures "the adapter exits zero after close over stdio"
                      (status == 0)
                    when (status /= 0) (killProcess child)

covering
main : IO ()
main =
  do initialise
     failures <- newIORef 0
     commandTests failures
     eventTests failures
     outboxTests failures
     tcpPhase failures
     stdioPhase failures
     failureCount <- readIORef failures
     if failureCount == 0
        then putStrLn "adapter tests passed"
        else do ignore $ fPutStrLn stderr ("adapter tests failed: " ++ show failureCount)
                exitFailure
