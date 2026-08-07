-- | Deterministic Live coverage against a fixture sync server.
-- |
-- | The failure modes that matter for Live are the ones an ordinary happy-path
-- | run never reaches: a query that fails and then recovers, an unsubscribe
-- | that races a relay which has already dequeued an event, a reconnect that
-- | has to resend the query set and suppress an unchanged rehydration, and a
-- | peer that starts a frame and then stops. Each scenario below drives those
-- | from a fixture server inside this process, so the ordering is decided
-- | rather than hoped for.
module Convex.Test.Live (main) where

import Convex.Prelude
import Adapter as Adapter
import Convex (Client)
import Convex as Convex
import Convex.Bytes (Bytes)
import Convex.Bytes as Bytes
import Convex.Json (Json(..))
import Convex.Json as Json
import Convex.Live (GateHeld, LiveEvent(..))
import Convex.Live as Live
import Convex.Sys (Pid, RecvResult(..), Socket)
import Convex.Sys as Sys
import Convex.Test.Check as Check
import Convex.Ws as Ws

-- | Fixture reads are generous: the point is deterministic ordering, not
-- | speed. Waits for something that must *not* happen are deliberately short.
wait :: Int
wait = 10000

quiet :: Int
quiet = 500

main :: Effect Unit
main = do
  initialValueAndExternalUpdate
  queryFailureThenRecovery
  initialValueThenFailureThenRepair
  lastQueryRemovalIsAcknowledged
  unsubscribeIsABarrier
  sameIdentifierReplacementIsABarrier
  reconnectResendsAndSuppresses
  protocolDriftThenRecovery
  stoppedConsumerHasOneInflightDelivery
  stalledFrameHasAnAbsoluteDeadline
  subscriptionCapacityIsBounded
  Check.done "convex_test_live"

-- ---------------------------------------------------------------------------
-- Scenarios
-- ---------------------------------------------------------------------------

-- | Add, an initial `QueryUpdated`, and an external update on the same query.
initialValueAndExternalUpdate :: Effect Unit
initialValueAndExternalUpdate = do
  listener <- startListener
  client <- newClient listener.port
  self <- Sys.selfPid
  subscription <- expectSubscribe client "demo:state" (roomArgs "alpha") self

  socket <- acceptUpgrade listener.socket
  connect <- expectMessage socket Bytes.empty
  Check.ok "the client opens with Connect"
    (stringContains connect.text "\"Connect\"")
  Check.ok "the first connection reports no earlier close"
    (stringContains connect.text "\"connectionCount\":0")

  modify <- expectMessage socket connect.rest
  Check.ok "the client adds the query"
    (stringContains modify.text "\"type\":\"Add\"")
  Check.ok "the add carries the query path"
    (stringContains modify.text "\"udfPath\":\"demo:state\"")
  Check.ok "the query set advances by one"
    ( stringContains modify.text "\"baseVersion\":0"
        && stringContains modify.text "\"newVersion\":1"
    )

  sendText socket (transition 0 0 1 1 (updated 0 0))
  initial <- nextCount subscription
  Check.equalInt "the initial value arrives" initial 0

  sendText socket (transition 1 1 1 2 (updated 0 1))
  external <- nextCount subscription
  Check.equalInt "an external update arrives" external 1

  expectOk "unsubscribe is accepted" (Convex.unsubscribe client subscription)
  remove <- expectMessage socket modify.rest
  Check.ok "unsubscribing removes the query"
    (stringContains remove.text "\"Remove\"")

  shutdown client socket listener.socket

-- | A failed query is reported without stranding the subscription: a later
-- | valid value on the same subscription still arrives.
queryFailureThenRecovery :: Effect Unit
queryFailureThenRecovery = do
  listener <- startListener
  client <- newClient listener.port
  self <- Sys.selfPid
  subscription <- expectSubscribe client "demo:fail" (roomArgs "beta") self

  socket <- acceptUpgrade listener.socket
  connect <- expectMessage socket Bytes.empty
  _ <- expectMessage socket connect.rest

  sendText socket (transition 0 0 1 1 (failed 0 "boom"))
  event <- nextEvent subscription
  case event of
    LiveFailure problem -> do
      Check.equalString "a query failure is a FunctionError" problem.name
        "FunctionError"
      Check.equalString "the failure carries its message" problem.message "boom"
    LiveValue _ _ -> Check.ok "expected a failure, not a value" false

  -- The same subscription must still be able to deliver a later value.
  sendText socket (transition 1 1 1 2 (updated 0 7))
  recovered <- nextCount subscription
  Check.equalInt "the subscription recovers" recovered 7

  shutdown client socket listener.socket

