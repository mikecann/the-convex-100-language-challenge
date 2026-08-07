-- | NDJSON adapter protocol v1. Test infrastructure, not public client code.
-- |
-- | The shared controller drives this program over stdin/stdout, or over a TCP
-- | connection when `ADAPTER_LISTEN` is set, and validates every emitted line
-- | against the shared schema. Three rules shape the design:
-- |
-- | * stdout carries protocol events only; diagnostics go to stderr.
-- | * Every operation calls the real client. Nothing here fakes a Convex
-- |   result, and a failure is never flattened into a successful value.
-- | * Input and output are both explicitly bounded. The reader waits for an
-- |   acknowledgement before reading again, and the writer refuses work once
-- |   its queue exceeds a count or byte budget, so neither direction can grow
-- |   this process without limit.
module Adapter
  ( main
  , Replacement
  , replaceMapping
  , resultEvent
  , callErrorEvent
  , closedEvent
  , subscriptionEvent
  , ackEvent
  , languageId
  , implementation
  , runtimeDescription
  , maxCommandBytes
  , maxOutputCount
  , maxOutputBytes
  ) where

import Convex.Prelude
import Convex (Client)
import Convex as Convex
import Convex.Bytes (Bytes)
import Convex.Bytes as Bytes
import Convex.Error (ConvexError)
import Convex.Error as Error
import Convex.Json (Json(..))
import Convex.Json as Json
import Convex.Live (LiveEvent(..), SubscriptionEvent)
import Convex.Live as Live
import Convex.Sys (Pid, Ref, RecvResult(..), ReadResult(..), Socket)
import Convex.Sys as Sys

languageId :: String
languageId = "purescript"

-- | Provenance string reported in the `ready` event. It names the target
-- | language, how it reaches a runtime, and what the client does not delegate.
implementation :: String
implementation = "transpiled-purescript-purerl-otp-sockets-0.1.0"

-- | Pinned toolchain versions. The Docker test stage asserts that the two
-- | compiler binaries in the image report these strings, so the reported
-- | runtime cannot drift from the compilers that produced the image.
purescriptVersion :: String
purescriptVersion = "0.15.14"

purerlVersion :: String
purerlVersion = "0.0.24"

-- | One NDJSON command may not exceed this many bytes. A longer line is
-- | discarded up to its newline and answered with a protocol error.
maxCommandBytes :: Int
maxCommandBytes = 9437184

-- | Bounds on queued output, including the payload the sender is physically
-- | writing. Saturation never buffers past these; a saturation that outlasts
-- | `emitTimeout` is what closes a controller that has stopped reading.
maxOutputCount :: Int
maxOutputCount = 16

maxOutputBytes :: Int
maxOutputBytes = 12582912

-- | How long a caller waits for the writer to accept an event before treating
-- | the writer as unusable.
emitTimeout :: Int
emitTimeout = 1000

-- | How long the reader waits for the controller to acknowledge a command.
ackTimeout :: Int
ackTimeout = 5000

main :: Effect Unit
main = do
  url <- Sys.env "CONVEX_URL" "http://127.0.0.1:3210"
  created <- Convex.new url
  case created of
    Left problem ->
      Sys.stderrWrite ("adapter could not start: " <> problem.message)
    Right client -> do
      listenAddress <- Sys.getenv "ADAPTER_LISTEN"
      case listenAddress of
        Nothing -> run client StdIo
        Just address -> listen client address

-- ---------------------------------------------------------------------------
-- Transports
-- ---------------------------------------------------------------------------

data Channel
  = StdIo
  | TcpChannel Socket

-- | `ADAPTER_LISTEN` is `host:port`, and the host is honoured rather than
-- | assumed. A controller sharing this network namespace connects to loopback,
-- | but one running as a peer container reaches this image across a Docker
-- | network, and a loopback bind refuses every connection from outside the
-- | namespace while still looking like a healthy listener inside it. Only
-- | loopback and the unspecified address are accepted, so this test-only
-- | control surface still cannot be pinned to an arbitrary interface, and the
-- | container boundary stays the thing that contains it.
listen :: Client -> String -> Effect Unit
listen client address = case parseListen address of
  Left reason -> Sys.stderrWrite reason
  Right (Tuple host port) -> do
    listener <- Sys.listenOn host port
    case listener of
      Left reason -> Sys.stderrWrite ("adapter cannot listen: " <> reason)
      Right socket -> do
        accepted <- Sys.accept socket 60000
        case accepted of
          Left reason -> Sys.stderrWrite ("adapter accept failed: " <> reason)
          Right connection -> do
            run client (TcpChannel connection)
            Sys.close connection
        Sys.close socket

