-- | Convex Live: the reactive half of the client.
-- |
-- | One owner process holds every piece of sync state: the query-set version,
-- | the server's last transition version, each subscription's last value, and
-- | the reconnect schedule. Nothing else may touch that state, so a query-set
-- | version can never be written twice or skipped.
-- |
-- | A second process per connection owns the socket. It is a byte pipe: it
-- | connects, performs the WebSocket handshake, forwards raw bytes to the
-- | owner, and writes the frames the owner hands it. Frame decoding stays in
-- | the owner, which is what lets a read timeout be harmless part-way through
-- | a frame — the parser state is in the owner and simply waits for more bytes.
-- |
-- | A third process per subscription, the relay, carries one event at a time
-- | towards the subscriber. It must ask the owner for permission immediately
-- | before delivery, so unsubscribing or replacing a subscription is a real
-- | barrier rather than a timing assumption: the owner erases the generation
-- | first, and any event the relay is still holding is then discarded.
module Convex.Live
  ( Live
  , LiveEvent(..)
  , SubscriptionEvent
  , GateHeld
  , acknowledge
  , start
  , subscribe
  , unsubscribe
  , debugDisconnect
  , close
  , timestampNumber
  , maxSubscriptions
  , maxQueueCount
  , maxQueueBytes
  ) where

import Convex.Prelude
import Convex.Bytes (Bytes)
import Convex.Bytes as Bytes
import Convex.Error (ConvexError)
import Convex.Error as Error
import Convex.Http (Url)
import Convex.Json (Json(..))
import Convex.Json as Json
import Convex.Sys (Pid, Ref, RecvResult(..), Socket, Timer)
import Convex.Sys as Sys
import Convex.Ws as Ws

-- | The zero timestamp every connection starts from: base64 of eight zero
-- | bytes, exactly as the pinned sync profile spells it.
initialTimestamp :: String
initialTimestamp = "AAAAAAAAAAA="

syncPath :: String
syncPath = "/api/sync"

-- | Identifies this client to the deployment. Convex logs it, which makes a
-- | hosted verification run traceable back to this language.
clientHeader :: String
clientHeader = "purescript-0.1.0"

-- | Newest undelivered events retained per subscription, and the byte budget
-- | that bounds them. The event a relay is physically holding counts against
-- | both, so a slow subscriber cannot hide memory from the accounting.
maxQueueCount :: Int
maxQueueCount = 16

-- | Charges encoded bytes four times plus a fixed record allowance, so the
-- | bound covers decoded BEAM terms as well as the JSON text used to size them.
maxQueueBytes :: Int
maxQueueBytes = 8388608

eventOverhead :: Int
eventOverhead = 1024

maxSubscriptions :: Int
maxSubscriptions = 8

maxSubscriptionBytes :: Int
maxSubscriptionBytes = 8388608

maxRetiringQueries :: Int
maxRetiringQueries = 128

initialBackoff :: Int
initialBackoff = 100

maxBackoff :: Int
maxBackoff = 15000

-- | How long a connection may take to reach an accepted WebSocket upgrade.
handshakeTimeout :: Int
handshakeTimeout = 5000

-- | How long the connection process blocks in one read before looking at its
-- | command mailbox again. Buffered bytes and partial frames live in the
-- | owner, so returning from a read early costs nothing.
readPoll :: Int
readPoll = 200

-- | Once the first byte of a message has arrived, continuous dribbling must
-- | not keep its parser state alive forever.
messageTimeout :: Int
messageTimeout = 3000

-- | Bound on retiring a worker. Killing is the barrier; this is how long we
-- | are willing to wait for the death certificate.
retireTimeout :: Int
retireTimeout = 1000

-- | A brief idle grace period lets the adapter replace one identifier with
-- | another over the same socket after it has observed the required Remove.
-- | It still releases a client that genuinely has no subscriptions.
idleCloseDelay :: Int
idleCloseDelay = 1000

frameSendTimeout :: Int
frameSendTimeout = 3000

replyTimeout :: Int
replyTimeout = 5000

-- ---------------------------------------------------------------------------
-- Public shapes
-- ---------------------------------------------------------------------------

-- | What a subscriber receives.
data LiveEvent
  -- | A new value for the query, with any log lines the query produced.
  = LiveValue Json (List String)
  -- | The query failed, the connection dropped, or the peer drifted from the
  -- | pinned protocol. The subscription stays alive and can recover.
  | LiveFailure ConvexError

-- | One delivery to a subscriber's mailbox. The subscriber must call
-- | `acknowledge` before the relay will carry anything else, which is what
-- | keeps a stopped reader from accumulating messages outside the queue bound.
type SubscriptionEvent =
  { subscriptionId :: String
  , event :: LiveEvent
  , ackPid :: Pid
  , ackRef :: Ref
  }

acknowledge :: SubscriptionEvent -> Effect Unit
acknowledge delivery = Sys.sendReply delivery.ackPid delivery.ackRef true

-- | A handle on the Live owner.
type Live = { owner :: Pid }

-- | A test-only pause point. `Convex.new` never installs one; the
-- | deterministic relay tests use it to hold an event after it has been
-- | dequeued and prove no stale value can cross an unsubscribe acknowledgement.
-- | It arrives on the gate process's command channel, which keeps it clear of
-- | the event channel a subscriber is using.
type GateHeld =
  { releasePid :: Pid
  , releaseRef :: Ref
  , subscriptionId :: String
  , event :: LiveEvent
  }

-- ---------------------------------------------------------------------------
-- Internal messages
-- ---------------------------------------------------------------------------

data Command
  = DoSubscribe String Json Pid Pid Ref
  | DoUnsubscribe String Pid Ref
  | DoDebugDisconnect Pid Ref
  | DoClose Pid Ref
  -- | A relay is holding an event and asks whether it may still be delivered.
  | RelayDelivery String Int Int Pid Ref
  -- | A relay has finished with an event and can take the next one.
  | RelayReady String Int Int
  | ConnUp Int Bytes
  | ConnBytes Int Bytes Pid Ref
  | ConnDown Int String
  | HandshakeExpired Int
  | FrameExpired Int Int
  | ReconnectDue Int
  | IdleClose Int

