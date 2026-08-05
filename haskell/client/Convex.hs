{-# LANGUAGE OverloadedStrings #-}

{- | A deliberately small native Convex client. HTTP uses Convex's public JSON
envelope; Live owns the pinned sync protocol here rather than delegating to
a JavaScript client or command-line tool.
-}
module Convex (
    Client,
    Result (..),
    Update (..),
    Subscription,
    ConvexError (..),
    newClient,
    setAuth,
    clearAuth,
    query,
    mutation,
    action,
    subscribe,
    nextUpdate,
    unsubscribe,
    closeClient,
    debugDisconnectForAdapter,
)
where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Async (Async, async, cancel)
import Control.Concurrent.STM
import Control.Exception (Exception, SomeException, displayException, throwIO, try)
import Control.Monad (foldM, forever, unless, void, when)
import Data.Aeson hiding (Result)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Bits (shiftL, (.|.))
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LBS
import Data.List (find, sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.UUID.V4 (nextRandom)
import Data.Word (Word64)
import Network.HTTP.Client
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types (statusCode)
import Network.WebSockets qualified as WS
import System.Timeout (timeout)
import Wuss qualified

data ConvexError
    = FunctionError Text (Maybe Value) [Text]
    | ProtocolError Text
    | TransportError Text
    | ClosedError Text
    deriving (Eq, Show)

instance Exception ConvexError

data Result = Result {resultValue :: Value, resultLogs :: [Text]}
    deriving (Eq, Show)

data Update = Update
    { updateValue :: Maybe Value
    , updateError :: Maybe ConvexError
    , updateLogs :: [Text]
    }
    deriving (Eq, Show)

-- The queue contains at most the newest sixteen states. Closing is checked in
-- the same STM transaction as dequeue, so a blocked reader cannot observe a
-- queued stale value after an unsubscribe barrier has completed.
data Subscription = Subscription
    { subscriptionId :: Int
    , subscriptionQueue :: TBQueue Update
    , subscriptionClosed :: TVar Bool
    }

data Command
    = Add Text Value (TMVar Subscription)
    | Remove Int (TMVar ())
    | DebugDisconnect (TMVar ())
    | Stop (TMVar ())

data Client = Client
    { clientUrl :: String
    , clientManager :: Manager
    , clientAuth :: TVar (Maybe Text)
    , clientCommands :: TQueue Command
    , clientWorker :: Async ()
    , clientClosed :: TVar Bool
    , clientCloseDone :: TMVar ()
    }

newClient :: String -> IO Client
newClient url = do
    address <- either throwIO pure (websocketAddress url)
    manager <- newManager tlsManagerSettings
    auth <- newTVarIO Nothing
    commands <- newTQueueIO
    closed <- newTVarIO False
    closeDone <- newEmptyTMVarIO
    worker <- async (liveWorker address commands closed)
    pure
        Client
            { clientUrl = dropTrailing url
            , clientManager = manager
            , clientAuth = auth
            , clientCommands = commands
            , clientWorker = worker
            , clientClosed = closed
            , clientCloseDone = closeDone
            }

{- | HTTP bearer authentication is mutable because the adapter exercises token
replacement and clearing on a single client. Live authentication remains a
deliberately separate deferred capability in the manifest.
-}
setAuth :: Client -> Text -> IO ()
setAuth client token = atomically (writeTVar (clientAuth client) (Just token))

clearAuth :: Client -> IO ()
clearAuth client = atomically (writeTVar (clientAuth client) Nothing)

query, mutation, action :: Client -> Text -> Value -> IO Result
query = call "query"
mutation = call "mutation"
action = call "action"

{- | The HTTP shape is Convex-specific. It intentionally refuses a malformed
success envelope instead of turning a protocol problem into a JSON value.
-}
call :: Text -> Client -> Text -> Value -> IO Result
call operation client path args = do
    isClosed <- readTVarIO (clientClosed client)
    when isClosed (throwIO (ClosedError "Convex client is closed"))
    token <- readTVarIO (clientAuth client)
    request0 <- parseRequest (clientUrl client <> "/api/" <> T.unpack operation)
    let body = encode (object ["path" .= path, "args" .= args, "format" .= ("json" :: Text)])
        authHeader = maybe [] (\value -> [("Authorization", "Bearer " <> TE.encodeUtf8 value)]) token
        request =
            request0
                { method = "POST"
                , requestHeaders =
                    [ ("Content-Type", "application/json")
                    , ("Accept", "application/json")
                    , ("Convex-Client", "haskell-0.1.0")
                    ]
                        <> authHeader
                , requestBody = RequestBodyLBS body
                }
    responseResult <- try (httpLbs request (clientManager client)) :: IO (Either SomeException (Response LBS.ByteString))
    response <- either (throwIO . TransportError . T.pack . displayException) pure responseResult
    case eitherDecode (responseBody response) of
        Left problem -> throwIO (ProtocolError ("invalid Convex HTTP response: " <> T.pack problem))
        Right (Object result) -> case KM.lookup "status" result of
            Just (String "success") -> case KM.lookup "value" result of
                Just value -> pure (Result value (textArray "logLines" result))
                Nothing -> throwIO (ProtocolError "success response omitted value")
            Just (String "error") ->
                throwIO
                    ( FunctionError
                        (textAt "errorMessage" result)
                        (KM.lookup "errorData" result)
                        (textArray "logLines" result)
                    )
            _ -> throwIO (ProtocolError ("unexpected HTTP status " <> T.pack (show (statusCode (responseStatus response)))))
        Right _ -> throwIO (ProtocolError "Convex HTTP response was not an object")

subscribe :: Client -> Text -> Value -> IO Subscription
subscribe client path args = do
    isClosed <- readTVarIO (clientClosed client)
    when isClosed (throwIO (ClosedError "Convex client is closed"))
    when (T.null path) (throwIO (ProtocolError "Convex function path is required"))
    reply <- newEmptyTMVarIO
    atomically (writeTQueue (clientCommands client) (Add path args reply))
    awaitReply "subscribing" 2000000 reply

nextUpdate :: Subscription -> IO Update
nextUpdate subscription = atomically $ do
    dead <- readTVar (subscriptionClosed subscription)
    when dead (throwSTM (ClosedError "Convex subscription is closed"))
    readTBQueue (subscriptionQueue subscription)

{- | Removal is an owner barrier: the subscription is invalidated and its
public queue is drained before the acknowledgement is published.
-}
unsubscribe :: Client -> Subscription -> IO ()
unsubscribe client subscription = do
    isClosed <- readTVarIO (clientClosed client)
    if isClosed
        then closeSubscription subscription
        else do
            reply <- newEmptyTMVarIO
            atomically (writeTQueue (clientCommands client) (Remove (subscriptionId subscription) reply))
            result <- timeout 2000000 (atomically (takeTMVar reply))
            case result of
                Just () -> pure ()
                Nothing -> do
                    -- Even if an unexpected owner failure prevents the command barrier,
                    -- invalidate the public handle so callers never wait forever.
                    closeSubscription subscription
                    throwIO (TransportError "timed out unsubscribing")

debugDisconnectForAdapter :: Client -> IO ()
debugDisconnectForAdapter client = do
    isClosed <- readTVarIO (clientClosed client)
    when isClosed (throwIO (ClosedError "Convex client is closed"))
    reply <- newEmptyTMVarIO
    atomically (writeTQueue (clientCommands client) (DebugDisconnect reply))
    awaitReply "retiring the Live connection" 2000000 reply

closeClient :: Client -> IO ()
closeClient client = do
    firstCloser <- atomically $ do
        already <- readTVar (clientClosed client)
        if already
            then pure False
            else do
                writeTVar (clientClosed client) True
                writeTQueue (clientCommands client) (Stop (clientCloseDone client))
                pure True
    -- Closing remains bounded even if an unforeseen exception killed the owner.
    -- Every caller observes the same completion barrier, so a repeated close
    -- cannot cancel the owner before the first Stop closes all subscriptions.
    completed <- timeout 2000000 (atomically (readTMVar (clientCloseDone client)))
    case completed of
        Just () -> pure ()
        Nothing
            | firstCloser -> do
                boundedCleanup (cancel (clientWorker client))
                atomically (void (tryPutTMVar (clientCloseDone client) ()))
            | otherwise -> pure ()

awaitReply :: Text -> Int -> TMVar value -> IO value
awaitReply operation micros reply = do
    result <- timeout micros (atomically (takeTMVar reply))
    maybe (throwIO (TransportError ("timed out " <> operation))) pure result

data Address = Address
    { addressSecure :: Bool
    , addressHost :: String
    , addressPort :: Int
    , addressPath :: String
    }

data SocketState
    = NoSocket
    | PendingSocket Int (Async ())
    | OpenSocket Int WS.Connection (Async ())

data SocketEvent
    = SocketReady Int WS.Connection
    | SocketMessage Int LBS.ByteString
    | SocketEnded Int Text
    | ReconnectDue Int
    | InactivityDue Int Int

data SubState = SubState
    { stateSubscription :: Subscription
    , statePath :: Text
    , stateArgs :: Value
    , stateLastDelivered :: Maybe Update
    }

data LiveState = LiveState
    { liveSubscriptions :: [SubState]
    , liveNextId :: Int
    , liveQuerySetVersion :: Int
    , liveRemoteVersion :: StateVersion
    , liveMaxObservedTimestamp :: Maybe Text
    , liveMaxObservedTimestampValue :: Maybe Word64
    , liveConnectionCount :: Int
    , liveLastCloseReason :: Text
    , liveBackoffMicros :: Int
    , liveGeneration :: Int
    , liveActivitySerial :: Int
    , liveSocket :: SocketState
    }

initialState :: LiveState
initialState =
    LiveState
        { liveSubscriptions = []
        , liveNextId = 0
        , liveQuerySetVersion = 0
        , liveRemoteVersion = zeroVersion
        , liveMaxObservedTimestamp = Nothing
        , liveMaxObservedTimestampValue = Nothing
        , liveConnectionCount = 0
        , liveLastCloseReason = "InitialConnect"
        , liveBackoffMicros = 100000
        , liveGeneration = 0
        , liveActivitySerial = 0
        , liveSocket = NoSocket
        }

-- One owner loop is the only code that changes query-set versions, connection
-- generations, reconnect metadata, or subscription membership. The transport
-- callback only performs reads and turns them into generation-tagged events;
-- controller and relay threads can only enqueue commands.
liveWorker :: Address -> TQueue Command -> TVar Bool -> IO ()
liveWorker address commands closed = do
    events <- newTQueueIO
    owner events initialState
  where
    owner events state = do
        next <- atomically ((Left <$> readTQueue commands) `orElse` (Right <$> readTQueue events))
        case next of
            Left command -> handleCommand events state command >>= maybe (pure ()) (owner events)
            Right event -> handleEvent events state event >>= owner events

    handleCommand events state (Add path args done) = do
        subscription <- newSubscription (liveNextId state)
        let entry = SubState subscription path args Nothing
            registered =
                state
                    { liveSubscriptions = liveSubscriptions state <> [entry]
                    , liveNextId = liveNextId state + 1
                    }
        sent <- case liveSocket registered of
            OpenSocket _ connection _ -> sendModify connection registered [addModification entry]
            _ -> pure (Right registered)
        let afterSend = either (const registered) id sent
        connected <- case sent of
            Left failure -> disconnectAndRetry events afterSend failure True
            Right _ -> ensureConnected events afterSend
        -- Registration and any connected-socket Add are complete before this
        -- acknowledgement. A disconnected registration is guaranteed to be in
        -- the next hydration set before it becomes visible to the caller.
        atomically (putTMVar done subscription)
        pure (Just connected)
    handleCommand events state (Remove ident done) = do
        let removed = find ((== ident) . subscriptionId . stateSubscription) (liveSubscriptions state)
        case removed of
            Nothing -> atomically (putTMVar done ()) >> pure (Just state)
            Just entry -> do
                closeSubscription (stateSubscription entry)
                let pruned = state{liveSubscriptions = filter ((/= ident) . subscriptionId . stateSubscription) (liveSubscriptions state)}
                sent <- case liveSocket state of
                    OpenSocket _ connection _ -> sendModify connection pruned [removeModification ident]
                    _ -> pure (Right pruned)
                afterSend <- case sent of
                    Right updated -> pure updated
                    Left failure -> disconnectAndRetry events pruned failure True
                -- The closed flag and queue drain above are the relay-generation
                -- barrier. No stale event can be dequeued after this acknowledgement.
                atomically (putTMVar done ())
                pure (Just afterSend)
    handleCommand events state (DebugDisconnect done) = do
        case liveSocket state of
            NoSocket -> do
                scheduled <- ensureReconnectScheduled events state 0
                atomically (putTMVar done ())
                pure (Just scheduled)
            _ -> do
                detached <- detachSocket state "DebugDisconnect"
                scheduled <- ensureReconnectScheduled events detached 0
                -- Generation invalidation and reconnect scheduling both precede the
                -- adapter acknowledgement. Events from the retired reader are now
                -- ignored even if kernel teardown finishes a little later.
                atomically (putTMVar done ())
                pure (Just scheduled)
    handleCommand _ state (Stop done) = do
        mapM_ (closeSubscription . stateSubscription) (liveSubscriptions state)
        _ <- detachSocket state "ClientClosed"
        atomically (writeTVar closed True >> putTMVar done ())
        pure Nothing

    handleEvent events state (SocketReady generation connection)
        | not (isPending generation (liveSocket state)) = pure state
        | otherwise = do
            let runner = socketRunner (liveSocket state)
                opened = state{liveSocket = OpenSocket generation connection runner, liveRemoteVersion = zeroVersion, liveQuerySetVersion = 0}
            connected <- sendConnect connection opened
            case connected of
                Left failure -> disconnectAndRetry events opened failure True
                Right hydrated -> do
                    scheduleInactivity events hydrated
                    -- A TCP/WebSocket handshake alone is not proof that this peer
                    -- speaks the pinned Convex protocol. Backoff resets only after a
                    -- valid server message below.
                    pure hydrated
    handleEvent events state (SocketMessage generation bytes)
        | not (isOpen generation (liveSocket state)) = pure state
        | otherwise = case eitherDecode bytes of
            Left problem -> protocolFailure events state ("invalid Live JSON: " <> T.pack problem)
            Right message -> do
                applied <- applyServerMessage state message
                case applied of
                    Left failure -> protocolFailure events state failure
                    Right updated -> do
                        let active = updated{liveActivitySerial = liveActivitySerial state + 1, liveBackoffMicros = 100000}
                        scheduleInactivity events active
                        pure active
    handleEvent events state (SocketEnded generation reason)
        | not (isCurrent generation (liveSocket state)) = pure state
        | otherwise = do
            broadcastUpdate state (Update Nothing (Just (TransportError reason)) [])
            disconnectAndRetry events state reason True
    handleEvent events state (ReconnectDue ticket)
        | ticket /= liveGeneration state || isSocketPresent (liveSocket state) || null (liveSubscriptions state) = pure state
        | otherwise = beginConnect events state
    handleEvent events state (InactivityDue generation serial)
        | not (isOpen generation (liveSocket state)) = pure state
        | serial /= liveActivitySerial state = pure state
        | otherwise = do
            let message = "Live server was inactive for 30 seconds"
            broadcastUpdate state (Update Nothing (Just (TransportError message)) [])
            disconnectAndRetry events state message True

    protocolFailure events state failure = do
        broadcastUpdate state (Update Nothing (Just (ProtocolError failure)) [])
        disconnectAndRetry events state failure True

    ensureConnected events state
        | null (liveSubscriptions state) || isSocketPresent (liveSocket state) = pure state
        | otherwise = beginConnect events state

    beginConnect events state = do
        let generation = liveGeneration state + 1
        runner <- startTransport address events generation
        pure state{liveGeneration = generation, liveSocket = PendingSocket generation runner}

    disconnectAndRetry events state reason exponential = do
        detached <- detachSocket state reason
        let delay = if exponential then liveBackoffMicros detached else 0
            nextBackoff = if exponential then min 15000000 (max 100000 (delay * 2)) else liveBackoffMicros detached
            waiting = detached{liveBackoffMicros = nextBackoff}
        ensureReconnectScheduled events waiting delay

    ensureReconnectScheduled events state delay
        | null (liveSubscriptions state) = pure state
        | otherwise = do
            let ticket = liveGeneration state
            -- The timer has no authority over state. Its generation-tagged event
            -- is ignored when a newer socket or shutdown has superseded it.
            unsafeFork (threadDelay delay >> atomically (writeTQueue events (ReconnectDue ticket)))
            pure state

    scheduleInactivity events state = case liveSocket state of
        OpenSocket generation _ _ ->
            void $ forkIO $ do
                threadDelay 30000000
                atomically (writeTQueue events (InactivityDue generation (liveActivitySerial state)))
        _ -> pure ()

-- This helper keeps timer creation visually distinct from the state-changing
-- owner. It returns immediately and the resulting thread owns no client state.
unsafeFork :: IO () -> IO ()
unsafeFork task = void (forkIO task)

-- The owner logically retires the generation first. Cancellation is done in a
-- separate bounded-cleanup thread so an idle or half-frame peer cannot prevent
-- unsubscribe, debugDisconnect, or close from acknowledging.
detachSocket :: LiveState -> Text -> IO LiveState
detachSocket state reason = do
    case liveSocket state of
        NoSocket -> pure ()
        PendingSocket _ runner -> unsafeFork (boundedCleanup (cancel runner))
        OpenSocket _ connection runner -> do
            unsafeFork (boundedCleanup (WS.sendClose connection ("client disconnect" :: Text)))
            unsafeFork (boundedCleanup (cancel runner))
    let counted = if isSocketPresent (liveSocket state) then liveConnectionCount state + 1 else liveConnectionCount state
    pure
        state
            { liveSocket = NoSocket
            , liveConnectionCount = counted
            , liveLastCloseReason = reason
            , liveQuerySetVersion = 0
            , liveRemoteVersion = zeroVersion
            }

-- Socket retirement is deliberately best effort. The peer may close between
-- logical generation invalidation and the physical close write, so cleanup
-- exceptions are consumed here instead of escaping from a detached thread.
boundedCleanup :: IO () -> IO ()
boundedCleanup task =
    void
        ( timeout
            500000
            (void (try task :: IO (Either SomeException ())))
        )

startTransport :: Address -> TQueue SocketEvent -> Int -> IO (Async ())
startTransport address events generation = async $ do
    let headers = [("Convex-Client", "haskell-0.1.0")]
        application connection = do
            atomically (writeTQueue events (SocketReady generation connection))
            forever $ do
                bytes <- WS.receiveData connection
                atomically (writeTQueue events (SocketMessage generation bytes))
        run
            | addressSecure address =
                Wuss.runSecureClientWith
                    (addressHost address)
                    (fromIntegral (addressPort address))
                    (addressPath address)
                    WS.defaultConnectionOptions
                    headers
                    application
            | otherwise =
                WS.runClientWith
                    (addressHost address)
                    (addressPort address)
                    (addressPath address)
                    WS.defaultConnectionOptions
                    headers
                    application
    outcome <- try run :: IO (Either SomeException ())
    let reason = either (T.pack . displayException) (const "Live WebSocket closed") outcome
    atomically (writeTQueue events (SocketEnded generation reason))

sendConnect :: WS.Connection -> LiveState -> IO (Either Text LiveState)
sendConnect connection state = do
    sessionId <- fmap (T.pack . show) nextRandom
    let connectMessage =
            object
                ( [ "type" .= ("Connect" :: Text)
                  , "sessionId" .= sessionId
                  , "connectionCount" .= liveConnectionCount state
                  , "lastCloseReason" .= liveLastCloseReason state
                  , "clientTs" .= (0 :: Int)
                  ]
                    <> maybe [] (pure . ("maxObservedTimestamp" .=)) (liveMaxObservedTimestamp state)
                )
    first <- sendJSON connection connectMessage
    case first of
        Left failure -> pure (Left failure)
        Right ()
            | null (liveSubscriptions state) -> pure (Right state)
            | otherwise -> sendModify connection state (map addModification (sortOn (subscriptionId . stateSubscription) (liveSubscriptions state)))

sendModify :: WS.Connection -> LiveState -> [Value] -> IO (Either Text LiveState)
sendModify connection state modifications = do
    let oldVersion = liveQuerySetVersion state
        message =
            object
                [ "type" .= ("ModifyQuerySet" :: Text)
                , "baseVersion" .= oldVersion
                , "newVersion" .= (oldVersion + 1)
                , "modifications" .= modifications
                ]
    result <- sendJSON connection message
    pure (state{liveQuerySetVersion = oldVersion + 1} <$ result)

sendJSON :: WS.Connection -> Value -> IO (Either Text ())
sendJSON connection value = do
    outcome <- timeout 500000 (try (WS.sendTextData connection (encode value)) :: IO (Either SomeException ()))
    pure $ case outcome of
        Nothing -> Left "timed out writing Live WebSocket frame"
        Just (Left failure) -> Left (T.pack (displayException failure))
        Just (Right ()) -> Right ()

addModification :: SubState -> Value
addModification entry =
    object
        [ "type" .= ("Add" :: Text)
        , "queryId" .= subscriptionId (stateSubscription entry)
        , "udfPath" .= statePath entry
        , "args" .= [stateArgs entry]
        ]

removeModification :: Int -> Value
removeModification ident = object ["type" .= ("Remove" :: Text), "queryId" .= ident]

applyServerMessage :: LiveState -> Value -> IO (Either Text LiveState)
applyServerMessage state (Object message) = case KM.lookup "type" message of
    Just (String "Transition") -> applyTransition state message
    Just (String "Ping") -> pure (Right state)
    Just (String "MutationResponse") -> pure (Right state)
    Just (String "ActionResponse") -> pure (Right state)
    Just (String "TransitionChunk") -> pure (Left "TransitionChunk assembly is not implemented")
    Just (String kind) -> pure (Left ("unexpected sync message: " <> kind))
    _ -> pure (Left "sync message omitted type")
applyServerMessage _ _ = pure (Left "sync message was not an object")

applyTransition :: LiveState -> Object -> IO (Either Text LiveState)
applyTransition state message = case validate of
    Left failure -> pure (Left failure)
    Right (end, changes) -> do
        let observed = liveMaxObservedTimestampValue state
            advancesMaximum = maybe True (< stateVersionTimestampValue end) observed
            committed =
                state
                    { liveRemoteVersion = end
                    , liveMaxObservedTimestamp =
                        if advancesMaximum
                            then Just (stateVersionTimestamp end)
                            else liveMaxObservedTimestamp state
                    , liveMaxObservedTimestampValue =
                        if advancesMaximum
                            then Just (stateVersionTimestampValue end)
                            else observed
                    }
            -- The sync protocol describes a transition as the resulting query
            -- set state. If a query appears more than once, only its final
            -- modification is public. Map.elems also fixes cross-query order.
            coalesced =
                Map.elems
                    (Map.fromList [(changeId change, change) | change <- changes])
        Right <$> foldM deliverChange committed coalesced
  where
    validate = do
        start <- requiredValue "startVersion" message >>= parseStateVersion "startVersion"
        end <- requiredValue "endVersion" message >>= parseStateVersion "endVersion"
        unlessEither (start == liveRemoteVersion state) "Transition startVersion did not match local state"
        unlessEither
            ( stateVersionQuerySet end >= stateVersionQuerySet start
                && stateVersionIdentity end >= stateVersionIdentity start
                && stateVersionTimestampValue end >= stateVersionTimestampValue start
            )
            "Transition endVersion moved backwards"
        changes <- case KM.lookup "modifications" message of
            Just (Array values) -> traverse parseChange (foldr (:) [] values)
            _ -> Left "Transition omitted modifications"
        pure (end, changes)

data StateVersion = StateVersion
    { stateVersionQuerySet :: Integer
    , stateVersionIdentity :: Integer
    , stateVersionTimestamp :: Text
    , stateVersionTimestampValue :: Word64
    }
    deriving (Eq, Show)

parseStateVersion :: Text -> Value -> Either Text StateVersion
parseStateVersion label (Object version) = do
    querySet <- versionCounter label "querySet" version
    identity <- versionCounter label "identity" version
    timestamp <- case KM.lookup "ts" version of
        Just (String value) -> Right value
        _ -> Left (label <> " omitted string ts")
    decoded <- decodeTimestamp timestamp
    pure (StateVersion querySet identity timestamp decoded)
parseStateVersion label _ = Left (label <> " was not an object")

versionCounter :: Text -> Text -> Object -> Either Text Integer
versionCounter label field version = case KM.lookup (Key.fromText field) version of
    Just (Number number) ->
        let integer = floor number
         in if fromInteger integer == number && integer >= 0 && integer <= 4294967295
                then Right integer
                else Left (label <> " had invalid " <> field)
    _ -> Left (label <> " omitted integer " <> field)

decodeTimestamp :: Text -> Either Text Word64
decodeTimestamp timestamp = do
    let encoded = TE.encodeUtf8 timestamp
    unlessEither (BS.length encoded == 12) "Live timestamp must encode exactly eight bytes"
    decoded <- either (const (Left "Live timestamp was not valid base64")) Right (Base64.decode encoded)
    unlessEither (BS.length decoded == 8) "Live timestamp must decode to exactly eight bytes"
    unlessEither (Base64.encode decoded == encoded) "Live timestamp was not canonical base64"
    pure
        ( foldl
            (\result (index, byte) -> result .|. (fromIntegral byte `shiftL` (index * 8)))
            0
            (zip [0 ..] (BS.unpack decoded))
        )

data Change = Changed Int Update | Removed Int

changeId :: Change -> Int
changeId (Changed ident _) = ident
changeId (Removed ident) = ident

parseChange :: Value -> Either Text Change
parseChange (Object change) = do
    ident <- case KM.lookup "queryId" change of
        Just (Number number) ->
            let integer = floor number :: Integer
             in if fromInteger integer == number && integer >= 0 && integer <= fromIntegral (maxBound :: Int)
                    then Right (fromInteger integer)
                    else Left "Live modification had invalid queryId"
        _ -> Left "Live modification omitted queryId"
    case KM.lookup "type" change of
        Just (String "QueryUpdated") -> case KM.lookup "value" change of
            Just value -> Right (Changed ident (Update (Just value) Nothing (textArray "logLines" change)))
            Nothing -> Left "QueryUpdated omitted value"
        Just (String "QueryFailed") -> do
            message <- case KM.lookup "errorMessage" change of
                Just (String value) -> Right value
                _ -> Left "QueryFailed omitted string errorMessage"
            let logs = textArray "logLines" change
            Right
                ( Changed
                    ident
                    ( Update
                        Nothing
                        (Just (FunctionError message (KM.lookup "errorData" change) logs))
                        logs
                    )
                )
        Just (String "QueryRemoved") -> Right (Removed ident)
        Just (String kind) -> Left ("unknown Transition modification: " <> kind)
        _ -> Left "Transition modification omitted type"
parseChange _ = Left "Transition modification was not an object"

-- The complete transition is validated and its version committed before this
-- fold publishes anything. Rehydrated values equal to the last delivered state
-- are suppressed, while QueryFailed followed by a value is a real change and
-- therefore recovers on the same subscription.
deliverChange :: LiveState -> Change -> IO LiveState
deliverChange state (Removed _) = pure state
deliverChange state (Changed ident update) =
    do
        subscriptions <- mapM offer (liveSubscriptions state)
        pure state{liveSubscriptions = subscriptions}
  where
    offer entry
        | subscriptionId (stateSubscription entry) /= ident = pure entry
        | stateLastDelivered entry == Just update = pure entry
        | otherwise = do
            offerUpdate (stateSubscription entry) update
            pure entry{stateLastDelivered = Just update}

broadcastUpdate :: LiveState -> Update -> IO ()
broadcastUpdate state update = mapM_ (\entry -> offerUpdate (stateSubscription entry) update) (liveSubscriptions state)

offerUpdate :: Subscription -> Update -> IO ()
offerUpdate subscription update = atomically $ do
    dead <- readTVar (subscriptionClosed subscription)
    unless dead $ do
        full <- isFullTBQueue (subscriptionQueue subscription)
        when full (void (readTBQueue (subscriptionQueue subscription)))
        writeTBQueue (subscriptionQueue subscription) update

closeSubscription :: Subscription -> IO ()
closeSubscription subscription = atomically $ do
    writeTVar (subscriptionClosed subscription) True
    void (flushTBQueue (subscriptionQueue subscription))

newSubscription :: Int -> IO Subscription
newSubscription ident = Subscription ident <$> newTBQueueIO 16 <*> newTVarIO False

zeroVersion :: StateVersion
zeroVersion = StateVersion 0 0 "AAAAAAAAAAA=" 0

requiredValue :: Text -> Object -> Either Text Value
requiredValue key payload = maybe (Left (key <> " was omitted")) Right (KM.lookup (Key.fromText key) payload)

unlessEither :: Bool -> Text -> Either Text ()
unlessEither condition problem = if condition then Right () else Left problem

isSocketPresent :: SocketState -> Bool
isSocketPresent NoSocket = False
isSocketPresent _ = True

isPending :: Int -> SocketState -> Bool
isPending generation (PendingSocket current _) = generation == current
isPending _ _ = False

isOpen :: Int -> SocketState -> Bool
isOpen generation (OpenSocket current _ _) = generation == current
isOpen _ _ = False

isCurrent :: Int -> SocketState -> Bool
isCurrent generation (PendingSocket current _) = generation == current
isCurrent generation (OpenSocket current _ _) = generation == current
isCurrent _ NoSocket = False

socketRunner :: SocketState -> Async ()
socketRunner (PendingSocket _ runner) = runner
socketRunner (OpenSocket _ _ runner) = runner
socketRunner NoSocket = error "socketRunner called without a socket"

textAt :: Text -> Object -> Text
textAt key payload = case KM.lookup (Key.fromText key) payload of
    Just (String text) -> text
    _ -> ""

textArray :: Text -> Object -> [Text]
textArray key payload = case KM.lookup (Key.fromText key) payload of
    Just (Array values) -> [text | String text <- foldr (:) [] values]
    _ -> []

dropTrailing :: String -> String
dropTrailing = reverse . dropWhile (== '/') . reverse

websocketAddress :: String -> Either ConvexError Address
websocketAddress url = do
    (secure, rest) <- case stripPrefix "https://" url of
        Just value -> Right (True, value)
        Nothing -> case stripPrefix "http://" url of
            Just value -> Right (False, value)
            Nothing -> Left (ProtocolError "Convex deployment URL must start with http:// or https://")
    let (authority, rawPath) = break (== '/') rest
        defaultPort = if secure then 443 else 80
        (host, port) = splitPort authority defaultPort
        path = if null rawPath then "/api/sync" else dropTrailing rawPath <> "/api/sync"
    if null host
        then Left (ProtocolError "Convex deployment URL omitted host")
        else Right (Address secure host port path)
  where
    stripPrefix prefix value = T.unpack <$> T.stripPrefix (T.pack prefix) (T.pack value)
    splitPort authority fallback = case break (== ':') authority of
        (host, ':' : digits) | not (null digits) && all (`elem` ['0' .. '9']) digits -> (host, read digits)
        _ -> (authority, fallback)