-- | The shape the shared pilot drives: a value arrives, the query then fails,
-- | the failure is repaired on the server, and a `QueryUpdated` for the same
-- | query id carries the repaired value.
-- |
-- | A `QueryFailed` is a value-state, not a removal. The query is still in the
-- | server's query set, so it has to stay registered here: forgetting it would
-- | make the repair look like a transition referencing an unknown query.
initialValueThenFailureThenRepair :: Effect Unit
initialValueThenFailureThenRepair = do
  listener <- startListener
  client <- newClient listener.port
  self <- Sys.selfPid
  subscription <- expectSubscribe client "demo:repair" (roomArgs "delta") self

  socket <- acceptUpgrade listener.socket
  connect <- expectMessage socket Bytes.empty
  _ <- expectMessage socket connect.rest

  sendText socket (transition 0 0 1 1 (updated 0 3))
  initial <- nextCount subscription
  Check.equalInt "the initial value arrives" initial 3

  sendText socket (transition 1 1 1 2 (failed 0 "repairing"))
  event <- nextEvent subscription
  case event of
    LiveFailure problem ->
      Check.equalString "the failure carries its message" problem.message
        "repairing"
    LiveValue _ _ -> Check.ok "expected a failure, not a value" false

  sendText socket (transition 1 2 1 3 (updated 0 4))
  repaired <- nextCount subscription
  Check.equalInt "the repaired value arrives" repaired 4

  -- And the subscription is ordinary again afterwards.
  sendText socket (transition 1 3 1 4 (updated 0 5))
  following <- nextCount subscription
  Check.equalInt "the repaired subscription keeps updating" following 5

  shutdown client socket listener.socket

-- | Unsubscribing the last query and immediately subscribing again, which is
-- | how the shared pilot moves from one Live check to the next.
-- |
-- | Removing the *last* query takes a different path from removing one of
-- | several, because it also has to close an otherwise idle socket. The
-- | acknowledgement the server sends for that removal names a query this
-- | client has already dropped from its subscriptions, so unless the removal
-- | was recorded as retiring it reads as a transition about a query the client
-- | never had. The protocol error that follows is broadcast to whichever
-- | subscription happens to be live by then, which is the next check's.
lastQueryRemovalIsAcknowledged :: Effect Unit
lastQueryRemovalIsAcknowledged = do
  listener <- startListener
  client <- newClient listener.port
  self <- Sys.selfPid
  first <- expectSubscribe client "demo:state" (roomArgs "epsilon") self

  socket <- acceptUpgrade listener.socket
  connect <- expectMessage socket Bytes.empty
  add <- expectMessage socket connect.rest
  Check.ok "the client adds the first query"
    (stringContains add.text "\"type\":\"Add\"")

  sendText socket (transition 0 0 1 1 (updated 0 0))
  initial <- nextCount first
  Check.equalInt "the initial value arrives" initial 0

  expectOk "unsubscribe is accepted" (Convex.unsubscribe client first)
  remove <- expectMessage socket add.rest
  Check.ok "removing the last query still reaches the wire"
    (stringContains remove.text "\"Remove\"")

  -- The replacement arrives before the server has acknowledged that removal.
  second <- expectSubscribe client "demo:repair" (roomArgs "zeta") self
  readd <- expectMessage socket remove.rest
  Check.ok "the replacement query is added"
    (stringContains readd.text "\"type\":\"Add\"")

  -- The acknowledgement names the query that was removed. It is the answer to
  -- a request this client made, not news about a query it never had.
  sendText socket (transition 1 1 2 2 (removed 0))
  sendText socket (transition 2 2 3 3 (updated 1 5))

  replacement <- nextCount second
  Check.equalInt "the replacement subscription is unaffected" replacement 5

  shutdown client socket listener.socket

