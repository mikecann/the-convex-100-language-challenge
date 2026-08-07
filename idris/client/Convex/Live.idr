||| The pinned Convex realtime profile `convex-rs-0.10.4-unversioned-sync`.
|||
||| Realtime is not a documented third-party API, so this module implements one
||| inspected revision and treats anything outside it as drift rather than
||| improvising. It speaks `Connect` and `ModifyQuerySet`, applies a whole
||| `Transition` atomically, and rebuilds the active query set on every new
||| connection.
|||
||| There is exactly one owner of the socket: the pump. Subscribe, unsubscribe,
||| close, and the adapter-only disconnect hook all run inside it rather than
||| touching the socket from somewhere else, which is why no lock appears here.
||| The client is single-threaded by construction; the caller drives it.
|||
||| Delivery buffering is owned by this client rather than a runtime mailbox.
||| The queue is bounded by both an event count and an encoded byte budget, and
||| a slow consumer loses the globally oldest intermediate state first.
module Convex.Live

import Data.IORef
import Data.List
import Data.Maybe
import Data.String

import Convex.Codec
import Convex.Error
import Convex.Json
import Convex.Net
import Convex.Prim
import public Convex.Update
import Convex.Ws

||| The state version triple Convex uses to order transitions.
public export
record Version where
  constructor MkVersion
  querySet : Int
  identity : Int
  timestampText : String

export
Eq Version where
  left == right =
    querySet left == querySet right
      && identity left == identity right
      && timestampText left == timestampText right

||| Base64 of eight zero bytes: the timestamp a fresh connection starts from.
export
zeroTimestamp : String
zeroTimestamp = "AAAAAAAAAAA="

export
zeroVersion : Version
zeroVersion = MkVersion 0 0 zeroTimestamp

public export
record LiveConfig where
  constructor MkLiveConfig
  liveEndpoint : Endpoint
  liveCaFile : String
  liveClientVersion : String
  connectBudgetMs : Int
  frameBudgetMs : Int
  ||| Retained updates across all subscriptions before the oldest is dropped.
  maximumDeliveries : Int
  ||| Encoded bytes retained across all subscriptions.
  maximumDeliveryBytes : Int
  initialBackoffMs : Int
  maximumBackoffMs : Int

||| A query the client wants the server to keep evaluating.
record ActiveQuery where
  constructor MkActiveQuery
  queryPath : String
  queryArgs : Json
  ||| Bumped whenever this query is removed or replaced, which invalidates any
  ||| delivery that was already queued or dequeued for it.
  queryGeneration : Int
  ||| The last state published to the caller, so an unchanged rehydration after
  ||| a reconnect is suppressed instead of replayed.
  lastPublished : Maybe String

record Delivery where
  constructor MkDelivery
  deliveryQueryId : Int
  deliveryGeneration : Int
  deliveryUpdate : LiveUpdate
  deliveryCost : Int

export
record Live where
  constructor MkLive
  config : LiveConfig
  sessionId : String
  socket : IORef (Maybe WsConnection)
  active : IORef (List (Int, ActiveQuery))
  nextQueryId : IORef Int
  querySetVersion : IORef Int
  remoteVersion : IORef Version
  deliveries : IORef (List Delivery)
  deliveryBytes : IORef Int
  connectionCount : IORef Int
  lastCloseReason : IORef String
  maxObservedTimestamp : IORef Integer
  backoffMs : IORef Int
  nextConnectAt : IORef (Maybe Int)
  generationSeed : IORef Int
  shutdown : IORef Bool

maximumUint32 : Int
maximumUint32 = 4294967295

--------------------------------------------------------------------------------
-- Construction and observation
--------------------------------------------------------------------------------

