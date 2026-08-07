||| NDJSON adapter protocol v1 for the shared black-box controller.
|||
||| This is test infrastructure, not client API. It parses controller commands
||| strictly, calls the real `Convex` client for every operation, and writes
||| protocol events on stdout while every diagnostic goes to stderr.
|||
||| Two transports carry the same stream. With no `ADAPTER_LISTEN` the adapter
||| speaks over stdin and stdout; with it set the adapter listens on that TCP
||| address and accepts exactly one controller connection.
|||
||| Output is queued rather than written inline, and the queue is bounded by an
||| event count, a per-event size, and a total byte budget. A controller that
||| stops reading therefore hits admission refusal and then a real output
||| deadline, instead of growing the process without limit.
module Conformance.Adapter

import Data.IORef
import Data.List
import Data.Maybe
import Data.String
import System
import System.File

import Convex
import Convex.Build
import Convex.Live
import Convex.Prim

--------------------------------------------------------------------------------
-- Bounded output
--------------------------------------------------------------------------------

record Pending where
  constructor MkPending
  chunk : Int
  size : Int
  sent : Int

export
record Outbox where
  constructor MkOutbox
  sink : Connection
  pending : IORef (List Pending)
  pendingBytes : IORef Int
  flushDeadline : IORef (Maybe Int)
  budgetMs : Int
  maximumEvents : Int
  maximumBytes : Int
  maximumEventBytes : Int

||| At most this many queued events before admission refuses.
export
defaultMaximumEvents : Int
defaultMaximumEvents = 128

||| At most this many queued bytes across all events. With the 2 MiB per-event
||| bound and the client's own 2 MiB frame budget, the adapter's resident total
||| stays far below the shared 128 MiB limit even with a stopped reader.
export
defaultMaximumBytes : Int
defaultMaximumBytes = 8 * 1024 * 1024

export
defaultMaximumEventBytes : Int
defaultMaximumEventBytes = 2 * 1024 * 1024

||| How long the queue may stay non-empty before the adapter gives up on a
||| reader that has stopped consuming.
export
defaultOutputBudgetMs : Int
defaultOutputBudgetMs = 20000