-- | Unsubscribe must invalidate a relay that has already taken an event.
-- |
-- | The gate holds the relay after it dequeued the value but before it asks
-- | for permission. The unsubscribe then completes, and the held event must
-- | never reach the subscriber.
unsubscribeIsABarrier :: Effect Unit
unsubscribeIsABarrier = do
  listener <- startListener
  self <- Sys.selfPid
  client <- newGatedClient listener.port self
  subscription <- expectSubscribe client "demo:state" (roomArgs "gamma") self

  socket <- acceptUpgrade listener.socket
  connect <- expectMessage socket Bytes.empty
  _ <- expectMessage socket connect.rest

  sendText socket (transition 0 0 1 1 (updated 0 0))
  held <- expectGate
  Check.equalString "the gate holds this subscription" held.subscriptionId
    subscription

  -- The relay is paused mid-delivery. Unsubscribing now has to win.
  expectOk "unsubscribe is accepted" (Convex.unsubscribe client subscription)
  Sys.sendReply held.releasePid held.releaseRef true

  silent <- noEventArrives
  Check.ok "no event crosses the unsubscribe acknowledgement" silent

  shutdown client socket listener.socket

-- | Reusing an adapter subscription identifier must retire the old relay
-- | before the replacement acknowledgement can be produced. This drives the
-- | adapter's actual replacement helper while the old relay is paused.
sameIdentifierReplacementIsABarrier :: Effect Unit
sameIdentifierReplacementIsABarrier = do
  listener <- startListener
  self <- Sys.selfPid
  client <- newGatedClient listener.port self
  let args = roomArgs "replacement"
  old <- expectSubscribe client "demo:state" args self

  socket <- acceptUpgrade listener.socket
  connect <- expectMessage socket Bytes.empty
  firstAdd <- expectMessage socket connect.rest

  sendText socket (transition 0 0 1 1 (updated 0 0))
  held <- expectGate
  Check.equalString "the replacement gate holds the old subscription"
    held.subscriptionId
    old

  replacement <- Adapter.replaceMapping client
    (listSingleton (Tuple old "shared"))
    "shared"
    "demo:state"
    args
    self
  Check.ok "replacement succeeds" (isRight replacement.outcome)
  Check.ok "replacement removes the old real identifier"
    ( not
        ( listAny (\(Tuple real _) -> real == old)
            replacement.subscriptions
        )
    )
  Check.equalInt "replacement leaves one real subscription"
    (listLength replacement.subscriptions)
    1

  remove <- expectMessage socket firstAdd.rest
  add <- expectMessage socket remove.rest
  Check.ok "replacement removes the old query first"
    (stringContains remove.text "\"type\":\"Remove\"")
  Check.ok "replacement then adds the new query"
    (stringContains add.text "\"type\":\"Add\"")

  Sys.sendReply held.releasePid held.releaseRef true
  silent <- noEventArrives
  Check.ok "no old event crosses the replacement acknowledgement" silent

  shutdown client socket listener.socket

-- | A forced disconnect must retire the old connection, resend the active
-- | query set on the new one, and suppress the unchanged rehydration so the
-- | subscriber sees only real news. Repeated five times, which is what the
-- | shared conformance suite requires.
reconnectResendsAndSuppresses :: Effect Unit
reconnectResendsAndSuppresses = do
  listener <- startListener
  client <- newClient listener.port
  self <- Sys.selfPid
  subscription <- expectSubscribe client "demo:state" (roomArgs "delta") self

  first <- acceptUpgrade listener.socket
  connect <- expectMessage first Bytes.empty
  session <- expectJust "the Connect message carries a session id"
    (maybeThen (rightToMaybe (Json.parse connect.text)) \value ->
      Json.stringField value "sessionId")
  _ <- expectMessage first connect.rest
  sendText first (transition 0 0 1 1 (updated 0 0))
  initial <- nextCount subscription
  Check.equalInt "the initial value arrives" initial 0

  final <- reconnectLoop listener.socket client subscription session 1 first 0
  Check.equalInt "five reconnects deliver five real changes" final.value 5

  shutdown client final.socket listener.socket