-- | What the owner can ask a connection process to do.
data ConnCommand
  = ConnSend Bytes
  -- | A final Remove must reach the kernel before the owner retires the last
  -- | connection, otherwise an eager close erases it from the wire.
  | ConnSendAndAcknowledge Bytes Pid Ref
  | ConnStop

data RelayMessage = RelayEvent String Int Int LiveEvent Pid

data DrainResult
  = Drained
  | Stopped
  | SendFailed String

data Modification
  = Add
  | Remove

type Connection =
  { id :: Int
  , pid :: Pid
  , ready :: Boolean
  , decoder :: Ws.Decoder
  , frameTimer :: Maybe Timer
  , frameToken :: Int
  }

type Subscription =
  { queryId :: Int
  , path :: String
  , args :: Json
  , sink :: Pid
  , generation :: Int
  , relayPid :: Pid
  , last :: Maybe Json
  , queue :: List (Tuple LiveEvent Int)
  , queueCount :: Int
  , queueBytes :: Int
  , relayBusy :: Boolean
  , inflightToken :: Maybe Int
  , inflightBytes :: Int
  -- | Next delivery token. Tokens only need to be unique within one
  -- | subscription, so a per-subscription counter is enough.
  , nextToken :: Int
  , charge :: Int
  }

type State =
  { self :: Pid
  , url :: Url
  , verifyPeer :: Boolean
  , gate :: Maybe Pid
  , connection :: Maybe Connection
  , nextConnectionId :: Int
  , subscriptions :: List (Tuple String Subscription)
  , activeBytes :: Int
  , retiring :: List Int
  , nextQueryId :: Int
  , sessionId :: String
  -- | The version this client has written up to.
  , querySet :: Int
  -- | The version the server last confirmed.
  , remoteQuerySet :: Int
  , remoteIdentity :: Int
  , remoteTimestamp :: String
  , maxObservedTimestamp :: Maybe String
  , connectionCount :: Int
  , lastCloseReason :: String
  , backoff :: Int
  , reconnect :: Maybe Timer
  , reconnectToken :: Int
  , handshake :: Maybe Timer
  , idleClose :: Maybe Timer
  , idleCloseToken :: Int
  -- | Generations are handed out from here. A subscription's generation is
  -- | what a relay must still match to be allowed to deliver.
  , nextGeneration :: Int
  }

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- | Start the single owner for a deployment. One client has exactly one owner,
-- | so subscriptions share one WebSocket and one query set.
start :: Url -> Boolean -> Maybe Pid -> Effect Live
start url verifyPeer gate = do
  owner <- Sys.spawnProcess do
    self <- Sys.selfPid
    session <- sessionIdentifier
    loop (initialState self session url verifyPeer gate)
  pure { owner: owner }

-- | Add a query to the subscribed set and return its client-side identifier.
-- | `Nothing` means the owner refused, which happens only at the documented
-- | subscription-count or byte bound.
subscribe :: Live -> String -> Json -> Pid -> Effect (Maybe String)
subscribe live path args sink = do
  self <- Sys.selfPid
  reference <- Sys.newRef
  Sys.sendCommand live.owner (DoSubscribe path args sink self reference)
  answer <- Sys.awaitReply reference replyTimeout
  pure (fromMaybe Nothing answer)

-- | Remove a query. When this returns, no further event for that subscription
-- | can reach the sink, including one a relay had already dequeued.
unsubscribe :: Live -> String -> Effect Boolean
unsubscribe live subscriptionId =
  request live \self reference ->
    DoUnsubscribe subscriptionId self reference

-- | Adapter-only: drop the current connection and reconnect.
-- |
-- | This is how the shared conformance controller proves real reconnects. It
-- | is not part of the educational client API, and the acknowledgement is only
-- | sent after the old connection is retired and the replacement is scheduled.
debugDisconnect :: Live -> Effect Boolean
debugDisconnect live = request live DoDebugDisconnect

-- | Stop the owner, its connection, and every relay.
close :: Live -> Effect Boolean
close live = request live DoClose

request :: Live -> (Pid -> Ref -> Command) -> Effect Boolean
request live build = do
  self <- Sys.selfPid
  reference <- Sys.newRef
  Sys.sendCommand live.owner (build self reference)
  answer <- Sys.awaitReply reference replyTimeout
  pure (fromMaybe false answer)

-- ---------------------------------------------------------------------------
-- Owner
-- ---------------------------------------------------------------------------

initialState :: Pid -> String -> Url -> Boolean -> Maybe Pid -> State
initialState self session url verifyPeer gate =
  { self: self
  , url: url
  , verifyPeer: verifyPeer
  , gate: gate
  , connection: Nothing
  , nextConnectionId: 1
  , subscriptions: Nil
  , activeBytes: 0
  , retiring: Nil
  , nextQueryId: 0
  , sessionId: session
  , querySet: 0
  , remoteQuerySet: 0
  , remoteIdentity: 0
  , remoteTimestamp: initialTimestamp
  , maxObservedTimestamp: Nothing
  , connectionCount: 0
  , lastCloseReason: "InitialConnect"
  , backoff: initialBackoff
  , reconnect: Nothing
  , reconnectToken: 0
  , handshake: Nothing
  , idleClose: Nothing
  , idleCloseToken: 0
  , nextGeneration: 1
  }

-- | The owner's mailbox loop. A receive timeout is not an event; it just means
-- | nothing happened, so the loop re-arms rather than treating it as a failure.
loop :: State -> Effect Unit
loop state = do
  incoming <- Sys.receiveCommand 60000
  case incoming of
    Nothing -> loop state
    Just command -> do
      outcome <- handle command state
      case outcome of
        Nothing -> pure unit
        Just continuing -> loop continuing