parseListen :: String -> Either String (Tuple String Int)
parseListen address = case stringSplitOnce address ":" of
  Nothing -> Left "ADAPTER_LISTEN must be host:port"
  Just (Tuple host rawPort) -> case parseInt rawPort of
    Nothing -> Left "ADAPTER_LISTEN has an invalid port"
    Just port ->
      if port > 0 && port < 65536 then case bindHost host of
        Just bind -> Right (Tuple bind port)
        Nothing -> Left listenProblem
      else Left listenProblem

-- | `localhost` is normalised to the address it names, because the bind call
-- | takes an address and resolving a name at that point would let what this
-- | listener is reachable from depend on the host's resolver.
bindHost :: String -> Maybe String
bindHost host =
  if host == "127.0.0.1" || host == "localhost" then Just "127.0.0.1"
  else if host == "0.0.0.0" then Just "0.0.0.0"
  else Nothing

listenProblem :: String
listenProblem =
  "ADAPTER_LISTEN must name a loopback or unspecified host and valid port"

-- ---------------------------------------------------------------------------
-- Controller
-- ---------------------------------------------------------------------------

data Event
  -- | One complete NDJSON command. The reply reference is how the reader
  -- | learns it may read again, which is what bounds this process's mailbox.
  = Incoming Bytes Pid Ref
  | Oversized Pid Ref
  | InputFailed String Pid Ref
  | InputClosed
  -- | A Live event, forwarded by the subscription bridge.
  | LiveDelivery SubscriptionEvent
  | OutputFailed String

data EmitResult
  = Emitted
  | Overflowed

type Controller =
  { client :: Client
  -- | Real client subscription id to the identifier the controller asked for.
  , subscriptions :: List (Tuple String String)
  , writer :: Pid
  , events :: Pid
  , sink :: Pid
  }

type Applied =
  { controller :: Controller
  , emitted :: EmitResult
  , stop :: Boolean
  }

run :: Client -> Channel -> Effect Unit
run client channel = do
  events <- Sys.selfPid
  writer <- startWriter events channel
  sink <- startBridge events
  -- A passive socket may only be read by its owner, and this process accepted
  -- it. Ownership moves to the reader before the reader takes its first byte,
  -- and the reader waits for that handover to be confirmed.
  handover <- Sys.newRef
  reader <- Sys.spawnProcess (readerStart handover events channel)
  transferred <- case channel of
    StdIo -> pure true
    TcpChannel socket -> Sys.controllingProcess socket reader
  Sys.sendReply reader handover transferred
  serve
    { client: client
    , subscriptions: Nil
    , writer: writer
    , events: events
    , sink: sink
    }
  voidEffect (flush writer 2000)
  Sys.sendCommand writer StopWriter

serve :: Controller -> Effect Unit
serve controller = do
  incoming <- Sys.receiveCommand 60000
  case incoming of
    Nothing -> serve controller
    Just InputClosed -> voidEffect (Convex.close controller.client)
    Just (OutputFailed reason) -> do
      Sys.stderrWrite ("controller output failed: " <> reason)
      voidEffect (Convex.close controller.client)
    Just (InputFailed reason ackPid ackRef) -> do
      voidEffect
        (emit controller (errorEvent Nothing "TransportError" reason))
      voidEffect (flush controller.writer 2000)
      Sys.sendReply ackPid ackRef true
      voidEffect (Convex.close controller.client)
    Just (Oversized ackPid ackRef) -> do
      outcome <- emit controller
        (errorEvent Nothing "ProtocolError" "NDJSON command exceeds 9 MiB")
      Sys.sendReply ackPid ackRef true
      continue controller outcome
    Just (LiveDelivery delivery) -> do
      outcome <- case assocGet controller.subscriptions delivery.subscriptionId of
        Nothing -> pure Emitted
        Just requested -> emit controller
          (subscriptionEvent requested delivery.event)
      Live.acknowledge delivery
      continue controller outcome
    Just (Incoming payload ackPid ackRef) -> do
      applied <- handleLine controller payload
      Sys.sendReply ackPid ackRef true
      if applied.stop then voidEffect (flush applied.controller.writer 2000)
      else continue applied.controller applied.emitted

-- | Keep serving unless the writer refused an event. Saturation is treated as
-- | a fatal condition on purpose: silently dropping protocol events would make
-- | a conformance run report a false result.
continue :: Controller -> EmitResult -> Effect Unit
continue controller outcome = case outcome of
  Emitted -> serve controller
  Overflowed -> do
    Sys.stderrWrite "controller output budget exceeded"
    voidEffect (Convex.close controller.client)