type Reconnected =
  { socket :: Socket
  , value :: Int
  }

reconnectLoop
  :: Socket
  -> Client
  -> String
  -> String
  -> Int
  -> Socket
  -> Int
  -> Effect Reconnected
reconnectLoop listener client subscription session attempt old current =
  if attempt > 5 then pure { socket: old, value: current }
  else do
    step <- reconnectOnce listener client subscription session attempt old
      current
    reconnectLoop listener client subscription session (attempt + 1) step.socket
      step.value

reconnectOnce
  :: Socket
  -> Client
  -> String
  -> String
  -> Int
  -> Socket
  -> Int
  -> Effect Reconnected
reconnectOnce listener client subscription session attempt old current = do
  expectOk "the forced disconnect is acknowledged"
    (Convex.debugDisconnect client)
  Sys.close old

  socket <- acceptUpgrade listener
  connect <- expectMessage socket Bytes.empty
  observed <- expectJust "the reconnect Connect carries a session id"
    (maybeThen (rightToMaybe (Json.parse connect.text)) \value ->
      Json.stringField value "sessionId")
  Check.equalString "a reconnect preserves the Convex session identifier"
    observed
    session
  Check.ok "the new connection reports its connection count"
    (stringContains connect.text
      ("\"connectionCount\":" <> intToString attempt))
  Check.ok "the new connection reports why the old one closed"
    (stringContains connect.text
      "\"lastCloseReason\":\"adapter debug disconnect\"")
  Check.ok "the new connection carries the highest timestamp seen"
    (stringContains connect.text "\"maxObservedTimestamp\"")

  modify <- expectMessage socket connect.rest
  Check.ok "the query set is resent" (stringContains modify.text "\"type\":\"Add\"")
  Check.ok "the resent query set starts from zero again"
    (stringContains modify.text "\"baseVersion\":0")

  let hydration = attempt * 2
  -- Rehydration with the same value is not news and must be suppressed.
  sendText socket (transition 0 0 1 hydration (updated 0 current))
  silent <- noEventArrives
  Check.ok "an unchanged rehydration is suppressed" silent

  let following = current + 1
  sendText socket
    (transition 1 hydration 1 (hydration + 1) (updated 0 following))
  delivered <- nextCount subscription
  Check.equalInt "the value after the reconnect arrives" delivered following
  pure { socket: socket, value: following }

-- | An unsolicited QueryRemoved would strand a still-active local
-- | subscription. It is protocol drift, followed by a clean replay and later
-- | recovery on the same public handle.
protocolDriftThenRecovery :: Effect Unit
protocolDriftThenRecovery = do
  listener <- startListener
  client <- newClient listener.port
  self <- Sys.selfPid
  subscription <- expectSubscribe client "demo:state" (roomArgs "protocol") self

  first <- acceptUpgrade listener.socket
  connect <- expectMessage first Bytes.empty
  _ <- expectMessage first connect.rest
  sendText first (transition 0 0 1 1 (updated 0 0))
  healthy <- nextCount subscription
  Check.equalInt "protocol recovery starts healthy" healthy 0

  sendText first (transition 1 1 1 2 (removed 0))
  event <- nextEvent subscription
  case event of
    LiveFailure problem -> Check.equalString
      "active QueryRemoved is protocol drift"
      problem.name
      "ProtocolError"
    LiveValue _ _ -> Check.ok "protocol drift must not publish a value" false
  Sys.close first

  second <- acceptUpgrade listener.socket
  connect2 <- expectMessage second Bytes.empty
  _ <- expectMessage second connect2.rest
  sendText second (transition 0 0 1 3 (updated 0 9))
  repaired <- nextCount subscription
  Check.equalInt "the subscription recovers after drift" repaired 9

  shutdown client second listener.socket