handle :: Command -> State -> Effect (Maybe State)
handle command state = case command of
  DoSubscribe path args sink replyPid replyRef -> do
    cleared <- cancelIdleClose state
    let
      queryId = cleared.nextQueryId
      charge = subscriptionCharge path args
    if
      listLength cleared.subscriptions >= maxSubscriptions
        || cleared.activeBytes + charge > maxSubscriptionBytes
        || queryId >= maxUnsigned32 then do
      Sys.sendReply replyPid replyRef (Nothing :: Maybe String)
      pure (Just cleared)
    else do
      relayPid <- Sys.spawnProcess (relayLoop cleared.self cleared.gate)
      let
        subscriptionId = intToString queryId
        subscription =
          { queryId: queryId
          , path: path
          , args: args
          , sink: sink
          , generation: cleared.nextGeneration
          , relayPid: relayPid
          , last: Nothing
          , queue: Nil
          , queueCount: 0
          , queueBytes: 0
          , relayBusy: false
          , inflightToken: Nothing
          , inflightBytes: 0
          , nextToken: 1
          , charge: charge
          }
        registered = cleared
          { nextQueryId = queryId + 1
          , nextGeneration = cleared.nextGeneration + 1
          , activeBytes = cleared.activeBytes + charge
          , subscriptions = assocPut cleared.subscriptions subscriptionId
              subscription
          }
      Sys.sendReply replyPid replyRef (Just subscriptionId)
      added <- sendModify Add subscription registered
      connected <- ensureConnected added
      pure (Just connected)

  DoUnsubscribe subscriptionId replyPid replyRef ->
    case assocGet state.subscriptions subscriptionId of
      Nothing -> do
        Sys.sendReply replyPid replyRef true
        pure (Just state)
      Just subscription -> do
        -- Retire the relay before acknowledging. Once it is dead it cannot
        -- obtain delivery permission, so no stale event can cross this line.
        retire subscription.relayPid
        let
          removed = state
            { activeBytes = state.activeBytes - subscription.charge
            , subscriptions = assocDelete state.subscriptions subscriptionId
            }
        settled <-
          if listNull removed.subscriptions then
            removeThenIdleClose subscription removed
          else do
            retired <- retireRemoteQuery subscription removed
            ensureConnected retired
        Sys.sendReply replyPid replyRef true
        pure (Just settled)

  DoDebugDisconnect replyPid replyRef -> do
    -- Retire the old connection first, then schedule the replacement, and only
    -- then acknowledge. The shared controller relies on that ordering.
    dropped <- disconnect "adapter debug disconnect" state
    reconnected <- ensureConnected dropped
    Sys.sendReply replyPid replyRef true
    pure (Just reconnected)

  DoClose replyPid replyRef -> do
    dropped <- disconnect "client closed" state
    forEach dropped.subscriptions \(Tuple _ subscription) ->
      retire subscription.relayPid
    Sys.sendReply replyPid replyRef true
    pure Nothing

  RelayDelivery subscriptionId generation token replyPid replyRef -> do
    -- Permission is granted only if this subscription still exists, still has
    -- the same generation, and is still waiting on this exact event.
    let
      allowed = case assocGet state.subscriptions subscriptionId of
        Just subscription ->
          subscription.generation == generation
            && subscription.inflightToken == Just token
        Nothing -> false
    Sys.sendReply replyPid replyRef allowed
    pure (Just state)

  RelayReady subscriptionId generation token ->
    case assocGet state.subscriptions subscriptionId of
      Nothing -> pure (Just state)
      Just subscription ->
        -- A ready message from a retired relay must not clear the charge held
        -- by its replacement.
        if
          subscription.generation /= generation
            || subscription.inflightToken /= Just token then pure (Just state)
        else do
          advanced <- dispatchNext subscriptionId
            ( subscription
                { relayBusy = false
                , inflightToken = Nothing
                , inflightBytes = 0
                }
            )
          pure (Just (putSubscription state subscriptionId advanced))

  ConnUp connectionId leftover ->
    case currentConnection state connectionId of
      Nothing -> pure (Just state)
      Just active -> do
        -- A completed upgrade is a healthy transport boundary, so a later
        -- brief outage does not inherit backoff from earlier failures.
        cleared <- cancelHandshake state
        let
          ready = cleared
            { backoff = initialBackoff
            , connection = Just (active { ready = true })
            }
        greeted <- sendJson (connectMessage ready) ready
        resent <- resendAll greeted
        consumed <- consume connectionId leftover resent
        pure (Just consumed)

  ConnBytes connectionId bytes ackPid ackRef ->
    case currentConnection state connectionId of
      Nothing -> do
        Sys.sendReply ackPid ackRef true
        pure (Just state)
      Just _ -> do
        consumed <- consume connectionId bytes state
        Sys.sendReply ackPid ackRef true
        pure (Just consumed)

  ConnDown connectionId reason ->
    case currentConnection state connectionId of
      Nothing -> pure (Just state)
      Just _ -> mapEffect Just (transportReconnect reason state)

  HandshakeExpired connectionId ->
    case currentConnection state connectionId of
      Nothing -> pure (Just state)
      Just active ->
        if active.ready then pure (Just state)
        else mapEffect Just
          ( transportReconnect "WebSocket handshake timed out"
              (state { handshake = Nothing })
          )

  FrameExpired connectionId token ->
    case currentConnection state connectionId of
      Nothing -> pure (Just state)
      Just active ->
        if active.frameToken == token && Ws.isMidMessage active.decoder then
          mapEffect Just
            (protocolReconnect "WebSocket message deadline exceeded" state)
        else pure (Just state)

  ReconnectDue token ->
    if token /= state.reconnectToken then pure (Just state)
    else mapEffect Just (ensureConnected (state { reconnect = Nothing }))

  IdleClose token ->
    if token == state.idleCloseToken && listNull state.subscriptions then
      mapEffect Just (disconnect "no active subscriptions" state)
    else pure (Just state)

-- | Ignore anything that arrives from a connection the owner has already
-- | retired. Late messages from a dead connection are normal, not errors.
currentConnection :: State -> Int -> Maybe Connection
currentConnection state connectionId = case state.connection of
  Nothing -> Nothing
  Just connection ->
    if connection.id == connectionId then Just connection else Nothing

subscriptionCharge :: String -> Json -> Int
subscriptionCharge path args =
  stringByteLength path + Bytes.size (Json.toBytes args) + 512