||| Build a Live manager. The session identifier is random per client, which is
||| what lets a reconnect present itself as the same logical session.
export covering
newLive : LiveConfig -> IO (Either String Live)
newLive settings =
  do nonce <- randomByteList 16
     case nonce of
          Nothing => pure (Left "could not generate a Live session identifier")
          Just bytes => assemble (hexEncode bytes)
  where
    assemble : String -> IO (Either String Live)
    assemble session =
      do socketRef <- newIORef Nothing
         activeRef <- newIORef []
         nextIdRef <- newIORef 0
         querySetRef <- newIORef 0
         versionRef <- newIORef zeroVersion
         deliveriesRef <- newIORef []
         bytesRef <- newIORef 0
         countRef <- newIORef 0
         reasonRef <- newIORef "InitialConnect"
         timestampRef <- newIORef 0
         backoffRef <- newIORef (initialBackoffMs settings)
         connectAtRef <- newIORef Nothing
         generationRef <- newIORef 0
         shutdownRef <- newIORef False
         pure (Right (MkLive settings session socketRef activeRef nextIdRef querySetRef
                             versionRef deliveriesRef bytesRef countRef reasonRef
                             timestampRef backoffRef connectAtRef generationRef
                             shutdownRef))

export
liveConnectionCount : Live -> IO Int
liveConnectionCount live = readIORef (connectionCount live)

export
liveLastCloseReason : Live -> IO String
liveLastCloseReason live = readIORef (lastCloseReason live)

export
liveMaxObservedTimestamp : Live -> IO Integer
liveMaxObservedTimestamp live = readIORef (maxObservedTimestamp live)

export
liveBackoff : Live -> IO Int
liveBackoff live = readIORef (backoffMs live)

export
liveQuerySetVersion : Live -> IO Int
liveQuerySetVersion live = readIORef (querySetVersion live)

export
liveActiveCount : Live -> IO Nat
liveActiveCount live = map length (readIORef (active live))

export
liveConnected : Live -> IO Bool
liveConnected live = map isJust (readIORef (socket live))

--------------------------------------------------------------------------------
-- Delivery queue
--------------------------------------------------------------------------------

updateCost : LiveUpdate -> IO Int
updateCost update =
  case updateValue update of
       Nothing => pure 256
       Just value => do rendered <- renderJson value
                        case rendered of
                             Left _ => pure 256
                             Right text => do size <- textSize text
                                              pure (size + 256)

||| Drop the globally oldest retained update until the queue is inside both
||| bounds. Losing an intermediate state is the documented behaviour for a slow
||| consumer; losing the newest state would be a correctness bug.
covering
trimDeliveries : Live -> IO ()
trimDeliveries live =
  do queued <- readIORef (deliveries live)
     bytes <- readIORef (deliveryBytes live)
     let settings = config live
     if cast (length queued) <= maximumDeliveries settings
          && bytes <= maximumDeliveryBytes settings
        then pure ()
        else case queued of
                  [] => writeIORef (deliveryBytes live) 0
                  (oldest :: rest) =>
                    do writeIORef (deliveries live) rest
                       writeIORef (deliveryBytes live) (bytes - deliveryCost oldest)
                       trimDeliveries live

covering
enqueueDelivery : Live -> Int -> Int -> LiveUpdate -> IO ()
enqueueDelivery live queryId generation update =
  do cost <- updateCost update
     modifyIORef (deliveries live)
                 (\queued => queued ++ [MkDelivery queryId generation update cost])
     modifyIORef (deliveryBytes live) (+ cost)
     trimDeliveries live

||| A delivery is only publishable while its subscription still holds the
||| generation it was queued under. Unsubscribe and same-identifier replacement
||| both bump the generation before their acknowledgement, so a delivery that
||| was already dequeued and held cannot cross that barrier.
currentGeneration : Live -> Int -> IO (Maybe Int)
currentGeneration live queryId =
  do queries <- readIORef (active live)
     pure (map queryGeneration (lookup queryId queries))

||| Take the next publishable delivery, discarding anything stale.
export covering
takeDelivery : Live -> IO (Maybe (Int, LiveUpdate))
takeDelivery live =
  do queued <- readIORef (deliveries live)
     case queued of
          [] => pure Nothing
          (next :: rest) =>
            do writeIORef (deliveries live) rest
               modifyIORef (deliveryBytes live) (\bytes => bytes - deliveryCost next)
               generation <- currentGeneration live (deliveryQueryId next)
               if generation == Just (deliveryGeneration next)
                  then pure (Just (deliveryQueryId next, deliveryUpdate next))
                  else takeDelivery live

||| Discard every queued delivery. Used when a socket is retired, because those
||| updates describe a connection that no longer exists.
dropDeliveries : Live -> IO ()
dropDeliveries live =
  do writeIORef (deliveries live) []
     writeIORef (deliveryBytes live) 0