-- | Delivery does not advance until the consumer acknowledges the value it
-- | removed from its mailbox. This proves a stopped reader cannot accumulate
-- | an unbounded series of already-delivered messages outside the queue bound.
stoppedConsumerHasOneInflightDelivery :: Effect Unit
stoppedConsumerHasOneInflightDelivery = do
  listener <- startListener
  client <- newClient listener.port
  self <- Sys.selfPid
  subscription <- expectSubscribe client "demo:state" (roomArgs "slow") self
  socket <- acceptUpgrade listener.socket
  connect <- expectMessage socket Bytes.empty
  _ <- expectMessage socket connect.rest
  sendText socket (transition 0 0 1 1 (updated 0 0))
  delivered <- Sys.receiveEvent wait
  held <- expectJust "the first delivery arrives" delivered

  -- A hundred newer values while the consumer still holds the first one. The
  -- relay may not carry another event until this one is acknowledged, so the
  -- consumer's mailbox cannot grow behind the client's own queue bound.
  forEach (listRange 1 100) \value ->
    sendText socket (transition 1 value 1 (value + 1) (updated 0 value))
  silent <- noEventArrives
  Check.ok "a stopped consumer receives only one unacknowledged delivery" silent

  Live.acknowledge held
  resumed <- nextCount subscription
  Check.ok "the bounded queue resumes with a newer value" (resumed > 0)

  shutdown client socket listener.socket

-- | A peer that starts a frame and then stops cannot retain parser state
-- | forever. The owner reports drift and retires that exact connection.
stalledFrameHasAnAbsoluteDeadline :: Effect Unit
stalledFrameHasAnAbsoluteDeadline = do
  listener <- startListener
  client <- newClient listener.port
  self <- Sys.selfPid
  subscription <- expectSubscribe client "demo:state" (roomArgs "stalled") self
  socket <- acceptUpgrade listener.socket
  connect <- expectMessage socket Bytes.empty
  _ <- expectMessage socket connect.rest

  started <- Sys.monotonicMs
  -- A header that promises 200 bytes, followed by four, and then silence.
  let
    stalled = Bytes.append
      ( Bytes.append (Bytes.append (Bytes.singleByte 0x81) (Bytes.singleByte 126))
          (Bytes.uint16BE 200)
      )
      (Bytes.fromString "{\"ty")
  expectOk "the partial frame is written" (Sys.send socket stalled wait)
  event <- nextEvent subscription
  case event of
    LiveFailure problem -> Check.equalString "a stalled frame is protocol drift"
      problem.name
      "ProtocolError"
    LiveValue _ _ -> Check.ok "a stalled frame must not publish a value" false
  finished <- Sys.monotonicMs
  Check.ok "the partial-frame deadline is bounded"
    (finished - started < 6000)

  shutdown client socket listener.socket

subscriptionCapacityIsBounded :: Effect Unit
subscriptionCapacityIsBounded = do
  listener <- startListener
  client <- newClient listener.port
  self <- Sys.selfPid
  forEach (listRange 0 7) \index -> do
    accepted <- Convex.subscribe client "demo:state"
      (roomArgs ("capacity-" <> intToString index))
      self
    Check.ok "eight active subscriptions fit the documented bound"
      (isRight accepted)
  overflow <- Convex.subscribe client "demo:state" (roomArgs "overflow") self
  Check.ok "a ninth active subscription is rejected" (not (isRight overflow))
  expectOk "the client closes" (Convex.close client)
  Sys.close listener.socket

-- ---------------------------------------------------------------------------
-- Subscriber helpers
-- ---------------------------------------------------------------------------

nextEvent :: String -> Effect LiveEvent
nextEvent subscription = do
  delivery <- Sys.receiveEvent wait
  case delivery of
    Nothing -> Sys.fatal "FAIL no Live event arrived before the timeout"
    Just received -> do
      Check.equalString "the event names its subscription"
        received.subscriptionId
        subscription
      -- Acknowledging is what lets the bounded relay carry the next event.
      Live.acknowledge received
      pure received.event

nextCount :: String -> Effect Int
nextCount subscription = do
  event <- nextEvent subscription
  case event of
    LiveValue value _ -> case maybeThen (Json.field value "count") Json.integralInt of
      Just count -> pure count
      Nothing -> Sys.fatal "FAIL a Live value had no whole-number count"
    LiveFailure problem ->
      Sys.fatal ("FAIL unexpected Live failure: " <> problem.message)