retire :: Pid -> Effect Unit
retire pid = voidEffect (Sys.killAndWait pid retireTimeout)

retireRemoteQuery :: Subscription -> State -> Effect State
retireRemoteQuery subscription state =
  if not (isReady state) then pure state
  else if listLength state.retiring >= maxRetiringQueries then
    disconnect "retiring query capacity reached" state
  else sendModify Remove subscription
    (state { retiring = Cons subscription.queryId state.retiring })

-- ---------------------------------------------------------------------------
-- Connection lifecycle
-- ---------------------------------------------------------------------------

-- | Open a connection when one is wanted. With no subscriptions there is
-- | nothing to sync, so an idle client holds no socket.
ensureConnected :: State -> Effect State
ensureConnected state =
  if isJust state.connection || listNull state.subscriptions then pure state
  else do
    let connectionId = state.nextConnectionId
    pid <- Sys.spawnProcess
      (connectionMain state.self connectionId state.url state.verifyPeer)
    timer <- Sys.sendCommandAfter state.self handshakeTimeout
      (HandshakeExpired connectionId)
    pure
      ( state
          { nextConnectionId = connectionId + 1
          , handshake = Just timer
          , connection = Just
              { id: connectionId
              , pid: pid
              , ready: false
              , decoder: Ws.newDecoder
              , frameTimer: Nothing
              , frameToken: 0
              }
          }
      )

-- | The connection process: connect, upgrade, then pipe bytes both ways.
connectionMain :: Pid -> Int -> Url -> Boolean -> Effect Unit
connectionMain owner connectionId url verifyPeer = do
  now <- Sys.monotonicMs
  let deadline = now + handshakeTimeout
  opened <- Sys.connect url.secure url.host url.port handshakeTimeout
    verifyPeer
  case opened of
    Left reason -> Sys.sendCommand owner (ConnDown connectionId reason)
    Right socket -> do
      upgraded <- Ws.handshake socket url.authority
        (url.basePath <> syncPath)
        (listSingleton (Tuple "convex-client" clientHeader))
        deadline
      case upgraded of
        Left reason -> do
          Sys.close socket
          Sys.sendCommand owner (ConnDown connectionId reason)
        Right leftover -> do
          Sys.sendCommand owner (ConnUp connectionId leftover)
          connectionLoop owner connectionId socket

connectionLoop :: Pid -> Int -> Socket -> Effect Unit
connectionLoop owner connectionId socket = do
  drained <- drainConnCommands socket
  case drained of
    Stopped -> Sys.close socket
    SendFailed reason -> do
      Sys.close socket
      Sys.sendCommand owner (ConnDown connectionId reason)
    Drained -> do
      outcome <- Sys.recv socket 0 readPoll
      case outcome of
        Received bytes -> do
          self <- Sys.selfPid
          reference <- Sys.newRef
          Sys.sendCommand owner (ConnBytes connectionId bytes self reference)
          acknowledged <- Sys.awaitReply reference replyTimeout
          if fromMaybe false acknowledged then
            connectionLoop owner connectionId socket
          else do
            Sys.close socket
            Sys.sendCommand owner
              (ConnDown connectionId "Live owner stopped acknowledging bytes")
        -- Nothing arrived in this window. The owner holds the decoder, so
        -- there is no parser state here to lose.
        RecvTimeout -> connectionLoop owner connectionId socket
        RecvClosed -> do
          Sys.close socket
          Sys.sendCommand owner
            (ConnDown connectionId "WebSocket closed by peer")
        RecvFailed reason -> do
          Sys.close socket
          Sys.sendCommand owner (ConnDown connectionId reason)

-- | Write every queued frame before the next read.
drainConnCommands :: Socket -> Effect DrainResult
drainConnCommands socket = do
  incoming <- Sys.receiveCommand 0
  case incoming of
    Nothing -> pure Drained
    Just ConnStop -> pure Stopped
    Just (ConnSend frame) -> do
      written <- Sys.send socket frame frameSendTimeout
      case written of
        Right _ -> drainConnCommands socket
        Left reason -> pure (SendFailed reason)
    Just (ConnSendAndAcknowledge frame replyPid replyRef) -> do
      written <- Sys.send socket frame frameSendTimeout
      case written of
        Right _ -> do
          Sys.sendReply replyPid replyRef true
          drainConnCommands socket
        Left _ -> do
          Sys.sendReply replyPid replyRef false
          pure (SendFailed "the connection could not write the final removal")

-- | Retire the current connection and reset the per-connection sync state. The
-- | query-set version restarts at zero because the next connection negotiates
-- | it from scratch.
disconnect :: String -> State -> Effect State
disconnect reason state = do
  withoutHandshake <- cancelHandshake state
  withoutReconnect <- cancelReconnect withoutHandshake
  cleared <- cancelIdleClose withoutReconnect
  case cleared.connection of
    Nothing -> pure unit
    Just connection -> do
      case connection.frameTimer of
        Nothing -> pure unit
        Just timer -> Sys.cancelTimer timer
      -- Killing the socket's owning process closes the socket, which is what
      -- makes shutdown bounded even against a peer that never responds.
      Sys.sendCommand connection.pid ConnStop
      retire connection.pid
  pure
    ( cleared
        { connection = Nothing
        , querySet = 0
        , remoteQuerySet = 0
        , remoteIdentity = 0
        , remoteTimestamp = initialTimestamp
        , retiring = Nil
        , connectionCount = cleared.connectionCount + 1
        , lastCloseReason = reason
        }
    )

scheduleReconnect :: String -> State -> Effect State
scheduleReconnect reason state =
  if listNull state.subscriptions || isJust state.reconnect then
    pure (state { lastCloseReason = reason })
  else do
    let token = state.reconnectToken + 1
    timer <- Sys.sendCommandAfter state.self state.backoff (ReconnectDue token)
    pure
      ( state
          { reconnect = Just timer
          , reconnectToken = token
          , backoff = minInt maxBackoff (state.backoff * 2)
          , lastCloseReason = reason
          }
      )