export
newOutbox : Connection -> Int -> Int -> Int -> Int -> IO Outbox
newOutbox sink' budget events bytes eventBytes =
  do queue <- newIORef []
     queued <- newIORef 0
     deadline <- newIORef Nothing
     pure (MkOutbox sink' queue queued deadline budget events bytes eventBytes)

export
outboxQueuedBytes : Outbox -> IO Int
outboxQueuedBytes box = readIORef (pendingBytes box)

export
outboxQueuedEvents : Outbox -> IO Nat
outboxQueuedEvents box = map length (readIORef (pending box))

||| Admit one encoded event. Refusal is a real answer, not a silent drop: the
||| caller reports it on stderr and stops rather than pretending it was sent.
export covering
admit : Outbox -> String -> IO (Either String ())
admit box text =
  do size <- textSize text
     -- `total` is a reserved word in Idris2 (totality annotations), so the
     -- event's byte total (payload plus its trailing newline) is named
     -- `eventBytes` instead.
     let eventBytes = size + 1
     queued <- readIORef (pending box)
     bytes <- readIORef (pendingBytes box)
     if eventBytes > maximumEventBytes box
        then pure (Left "adapter event exceeds the per-event byte budget")
        else if cast (length queued) + 1 > maximumEvents box
                then pure (Left "adapter output queue exceeds its event budget")
                else if bytes + eventBytes > maximumBytes box
                        then pure (Left "adapter output queue exceeds its byte budget")
                        else stage eventBytes
  where
    stage : Int -> IO (Either String ())
    stage eventBytes =
      do buffer <- bufNew (eventBytes + 8)
         if buffer < 0
            then pure (Left "adapter could not allocate an output buffer")
            else do written <- bufPutText buffer 0 text
                    ignore $ bufSet buffer written 10
                    modifyIORef (pending box) (\queue => queue ++ [MkPending buffer eventBytes 0])
                    modifyIORef (pendingBytes box) (+ eventBytes)
                    existing <- readIORef (flushDeadline box)
                    case existing of
                         Just _ => pure ()
                         Nothing => do at <- deadlineIn (budgetMs box)
                                       writeIORef (flushDeadline box) (Just at)
                    pure (Right ())

||| Whether a queue that is still non-empty has outlived its absolute deadline.
||| The deadline was set when the queue first became non-empty, so a reader that
||| stops consuming is bounded rather than merely slow.
covering
outboxStalled : Outbox -> IO (Either String ())
outboxStalled box =
  do deadline <- readIORef (flushDeadline box)
     case deadline of
          Nothing => pure (Right ())
          Just at =>
            do now <- nowMs
               pure (if now >= at
                        then Left "adapter output deadline expired with a stopped reader"
                        else Right ())

||| Write as much as the transport will take without blocking. `pendingBytes`
||| tracks bytes still to send, so a partial write and its later completion each
||| subtract exactly what they moved.
export covering
flushOutbox : Outbox -> IO (Either String ())
flushOutbox box =
  do queued <- readIORef (pending box)
     case queued of
          [] => do writeIORef (flushDeadline box) Nothing
                   pure (Right ())
          (item :: rest) =>
            do let remaining = size item - sent item
               written <- fdWrite (connectionWriteFd (sink box)) (chunk item)
                                  (sent item) remaining
               if written <= 0
                  then if written == ioWantWrite || written == ioWantRead
                          then outboxStalled box
                          else do detail <- lastError
                                  pure (Left ("adapter output failed: " ++ detail))
                  else do modifyIORef (pendingBytes box) (\bytes => bytes - written)
                          if written >= remaining
                             then do bufFree (chunk item)
                                     writeIORef (pending box) rest
                             else writeIORef (pending box)
                                             ({ sent := sent item + written } item :: rest)
                          flushOutbox box

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

public export
data Command
  = CmdHello String
  | CmdCall String String String Json
  | CmdSubscribe String String (Maybe String) Json
  | CmdUnsubscribe String String
  | CmdSetAuth String String
  | CmdClose String
  | CmdDebugDisconnect String

export
commandId : Command -> String
commandId (CmdHello identifier) = identifier
commandId (CmdCall identifier _ _ _) = identifier
commandId (CmdSubscribe identifier _ _ _) = identifier
commandId (CmdUnsubscribe identifier _) = identifier
commandId (CmdSetAuth identifier _) = identifier
commandId (CmdClose identifier) = identifier
commandId (CmdDebugDisconnect identifier) = identifier

keysOf : Json -> List String
keysOf value = maybe [] (map fst) (asObject value)

||| Reject any key the schema does not define for this operation. Silently
||| ignoring an unknown field would let a controller change and go unnoticed.
onlyKeys : List String -> Json -> Bool
onlyKeys allowed value = all (\key => elem key allowed) (keysOf value)

textField : String -> Json -> Maybe String
textField name value = field name value >>= asString

||| Identifiers are bounded by the shared schema, so the adapter enforces the
||| same bound rather than trusting the controller.
validIdentifier : String -> Bool
validIdentifier value =
  let size = length value in
  size >= 1 && size <= 128

export
parseCommand : Json -> Either String Command
parseCommand value =
  case textField "op" value of
       Nothing => Left "command has no op"
       Just op => withOp op
  where
    identifier : Either String String
    identifier =
      case textField "id" value of
           Nothing => Left "command has no id"
           Just text => if validIdentifier text
                           then Right text
                           else Left "command id is out of range"

    call : String -> String -> Either String Command
    call op name =
      if not (onlyKeys ["id", "op", "path", "args"] value)
         then Left "call command has an unexpected field"
         else case (textField "path" value, field "args" value) of
                   (Just path, Just args) =>
                     if length path < 3
                        then Left "call command path is too short"
                        else if not (isObject args)
                                then Left "call command args must be an object"
                                else Right (CmdCall name op path args)
                   _ => Left "call command needs a path and args"

    subscribe' : String -> Either String Command
    subscribe' name =
      if not (onlyKeys ["id", "op", "subscriptionId", "path", "args"] value)
         then Left "subscribe command has an unexpected field"
         else case textField "subscriptionId" value of
                   Nothing => Left "subscribe command has no subscriptionId"
                   Just subscriptionId =>
                     if not (validIdentifier subscriptionId)
                        then Left "subscriptionId is out of range"
                        else Right (CmdSubscribe name subscriptionId
                                      (textField "path" value)
                                      (fromMaybe (JObject []) (field "args" value)))

    unsubscribe' : String -> Either String Command
    unsubscribe' name =
      if not (onlyKeys ["id", "op", "subscriptionId", "path", "args"] value)
         then Left "unsubscribe command has an unexpected field"
         else case textField "subscriptionId" value of
                   Nothing => Left "unsubscribe command has no subscriptionId"
                   Just subscriptionId =>
                     if not (validIdentifier subscriptionId)
                        then Left "subscriptionId is out of range"
                        else Right (CmdUnsubscribe name subscriptionId)

    hello : String -> Either String Command
    hello name =
      if not (onlyKeys ["id", "op", "protocolVersion"] value)
         then Left "hello command has an unexpected field"
         else case field "protocolVersion" value >>= wholeNumber of
                   Just 1 => Right (CmdHello name)
                   _ => Left "unsupported adapter protocol version"

    auth : String -> Either String Command
    auth name =
      if not (onlyKeys ["id", "op", "token"] value)
         then Left "setAuth command has an unexpected field"
         else case textField "token" value of
                   Nothing => Left "setAuth command has no token"
                   Just token => Right (CmdSetAuth name token)

    control : String -> String -> Either String Command
    control op name =
      if not (onlyKeys ["id", "op"] value)
         then Left "control command has an unexpected field"
         else Right (if op == "close" then CmdClose name else CmdDebugDisconnect name)

    dispatchOp : String -> String -> Either String Command
    dispatchOp op name =
      if op == "hello" then hello name
      else if elem op ["query", "mutation", "action"] then call op name
      else if op == "subscribe" then subscribe' name
      else if op == "unsubscribe" then unsubscribe' name
      else if op == "setAuth" then auth name
      else if op == "close" || op == "debugDisconnect" then control op name
      else Left ("unknown operation: " ++ op)

    withOp : String -> Either String Command
    withOp op =
      case identifier of
           Left problem => Left problem
           Right name => dispatchOp op name

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

||| Optional fields are omitted rather than serialised as null. The shared
||| controller validates every event against the adapter schema, and an
||| explicit null where a field is absent is a schema violation.
logsField : List String -> List (String, Json)
logsField [] = []
logsField entries = [("logs", JArray (map JString entries))]

export
readyEvent : String -> Json
readyEvent identifier =
  JObject [ ("protocolVersion", jsonInt 1)
          , ("id", JString identifier)
          , ("type", JString "ready")
          , ("language", JString languageId)
          , ("implementation", JString implementationName)
          , ("runtime", JString runtimeVersion)
          ]

export
resultEvent : String -> Json -> List String -> Json
resultEvent identifier value logs =
  JObject ([("id", JString identifier), ("type", JString "result"), ("value", value)]
             ++ logsField logs)

export
errorEvent : String -> ConvexError -> Json
errorEvent identifier failure =
  JObject [ ("id", JString identifier)
          , ("type", JString "error")
          , ("error", errorJson failure)
          ]

export
protocolErrorEvent : String -> String -> Json
protocolErrorEvent identifier reason =
  errorEvent identifier (protocolError "adapter" reason)

||| A command that could not even be attributed to a request identifier still
||| produces an error event, but without an `id` field rather than a null one.
export
anonymousErrorEvent : String -> Json
anonymousErrorEvent reason =
  JObject [ ("type", JString "error")
          , ("error", errorJson (protocolError "adapter" reason))
          ]

export
ackEvent : String -> Json
ackEvent identifier = JObject [("id", JString identifier), ("type", JString "ack")]

export
closedEvent : String -> Json
closedEvent identifier = JObject [("id", JString identifier), ("type", JString "closed")]

export
subscriptionValueEvent : String -> Json -> List String -> Json
subscriptionValueEvent subscriptionId value logs =
  JObject ([ ("type", JString "subscription")
           , ("subscriptionId", JString subscriptionId)
           , ("value", value)
           ] ++ logsField logs)

export
subscriptionErrorEvent : String -> ConvexError -> Json
subscriptionErrorEvent subscriptionId failure =
  JObject [ ("type", JString "subscription")
          , ("subscriptionId", JString subscriptionId)
          , ("error", errorJson failure)
          ]

||| Turn one reactive update into its event. An update carries a value or an
||| error, never both, so the two shapes never overlap.
export
updateEvent : String -> LiveUpdate -> Json
updateEvent subscriptionId update =
  case updateError update of
       Just failure => subscriptionErrorEvent subscriptionId failure
       Nothing =>
         subscriptionValueEvent subscriptionId
           (fromMaybe JNull (updateValue update)) (updateLogs update)

--------------------------------------------------------------------------------
-- The adapter loop
--------------------------------------------------------------------------------

record Session where
  constructor MkSession
  client : Client
  outbox : Outbox
  control : Connection
  subscriptions : IORef (List (String, Int))
  greeted : IORef Bool
  finishing : IORef Bool

diagnostic : String -> IO ()
diagnostic text = writeStderr ("convex-adapter: " ++ text ++ "\n")

covering
emit : Session -> Json -> IO (Either String ())
emit session event =
  do encoded <- renderJson event
     case encoded of
          Left problem => pure (Left ("could not encode an event: " ++ problem))
          Right text => admit (outbox session) text

covering
handleCall : Session -> String -> String -> String -> Json -> IO (Either String ())
handleCall session identifier op path args =
  do outcome <- case op of
                     "query" => query (client session) path args
                     "mutation" => mutation (client session) path args
                     _ => action (client session) path args
     case outcome of
          Left failure => emit session (errorEvent identifier failure)
          Right value =>
            emit session (resultEvent identifier (resultValue value) (resultLogs value))

||| Start a subscription. A repeated identifier replaces the old one, and the
||| replacement removes the previous query before the acknowledgement so no
||| event from the old relay can cross it.
covering
handleSubscribe : Session -> String -> String -> Maybe String -> Json
               -> IO (Either String ())
handleSubscribe session identifier subscriptionId path args =
  case path of
       Nothing => emit session (protocolErrorEvent identifier
                                 "subscribe needs a function path")
       Just target => replaceThenStart target
  where
    covering
    forgetExisting : IO ()
    forgetExisting =
      do known <- readIORef (subscriptions session)
         case lookup subscriptionId known of
              Nothing => pure ()
              Just queryId =>
                do ignore $ unsubscribe (client session)
                              (MkSubscription queryId)
                   modifyIORef (subscriptions session)
                               (filter (\entry => fst entry /= subscriptionId))

    covering
    replaceThenStart : String -> IO (Either String ())
    replaceThenStart target =
      do forgetExisting
         started <- subscribe (client session) target args
         case started of
              Left failure => emit session (errorEvent identifier failure)
              Right handle =>
                do modifyIORef (subscriptions session)
                               (\known => known ++ [(subscriptionId,
                                                     subscriptionQueryId handle)])
                   emit session (ackEvent identifier)

covering
handleUnsubscribe : Session -> String -> String -> IO (Either String ())
handleUnsubscribe session identifier subscriptionId =
  do known <- readIORef (subscriptions session)
     case lookup subscriptionId known of
          Nothing => emit session (ackEvent identifier)
          Just queryId =>
            do ignore $ unsubscribe (client session) (MkSubscription queryId)
               modifyIORef (subscriptions session)
                           (filter (\entry => fst entry /= subscriptionId))
               emit session (ackEvent identifier)

covering
handleCommand : Session -> Command -> IO (Either String ())
handleCommand session (CmdHello identifier) =
  do writeIORef (greeted session) True
     emit session (readyEvent identifier)
handleCommand session (CmdCall identifier op path args) =
  handleCall session identifier op path args
handleCommand session (CmdSubscribe identifier subscriptionId path args) =
  handleSubscribe session identifier subscriptionId path args
handleCommand session (CmdUnsubscribe identifier subscriptionId) =
  handleUnsubscribe session identifier subscriptionId
handleCommand session (CmdSetAuth identifier token) =
  do setAuth (client session) token
     emit session (ackEvent identifier)
handleCommand session (CmdDebugDisconnect identifier) =
  do dropped <- debugDisconnectLive (clientLive (client session))
     case dropped of
          Left failure => emit session (errorEvent identifier failure)
          Right () => emit session (ackEvent identifier)
handleCommand session (CmdClose identifier) =
  do known <- readIORef (subscriptions session)
     traverse_ (\entry => ignore (unsubscribe (client session)
                                   (MkSubscription (snd entry)))) known
     writeIORef (subscriptions session) []
     closeClient (client session)
     writeIORef (finishing session) True
     emit session (closedEvent identifier)

||| Every command is answered, including one that fails validation, so the
||| controller never waits on a request the adapter silently discarded.
covering
dispatch : Session -> String -> IO (Either String ())
dispatch session line =
  do parsed <- parseJsonText line
     case parsed of
          Left problem => emit session (anonymousErrorEvent ("command is not JSON: "
                                                               ++ problem))
          Right value => validated value
  where
    -- ordered is defined before validated, which calls it, per the
    -- where-block ordering rule (see the Convex.Ws await/upgrade note).
    covering
    ordered : Command -> IO (Either String ())
    ordered command =
      do hasGreeted <- readIORef (greeted session)
         case command of
              CmdHello _ => handleCommand session command
              _ => if hasGreeted
                      then handleCommand session command
                      else emit session (protocolErrorEvent (commandId command)
                                          "the first command must be hello")

    covering
    validated : Json -> IO (Either String ())
    validated value =
      case parseCommand value of
           Left problem =>
             -- A rejected command still gets an answer. The identifier is only
             -- echoed when it is itself schema-valid, so a malformed id cannot
             -- push an invalid event back at the controller.
             case filter validIdentifier (toList (field "id" value >>= asString)) of
                  (identifier :: _) => emit session (protocolErrorEvent identifier problem)
                  [] => emit session (anonymousErrorEvent problem)
           Right command => ordered command

covering
publishUpdates : Session -> IO (Either String ())
publishUpdates session =
  do taken <- takeDelivery (clientLive (client session))
     case taken of
          Nothing => pure (Right ())
          Just (queryId, update) =>
            do known <- readIORef (subscriptions session)
               case find (\entry => snd entry == queryId) known of
                    Nothing => publishUpdates session
                    Just entry =>
                      do sent <- emit session (updateEvent (fst entry) update)
                         case sent of
                              Left problem => pure (Left problem)
                              Right () => publishUpdates session

covering
readCommands : Session -> IO (Either String ())
readCommands session =
  do line <- tryReadLine (control session) (4 * 1024 * 1024)
     case line of
          Left problem => pure (Left problem)
          Right Nothing => pure (Right ())
          Right (Just text) =>
            do handled <- dispatch session text
               case handled of
                    Left problem => pure (Left problem)
                    Right () =>
                      do done <- readIORef (finishing session)
                         if done then pure (Right ()) else readCommands session

covering
waitForWork : Session -> IO ()
waitForWork session =
  do pollsetReset
     done <- readIORef (finishing session)
     when (not done) (pollsetAdd (connectionReadFd (control session)) pollRead)
     queued <- readIORef (pending (outbox session))
     when (not (null queued))
          (pollsetAdd (connectionWriteFd (control session)) pollWrite)
     descriptor <- liveWaitDescriptor (clientLive (client session))
     case descriptor of
          Nothing => pure ()
          Just fd => pollsetAdd fd pollRead
     due <- liveNextConnectAt (clientLive (client session))
     now <- nowMs
     let timeout = case due of
                        Nothing => 250
                        Just at => let remaining = at - now in
                                   if remaining < 0 then 0
                                   else if remaining > 250 then 250
                                   else remaining
     ignore $ pollsetWait timeout

||| One turn of the adapter: flush, service the sync socket, publish any
||| updates, then read whatever commands have arrived.
covering
turn : Session -> IO (Either String ())
turn session =
  do flushed <- flushOutbox (outbox session)
     case flushed of
          Left problem => pure (Left problem)
          Right () =>
            do pumpReady (clientLive (client session))
               published <- publishUpdates session
               case published of
                    Left problem => pure (Left problem)
                    Right () =>
                      do done <- readIORef (finishing session)
                         -- After `close` the controller may drop its end at any
                         -- moment. Reading again would turn its ordinary
                         -- disconnect into a fatal error on the way out.
                         if done then pure (Right ()) else readCommands session

||| The adapter's only loop. It is written as a single directly self-recursive
||| function whose recursive call is in tail position, so the generated code
||| stays a loop rather than growing the stack for the life of a session.
covering
loopSession : Session -> IO ()
loopSession session =
  do outcome <- turn session
     case outcome of
          Left problem =>
            do diagnostic problem
               exitWith (ExitFailure 1)
          Right () =>
            do done <- readIORef (finishing session)
               queued <- readIORef (pending (outbox session))
               if done && null queued
                  then exitSuccess
                  else do waitForWork session
                          loopSession session

||| Accept the single controller connection when `ADAPTER_LISTEN` is set, or
||| fall back to stdin and stdout.
covering
openControl : IO (Either String Connection)
openControl =
  do address <- getEnv "ADAPTER_LISTEN"
     case address of
          Nothing => rawConnection 0 1 (1024 * 1024)
          Just "" => rawConnection 0 1 (1024 * 1024)
          Just text => listenOn text
  where
    covering
    listenOn : String -> IO (Either String Connection)
    listenOn text =
      case span (/= ':') text of
           (_, "") => pure (Left "ADAPTER_LISTEN must be host:port")
           (hostText, rest) =>
             do let portText = substr 1 (length rest) rest
                let bindHost = if hostText == "" then "0.0.0.0" else hostText
                listener <- tcpListen bindHost (cast portText)
                if listener < 0
                   then do detail <- lastError
                           pure (Left ("could not listen on " ++ text ++ ": " ++ detail))
                   else do deadline <- deadlineIn 60000
                           accepted <- acceptConnection listener "" "" deadline
                                                        (1024 * 1024)
                           closeFd listener
                           pure accepted

||| Entry point shared by the adapter executable and its language-local tests.
export covering
runAdapter : IO ()
runAdapter =
  do initialise
     deployment <- getEnv "CONVEX_URL"
     case deployment of
          Nothing => fail' "CONVEX_URL is required"
          Just url => withControl url
  where
    fail' : String -> IO ()
    fail' reason =
      do diagnostic reason
         exitWith (ExitFailure 1)

    covering
    start : Client -> Connection -> IO ()
    start client' control' =
      do box <- newOutbox control' defaultOutputBudgetMs defaultMaximumEvents
                          defaultMaximumBytes defaultMaximumEventBytes
         known <- newIORef []
         hasGreeted <- newIORef False
         done <- newIORef False
         loopSession (MkSession client' box control' known hasGreeted done)

    covering
    withControl : String -> IO ()
    withControl url =
      do control' <- openControl
         case control' of
              Left problem => fail' problem
              Right link =>
                do created <- newClient url
                   case created of
                        Left problem => fail' problem
                        Right client' => start client' link