-- | True when nothing is delivered inside the quiet window, which is how the
-- | suppression and barrier scenarios are asserted.
noEventArrives :: Effect Boolean
noEventArrives = do
  delivery <- Sys.receiveEvent quiet
  case (delivery :: Maybe Live.SubscriptionEvent) of
    Nothing -> pure true
    Just received -> do
      Live.acknowledge received
      pure false

expectGate :: Effect GateHeld
expectGate = do
  incoming <- Sys.receiveCommand wait
  case incoming of
    Nothing -> Sys.fatal "FAIL the relay gate never held an event"
    Just held -> pure held

roomArgs :: String -> Json
roomArgs room = JsonObject (listSingleton (Tuple "room" (JsonString room)))

newClient :: Int -> Effect Client
newClient port = do
  created <- Convex.new (localUrl port)
  expectRight "the client is created" created

newGatedClient :: Int -> Pid -> Effect Client
newGatedClient port gate = do
  created <- Convex.newWithRelayGate (localUrl port) gate
  expectRight "the gated client is created" created

expectSubscribe :: Client -> String -> Json -> Pid -> Effect String
expectSubscribe client path args sink = do
  accepted <- Convex.subscribe client path args sink
  expectRight "the subscription is accepted" accepted

localUrl :: Int -> String
localUrl port = "http://127.0.0.1:" <> intToString port

shutdown :: Client -> Socket -> Socket -> Effect Unit
shutdown client socket listener = do
  expectOk "the client closes" (Convex.close client)
  Sys.close socket
  Sys.close listener

expectOk :: forall e a. String -> Effect (Either e a) -> Effect Unit
expectOk name action = do
  outcome <- action
  Check.ok name (isRight outcome)

expectRight :: forall e a. String -> Either e a -> Effect a
expectRight name value = case value of
  Right inner -> pure inner
  Left _ -> Sys.fatal ("FAIL " <> name)

expectJust :: forall a. String -> Maybe a -> Effect a
expectJust name value = case value of
  Just inner -> pure inner
  Nothing -> Sys.fatal ("FAIL " <> name)

rightToMaybe :: forall e a. Either e a -> Maybe a
rightToMaybe value = case value of
  Right inner -> Just inner
  Left _ -> Nothing

-- ---------------------------------------------------------------------------
-- Fixture sync server
-- ---------------------------------------------------------------------------

type Listener =
  { socket :: Socket
  , port :: Int
  }

startListener :: Effect Listener
startListener = do
  opened <- Sys.listen 0
  socket <- expectRight "the fixture listener opens" opened
  bound <- Sys.listenPort socket
  port <- expectRight "the fixture listener reports its port" bound
  pure { socket: socket, port: port }

-- | Accept one connection and complete the WebSocket upgrade the way a Convex
-- | deployment would, including the derived accept header.
acceptUpgrade :: Socket -> Effect Socket
acceptUpgrade listener = do
  accepted <- Sys.accept listener wait
  socket <- expectRight "the fixture accepts a connection" accepted
  head <- readUntilBlankLine socket Bytes.empty
  key <- expectJust "the upgrade carries a key"
    (headerValue (Bytes.toStringOrEmpty head) "sec-websocket-key:")
  let
    response = "HTTP/1.1 101 Switching Protocols\r\n"
      <> "upgrade: websocket\r\n"
      <> "connection: Upgrade\r\n"
      <> "sec-websocket-accept: "
      <> Ws.expectedAccept key
      <> "\r\n\r\n"
  expectOk "the fixture answers the upgrade"
    (Sys.send socket (Bytes.fromString response) wait)
  pure socket

headerValue :: String -> String -> Maybe String
headerValue head name =
  listHead
    ( listFilterMap
        ( \line ->
            if stringStartsWith (stringLowercase line) name then
              Just (stringTrim (stringDropStart (stringByteLength name) line))
            else Nothing
        )
        (stringSplit head "\r\n")
    )

readUntilBlankLine :: Socket -> Bytes -> Effect Bytes
readUntilBlankLine socket buffer =
  let
    boundary = Bytes.indexOfBytes buffer (Bytes.fromString "\r\n\r\n") 0
  in
    if boundary >= 0 then pure (Bytes.take boundary buffer)
    else do
      chunk <- readChunk socket
      readUntilBlankLine socket (Bytes.append buffer chunk)