cancelHandshake :: State -> Effect State
cancelHandshake state = case state.handshake of
  Nothing -> pure state
  Just timer -> do
    Sys.cancelTimer timer
    pure (state { handshake = Nothing })

cancelReconnect :: State -> Effect State
cancelReconnect state = case state.reconnect of
  Nothing -> pure state
  Just timer -> do
    Sys.cancelTimer timer
    pure (state { reconnect = Nothing })

cancelIdleClose :: State -> Effect State
cancelIdleClose state = case state.idleClose of
  Nothing -> pure state
  Just timer -> do
    Sys.cancelTimer timer
    pure (state { idleClose = Nothing })

-- | A protocol failure is drift: report it to every subscription, then rebuild
-- | the connection from a known state.
protocolReconnect :: String -> State -> Effect State
protocolReconnect message state = do
  told <- broadcast (Error.protocolError message) state
  dropped <- disconnect message told
  scheduleReconnect message dropped

-- | A transport failure is also an observable subscription event. The
-- | adapter-forced disconnect deliberately does not come through here: it is
-- | an acknowledged test action, not a failure.
transportReconnect :: String -> State -> Effect State
transportReconnect reason state = do
  told <- broadcast (Error.transportError reason) state
  dropped <- disconnect reason told
  scheduleReconnect reason dropped

broadcast :: ConvexError -> State -> Effect State
broadcast error state =
  foldEffect state state.subscriptions \carried (Tuple subscriptionId _) ->
    case assocGet carried.subscriptions subscriptionId of
      Nothing -> pure carried
      Just subscription -> do
        queued <- enqueue subscriptionId (LiveFailure error) subscription
        pure (putSubscription carried subscriptionId queued)

-- ---------------------------------------------------------------------------
-- Sync protocol
-- ---------------------------------------------------------------------------

connectMessage :: State -> Json
connectMessage state =
  let
    base = Cons (Tuple "type" (JsonString "Connect"))
      ( Cons (Tuple "sessionId" (JsonString state.sessionId))
          ( Cons (Tuple "connectionCount" (JsonInt state.connectionCount))
              ( Cons (Tuple "lastCloseReason" (JsonString state.lastCloseReason))
                  (listSingleton (Tuple "clientTs" (JsonInt 0)))
              )
          )
      )
  in
    case state.maxObservedTimestamp of
      Nothing -> JsonObject base
      Just timestamp -> JsonObject
        (listSnoc base (Tuple "maxObservedTimestamp" (JsonString timestamp)))

-- | A version 4 UUID built from strong random bytes, in the shape the sync
-- | protocol expects for a session identifier. The same identifier is reused
-- | across reconnects so the deployment can recognise the returning client.
sessionIdentifier :: Effect String
sessionIdentifier = do
  bytes <- Sys.randomBytes 16
  let
    -- Byte 6 carries the version nibble and byte 8 the variant bits.
    octet index =
      if index == 6 then bitOr (bitAnd (Bytes.byteAt bytes 6) 0x0F) 0x40
      else if index == 8 then bitOr (bitAnd (Bytes.byteAt bytes 8) 0x3F) 0x80
      else Bytes.byteAt bytes index
    group from to = listConcatMapString
      (\index -> intToLowerHex (octet index) 2)
      (listRange from to)
  pure
    ( stringJoin
        ( Cons (group 0 3)
            ( Cons (group 4 5)
                ( Cons (group 6 7)
                    (Cons (group 8 9) (listSingleton (group 10 15)))
                )
            )
        )
        "-"
    )

-- | Write one query-set modification. Every write advances the version by
-- | exactly one, which is why only the owner may build these.
sendModify :: Modification -> Subscription -> State -> Effect State
sendModify kind subscription state =
  if not (isReady state) then pure state
  else if state.querySet >= maxUnsigned32 then
    protocolReconnect "Live query-set version is exhausted" state
  else do
    let
      entry = case kind of
        Add -> JsonObject
          ( Cons (Tuple "type" (JsonString "Add"))
              ( Cons (Tuple "queryId" (JsonInt subscription.queryId))
                  ( Cons (Tuple "udfPath" (JsonString subscription.path))
                      ( listSingleton
                          ( Tuple "args"
                              (JsonArray (listSingleton subscription.args))
                          )
                      )
                  )
              )
          )
        Remove -> JsonObject
          ( Cons (Tuple "type" (JsonString "Remove"))
              (listSingleton (Tuple "queryId" (JsonInt subscription.queryId)))
          )
    sendJson (modifyQuerySet state.querySet entry)
      (state { querySet = state.querySet + 1 })

modifyQuerySet :: Int -> Json -> Json
modifyQuerySet baseVersion modification = JsonObject
  ( Cons (Tuple "type" (JsonString "ModifyQuerySet"))
      ( Cons (Tuple "baseVersion" (JsonInt baseVersion))
          ( Cons (Tuple "newVersion" (JsonInt (baseVersion + 1)))
              ( listSingleton
                  (Tuple "modifications" (JsonArray (listSingleton modification)))
              )
          )
      )
  )

-- | Remove the last query as an acknowledged connection command, then close an
-- | otherwise idle socket after a short replacement grace period. `ConnSend`
-- | is intentionally asynchronous for normal traffic, but using it here would
-- | race the final close and make the required Remove vanish from the wire.
removeThenIdleClose :: Subscription -> State -> Effect State
removeThenIdleClose subscription state = case state.connection of
  Just connection | connection.ready -> do
    self <- Sys.selfPid
    reference <- Sys.newRef
    let
      entry = JsonObject
        ( Cons (Tuple "type" (JsonString "Remove"))
            (listSingleton (Tuple "queryId" (JsonInt subscription.queryId)))
        )
    frame <- Ws.textFrame
      (Json.toString (modifyQuerySet state.querySet entry))
    Sys.sendCommand connection.pid
      (ConnSendAndAcknowledge frame self reference)
    written <- Sys.awaitReply reference frameSendTimeout
    case written of
      Just true -> scheduleIdleClose (state { querySet = state.querySet + 1 })
      Just _ -> transportReconnect "the final query removal was not written"
        state
      Nothing ->
        transportReconnect "timed out sending the final query removal" state
  _ -> disconnect "no active subscriptions" state