||| Invalidate everything already queued for one query.
bumpGeneration : Live -> Int -> IO ()
bumpGeneration live queryId =
  do seed <- readIORef (generationSeed live)
     let next = seed + 1
     writeIORef (generationSeed live) next
     modifyIORef (active live)
                 (map (\entry => if fst entry == queryId
                                    then (fst entry,
                                          { queryGeneration := next } (snd entry))
                                    else entry))

--------------------------------------------------------------------------------
-- Protocol messages
--------------------------------------------------------------------------------

addModification : Int -> ActiveQuery -> Json
addModification queryId query =
  JObject [ ("type", JString "Add")
          , ("queryId", jsonInt queryId)
          , ("udfPath", JString (queryPath query))
          , ("args", JArray [queryArgs query])
          ]

removeModification : Int -> Json
removeModification queryId =
  JObject [("type", JString "Remove"), ("queryId", jsonInt queryId)]

covering
connectMessage : Live -> IO Json
connectMessage live =
  do count <- readIORef (connectionCount live)
     reason <- readIORef (lastCloseReason live)
     observed <- readIORef (maxObservedTimestamp live)
     let base = [ ("type", JString "Connect")
                , ("sessionId", JString (sessionId live))
                , ("connectionCount", jsonInt count)
                , ("lastCloseReason", JString reason)
                , ("clientTs", jsonInt 0)
                ]
     pure (JObject (base ++ observedField observed))
  where
    observedField : Integer -> List (String, Json)
    observedField observed =
      if observed <= 0
         then []
         else case encodeTimestamp observed of
                   Nothing => []
                   Just text => [("maxObservedTimestamp", JString text)]

covering
sendJson : WsConnection -> Json -> IO (Either String ())
sendJson wire value =
  do encoded <- renderJson value
     case encoded of
          Left problem => pure (Left problem)
          Right text => sendText wire text

--------------------------------------------------------------------------------
-- Connection lifecycle
--------------------------------------------------------------------------------

||| Retire the current socket. Queued deliveries belong to it and are dropped,
||| so nothing from a dead connection can be published afterwards.
covering
retire : Live -> String -> IO ()
retire live reason =
  do current <- readIORef (socket live)
     case current of
          Nothing => pure ()
          -- Retirement is abrupt on purpose. The connection is already gone or
          -- being discarded, so nothing is spent trying to be polite to it.
          Just wire => wsAbandon wire
     writeIORef (socket live) Nothing
     modifyIORef (connectionCount live) (+ 1)
     writeIORef (lastCloseReason live) reason
     writeIORef (querySetVersion live) 0
     writeIORef (remoteVersion live) zeroVersion
     dropDeliveries live