handleLine :: Controller -> Bytes -> Effect Applied
handleLine controller payload = case decodeCommand payload of
  Left (Tuple commandId message) -> do
    outcome <- emit controller (errorEvent commandId "ProtocolError" message)
    pure { controller: controller, emitted: outcome, stop: false }
  Right command -> execute controller command

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

data Command
  = Hello String
  | Call String Convex.CallKind String Json
  | SetAuth String String
  | Subscribe String String String Json
  | Unsubscribe String String
  | DebugDisconnect String
  | CloseClient String
  | Unknown String

-- | Validate a command before anything acts on it. The error path carries the
-- | command id when one could be recovered, because the shared controller
-- | correlates replies by id.
decodeCommand :: Bytes -> Either (Tuple (Maybe String) String) Command
decodeCommand payload = case Json.parseBytes payload of
  Left _ -> Left (Tuple Nothing "invalid NDJSON command")
  Right value ->
    let
      commandId = optionalId value
    in
      case commandId, Json.stringField value "op" of
        Just recovered, Just op -> validate op recovered value
        _, _ -> Left (Tuple commandId "command requires string id and op")

validate
  :: String -> String -> Json -> Either (Tuple (Maybe String) String) Command
validate op commandId value =
  if op == "hello" then
    if not (Json.onlyFields value helloFields) then
      Left (Tuple (Just commandId) "hello requires protocolVersion 1")
    else case maybeThen (Json.field value "protocolVersion") Json.integralInt of
      Just 1 -> Right (Hello commandId)
      _ -> Left (Tuple (Just commandId) "hello requires protocolVersion 1")
  else if op == "query" then callCommand commandId Convex.Query value
  else if op == "mutation" then callCommand commandId Convex.Mutation value
  else if op == "action" then callCommand commandId Convex.Action value
  else if op == "setAuth" then
    if not (Json.onlyFields value authFields) then
      Left (Tuple (Just commandId) "setAuth requires a string token")
    else case Json.stringField value "token" of
      Just token -> Right (SetAuth commandId token)
      Nothing -> Left (Tuple (Just commandId) "setAuth requires a string token")
  else if op == "subscribe" then
    let
      shape = Json.onlyFields value subscribeFields
      wanted = subscriptionId value
      path = Json.stringField value "path"
      args = objectField value "args"
    in
      case shape, wanted, path, args of
        true, Just subscription, Just target, Just payload ->
          Right (Subscribe commandId subscription target payload)
        _, _, _, _ ->
          Left (Tuple (Just commandId) "malformed subscribe command")
  else if op == "unsubscribe" then
    let
      shape = Json.onlyFields value subscribeFields
      wanted = subscriptionId value
      path = optionalString value "path"
      args = optionalObject value "args"
    in
      case shape, wanted, path, args of
        true, Just subscription, true, true ->
          Right (Unsubscribe commandId subscription)
        _, _, _, _ ->
          Left (Tuple (Just commandId) "malformed unsubscribe command")
  else if op == "debugDisconnect" then
    if Json.onlyFields value controlFields then
      Right (DebugDisconnect commandId)
    else Left (Tuple (Just commandId) "malformed debugDisconnect command")
  else if op == "close" then
    if Json.onlyFields value controlFields then Right (CloseClient commandId)
    else Left (Tuple (Just commandId) "malformed close command")
  else Right (Unknown commandId)

helloFields :: List String
helloFields = Cons "protocolVersion" (Cons "id" (listSingleton "op"))

authFields :: List String
authFields = Cons "id" (Cons "op" (listSingleton "token"))

controlFields :: List String
controlFields = listPair "id" "op"

callFields :: List String
callFields = Cons "id" (Cons "op" (Cons "path" (listSingleton "args")))

subscribeFields :: List String
subscribeFields =
  Cons "id"
    (Cons "op" (Cons "subscriptionId" (Cons "path" (listSingleton "args"))))

callCommand
  :: String
  -> Convex.CallKind
  -> Json
  -> Either (Tuple (Maybe String) String) Command
callCommand commandId kind value =
  let
    shape = Json.onlyFields value callFields
    path = Json.stringField value "path"
    args = objectField value "args"
  in
    case shape, path, args of
      true, Just target, Just payload ->
        if stringByteLength target >= 3 then
          Right (Call commandId kind target payload)
        else Left (Tuple (Just commandId) "malformed function command")
      _, _, _ -> Left (Tuple (Just commandId) "malformed function command")

-- | The value of a field that must be present and must be a JSON object.
objectField :: Json -> String -> Maybe Json
objectField value key = maybeThen (Json.field value key) \inner ->
  if isJust (Json.asObject inner) then Just inner else Nothing