scheduleIdleClose :: State -> Effect State
scheduleIdleClose state = do
  let token = state.idleCloseToken + 1
  timer <- Sys.sendCommandAfter state.self idleCloseDelay (IdleClose token)
  pure (state { idleClose = Just timer, idleCloseToken = token })

-- | Every connection re-adds the active subscriptions, because the server
-- | keeps no memory of a connection that has gone away.
resendAll :: State -> Effect State
resendAll state =
  let
    ordered = listSortBy
      (\(Tuple _ left) (Tuple _ right) -> left.queryId < right.queryId)
      state.subscriptions
  in
    foldEffect state ordered \carried (Tuple _ subscription) ->
      sendModify Add subscription carried

isReady :: State -> Boolean
isReady state = case state.connection of
  Nothing -> false
  Just connection -> connection.ready

sendJson :: Json -> State -> Effect State
sendJson message state = case state.connection of
  Just connection | connection.ready -> do
    frame <- Ws.textFrame (Json.toString message)
    Sys.sendCommand connection.pid (ConnSend frame)
    pure state
  _ -> pure state

-- | Feed freshly read bytes into the connection's decoder and act on every
-- | complete message it yields.
consume :: Int -> Bytes -> State -> Effect State
consume connectionId bytes state = case currentConnection state connectionId of
  Nothing -> pure state
  Just active -> drainFrames connectionId (Ws.feed active.decoder bytes) state

drainFrames :: Int -> Ws.Decoder -> State -> Effect State
drainFrames connectionId decoder state = case Ws.next decoder of
  Ws.NeedMore pending -> storeDecoder connectionId pending state
  Ws.Failed reason -> protocolReconnect reason state
  Ws.Decoded message pending -> do
    stored <- storeDecoder connectionId pending state
    outcome <- handleMessage connectionId message stored
    case outcome of
      -- A message that retires the connection also discards its decoder, so
      -- the frames still buffered behind it belong to nothing and are dropped.
      Left ended -> pure ended
      Right continuing -> drainFrames connectionId pending continuing

storeDecoder :: Int -> Ws.Decoder -> State -> Effect State
storeDecoder connectionId decoder state =
  case currentConnection state connectionId of
    Nothing -> pure state
    Just active ->
      if Ws.isMidMessage decoder then case active.frameTimer of
        Just _ ->
          pure (state { connection = Just (active { decoder = decoder }) })
        Nothing -> do
          let token = active.frameToken + 1
          timer <- Sys.sendCommandAfter state.self messageTimeout
            (FrameExpired connectionId token)
          pure
            ( state
                { connection = Just
                    ( active
                        { decoder = decoder
                        , frameTimer = Just timer
                        , frameToken = token
                        }
                    )
                }
            )
      else case active.frameTimer of
        Nothing ->
          pure (state { connection = Just (active { decoder = decoder }) })
        Just timer -> do
          Sys.cancelTimer timer
          pure
            ( state
                { connection = Just
                    ( active
                        { decoder = decoder
                        , frameTimer = Nothing
                        , frameToken = active.frameToken + 1
                        }
                    )
                }
            )

-- | Act on one WebSocket message. `Left` means the connection is gone.
handleMessage :: Int -> Ws.Message -> State -> Effect (Either State State)
handleMessage connectionId message state = case message of
  Ws.TextMessage text -> handleSyncText text state
  Ws.BinaryMessage _ -> mapEffect Left
    (protocolReconnect "unexpected binary sync frame" state)
  Ws.Ping payload -> do
    case currentConnection state connectionId of
      Just connection -> do
        frame <- Ws.pongFrame payload
        Sys.sendCommand connection.pid (ConnSend frame)
      Nothing -> pure unit
    pure (Right state)
  Ws.Pong _ -> pure (Right state)
  Ws.Close code reason -> mapEffect Left
    ( transportReconnect
        ("WebSocket close " <> intToString code <> ": " <> reason)
        state
    )

handleSyncText :: String -> State -> Effect (Either State State)
handleSyncText text state = case Json.parse text of
  Left _ -> mapEffect Left (protocolReconnect "invalid sync JSON" state)
  Right message -> case Json.stringField message "type" of
    Just "Transition" -> applyTransition message state
    Just "Ping" -> pure (Right state)
    Just "FatalError" -> mapEffect Left
      (protocolReconnect (fatalMessage message) state)
    Just other -> mapEffect Left
      (protocolReconnect ("unexpected sync message " <> other) state)
    Nothing -> mapEffect Left
      (protocolReconnect "sync message has no type" state)

fatalMessage :: Json -> String
fatalMessage message = case Json.stringField message "error" of
  Just detail -> detail
  Nothing -> "server reported a fatal sync error"

data Change
  = ChangedValue Int Json (List String)
  | ChangedFailure Int ConvexError
  | ChangedRemoved Int

type Transition =
  { endQuerySet :: Int
  , endIdentity :: Int
  , endTimestamp :: String
  , changes :: List Change
  }

-- | A Transition is atomic: validate the whole message, then apply it.
-- |
-- | Validating first matters because a malformed tail must not be able to leak
-- | an earlier value from the same Transition, or to advance the version
-- | counters half way.
applyTransition :: Json -> State -> Effect (Either State State)
applyTransition message state = case transitionParts message state of
  Left reason -> mapEffect Left (protocolReconnect reason state)
  Right transition -> do
    let
      advanced = state
        { remoteQuerySet = transition.endQuerySet
        , remoteIdentity = transition.endIdentity
        , remoteTimestamp = transition.endTimestamp
        , maxObservedTimestamp = observedMax state.maxObservedTimestamp
            transition.endTimestamp
        -- A valid server transition proves the connection works.
        , backoff = initialBackoff
        }
    applied <- foldEffect advanced transition.changes applyChange
    pure (Right applied)