||| Publish one error to every active subscription. Transport and protocol
||| failures are reported without removing the subscription, so a later valid
||| value can still arrive on the same subscription after the reconnect.
covering
publishFailure : Live -> ErrorKind -> String -> IO ()
publishFailure live kind' reason =
  do queries <- readIORef (active live)
     traverse_ (\entry =>
                  enqueueDelivery live (fst entry) (queryGeneration (snd entry))
                    (MkLiveUpdate Nothing []
                       (Just (simpleError kind' "subscription" reason))))
               queries

scheduleReconnect : Live -> IO ()
scheduleReconnect live =
  do now <- nowMs
     delay <- readIORef (backoffMs live)
     writeIORef (nextConnectAt live) (Just (now + delay))
     let capped = config live
     let doubled = delay * 2
     writeIORef (backoffMs live)
                (if doubled > maximumBackoffMs capped
                    then maximumBackoffMs capped
                    else doubled)

||| A successful handshake or a valid transition resets the backoff, so a
||| healthy connection between two failures does not inherit an old maximum.
resetBackoff : Live -> IO ()
resetBackoff live =
  do writeIORef (backoffMs live) (initialBackoffMs (config live))
     writeIORef (nextConnectAt live) Nothing

||| Open a connection and rebuild the whole active query set on it.
export covering
connectNow : Live -> IO (Either ConvexError ())
connectNow live =
  do let settings = config live
     opened <- wsConnect (liveEndpoint settings) (liveCaFile settings)
                         (liveClientVersion settings) (connectBudgetMs settings)
                         (frameBudgetMs settings)
     case opened of
          Left problem => failed problem
          Right wire => introduce wire
  where
    covering
    failed : String -> IO (Either ConvexError ())
    failed problem =
      do modifyIORef (connectionCount live) (+ 1)
         writeIORef (lastCloseReason live) problem
         scheduleReconnect live
         pure (Left (transportError "live" ("Live connection failed: " ++ problem)))

    -- settle is defined before rebuild, which calls it (where-block callees
    -- must precede their call sites; see the Convex.Ws note on this).
    covering
    settle : WsConnection -> IO (Either ConvexError ())
    settle wire =
      do writeIORef (socket live) (Just wire)
         writeIORef (remoteVersion live) zeroVersion
         resetBackoff live
         pure (Right ())

    covering
    rebuild : WsConnection -> IO (Either ConvexError ())
    rebuild wire =
      do queries <- readIORef (active live)
         if null queries
            then settle wire
            else do let adds = map (\entry => addModification (fst entry) (snd entry))
                                   (sortBy (\a, b => compare (fst a) (fst b)) queries)
                    sent <- sendJson wire
                              (JObject [ ("type", JString "ModifyQuerySet")
                                       , ("baseVersion", jsonInt 0)
                                       , ("newVersion", jsonInt 1)
                                       , ("modifications", JArray adds)
                                       ])
                    case sent of
                         Left problem => do wsClose wire 1002
                                            failed problem
                         Right () => do writeIORef (querySetVersion live) 1
                                        settle wire

    covering
    introduce : WsConnection -> IO (Either ConvexError ())
    introduce wire =
      do hello <- connectMessage live
         sent <- sendJson wire hello
         case sent of
              Left problem => do wsClose wire 1002
                                 failed problem
              Right () => rebuild wire

--------------------------------------------------------------------------------
-- Transitions
--------------------------------------------------------------------------------

uint32Of : Maybe Json -> Maybe Int
uint32Of value =
  do present <- value
     number <- wholeNumber present
     if number < 0 || number > maximumUint32 then Nothing else Just number

parseVersion : Maybe Json -> Either String Version
parseVersion value =
  case value of
       Nothing => Left "Live state version is missing"
       Just present =>
         case (uint32Of (field "querySet" present), uint32Of (field "identity" present),
               map asString (field "ts" present)) of
              (Just querySet', Just identity', Just (Just timestamp)) =>
                case decodeTimestamp timestamp of
                     Nothing => Left "Live state version timestamp is not canonical"
                     Just _ => Right (MkVersion querySet' identity' timestamp)
              _ => Left "Live state version is malformed"

logLinesOf : Json -> Either String (List String)
logLinesOf change =
  case field "logLines" change of
       Nothing => Right []
       Just value =>
         case stringList value of
              Nothing => Left "Live logLines must be an array of strings"
              Just logs => Right logs

||| Parse one modification into a query identifier and, when the query is one
||| the caller subscribed to, the update it produced. `QueryRemoved` yields no
||| update because the server is confirming a removal the client asked for.
parseModification : Json -> Either String (Int, Maybe LiveUpdate)
parseModification change =
  case uint32Of (field "queryId" change) of
       Nothing => Left "Live modification queryId is malformed"
       Just queryId =>
         case map asString (field "type" change) of
              Just (Just "QueryUpdated") =>
                case (field "value" change, logLinesOf change) of
                     (Nothing, _) => Left "QueryUpdated is missing value"
                     (_, Left problem) => Left problem
                     (Just value, Right logs) =>
                       Right (queryId, Just (MkLiveUpdate (Just value) logs Nothing))
              Just (Just "QueryFailed") =>
                case (map asString (field "errorMessage" change), logLinesOf change) of
                     (Just (Just text), Right logs) =>
                       let detail = case field "errorData" change of
                                         Just value => value
                                         Nothing => JNull in
                       Right (queryId,
                              Just (MkLiveUpdate Nothing logs
                                     (Just (MkConvexError FunctionFailure text detail logs
                                                          "subscription"))))
                     (_, Left problem) => Left problem
                     _ => Left "QueryFailed errorMessage must be a string"
              Just (Just "QueryRemoved") => Right (queryId, Nothing)
              _ => Left "unsupported Live modification"

||| Keep only the final modification for each query, preserving order.
coalesce : List (Int, Maybe LiveUpdate) -> List (Int, Maybe LiveUpdate)
coalesce items = foldl replace [] items
  where
    replace : List (Int, Maybe LiveUpdate) -> (Int, Maybe LiveUpdate)
           -> List (Int, Maybe LiveUpdate)
    replace acc item = filter (\existing => fst existing /= fst item) acc ++ [item]

||| The digest used to suppress an unchanged rehydration. Errors and values are
||| kept distinct so a repaired query always publishes.
covering
publishedDigest : LiveUpdate -> IO String
publishedDigest update =
  case updateError update of
       Just failure => pure ("error:" ++ errorKindName (kind failure) ++ ":"
                               ++ message failure)
       Nothing =>
         case updateValue update of
              Nothing => pure "empty"
              Just value =>
                do rendered <- renderJson value
                   case rendered of
                        Left problem => pure ("unrenderable:" ++ problem)
                        Right text => pure ("value:" ++ text)

covering
publishUpdate : Live -> Int -> LiveUpdate -> IO ()
publishUpdate live queryId update =
  do queries <- readIORef (active live)
     case lookup queryId queries of
          Nothing => pure ()
          Just query =>
            do digest <- publishedDigest update
               if lastPublished query == Just digest
                  then pure ()
                  else do modifyIORef (active live)
                                      (map (\entry =>
                                              if fst entry == queryId
                                                 then (fst entry,
                                                       { lastPublished := Just digest }
                                                         (snd entry))
                                                 else entry))
                          enqueueDelivery live queryId (queryGeneration query) update

||| Apply a whole transition or reject it. Nothing is published until every
||| field validates, so a malformed tail cannot leave the caller holding a
||| partially applied state.
covering
applyTransition : Live -> Json -> IO (Either String ())
applyTransition live event =
  do current <- readIORef (remoteVersion live)
     case (parseVersion (field "startVersion" event),
           parseVersion (field "endVersion" event)) of
          (Left problem, _) => pure (Left problem)
          (_, Left problem) => pure (Left problem)
          (Right start, Right end) =>
            if start /= current
               then pure (Left "Live transition start version did not match local state")
               else ordered start end
  where
    covering
    commit : Version -> Integer -> List (Int, Maybe LiveUpdate) -> IO (Either String ())
    commit end endStamp changes =
      do writeIORef (remoteVersion live) end
         observed <- readIORef (maxObservedTimestamp live)
         when (endStamp > observed) (writeIORef (maxObservedTimestamp live) endStamp)
         traverse_ (\change =>
                      case snd change of
                           Nothing => pure ()
                           Just update => publishUpdate live (fst change) update)
                   (coalesce changes)
         resetBackoff live
         pure (Right ())

    covering
    ordered : Version -> Version -> IO (Either String ())
    ordered start end =
      case (decodeTimestamp (timestampText start), decodeTimestamp (timestampText end)) of
           (Just startStamp, Just endStamp) =>
             if endStamp < startStamp
                then pure (Left "Live timestamp moved backwards")
                else case field "modifications" event of
                          Just (JArray items) =>
                            -- `traverse`'s Applicative is only pinned down by
                            -- how the case alternatives use the result, and
                            -- Idris2 does not push that expected type back
                            -- into the scrutinee, so it must be annotated
                            -- explicitly here.
                            case the (Either String (List (Int, Maybe LiveUpdate)))
                                     (traverse parseModification items) of
                                 Left problem => pure (Left problem)
                                 Right changes => commit end endStamp changes
                          _ => pure (Left "Live modifications must be an array")
           _ => pure (Left "Live transition timestamps are not canonical")

||| Dispatch one server message. The pinned profile assembles `Transition` and
||| tolerates `Ping`, `MutationResponse`, and `ActionResponse`; anything else,
||| including `TransitionChunk`, is drift and retires the connection.
covering
applyMessage : Live -> String -> IO (Either String ())
applyMessage live text =
  do parsed <- parseJsonText text
     case parsed of
          Left problem => pure (Left ("Live message is not JSON: " ++ problem))
          Right event =>
            case map asString (field "type" event) of
                 Just (Just "Transition") => applyTransition live event
                 Just (Just "Ping") => pure (Right ())
                 Just (Just "MutationResponse") => pure (Right ())
                 Just (Just "ActionResponse") => pure (Right ())
                 Just (Just other) =>
                   pure (Left ("unsupported Live server message: " ++ other))
                 _ => pure (Left "Live message type is missing")

--------------------------------------------------------------------------------
-- The pump
--------------------------------------------------------------------------------

covering
handleFailure : Live -> ErrorKind -> String -> IO ()
handleFailure live kind' reason =
  do retire live reason
     publishFailure live kind' reason
     scheduleReconnect live

||| Service whatever the socket already has. Returns False when the socket was
||| retired, so the caller stops using it this round.
covering
serviceSocket : Live -> WsConnection -> IO Bool
serviceSocket live wire =
  do event <- readEvent wire
     case event of
          Left (_, reason) =>
            do handleFailure live TransportFailure reason
               pure False
          Right WsAgain => pure True
          Right (WsPeerClose _ _) =>
            do handleFailure live TransportFailure "Live server closed the WebSocket"
               pure False
          Right (WsMessage text) =>
            do applied <- applyMessage live text
               case applied of
                    Left problem =>
                      do handleFailure live ProtocolFailure problem
                         pure False
                    Right () => pure True

||| The descriptor an external event loop should watch, when one exists.
export
liveWaitDescriptor : Live -> IO (Maybe Int)
liveWaitDescriptor live =
  do current <- readIORef (socket live)
     case current of
          Nothing => pure Nothing
          Just wire => pure (Just (connectionReadFd (wsLink wire)))

||| When the next reconnect attempt becomes due, so an external event loop can
||| bound its own wait rather than sleeping through a scheduled retry.
export
liveNextConnectAt : Live -> IO (Maybe Int)
liveNextConnectAt live = readIORef (nextConnectAt live)

||| Service everything that is already readable and start a reconnect that has
||| come due, without ever waiting. This is what an adapter or example event
||| loop calls; `pumpLive` is the waiting form built on top of it.
export covering
pumpReady : Live -> IO ()
pumpReady live =
  do stopped <- readIORef (shutdown live)
     if stopped
        then pure ()
        else do current <- readIORef (socket live)
                case current of
                     Nothing => reconnectIfDue
                     Just wire => drain wire
  where
    covering
    reconnectIfDue : IO ()
    reconnectIfDue =
      do due <- readIORef (nextConnectAt live)
         case due of
              Nothing => pure ()
              Just at =>
                do now <- nowMs
                   when (now >= at) (ignore (connectNow live))

    covering
    drain : WsConnection -> IO ()
    drain wire =
      do readable <- wsReadable wire
         if readable <= 0
            then pure ()
            else do alive <- serviceSocket live wire
                    if alive then drain wire else pure ()

||| Run the owner loop until the deadline or until something is publishable.
export covering
pumpLive : Live -> (budgetMs : Int) -> IO ()
pumpLive live budgetMs =
  do deadline <- deadlineIn budgetMs
     loop deadline
  where
    -- reconnectIfDue, waitForSocket, and loop call each other in both
    -- directions (genuine mutual recursion), not just a forward reference
    -- a reordering could fix, so this group needs an explicit `mutual`.
    --
    -- waitForSocket calling serviceSocket directly, instead of looping back
    -- into `loop` and letting it re-check `wsReadable`, is deliberate and
    -- load-bearing: `wsReadable` only reports bytes a *previous* read has
    -- already pulled into a userspace buffer (via `buffered`/
    -- `pendingDecrypted`); it is never satisfied by the OS-level readiness
    -- `awaitDescriptor` just observed on the socket. Looping back into
    -- `loop` here previously re-checked `wsReadable`, found it still zero
    -- (nothing had actually been read yet), and called `waitForSocket`
    -- again -- which immediately re-polled an fd the OS still correctly
    -- reports as ready, since nothing had drained it. That is a live
    -- lock: every message delivery busy-spun on `awaitDescriptor` until
    -- the caller's deadline ran out, silently, with the socket's actual
    -- bytes never read. `serviceSocket` is what performs the real read, so
    -- it must run the instant readiness is confirmed.
    mutual
      covering
      reconnectIfDue : Int -> IO ()
      reconnectIfDue deadline =
        do due <- readIORef (nextConnectAt live)
           case due of
                Nothing => pure ()
                Just at =>
                  do now <- nowMs
                     if now >= at
                        then do ignore $ connectNow live
                                loop deadline
                        else do let waitUntil = if at < deadline then at else deadline
                                sleepMs (waitUntil - now)
                                loop deadline

      covering
      waitForSocket : WsConnection -> Int -> IO ()
      waitForSocket wire deadline =
        do ready <- awaitDescriptor (connectionReadFd (wsLink wire)) pollRead deadline
           if ready == 0
              then pure ()
              else do ignore $ serviceSocket live wire
                      loop deadline

      covering
      loop : Int -> IO ()
      loop deadline =
        do stopped <- readIORef (shutdown live)
           queued <- readIORef (deliveries live)
           now <- nowMs
           if stopped || not (null queued) || now >= deadline
              then pure ()
              else do current <- readIORef (socket live)
                      case current of
                           Nothing => reconnectIfDue deadline
                           Just wire =>
                             do readable <- wsReadable wire
                                if readable > 0
                                   -- Whether the socket survived or was retired,
                                   -- the next turn re-reads the reference and
                                   -- picks the reconnect path if it is gone.
                                   then do ignore $ serviceSocket live wire
                                           loop deadline
                                   else waitForSocket wire deadline

--------------------------------------------------------------------------------
-- Subscriptions
--------------------------------------------------------------------------------

||| Start a subscription, connecting first when the socket is not up. The
||| acknowledgement is only produced once the `Add` has actually been written.
export covering
subscribeLive : Live -> String -> Json -> IO (Either ConvexError Int)
subscribeLive live path args =
  do stopped <- readIORef (shutdown live)
     queries <- readIORef (active live)
     queryId <- readIORef (nextQueryId live)
     if stopped
        then pure (Left (protocolError "subscribe" "the Live client is closed"))
        else if queryId >= maximumUint32
                then pure (Left (protocolError "subscribe" "Live query IDs are exhausted"))
                else register queryId queries
  where
    covering
    remember : Int -> Int -> IO ()
    remember queryId generation =
      do modifyIORef (active live)
                     (\queries =>
                        queries ++ [(queryId, MkActiveQuery path args generation Nothing)])
         writeIORef (nextQueryId live) (queryId + 1)

    covering
    forget : Int -> IO ()
    forget queryId =
      modifyIORef (active live) (filter (\entry => fst entry /= queryId))

    -- modify is defined before send, which calls it, per the where-block
    -- ordering rule (see the Convex.Ws await/upgrade note).
    covering
    modify : WsConnection -> Int -> Int -> ActiveQuery -> IO (Either ConvexError Int)
    modify wire version queryId query =
      do sent <- sendJson wire
                   (JObject [ ("type", JString "ModifyQuerySet")
                            , ("baseVersion", jsonInt version)
                            , ("newVersion", jsonInt (version + 1))
                            , ("modifications", JArray [addModification queryId query])
                            ])
         case sent of
              Left problem =>
                -- The write may have partly happened, so retire before the
                -- failure is reported. No stale `Add` can cross it.
                do handleFailure live TransportFailure problem
                   forget queryId
                   pure (Left (transportError "subscribe"
                                ("Live subscribe failed: " ++ problem)))
              Right () => do writeIORef (querySetVersion live) (version + 1)
                             pure (Right queryId)

    covering
    send : Int -> IO (Either ConvexError Int)
    send queryId =
      do current <- readIORef (socket live)
         case current of
              Nothing =>
                do connected <- connectNow live
                   case connected of
                        Left failure => do forget queryId
                                           pure (Left failure)
                        -- The rebuild on a fresh connection already carries the
                        -- new query, so there is nothing further to write.
                        Right () => pure (Right queryId)
              Just wire =>
                do version <- readIORef (querySetVersion live)
                   queries <- readIORef (active live)
                   if version >= maximumUint32
                      then do forget queryId
                              pure (Left (protocolError "subscribe"
                                            "Live query-set version is exhausted"))
                      else case lookup queryId queries of
                                Nothing => pure (Left (protocolError "subscribe"
                                                        "subscription vanished"))
                                Just query => modify wire version queryId query

    covering
    register : Int -> List (Int, ActiveQuery) -> IO (Either ConvexError Int)
    register queryId queries =
      do seed <- readIORef (generationSeed live)
         let generation = seed + 1
         writeIORef (generationSeed live) generation
         remember queryId generation
         send queryId

||| Stop a subscription. The generation is bumped before the acknowledgement,
||| so any delivery already queued or held for this query is discarded rather
||| than published after the caller believes the subscription is gone.
export covering
unsubscribeLive : Live -> Int -> IO (Either ConvexError ())
unsubscribeLive live queryId =
  do queries <- readIORef (active live)
     case lookup queryId queries of
          Nothing => pure (Right ())
          Just _ => remove
  where
    -- tell is defined before remove, which calls it, per the where-block
    -- ordering rule (see the Convex.Ws await/upgrade note).
    covering
    tell : WsConnection -> IO (Either ConvexError ())
    tell wire =
      do version <- readIORef (querySetVersion live)
         sent <- sendJson wire
                   (JObject [ ("type", JString "ModifyQuerySet")
                            , ("baseVersion", jsonInt version)
                            , ("newVersion", jsonInt (version + 1))
                            , ("modifications", JArray [removeModification queryId])
                            ])
         case sent of
              -- Retirement is itself a valid removal barrier: the retired
              -- connection can publish nothing even though its write failed.
              Left problem => do handleFailure live TransportFailure problem
                                 pure (Right ())
              Right () => do writeIORef (querySetVersion live) (version + 1)
                             pure (Right ())

    covering
    remove : IO (Either ConvexError ())
    remove =
      do bumpGeneration live queryId
         modifyIORef (active live) (filter (\entry => fst entry /= queryId))
         modifyIORef (deliveries live)
                     (filter (\item => deliveryQueryId item /= queryId))
         current <- readIORef (socket live)
         case current of
              Nothing => pure (Right ())
              Just wire => tell wire

||| Adapter-only fault injection. It closes the active socket without closing
||| the client, and only acknowledges once the old connection is retired and
||| the reconnect is scheduled, so no event from the old connection can appear
||| after the acknowledgement.
export covering
debugDisconnectLive : Live -> IO (Either ConvexError ())
debugDisconnectLive live =
  do current <- readIORef (socket live)
     case current of
          Nothing => pure (Left (transportError "debugDisconnect"
                                  "Live WebSocket is not connected"))
          Just _ =>
            do retire live "DebugDisconnect"
               writeIORef (backoffMs live) (initialBackoffMs (config live))
               scheduleReconnect live
               pure (Right ())

||| Close the client. Subscriptions are dropped first so nothing can be
||| published afterwards, and the socket is closed within its own deadline.
export covering
closeLive : Live -> IO ()
closeLive live =
  do writeIORef (shutdown live) True
     writeIORef (active live) []
     dropDeliveries live
     current <- readIORef (socket live)
     case current of
          Nothing => pure ()
          Just wire => wsClose wire 1000
     writeIORef (socket live) Nothing
     writeIORef (nextConnectAt live) Nothing
     writeIORef (lastCloseReason live) "ClientClosed"

||| Wait for the next update belonging to one subscription. Anything that
||| arrives for another subscription is left in the queue for its own reader.
export covering
awaitUpdate : Live -> Int -> (budgetMs : Int) -> IO (Maybe LiveUpdate)
awaitUpdate live queryId budgetMs =
  do deadline <- deadlineIn budgetMs
     loop deadline []
  where
    covering
    restore : List Delivery -> IO ()
    restore held = when (not (null held)) (modifyIORef (deliveries live) (held ++))

    covering
    loop : Int -> List Delivery -> IO (Maybe LiveUpdate)
    loop deadline held =
      do taken <- takeDelivery live
         case taken of
              Just (owner, update) =>
                if owner == queryId
                   then do restore held
                           pure (Just update)
                   else do cost <- updateCost update
                           generation <- currentGeneration live owner
                           let stamp = case generation of
                                            Just value => value
                                            Nothing => -1
                           loop deadline (held ++ [MkDelivery owner stamp update cost])
              Nothing =>
                do now <- nowMs
                   if now >= deadline
                      then do restore held
                              pure Nothing
                      else do pumpLive live (deadline - now)
                              queued <- readIORef (deliveries live)
                              if null queued
                                 then do restore held
                                         pure Nothing
                                 else loop deadline held