readChunk :: Socket -> Effect Bytes
readChunk socket = do
  outcome <- Sys.recv socket 0 wait
  case outcome of
    Received chunk -> pure chunk
    RecvTimeout -> Sys.fatal "FAIL the fixture peer went quiet"
    RecvClosed -> Sys.fatal "FAIL the fixture peer closed"
    RecvFailed reason -> Sys.fatal ("FAIL fixture read failed: " <> reason)

type ClientMessage =
  { text :: String
  , rest :: Bytes
  }

-- | Read one masked client frame. Convex clients must mask, so the fixture
-- | insists on it rather than quietly accepting an unmasked frame.
expectMessage :: Socket -> Bytes -> Effect ClientMessage
expectMessage socket buffer = case takeClientFrame buffer of
  Just message -> pure message
  Nothing -> do
    chunk <- readChunk socket
    expectMessage socket (Bytes.append buffer chunk)

takeClientFrame :: Bytes -> Maybe ClientMessage
takeClientFrame buffer =
  let
    first = Bytes.byteAt buffer 0
    second = Bytes.byteAt buffer 1
  in
    if first /= 0x81 || bitAnd second 0x80 /= 0x80 then Nothing
    else
      let
        short = bitAnd second 0x7F
      in
        if short == 126 then
          let
            extended = Bytes.readUint16BE buffer 2
          in
            if extended < 0 then Nothing else takeMasked buffer 4 extended
        else if short == 127 then Nothing
        else takeMasked buffer 2 short

takeMasked :: Bytes -> Int -> Int -> Maybe ClientMessage
takeMasked buffer offset length =
  if Bytes.size buffer < offset + 4 + length then Nothing
  else
    let
      key = Bytes.slice buffer offset 4
      payload = Bytes.slice buffer (offset + 4) length
    in
      Just
        { text: Bytes.toStringOrEmpty (Bytes.xorRepeating payload key)
        , rest: Bytes.drop (offset + 4 + length) buffer
        }

-- | Servers do not mask, so the fixture writes plain frames.
sendText :: Socket -> String -> Effect Unit
sendText socket text = do
  let
    payload = Bytes.fromString text
    length = Bytes.size payload
    header =
      if length < 126 then
        Bytes.append (Bytes.singleByte 0x81) (Bytes.singleByte length)
      else Bytes.append
        (Bytes.append (Bytes.singleByte 0x81) (Bytes.singleByte 126))
        (Bytes.uint16BE length)
  expectOk "the fixture writes a frame"
    (Sys.send socket (Bytes.append header payload) wait)

-- ---------------------------------------------------------------------------
-- Sync protocol fixtures
-- ---------------------------------------------------------------------------

-- | Build a Transition between two versions. The timestamps are the base64
-- | little-endian encoding the pinned profile uses.
transition :: Int -> Int -> Int -> Int -> String -> String
transition startQuerySet startTs endQuerySet endTs entry =
  "{\"type\":\"Transition\",\"startVersion\":"
    <> versionText startQuerySet startTs
    <> ",\"endVersion\":"
    <> versionText endQuerySet endTs
    <> ",\"modifications\":["
    <> entry
    <> "]}"

versionText :: Int -> Int -> String
versionText querySet ts =
  "{\"querySet\":" <> intToString querySet <> ",\"identity\":0,\"ts\":\""
    <> Bytes.base64Encode (Bytes.uint64LE ts)
    <> "\"}"

updated :: Int -> Int -> String
updated queryId count =
  "{\"type\":\"QueryUpdated\",\"queryId\":" <> intToString queryId
    <> ",\"value\":{\"count\":"
    <> intToString count
    <> "},\"logLines\":[]}"

failed :: Int -> String -> String
failed queryId message =
  "{\"type\":\"QueryFailed\",\"queryId\":" <> intToString queryId
    <> ",\"errorMessage\":\""
    <> message
    <> "\",\"logLines\":[]}"

removed :: Int -> String
removed queryId =
  "{\"type\":\"QueryRemoved\",\"queryId\":" <> intToString queryId
    <> ",\"logLines\":[]}"