transitionParts :: Json -> State -> Either String Transition
transitionParts message state =
  eitherThen
    ( require (Json.field message "startVersion")
        "Transition has no startVersion"
    ) \rawStart ->
    eitherThen
      (require (Json.field message "endVersion") "Transition has no endVersion")
      \rawEnd ->
      eitherThen
        ( require (maybeThen (Json.field message "modifications") Json.asArray)
            "Transition has no modifications"
        ) \modifications ->
        eitherThen (version rawStart) \startVersion ->
          eitherThen (version rawEnd) \endVersion ->
            eitherThen
              ( require (timestampNumber startVersion.timestamp)
                  "Transition has an invalid start timestamp"
              ) \startNumber ->
              eitherThen
                ( require (timestampNumber endVersion.timestamp)
                    "Transition has an invalid end timestamp"
                ) \endNumber ->
                if
                  startVersion.querySet /= state.remoteQuerySet
                    || startVersion.identity /= state.remoteIdentity
                    || startVersion.timestamp /= state.remoteTimestamp then
                  Left "Transition does not continue the current version"
                else if endNumber < startNumber then
                  Left "Transition timestamp went backwards"
                else if
                  endVersion.querySet < startVersion.querySet
                    || endVersion.querySet > state.querySet
                    || endVersion.identity < startVersion.identity then
                  Left
                    "Transition version moved backwards or acknowledged unsent work"
                else
                  eitherThen (listTraverseEither modification modifications)
                    \changes ->
                      eitherThen (validateChanges changes state Nil) \_ ->
                        Right
                          { endQuerySet: endVersion.querySet
                          , endIdentity: endVersion.identity
                          , endTimestamp: endVersion.timestamp
                          , changes: changes
                          }

require :: forall a. Maybe a -> String -> Either String a
require value message = case value of
  Nothing -> Left message
  Just inner -> Right inner

type Version =
  { querySet :: Int
  , identity :: Int
  , timestamp :: String
  }

version :: Json -> Either String Version
version value =
  eitherThen
    (require (Json.u32Field value "querySet") "sync version has no querySet")
    \querySet ->
    eitherThen
      (require (Json.u32Field value "identity") "sync version has no identity")
      \identity ->
      eitherThen
        (require (Json.stringField value "ts") "sync version has no ts")
        \timestamp ->
        Right { querySet: querySet, identity: identity, timestamp: timestamp }

modification :: Json -> Either String Change
modification value =
  eitherThen
    (require (Json.u32Field value "queryId") "modification has no queryId")
    \queryId ->
    eitherThen
      (require (Json.logLines value) "modification has invalid logLines")
      \logs ->
      case Json.stringField value "type" of
        Just "QueryUpdated" -> case Json.field value "value" of
          Just inner -> Right (ChangedValue queryId inner logs)
          Nothing -> Left "QueryUpdated has no value"
        Just "QueryFailed" -> case Json.stringField value "errorMessage" of
          Nothing -> Left "QueryFailed has no errorMessage"
          Just detail -> Right
            ( ChangedFailure queryId
                ( Error.functionError detail
                    -- Absence and an explicit null mean different things.
                    ( if Json.hasField value "errorData" then
                        Json.field value "errorData"
                      else Nothing
                    )
                    logs
                )
            )
        Just "QueryRemoved" -> Right (ChangedRemoved queryId)
        _ -> Left "unknown query-set modification"

validateChanges :: List Change -> State -> List Int -> Either String Unit
validateChanges changes state seen = case changes of
  Nil -> Right unit
  Cons change rest ->
    let
      queryId = changeQueryId change
    in
      if listContains queryId seen then
        Left "Transition repeats a query identifier"
      else case findByQueryId state queryId, change of
        Just _, ChangedRemoved _ -> Left "server removed an active query"
        Just _, _ -> validateChanges rest state (Cons queryId seen)
        Nothing, _ ->
          if listContains queryId state.retiring then
            validateChanges rest state (Cons queryId seen)
          else Left "Transition references an unknown query"

changeQueryId :: Change -> Int
changeQueryId change = case change of
  ChangedValue queryId _ _ -> queryId
  ChangedFailure queryId _ -> queryId
  ChangedRemoved queryId -> queryId

applyChange :: State -> Change -> Effect State
applyChange state change =
  case findByQueryId state (changeQueryId change) of
    Nothing -> case change of
      ChangedRemoved queryId -> pure
        ( state
            { retiring = listFilter (\other -> other /= queryId) state.retiring
            }
        )
      _ -> pure state
    Just (Tuple subscriptionId subscription) -> case change of
      ChangedRemoved _ -> pure state
      ChangedFailure _ error -> do
        queued <- enqueue subscriptionId (LiveFailure error)
          (subscription { last = Nothing })
        pure (putSubscription state subscriptionId queued)
      ChangedValue _ value logs ->
        -- An unchanged value after a reconnect is rehydration, not news.
        if subscription.last == Just value then pure state
        else do
          queued <- enqueue subscriptionId (LiveValue value logs)
            (subscription { last = Just value })
          pure (putSubscription state subscriptionId queued)

findByQueryId :: State -> Int -> Maybe (Tuple String Subscription)
findByQueryId state queryId =
  listFind (\(Tuple _ subscription) -> subscription.queryId == queryId)
    state.subscriptions

-- | Convex timestamps are base64 of a little-endian unsigned 64-bit value.
-- | Re-encoding proves the text was canonical, so a padded or mangled variant
-- | is rejected rather than compared as a string.
timestampNumber :: String -> Maybe Int
timestampNumber timestamp =
  let
    bytes = Bytes.base64Decode timestamp
  in
    if Bytes.size bytes /= 8 then Nothing
    else if Bytes.base64Encode bytes /= timestamp then Nothing
    else Just (Bytes.readUint64LE bytes 0)

observedMax :: Maybe String -> String -> Maybe String
observedMax current candidate = case current of
  Nothing -> Just candidate
  Just seen -> case timestampNumber seen, timestampNumber candidate of
    Just left, Just right -> if left < right then Just candidate else Just seen
    _, _ -> Just candidate

-- ---------------------------------------------------------------------------
-- Delivery
-- ---------------------------------------------------------------------------