optionalId :: Json -> Maybe String
optionalId value = case Json.stringField value "id" of
  Just recovered -> if validId recovered then Just recovered else Nothing
  Nothing -> Nothing

subscriptionId :: Json -> Maybe String
subscriptionId value =
  maybeThen (Json.stringField value "subscriptionId") \recovered ->
    if validId recovered then Just recovered else Nothing

-- | The shared schema bounds identifiers in Unicode scalar values, so the
-- | length check is not a byte count. A byte ceiling is applied first so a
-- | pathological string is rejected before it is decoded.
validId :: String -> Boolean
validId identifier =
  if stringByteLength identifier > 512 then false
  else
    let
      length = Json.codepointLength identifier
    in
      length > 0 && length <= 128 && stringTrim identifier /= ""

optionalString :: Json -> String -> Boolean
optionalString value key = case Json.field value key of
  Nothing -> true
  Just (JsonString _) -> true
  Just _ -> false

optionalObject :: Json -> String -> Boolean
optionalObject value key = case Json.field value key of
  Nothing -> true
  Just inner -> isJust (Json.asObject inner)

execute :: Controller -> Command -> Effect Applied
execute controller command = case command of
  Hello commandId -> do
    runtime <- runtimeDescription
    outcome <- emit controller
      ( JsonObject
          ( Cons (Tuple "protocolVersion" (JsonInt 1))
              ( Cons (Tuple "id" (JsonString commandId))
                  ( Cons (Tuple "type" (JsonString "ready"))
                      ( Cons (Tuple "language" (JsonString languageId))
                          ( Cons
                              (Tuple "implementation" (JsonString implementation))
                              ( listSingleton
                                  (Tuple "runtime" (JsonString runtime))
                              )
                          )
                      )
                  )
              )
          )
      )
    pure { controller: controller, emitted: outcome, stop: false }

  Call commandId kind path args -> do
    answered <- Convex.call controller.client kind path args
    outcome <- case answered of
      Right result -> emit controller
        (resultEvent commandId result.value result.logs)
      Left problem -> emit controller (callErrorEvent commandId problem)
    pure { controller: controller, emitted: outcome, stop: false }

  SetAuth commandId token -> case Convex.setAuth controller.client token of
    Right client -> do
      outcome <- emit controller (ackEvent commandId)
      pure
        { controller: controller { client = client }
        , emitted: outcome
        , stop: false
        }
    Left problem -> do
      outcome <- emit controller
        (errorEvent (Just commandId) problem.name problem.message)
      pure { controller: controller, emitted: outcome, stop: false }

  Subscribe commandId requested path args -> do
    -- Replacing an identifier is a barrier: the previous subscription is
    -- removed first, so no event from it can arrive after this
    -- acknowledgement wearing the same identifier.
    replacement <- replaceMapping controller.client controller.subscriptions
      requested
      path
      args
      controller.sink
    let updated = controller { subscriptions = replacement.subscriptions }
    case replacement.outcome of
      Left problem -> do
        outcome <- emit updated
          (errorEvent (Just commandId) problem.name problem.message)
        pure { controller: updated, emitted: outcome, stop: false }
      Right _ -> do
        outcome <- emit updated (ackEvent commandId)
        pure { controller: updated, emitted: outcome, stop: false }

  Unsubscribe commandId requested -> do
    dropped <- dropRequested controller.client controller.subscriptions requested
    case dropped.outcome of
      Left problem -> do
        outcome <- emit controller
          (errorEvent (Just commandId) problem.name problem.message)
        pure { controller: controller, emitted: outcome, stop: false }
      Right _ -> do
        let updated = controller { subscriptions = dropped.subscriptions }
        outcome <- emit updated (ackEvent commandId)
        pure { controller: updated, emitted: outcome, stop: false }

  DebugDisconnect commandId -> do
    answered <- Convex.debugDisconnect controller.client
    outcome <- case answered of
      Right _ -> emit controller (ackEvent commandId)
      Left problem -> emit controller
        (errorEvent (Just commandId) problem.name problem.message)
    pure { controller: controller, emitted: outcome, stop: false }

  CloseClient commandId -> do
    answered <- Convex.close controller.client
    case answered of
      Left problem -> do
        outcome <- emit controller
          (errorEvent (Just commandId) problem.name problem.message)
        pure { controller: controller, emitted: outcome, stop: false }
      Right _ -> do
        outcome <- emit controller (closedEvent commandId)
        pure
          { controller: controller { subscriptions = Nil }
          , emitted: outcome
          , stop: true
          }

  Unknown commandId -> do
    outcome <- emit controller
      (errorEvent (Just commandId) "ProtocolError" "unknown operation")
    pure { controller: controller, emitted: outcome, stop: false }

-- | Replace one controller-facing identifier through the same barrier the real
-- | subscribe command uses. The Live socket fixture calls this so replacement
-- | ordering is proved without a second test-only copy of the adapter logic.
type Replacement =
  { subscriptions :: List (Tuple String String)
  , outcome :: Either ConvexError Unit
  }

replaceMapping
  :: Client
  -> List (Tuple String String)
  -> String
  -> String
  -> Json
  -> Pid
  -> Effect Replacement
replaceMapping client subscriptions requested path args sink = do
  dropped <- dropRequested client subscriptions requested
  case dropped.outcome of
    Left problem -> pure
      { subscriptions: dropped.subscriptions, outcome: Left problem }
    Right _ -> do
      added <- Convex.subscribe client path args sink
      case added of
        Left problem -> pure
          { subscriptions: dropped.subscriptions, outcome: Left problem }
        Right real -> pure
          { subscriptions: listSnoc dropped.subscriptions (Tuple real requested)
          , outcome: Right unit
          }

-- | Remove whichever real subscriptions are currently wearing this
-- | controller-facing identifier, waiting for the client to confirm each one.
dropRequested
  :: Client -> List (Tuple String String) -> String -> Effect Replacement
dropRequested client subscriptions requested =
  let
    matches = listFilterMap
      (\(Tuple real wanted) -> if wanted == requested then Just real else Nothing)
      subscriptions
  in
    foldRemovals client matches
      { subscriptions: subscriptions, outcome: Right unit }

foldRemovals :: Client -> List String -> Replacement -> Effect Replacement
foldRemovals client matches carried = case matches of
  Nil -> pure carried
  Cons real rest -> do
    removed <- Convex.unsubscribe client real
    case removed of
      Left problem -> pure (carried { outcome = Left problem })
      Right _ -> foldRemovals client rest
        (carried { subscriptions = assocDelete carried.subscriptions real })

runtimeDescription :: Effect String
runtimeDescription = do
  release <- Sys.otpRelease
  pure
    ( "PureScript " <> purescriptVersion <> " via purerl " <> purerlVersion
        <> " on Erlang/OTP "
        <> release
    )

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

ackEvent :: String -> Json
ackEvent commandId = JsonObject
  ( listPair (Tuple "id" (JsonString commandId))
      (Tuple "type" (JsonString "ack"))
  )

-- | Serialise the successful call shape the shared schema validates. Keeping
-- | this as the production builder lets the language-local adapter test
-- | inspect the exact event rather than a hand-written approximation.
resultEvent :: String -> Json -> List String -> Json
resultEvent commandId value logs = JsonObject
  ( Cons (Tuple "id" (JsonString commandId))
      ( Cons (Tuple "type" (JsonString "result"))
          ( Cons (Tuple "value" value)
              ( listSingleton
                  (Tuple "logs" (JsonArray (listMap JsonString logs)))
              )
          )
      )
  )

callErrorEvent :: String -> ConvexError -> Json
callErrorEvent commandId problem = JsonObject
  ( Cons (Tuple "id" (JsonString commandId))
      ( Cons (Tuple "type" (JsonString "error"))
          (listSingleton (Tuple "error" (Error.toJson problem)))
      )
  )

closedEvent :: String -> Json
closedEvent commandId = JsonObject
  ( listPair (Tuple "id" (JsonString commandId))
      (Tuple "type" (JsonString "closed"))
  )

-- | Optional members are omitted rather than serialised as null, because the
-- | shared schema validates event shapes strictly.
errorEvent :: Maybe String -> String -> String -> Json
errorEvent commandId name message =
  let
    problem = JsonObject
      ( listPair (Tuple "name" (JsonString name))
          (Tuple "message" (JsonString message))
      )
  in
    case commandId of
      Nothing -> JsonObject
        ( listPair (Tuple "type" (JsonString "error"))
            (Tuple "error" problem)
        )
      Just recovered -> JsonObject
        ( Cons (Tuple "id" (JsonString recovered))
            ( Cons (Tuple "type" (JsonString "error"))
                (listSingleton (Tuple "error" problem))
            )
        )

subscriptionEvent :: String -> LiveEvent -> Json
subscriptionEvent requested event = case event of
  LiveValue value logs -> JsonObject
    ( Cons (Tuple "type" (JsonString "subscription"))
        ( Cons (Tuple "subscriptionId" (JsonString requested))
            ( Cons (Tuple "value" value)
                ( listSingleton
                    (Tuple "logs" (JsonArray (listMap JsonString logs)))
                )
            )
        )
    )
  LiveFailure problem -> JsonObject
    ( Cons (Tuple "type" (JsonString "subscription"))
        ( Cons (Tuple "subscriptionId" (JsonString requested))
            (listSingleton (Tuple "error" (Error.toJson problem)))
        )
    )