relayLoop :: Pid -> Maybe Pid -> Effect Unit
relayLoop owner gate = do
  incoming <- Sys.receiveCommand 60000
  case incoming of
    Nothing -> relayLoop owner gate
    Just (RelayEvent subscriptionId generation token event sink) -> do
      hold gate subscriptionId event
      self <- Sys.selfPid
      permission <- Sys.newRef
      Sys.sendCommand owner
        (RelayDelivery subscriptionId generation token self permission)
      allowed <- waitForReply permission
      if not allowed then pure unit
      else do
        acknowledged <- Sys.newRef
        Sys.sendEvent sink
          { subscriptionId: subscriptionId
          , event: event
          , ackPid: self
          , ackRef: acknowledged
          }
        _ <- waitForReply acknowledged
        Sys.sendCommand owner (RelayReady subscriptionId generation token)
        relayLoop owner gate

-- | Wait indefinitely, in bounded steps, for one selective reply. A relay has
-- | nothing else to do until it hears back, and being killed is how it stops.
waitForReply :: Ref -> Effect Boolean
waitForReply reference = do
  answer <- Sys.awaitReply reference 60000
  case answer of
    Just allowed -> pure allowed
    Nothing -> waitForReply reference

-- | The deterministic tests pause a relay here, after it has taken an event
-- | but before it asks for permission. Production clients pass `Nothing`.
hold :: Maybe Pid -> String -> LiveEvent -> Effect Unit
hold gate subscriptionId event = case gate of
  Nothing -> pure unit
  Just gatePid -> do
    self <- Sys.selfPid
    release <- Sys.newRef
    Sys.sendCommand gatePid
      { releasePid: self
      , releaseRef: release
      , subscriptionId: subscriptionId
      , event: event
      }
    voidEffect (Sys.awaitReply release 60000 :: Effect (Maybe Boolean))

-- | Hand an event to the relay if it is idle, otherwise queue it under the
-- | count and byte bounds.
enqueue :: String -> LiveEvent -> Subscription -> Effect Subscription
enqueue subscriptionId event subscription =
  let
    bytes = eventBytes event
  in
    -- One event larger than the whole budget can never be delivered without
    -- breaking the bound, so it is dropped rather than allowed through.
    if bytes > maxQueueBytes then pure subscription
    else if not subscription.relayBusy then
      sendToRelay subscriptionId event bytes subscription
    else pure
      ( trim
          ( subscription
              { queue = listSnoc subscription.queue (Tuple event bytes)
              , queueCount = subscription.queueCount + 1
              , queueBytes = subscription.queueBytes + bytes
              }
          )
      )

-- | Hand one event to the relay and record the delivery token that will be
-- | checked when the relay comes back asking for permission.
sendToRelay :: String -> LiveEvent -> Int -> Subscription -> Effect Subscription
sendToRelay subscriptionId event bytes subscription = do
  let token = subscription.nextToken
  Sys.sendCommand subscription.relayPid
    ( RelayEvent subscriptionId subscription.generation token event
        subscription.sink
    )
  pure
    ( subscription
        { nextToken = token + 1
        , relayBusy = true
        , inflightToken = Just token
        , inflightBytes = bytes
        }
    )

-- | Enforce the count and byte bounds, dropping the oldest events first so a
-- | slow subscriber sees the newest state rather than a stale prefix.
trim :: Subscription -> Subscription
trim subscription =
  let
    totalBytes = subscription.queueBytes + subscription.inflightBytes
    totalCount =
      subscription.queueCount + (if subscription.relayBusy then 1 else 0)
  in
    if totalCount <= maxQueueCount && totalBytes <= maxQueueBytes then
      subscription
    else case subscription.queue of
      Cons (Tuple _ droppedBytes) rest -> trim
        ( subscription
            { queue = rest
            , queueCount = subscription.queueCount - 1
            , queueBytes = subscription.queueBytes - droppedBytes
            }
        )
      -- The one in-flight event is waiting for the consumer's explicit
      -- acknowledgement. It cannot be evicted from the relay process, but it
      -- was rejected before dispatch if it exceeded the whole budget.
      Nil -> subscription

-- | Give the relay the next queued event once it reports itself idle.
dispatchNext :: String -> Subscription -> Effect Subscription
dispatchNext subscriptionId subscription = case subscription.queue of
  Nil -> pure subscription
  Cons (Tuple event bytes) rest -> sendToRelay subscriptionId event bytes
    ( subscription
        { queue = rest
        , queueCount = subscription.queueCount - 1
        , queueBytes = subscription.queueBytes - bytes
        }
    )

-- | Size an event by its encoded form, which is what the adapter will actually
-- | write, rather than by an in-memory estimate.
eventBytes :: LiveEvent -> Int
eventBytes event =
  let
    encoded = case event of
      LiveValue value logs -> Json.toBytes
        ( JsonObject
            ( listPair (Tuple "value" value)
                (Tuple "logs" (JsonArray (listMap JsonString logs)))
            )
        )
      LiveFailure error -> Json.toBytes (Error.toJson error)
  in
    Bytes.size encoded * 4 + eventOverhead

-- ---------------------------------------------------------------------------
-- Subscription table
-- ---------------------------------------------------------------------------

putSubscription :: State -> String -> Subscription -> State
putSubscription state subscriptionId subscription =
  state
    { subscriptions = assocPut state.subscriptions subscriptionId subscription
    }

assocGet :: forall v. List (Tuple String v) -> String -> Maybe v
assocGet entries key =
  maybeMap snd (listFind (\(Tuple name _) -> name == key) entries)

-- | Replace in place when the key is present, so the insertion order that
-- | `resendAll` and the fairness of delivery depend on stays stable.
assocPut :: forall v. List (Tuple String v) -> String -> v -> List (Tuple String v)
assocPut entries key value =
  if listAny (\(Tuple name _) -> name == key) entries then
    listMap
      (\(Tuple name held) -> if name == key then Tuple name value else Tuple name held)
      entries
  else listSnoc entries (Tuple key value)

assocDelete :: forall v. List (Tuple String v) -> String -> List (Tuple String v)
assocDelete entries key = listFilter (\(Tuple name _) -> name /= key) entries