-- ---------------------------------------------------------------------------
-- Subscription bridge
-- ---------------------------------------------------------------------------

-- | The client delivers Live events on the event channel. This process
-- | forwards them into the controller's single command mailbox so the
-- | controller never has to choose between two sources while it is busy.
startBridge :: Pid -> Effect Pid
startBridge events = Sys.spawnProcess (bridgeLoop events)

bridgeLoop :: Pid -> Effect Unit
bridgeLoop events = do
  incoming <- Sys.receiveEvent 60000
  case incoming of
    Nothing -> bridgeLoop events
    Just delivery -> do
      Sys.sendCommand events (LiveDelivery delivery)
      bridgeLoop events

-- ---------------------------------------------------------------------------
-- Reader
-- ---------------------------------------------------------------------------

type ReaderState =
  { chunks :: Bytes.Chunks
  , bytes :: Int
  , discarding :: Boolean
  -- | Set when the last step threw away a partly read command. The bytes are
  -- | unreachable from the next state but not yet returned, and only the loop
  -- | head can act on that; see `readerLoop`.
  , abandoned :: Boolean
  }

emptyReader :: ReaderState
emptyReader =
  { chunks: Bytes.emptyChunks
  , bytes: 0
  , discarding: false
  , abandoned: false
  }

-- | Wait for the controller to confirm that this process owns the transport,
-- | then start reading. Reading first would race the ownership handover.
readerStart :: Ref -> Pid -> Channel -> Effect Unit
readerStart handover events channel = do
  granted <- Sys.awaitReply handover ackTimeout
  if fromMaybe false granted then readerLoop events channel emptyReader
  else Sys.stderrWrite "adapter reader never received the transport"

-- | Read commands and hand them over one at a time. Waiting for each
-- | acknowledgement is what stops a fast controller from filling this
-- | process's mailbox with unread work.
readerLoop :: Pid -> Channel -> ReaderState -> Effect Unit
readerLoop events channel state = do
  -- Reclaim an abandoned command here rather than where it was abandoned. A
  -- collection only frees what the *current* call stack can no longer reach,
  -- and while `parseLines` is deciding to reject a command its own frame still
  -- names the accumulated bytes. Those frames have all returned by the time
  -- the loop comes back round, which makes this the first point where the
  -- memory is genuinely unreachable, and the last point before this process
  -- blocks and starts accumulating the next command on top of the old one.
  whenEffect state.abandoned Sys.collectGarbage
  chunk <- readChannel channel
  case chunk of
    Left reason -> do
      self <- Sys.selfPid
      reference <- Sys.newRef
      Sys.sendCommand events (InputFailed reason self reference)
      voidEffect (Sys.awaitReply reference ackTimeout :: Effect (Maybe Boolean))
    -- NDJSON requires a terminating newline, so a trailing fragment at end of
    -- input is discarded rather than guessed at.
    Right Nothing -> Sys.sendCommand events InputClosed
    Right (Just bytes) -> do
      advanced <- consumeChunk events state bytes
      case advanced of
        Nothing -> pure unit
        Just next -> readerLoop events channel next

readChannel :: Channel -> Effect (Either String (Maybe Bytes))
readChannel channel = case channel of
  StdIo -> do
    outcome <- Sys.stdinRead
    case outcome of
      ReadChunk bytes -> pure (Right (Just bytes))
      ReadEnd -> pure (Right Nothing)
      ReadFailed reason -> pure (Left reason)
  TcpChannel socket -> do
    outcome <- Sys.recv socket 0 60000
    case outcome of
      Received bytes -> pure (Right (Just bytes))
      RecvClosed -> pure (Right Nothing)
      RecvTimeout -> pure (Right (Just Bytes.empty))
      RecvFailed reason -> pure (Left reason)

-- | Split whatever has arrived into complete lines. `Nothing` means the
-- | controller stopped acknowledging, so this reader has nothing left to do.
consumeChunk
  :: Pid -> ReaderState -> Bytes -> Effect (Maybe ReaderState)
consumeChunk events state bytes =
  if Bytes.size bytes == 0 then pure (Just state)
  else if state.discarding then
    let
      newline = Bytes.indexOfByte bytes 0x0A 0
    in
      if newline < 0 then pure (Just discardingReader)
      else consumeChunk events emptyReader (Bytes.drop (newline + 1) bytes)
  else parseLines events state.chunks state.bytes bytes

-- | Consuming the tail of a rejected command. Nothing is accumulated, so each
-- | further chunk of it is read and dropped rather than held.
discardingReader :: ReaderState
discardingReader = emptyReader { discarding = true }

parseLines
  :: Pid -> Bytes.Chunks -> Int -> Bytes -> Effect (Maybe ReaderState)
parseLines events chunks carried bytes =
  let
    newline = Bytes.indexOfByte bytes 0x0A 0
  in
    if newline < 0 then
      let
        total = carried + Bytes.size bytes
      in
        -- The line is already too long to be legal, so its remaining bytes are
        -- dropped without being retained.
        if total > maxCommandBytes then do
          delivered <- deliver events Oversized
          if delivered then
            pure (Just (discardingReader { abandoned = true }))
          else pure Nothing
        else pure
          ( Just
              { chunks: Bytes.pushChunk bytes chunks
              , bytes: total
              , discarding: false
              , abandoned: false
              }
          )
    else
      let
        prefix = Bytes.take newline bytes
        rest = Bytes.drop (newline + 1) bytes
        lineBytes = carried + Bytes.size prefix
      in
        if lineBytes > maxCommandBytes then do
          delivered <- deliver events Oversized
          if delivered then markAbandoned (parseLines events Bytes.emptyChunks 0 rest)
          else pure Nothing
        else do
          let line = Bytes.chunksToBytes (Bytes.pushChunk prefix chunks)
          delivered <- deliver events (Incoming line)
          if not delivered then pure Nothing
          -- Flattening copied the accumulated chunks into `line`, so a command
          -- that spanned more than one read leaves a second, dead copy of
          -- itself behind. Only the copy the controller was handed is live.
          else if carried > 0 then
            markAbandoned (parseLines events Bytes.emptyChunks 0 rest)
          else parseLines events Bytes.emptyChunks 0 rest

-- | Carry "a large accumulation was just dropped" out through the rest of the
-- | chunk, so the loop head collects once for the whole read rather than once
-- | for every command inside it.
markAbandoned :: Effect (Maybe ReaderState) -> Effect (Maybe ReaderState)
markAbandoned action = do
  advanced <- action
  pure (maybeMap (\state -> state { abandoned = true }) advanced)

deliver :: Pid -> (Pid -> Ref -> Event) -> Effect Boolean
deliver events build = do
  self <- Sys.selfPid
  reference <- Sys.newRef
  Sys.sendCommand events (build self reference)
  answer <- Sys.awaitReply reference ackTimeout
  pure (fromMaybe false answer)

-- ---------------------------------------------------------------------------
-- Writer
-- ---------------------------------------------------------------------------

data WriterMessage
  = Enqueue Bytes Pid Ref
  | SendDone Boolean String
  | FlushWhenIdle Pid Ref
  | StopWriter

-- | One event the writer has been offered but has not answered, because
-- | accepting it would breach the budget. It is not charged to the queue: the
-- | caller built the payload, is still holding it, and is still blocked on the
-- | answer, so the writer is not storing anything the caller was not already.
type Pending =
  { payload :: Bytes
  , size :: Int
  , replyPid :: Pid
  , replyRef :: Ref
  }

type Writer =
  { events :: Pid
  , sender :: Pid
  , queue :: List (Tuple Bytes Int)
  , count :: Int
  , bytes :: Int
  , inflight :: Maybe Int
  , pending :: Maybe Pending
  , waiters :: List (Tuple Pid Ref)
  }

-- | The writer owns the whole output budget. Its accounting includes the
-- | payload the sender is physically writing, so a blocked socket write can
-- | never hide memory from the bound.
startWriter :: Pid -> Channel -> Effect Pid
startWriter events channel = Sys.spawnProcess do
  self <- Sys.selfPid
  sender <- Sys.spawnProcess (senderLoop self channel)
  writerLoop
    { events: events
    , sender: sender
    , queue: Nil
    , count: 0
    , bytes: 0
    , inflight: Nothing
    , pending: Nothing
    , waiters: Nil
    }

writerLoop :: Writer -> Effect Unit
writerLoop writer = do
  incoming <- Sys.receiveCommand 60000
  case incoming of
    Nothing -> writerLoop writer
    -- Killing the sender before anything else bounds shutdown even when the
    -- peer has stopped reading and a write is blocked in the kernel.
    Just StopWriter -> voidEffect (Sys.killAndWait writer.sender 1000)
    Just (Enqueue payload replyPid replyRef) -> do
      admitted <- admit writer
        { payload: payload
        , size: Bytes.size payload
        , replyPid: replyPid
        , replyRef: replyRef
        }
      writerLoop admitted
    Just (SendDone ok reason) -> do
      let
        released = fromMaybe 0 writer.inflight
        settled = writer
          { count = writer.count - 1
          , bytes = writer.bytes - released
          , inflight = Nothing
          }
      unlessEffect ok (Sys.sendCommand settled.events (OutputFailed reason))
      dispatched <- dispatch settled
      resumed <- resume dispatched
      notified <- notify resumed
      writerLoop notified
    Just (FlushWhenIdle replyPid replyRef) ->
      if writer.count == 0 then do
        Sys.sendReply replyPid replyRef true
        writerLoop writer
      else writerLoop
        (writer { waiters = Cons (Tuple replyPid replyRef) writer.waiters })

-- | Take one event if the budget has room for it.
-- |
-- | A full queue is not by itself a stalled controller. This node runs on a
-- | single scheduler, so the process filling the queue routinely runs a whole
-- | burst before the process draining it is scheduled at all, and answering
-- | `Overflowed` on sight of a full queue would abandon a conformance run over
-- | ordinary scheduling. The writer holds the event unanswered instead and
-- | answers it when a completed write makes room, which leaves `emitTimeout` —
-- | the caller's own bound — as the thing that decides the peer has stopped
-- | reading. Memory is still bounded, because holding one unanswered event
-- | admits nothing to the queue.
admit :: Writer -> Pending -> Effect Writer
admit writer offered =
  if writer.count >= maxOutputCount
    || writer.bytes + offered.size > maxOutputBytes then
    case writer.pending of
      -- Only the controller emits, and it blocks until it is answered, so a
      -- second unanswered event means the first caller has already given up.
      -- Refuse it rather than accumulate callers.
      Just _ -> do
        Sys.sendReply offered.replyPid offered.replyRef Overflowed
        pure writer
      Nothing -> pure (writer { pending = Just offered })
  else do
    Sys.sendReply offered.replyPid offered.replyRef Emitted
    dispatch
      ( writer
          { queue = listSnoc writer.queue (Tuple offered.payload offered.size)
          , count = writer.count + 1
          , bytes = writer.bytes + offered.size
          }
      )

-- | Reconsider the held event now that a write has completed. It goes back to
-- | being held if the queue is still full.
resume :: Writer -> Effect Writer
resume writer = case writer.pending of
  Nothing -> pure writer
  Just held -> admit (writer { pending = Nothing }) held

dispatch :: Writer -> Effect Writer
dispatch writer = case writer.inflight, writer.queue of
  Nothing, Cons (Tuple payload size) rest -> do
    Sys.sendCommand writer.sender payload
    pure (writer { queue = rest, inflight = Just size })
  _, _ -> pure writer

notify :: Writer -> Effect Writer
notify writer =
  if writer.count /= 0 then pure writer
  else do
    forEach writer.waiters \(Tuple replyPid replyRef) ->
      Sys.sendReply replyPid replyRef true
    pure (writer { waiters = Nil })

-- | One sender may block in a write without growing any mailbox, because the
-- | writer will not hand it a second payload until this one completes.
senderLoop :: Pid -> Channel -> Effect Unit
senderLoop writer channel = do
  incoming <- Sys.receiveCommand 60000
  case incoming of
    Nothing -> senderLoop writer channel
    Just payload -> do
      written <- case channel of
        StdIo -> Sys.stdoutWrite payload
        TcpChannel socket -> Sys.send socket payload 1000
      case written of
        Right _ -> Sys.sendCommand writer (SendDone true "")
        Left reason -> Sys.sendCommand writer (SendDone false reason)
      senderLoop writer channel

emit :: Controller -> Json -> Effect EmitResult
emit controller event = do
  self <- Sys.selfPid
  reference <- Sys.newRef
  let payload = Bytes.append (Json.toBytes event) (Bytes.fromString "\n")
  Sys.sendCommand controller.writer (Enqueue payload self reference)
  answer <- Sys.awaitReply reference emitTimeout
  pure (fromMaybe Overflowed answer)

flush :: Pid -> Int -> Effect Boolean
flush writer timeout = do
  self <- Sys.selfPid
  reference <- Sys.newRef
  Sys.sendCommand writer (FlushWhenIdle self reference)
  answer <- Sys.awaitReply reference timeout
  pure (fromMaybe false answer)

-- ---------------------------------------------------------------------------
-- Mapping table
-- ---------------------------------------------------------------------------

assocGet :: List (Tuple String String) -> String -> Maybe String
assocGet entries key =
  maybeMap snd (listFind (\(Tuple name _) -> name == key) entries)

assocDelete
  :: List (Tuple String String) -> String -> List (Tuple String String)
assocDelete entries key = listFilter (\(Tuple name _) -> name /= key) entries
