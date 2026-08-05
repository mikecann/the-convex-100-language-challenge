{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

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

import Control.Concurrent (forkIO, threadDelay, throwTo)
import Control.Concurrent.Async (Async, async, asyncThreadId, cancel, poll, waitCatch)
import Control.Concurrent.STM
import Control.Exception (Exception, SomeException, catch, displayException, finally, mask, throwIO, try)
import Control.Monad (foldM, forM_, forever, unless, void, when)
import Crypto.Hash.SHA1 qualified as SHA1
import Data.Aeson hiding (Result)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Bits (shiftL, (.|.))
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (toList)
import Data.List (find, sortOn)
import Data.Map.Strict qualified as Map
import Data.Sequence (Seq (..), ViewL (..), (|>))
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.UUID.V4 (nextRandom)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
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

maxPendingCommands, maxSubscriptions, maxUpdatesPerSubscription :: Int
maxPendingCommands = 32
maxSubscriptions = 8
maxUpdatesPerSubscription = 16

maxLiveMessageBytes, maxQueuedUpdateBytes, maxTotalQueuedBytes, maxSubscriptionArgsBytes :: Int
maxLiveMessageBytes = 2 * 1024 * 1024
maxTotalQueuedBytes = 16 * 1024 * 1024
maxQueuedUpdateBytes = maxTotalQueuedBytes
maxSubscriptionArgsBytes = 256 * 1024

-- Count-only queues are not actually bounded when one value can be close to the
-- WebSocket frame limit. Every client therefore shares one encoded-byte budget
-- across all subscriptions as well as retaining at most sixteen updates each.
data QueueBudget = QueueBudget
    { queueBudgetBytes :: TVar Int
    , queueBudgetSerial :: TVar Word64
    }

data QueuedUpdate = QueuedUpdate
    { queuedUpdateValue :: Update
    , queuedUpdateBytes :: Int
    , queuedUpdateSerial :: Word64
    }

data Subscription = Subscription
    { subscriptionId :: Int
    , subscriptionQueue :: TVar (Seq QueuedUpdate)
    , subscriptionClosed :: TVar Bool
    , subscriptionBudget :: QueueBudget
    }

data Command
    = Add Text Value (TMVar (Either ConvexError Subscription))
    | Remove Int (TMVar (Either ConvexError ()))
    | DebugDisconnect (TMVar (Either ConvexError ()))
    | Stop (TMVar (Either ConvexError ()))

data Client = Client
    { clientUrl :: String
    , clientManager :: Manager
    , clientAuth :: TVar (Maybe Text)
    , clientCommands :: TBQueue Command
    , clientWorker :: Async ()
    , clientClosed :: TVar Bool
    , clientCloseDone :: TMVar (Either ConvexError ())
    }

newClient :: String -> IO Client
newClient url = do
    address <- either throwIO pure (websocketAddress url)
    manager <- newManager tlsManagerSettings
    auth <- newTVarIO Nothing
    commands <- newTBQueueIO (fromIntegral maxPendingCommands)
    budget <- QueueBudget <$> newTVarIO 0 <*> newTVarIO 0
    closed <- newTVarIO False
    closeDone <- newEmptyTMVarIO
    worker <- async (liveWorker address commands closed budget)
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
            Just (String "success") -> do
                value <- maybe (throwIO (ProtocolError "success response omitted value")) pure (KM.lookup "value" result)
                logs <- either (throwIO . ProtocolError) pure (parseTextArray "logLines" result)
                pure (Result value logs)
            Just (String "error") -> do
                message <- case KM.lookup "errorMessage" result of
                    Just (String value) -> pure value
                    _ -> throwIO (ProtocolError "error response omitted string errorMessage")
                logs <- either (throwIO . ProtocolError) pure (parseTextArray "logLines" result)
                throwIO (FunctionError message (KM.lookup "errorData" result) logs)
            _ -> throwIO (ProtocolError ("unexpected HTTP status " <> T.pack (show (statusCode (responseStatus response)))))
        Right _ -> throwIO (ProtocolError "Convex HTTP response was not an object")

subscribe :: Client -> Text -> Value -> IO Subscription
subscribe client path args = do
    isClosed <- readTVarIO (clientClosed client)
    when isClosed (throwIO (ClosedError "Convex client is closed"))
    when (T.null path) (throwIO (ProtocolError "Convex function path is required"))
    when (LBS.length (encode args) > fromIntegral maxSubscriptionArgsBytes) (throwIO (ProtocolError "Live subscription arguments exceeded 256 KiB"))
    reply <- newEmptyTMVarIO
    enqueueCommand client (Add path args reply)
    either throwIO pure =<< awaitReply "subscribing" 20000000 reply

nextUpdate :: Subscription -> IO Update
nextUpdate subscription = atomically $ do
    dead <- readTVar (subscriptionClosed subscription)
    when dead (throwSTM (ClosedError "Convex subscription is closed"))
    queued <- readTVar (subscriptionQueue subscription)
    case Seq.viewl queued of
        EmptyL -> retry
        item :< remaining -> do
            writeTVar (subscriptionQueue subscription) remaining
            modifyTVar' (queueBudgetBytes (subscriptionBudget subscription)) (subtract (queuedUpdateBytes item))
            pure (queuedUpdateValue item)

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
            enqueueCommand client (Remove (subscriptionId subscription) reply)
            result <- timeout 2000000 (atomically (takeTMVar reply))
            case result of
                Just (Right ()) -> pure ()
                Just (Left failure) -> throwIO failure
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
    enqueueCommand client (DebugDisconnect reply)
    either throwIO pure =<< awaitReply "retiring the Live connection" 2000000 reply

closeClient :: Client -> IO ()
closeClient client = do
    firstCloser <- atomically $ do
        already <- readTVar (clientClosed client)
        if already
            then pure False
            else do
                writeTVar (clientClosed client) True
                pending <- flushTBQueue (clientCommands client)
                mapM_ rejectPending pending
                writeTBQueue (clientCommands client) (Stop (clientCloseDone client))
                pure True
    -- Closing remains bounded even if an unforeseen exception killed the owner.
    -- Every caller observes the same completion barrier, so a repeated close
    -- cannot cancel the owner before the first Stop closes all subscriptions.
    completed <- timeout 2500000 (atomically (readTMVar (clientCloseDone client)))
    case completed of
        Just (Right ()) -> pure ()
        Just (Left failure) -> throwIO failure
        Nothing -> throwIO (TransportError (if firstCloser then "timed out closing Convex client" else "timed out waiting for concurrent close"))

enqueueCommand :: Client -> Command -> IO ()
enqueueCommand client command = do
    accepted <- atomically $ do
        dead <- readTVar (clientClosed client)
        if dead
            then pure (Left (ClosedError "Convex client is closed"))
            else do
                full <- isFullTBQueue (clientCommands client)
                if full
                    then pure (Left (TransportError "Live command queue is full"))
                    else writeTBQueue (clientCommands client) command >> pure (Right ())
    either throwIO pure accepted

rejectPending :: Command -> STM ()
rejectPending (Add _ _ reply) = void (tryPutTMVar reply (Left (ClosedError "Convex client is closed")))
rejectPending (Remove _ reply) = void (tryPutTMVar reply (Left (ClosedError "Convex client is closed")))
rejectPending (DebugDisconnect reply) = void (tryPutTMVar reply (Left (ClosedError "Convex client is closed")))
rejectPending (Stop reply) = void (tryPutTMVar reply (Right ()))

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

data TransportCommand
    = TransportSend [Value] (TMVar (Either Text ()))
    | TransportRetire (TMVar ())

data Transport = Transport
    { transportGeneration :: Int
    , transportCommands :: TQueue TransportCommand
    , transportSleeping :: TVar Bool
    , transportWorker :: Async ()
    }

data SocketState
    = NoSocket
    | PendingSocket Transport
    | OpenSocket Transport

data SocketEvent
    = SocketReady Int
    | SocketEnded Int Text
    | ReconnectDue Int
    | InactivityTick

data InboundMessage = InboundMessage Int LBS.ByteString Int

data InboundQueue = InboundQueue
    { inboundMessages :: TBQueue InboundMessage
    , inboundBytes :: TVar Int
    }

data WakeSocketOwner = WakeSocketOwner
    deriving (Show)

instance Exception WakeSocketOwner

data SubState = SubState
    { stateSubscription :: Subscription
    , statePath :: Text
    , stateArgs :: Value
    , stateLastDelivered :: Maybe BS.ByteString
    , stateAddBarrier :: Maybe (TMVar (Either ConvexError Subscription))
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
    , liveLastActivityNanos :: Word64
    , liveSocket :: SocketState
    , liveRemoveBarriers :: [TMVar (Either ConvexError ())]
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
        , liveLastActivityNanos = 0
        , liveSocket = NoSocket
        , liveRemoveBarriers = []
        }

-- One owner loop is the only code that changes query-set versions, connection
-- generations, reconnect metadata, or subscription membership. The transport
-- callback only performs reads and turns them into generation-tagged events;
-- controller and relay threads can only enqueue commands.
liveWorker :: Address -> TBQueue Command -> TVar Bool -> QueueBudget -> IO ()
liveWorker address commands closed budget = do
    events <- newTQueueIO
    inbound <- InboundQueue <$> newTBQueueIO 2 <*> newTVarIO 0
    unsafeFork $ forever $ threadDelay 1000000 >> atomically (writeTQueue events InactivityTick)
    owner events inbound initialState
  where
    owner events inbound state = do
        next <- atomically $ chooseInput commands events inbound
        case next of
            OwnerCommand command -> handleCommand events inbound state command >>= maybe (pure ()) (owner events inbound)
            OwnerEvent event -> handleEvent events inbound state event >>= owner events inbound
            OwnerMessage generation bytes -> handleMessage events inbound state generation bytes >>= owner events inbound

    handleCommand events inbound state (Add path args done)
        | length (liveSubscriptions state) >= maxSubscriptions = do
            atomically (putTMVar done (Left (ProtocolError "Live supports at most eight active subscriptions")))
            pure (Just state)
        | otherwise = do
            subscription <- newSubscription budget (liveNextId state)
            let entry = SubState subscription path args Nothing (Just done)
                registered =
                    state
                        { liveSubscriptions = liveSubscriptions state <> [entry]
                        , liveNextId = liveNextId state + 1
                        }
            connected <- case liveSocket registered of
                OpenSocket transport -> do
                    sent <- sendModify transport registered [addModification entry]
                    case sent of
                        Left failure -> disconnectAndRetry events inbound registered failure True
                        Right updated -> completeAddBarriers updated
                -- A new or already-connecting generation has not written this
                -- Add yet. sendConnect completes the barrier only after its
                -- batched Connect and hydration write succeeds.
                _ -> ensureConnected events inbound registered
            -- A disconnected Add deliberately keeps its barrier pending. The public
            -- subscribe call cannot return until the socket owner has completed the
            -- Connect and hydration writes on a real connection.
            pure (Just connected)
    handleCommand events inbound state (Remove ident done) = do
        let removed = find ((== ident) . subscriptionId . stateSubscription) (liveSubscriptions state)
        case removed of
            Nothing -> atomically (putTMVar done (Right ())) >> pure (Just state)
            Just entry -> do
                closeSubscription (stateSubscription entry)
                forM_ (stateAddBarrier entry) (\barrier -> atomically (void (tryPutTMVar barrier (Left (ClosedError "subscription was removed before Add completed")))))
                let pruned = state{liveSubscriptions = filter ((/= ident) . subscriptionId . stateSubscription) (liveSubscriptions state)}
                sent <- case liveSocket state of
                    OpenSocket transport -> sendModify transport pruned [removeModification ident]
                    _ -> pure (Right pruned)
                (afterSend, reply) <- case sent of
                    Right updated -> pure (updated, Just (Right ()))
                    Left failure | null (liveSubscriptions pruned) -> do
                        -- With no remaining queries there is nothing to
                        -- rehydrate. Retiring the failed generation itself is
                        -- the transport completion barrier for this Remove.
                        (detached, retirement) <- detachSocket pruned failure
                        pure (detached, Just (maybe (Right ()) (Left . TransportError) retirement))
                    Left failure -> do
                        retrying <- disconnectAndRetry events inbound pruned failure True
                        pure (retrying{liveRemoveBarriers = done : liveRemoveBarriers retrying}, Nothing)
                -- Local invalidation, the socket-owner Remove completion, and
                -- queue drain all precede this barrier.
                forM_ reply (atomically . putTMVar done)
                pure (Just afterSend)
    handleCommand events _ state (DebugDisconnect done) = do
        case liveSocket state of
            NoSocket -> do
                scheduled <- ensureReconnectScheduled events state 0
                atomically (putTMVar done (Right ()))
                pure (Just scheduled)
            _ -> do
                (detached, retirement) <- detachSocket state "DebugDisconnect"
                case retirement of
                    Nothing -> do
                        scheduled <- ensureReconnectScheduled events detached 0
                        -- The retired worker has finished before a replacement is
                        -- scheduled, so one generation can never overlap another.
                        atomically (putTMVar done (Right ()))
                        pure (Just scheduled)
                    Just failure -> do
                        -- A worker that could not be retired must never be followed
                        -- by a replacement owner. Report the bounded failure and
                        -- leave the client detached instead.
                        atomically (putTMVar done (Left (TransportError failure)))
                        pure (Just detached)
    handleCommand _ _ state (Stop done) = do
        mapM_ (closeSubscription . stateSubscription) (liveSubscriptions state)
        forM_ (liveSubscriptions state) $ \entry ->
            forM_ (stateAddBarrier entry) (\barrier -> atomically (void (tryPutTMVar barrier (Left (ClosedError "Convex client is closed")))))
        (_, retirement) <- detachSocket state "ClientClosed"
        atomically (writeTVar closed True >> putTMVar done (maybe (Right ()) (Left . TransportError) retirement))
        pure Nothing

    handleEvent events inbound state (SocketReady generation)
        | not (isPending generation (liveSocket state)) = pure state
        | otherwise = do
            let transport = socketTransport (liveSocket state)
                opened = state{liveSocket = OpenSocket transport, liveRemoteVersion = zeroVersion, liveQuerySetVersion = 0}
            connected <- sendConnect transport opened
            case connected of
                Left failure -> disconnectAndRetry events inbound opened failure True
                Right hydrated -> do
                    completed <- completeAddBarriers hydrated
                    withRemovals <- completeRemoveBarriers completed
                    now <- getMonotonicTimeNSec
                    -- A TCP/WebSocket handshake alone is not proof that this peer
                    -- speaks the pinned Convex protocol. Backoff resets only after a
                    -- valid server message below.
                    pure withRemovals{liveLastActivityNanos = now}
    handleEvent events inbound state (SocketEnded generation reason)
        | not (isCurrent generation (liveSocket state)) = pure state
        | otherwise = do
            broadcastUpdate state (Update Nothing (Just (TransportError reason)) [])
            disconnectAndRetry events inbound state reason True
    handleEvent events inbound state (ReconnectDue ticket)
        | ticket /= liveGeneration state || isSocketPresent (liveSocket state) || null (liveSubscriptions state) = pure state
        | otherwise = beginConnect events inbound state
    handleEvent events inbound state InactivityTick = case liveSocket state of
        OpenSocket _ -> do
            now <- getMonotonicTimeNSec
            if now - liveLastActivityNanos state < 30000000000
                then pure state
                else do
                    let message = "Live server was inactive for 30 seconds"
                    broadcastUpdate state (Update Nothing (Just (TransportError message)) [])
                    disconnectAndRetry events inbound state message True
        _ -> pure state

    handleMessage events inbound state generation bytes
        | not (isOpen generation (liveSocket state)) = pure state
        | otherwise = do
            case eitherDecode bytes of
                Left problem -> protocolFailure events inbound state ("invalid Live JSON: " <> T.pack problem)
                Right message -> do
                    applied <- applyServerMessage state message
                    case applied of
                        Left failure -> protocolFailure events inbound state failure
                        Right (updated, relevant) ->
                            if relevant
                                then do
                                    now <- getMonotonicTimeNSec
                                    pure updated{liveLastActivityNanos = now, liveBackoffMicros = 100000}
                                else pure updated

    protocolFailure events inbound state failure = do
        broadcastUpdate state (Update Nothing (Just (ProtocolError failure)) [])
        disconnectAndRetry events inbound state failure True

    ensureConnected events inbound state
        | null (liveSubscriptions state) || isSocketPresent (liveSocket state) = pure state
        | otherwise = beginConnect events inbound state

    beginConnect events inbound state = do
        let generation = liveGeneration state + 1
        transport <- startTransport address events inbound generation
        pure state{liveGeneration = generation, liveSocket = PendingSocket transport}

    disconnectAndRetry events _inbound state reason exponential = do
        (detached, retirement) <- detachSocket state reason
        case retirement of
            Just _ -> pure detached
            Nothing -> do
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

-- This helper keeps timer creation visually distinct from the state-changing
-- owner. It returns immediately and the resulting thread owns no client state.
unsafeFork :: IO () -> IO ()
unsafeFork task = void (forkIO task)

-- Socket cleanup is a command to the same actor that performs every read and
-- write. No controller, state owner, timer, or detached cleanup thread ever
-- calls a WebSocket operation.
detachSocket :: LiveState -> Text -> IO (LiveState, Maybe Text)
detachSocket state reason = do
    retirement <- case liveSocket state of
        NoSocket -> pure Nothing
        PendingSocket transport -> either Just (const Nothing) <$> retireTransport transport
        OpenSocket transport -> either Just (const Nothing) <$> retireTransport transport
    let counted = if isSocketPresent (liveSocket state) then liveConnectionCount state + 1 else liveConnectionCount state
    pure
        ( state
            { liveSocket = NoSocket
            , liveConnectionCount = counted
            , liveLastCloseReason = reason
            , liveQuerySetVersion = 0
            , liveRemoteVersion = zeroVersion
            }
        , retirement
        )

data OwnerInput
    = OwnerCommand Command
    | OwnerEvent SocketEvent
    | OwnerMessage Int LBS.ByteString

chooseInput :: TBQueue Command -> TQueue SocketEvent -> InboundQueue -> STM OwnerInput
chooseInput commands events inbound =
    (OwnerCommand <$> readTBQueue commands)
        `orElse` (OwnerEvent <$> readTQueue events)
        `orElse` do
            InboundMessage generation bytes size <- readTBQueue (inboundMessages inbound)
            modifyTVar' (inboundBytes inbound) (subtract size)
            pure (OwnerMessage generation bytes)

startTransport :: Address -> TQueue SocketEvent -> InboundQueue -> Int -> IO Transport
startTransport address events inbound generation = do
    commandQueue <- newTQueueIO
    sleeping <- newTVarIO True
    worker <- async (runSocketOwner address events inbound generation commandQueue sleeping)
    pure (Transport generation commandQueue sleeping worker)

runSocketOwner :: Address -> TQueue SocketEvent -> InboundQueue -> Int -> TQueue TransportCommand -> TVar Bool -> IO ()
runSocketOwner address events inbound generation commandQueue sleeping = do
    let headers = [("Convex-Client", "haskell-0.1.0")]
        options =
            WS.defaultConnectionOptions
                { WS.connectionTimeout = 2
                , WS.connectionStrictUnicode = True
                , WS.connectionFramePayloadSizeLimit = WS.SizeLimit (fromIntegral maxLiveMessageBytes)
                , WS.connectionMessageDataSizeLimit = WS.SizeLimit (fromIntegral maxLiveMessageBytes)
                }
        application connection = mask $ \restore -> do
            atomically (writeTVar sleeping False >> writeTQueue events (SocketReady generation))
            transportLoop restore connection inbound generation commandQueue sleeping
        run
            | addressSecure address =
                Wuss.runSecureClientWith
                    (addressHost address)
                    (fromIntegral (addressPort address))
                    (addressPath address)
                    options
                    headers
                    application
            | otherwise =
                WS.runClientWith
                    (addressHost address)
                    (addressPort address)
                    (addressPath address)
                    options
                    headers
                    application
    outcome <- try run :: IO (Either SomeException ())
    let reason = either (T.pack . displayException) (const "Live WebSocket closed") outcome
    atomically $ do
        writeTVar sleeping False
        pending <- flushTQueue commandQueue
        forM_ pending $ \command -> case command of
            TransportSend _ reply -> void (tryPutTMVar reply (Left reason))
            TransportRetire reply -> void (tryPutTMVar reply ())
    atomically (writeTQueue events (SocketEnded generation reason))

transportLoop :: (forall a. IO a -> IO a) -> WS.Connection -> InboundQueue -> Int -> TQueue TransportCommand -> TVar Bool -> IO ()
transportLoop restore connection inbound generation commandQueue sleeping = do
    grace <- registerDelay 50000
    command <-
        atomically $
            (Just <$> readTQueue commandQueue)
                `orElse` do
                    expired <- readTVar grace
                    check expired
                    writeTVar sleeping True
                    pure Nothing
    case command of
        Just (TransportSend values done) -> do
            result <- sendJSONBatchOwned connection values
            atomically (putTMVar done result)
            either (throwIO . TransportError) (const (transportLoop restore connection inbound generation commandQueue sleeping)) result
        Just (TransportRetire done) -> do
            _ <- timeout 500000 (try (WS.sendClose connection ("client disconnect" :: Text)) :: IO (Either SomeException ()))
            atomically (putTMVar done ())
        Nothing -> do
            received <- ((Just <$> restore (WS.receiveData connection)) `catch` ownerWake) `finally` atomically (writeTVar sleeping False)
            case received of
                Nothing -> transportLoop restore connection inbound generation commandQueue sleeping
                Just bytes -> do
                    let size = fromIntegral (LBS.length bytes)
                    when (size > maxLiveMessageBytes) (throwIO (ProtocolError "Live message exceeded 2 MiB"))
                    publishInbound restore sleeping inbound (InboundMessage generation bytes size)
                    transportLoop restore connection inbound generation commandQueue sleeping
  where
    ownerWake :: WakeSocketOwner -> IO (Maybe LBS.ByteString)
    ownerWake _ = throwIO (TransportError "Live socket read was interrupted for an owner command")

publishInbound :: (forall a. IO a -> IO a) -> TVar Bool -> InboundQueue -> InboundMessage -> IO ()
publishInbound restore sleeping inbound message@(InboundMessage _ _ size) =
    ( do
        atomically (writeTVar sleeping True)
        restore $ atomically $ do
            used <- readTVar (inboundBytes inbound)
            when (used + size > 2 * maxLiveMessageBytes) retry
            writeTBQueue (inboundMessages inbound) message
            writeTVar (inboundBytes inbound) (used + size)
    )
        `finally` atomically (writeTVar sleeping False)

sendConnect :: Transport -> LiveState -> IO (Either Text LiveState)
sendConnect transport state = do
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
        entries = sortOn (subscriptionId . stateSubscription) (liveSubscriptions state)
        modificationMessage = modifyMessage state (map addModification entries)
        messages = connectMessage : [modificationMessage | not (null entries)]
    sent <- sendJSONBatch transport messages
    pure $ case sent of
        Left failure -> Left failure
        Right ()
            | null entries -> Right state
            | otherwise -> Right state{liveQuerySetVersion = liveQuerySetVersion state + 1}

sendModify :: Transport -> LiveState -> [Value] -> IO (Either Text LiveState)
sendModify transport state modifications = do
    let oldVersion = liveQuerySetVersion state
        message = modifyMessage state modifications
    result <- sendJSON transport message
    pure (state{liveQuerySetVersion = oldVersion + 1} <$ result)

modifyMessage :: LiveState -> [Value] -> Value
modifyMessage state modifications =
    object
        [ "type" .= ("ModifyQuerySet" :: Text)
        , "baseVersion" .= liveQuerySetVersion state
        , "newVersion" .= (liveQuerySetVersion state + 1)
        , "modifications" .= modifications
        ]

sendJSON :: Transport -> Value -> IO (Either Text ())
sendJSON transport value = sendJSONBatch transport [value]

sendJSONBatch :: Transport -> [Value] -> IO (Either Text ())
sendJSONBatch transport values = do
    reply <- newEmptyTMVarIO
    wakeTransport transport (TransportSend values reply)
    result <- timeout 750000 (atomically (takeTMVar reply))
    pure (maybe (Left "timed out waiting for Live socket owner write") id result)

sendJSONBatchOwned :: WS.Connection -> [Value] -> IO (Either Text ())
sendJSONBatchOwned connection values = do
    outcome <- timeout 500000 (try (mapM_ (WS.sendTextData connection . encode) values) :: IO (Either SomeException ()))
    pure $ case outcome of
        Nothing -> Left "timed out writing Live WebSocket frame"
        Just (Left failure) -> Left (T.pack (displayException failure))
        Just (Right ()) -> Right ()

retireTransport :: Transport -> IO (Either Text ())
retireTransport transport = do
    finished <- poll (transportWorker transport)
    case finished of
        Just _ -> pure (Right ())
        Nothing -> do
            reply <- newEmptyTMVarIO
            wakeTransport transport (TransportRetire reply)
            result <- timeout 750000 (atomically (takeTMVar reply))
            case result of
                Just () -> joinOrForce
                Nothing -> joinOrForce
  where
    joinOrForce = do
        joined <- timeout 750000 (waitCatch (transportWorker transport))
        case joined of
            Just _ -> pure (Right ())
            Nothing -> do
                forced <- timeout 750000 (cancel (transportWorker transport))
                pure (maybe (Left "timed out retiring Live socket owner") (const (Right ())) forced)

wakeTransport :: Transport -> TransportCommand -> IO ()
wakeTransport transport command = do
    shouldWake <- atomically $ do
        writeTQueue (transportCommands transport) command
        readTVar (transportSleeping transport)
    when shouldWake $ void (timeout 500000 (throwTo (asyncThreadId (transportWorker transport)) WakeSocketOwner))

completeAddBarriers :: LiveState -> IO LiveState
completeAddBarriers state = do
    subscriptions <- mapM complete (liveSubscriptions state)
    pure state{liveSubscriptions = subscriptions}
  where
    complete entry = case stateAddBarrier entry of
        Nothing -> pure entry
        Just barrier -> do
            atomically (void (tryPutTMVar barrier (Right (stateSubscription entry))))
            pure entry{stateAddBarrier = Nothing}

completeRemoveBarriers :: LiveState -> IO LiveState
completeRemoveBarriers state = do
    atomically $ forM_ (liveRemoveBarriers state) (\barrier -> void (tryPutTMVar barrier (Right ())))
    pure state{liveRemoveBarriers = []}

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

applyServerMessage :: LiveState -> Value -> IO (Either Text (LiveState, Bool))
applyServerMessage state (Object message) = case KM.lookup "type" message of
    Just (String "Transition") -> fmap (\updated -> (updated, True)) <$> applyTransition state message
    Just (String "Ping") -> pure (Right (state, True))
    -- This educational client never issues WebSocket mutations or actions, so
    -- their response envelopes are irrelevant. They are tolerated for drift
    -- compatibility but cannot keep a dead connection healthy or reset backoff.
    Just (String "MutationResponse") -> pure (Right (state, False))
    Just (String "ActionResponse") -> pure (Right (state, False))
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
        let activeIds = map (subscriptionId . stateSubscription) (liveSubscriptions state)
        forM_ changes $ \change -> case change of
            Changed ident _ -> unlessEither (ident `elem` activeIds) "Transition updated an inactive queryId"
            Removed _ -> Right ()
        unlessEither (stateVersionQuerySet end <= fromIntegral (liveQuerySetVersion state)) "Transition exceeded the locally written query-set version"
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
        Just (String "QueryUpdated") -> do
            value <- maybe (Left "QueryUpdated omitted value") Right (KM.lookup "value" change)
            logs <- parseTextArray "logLines" change
            Right (Changed ident (Update (Just value) Nothing logs))
        Just (String "QueryFailed") -> do
            message <- case KM.lookup "errorMessage" change of
                Just (String value) -> Right value
                _ -> Left "QueryFailed omitted string errorMessage"
            logs <- parseTextArray "logLines" change
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
    digest = updateDigest update
    offer entry
        | subscriptionId (stateSubscription entry) /= ident = pure entry
        | stateLastDelivered entry == Just digest = pure entry
        | otherwise = do
            offerUpdate (map stateSubscription (liveSubscriptions state)) (stateSubscription entry) update
            pure entry{stateLastDelivered = Just digest}

broadcastUpdate :: LiveState -> Update -> IO ()
broadcastUpdate state update =
    let subscriptions = map stateSubscription (liveSubscriptions state)
     in mapM_ (\subscription -> offerUpdate subscriptions subscription update) subscriptions

offerUpdate :: [Subscription] -> Subscription -> Update -> IO ()
offerUpdate allSubscriptions subscription original = do
    let originalSize = updateEncodedBytes original
        update =
            if originalSize <= maxQueuedUpdateBytes
                then original
                else Update Nothing (Just (ProtocolError "Live update exceeded the bounded delivery size")) []
        size = updateEncodedBytes update
    atomically $ do
        dead <- readTVar (subscriptionClosed subscription)
        unless dead $ do
            serial <- readTVar (queueBudgetSerial (subscriptionBudget subscription))
            let nextSerial = serial + 1
                item = QueuedUpdate update size nextSerial
            writeTVar (queueBudgetSerial (subscriptionBudget subscription)) nextSerial
            modifyTVar' (subscriptionQueue subscription) (|> item)
            modifyTVar' (queueBudgetBytes (subscriptionBudget subscription)) (+ size)
            trimSubscription subscription
            trimGlobal allSubscriptions

closeSubscription :: Subscription -> IO ()
closeSubscription subscription = atomically $ do
    writeTVar (subscriptionClosed subscription) True
    queued <- readTVar (subscriptionQueue subscription)
    writeTVar (subscriptionQueue subscription) Seq.empty
    modifyTVar' (queueBudgetBytes (subscriptionBudget subscription)) (subtract (sum (map queuedUpdateBytes (toList queued))))

newSubscription :: QueueBudget -> Int -> IO Subscription
newSubscription budget ident = Subscription ident <$> newTVarIO Seq.empty <*> newTVarIO False <*> pure budget

trimSubscription :: Subscription -> STM ()
trimSubscription subscription = do
    queued <- readTVar (subscriptionQueue subscription)
    when (Seq.length queued > maxUpdatesPerSubscription) $ dropOldest subscription >> trimSubscription subscription

trimGlobal :: [Subscription] -> STM ()
trimGlobal subscriptions = do
    used <- case subscriptions of
        [] -> pure 0
        first : _ -> readTVar (queueBudgetBytes (subscriptionBudget first))
    when (used > maxTotalQueuedBytes) $ do
        heads <- fmap concat $ mapM queuedHead subscriptions
        case sortOn (queuedUpdateSerial . snd) heads of
            (oldest, _) : _ -> dropOldest oldest >> trimGlobal subscriptions
            [] -> pure ()
  where
    queuedHead subscription = do
        queued <- readTVar (subscriptionQueue subscription)
        pure $ case Seq.viewl queued of
            EmptyL -> []
            item :< _ -> [(subscription, item)]

dropOldest :: Subscription -> STM ()
dropOldest subscription = do
    queued <- readTVar (subscriptionQueue subscription)
    case Seq.viewl queued of
        EmptyL -> pure ()
        item :< remaining -> do
            writeTVar (subscriptionQueue subscription) remaining
            modifyTVar' (queueBudgetBytes (subscriptionBudget subscription)) (subtract (queuedUpdateBytes item))

updateDigest :: Update -> BS.ByteString
updateDigest = SHA1.hashlazy . encode . updateBudgetValue

updateEncodedBytes :: Update -> Int
updateEncodedBytes update = fromIntegral (LBS.length (encode (updateBudgetValue update))) * 8 + 4096

updateBudgetValue :: Update -> Value
updateBudgetValue update =
    object
        [ "value" .= updateValue update
        , "error" .= fmap show (updateError update)
        , "logs" .= updateLogs update
        ]

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
isPending generation (PendingSocket transport) = generation == transportGeneration transport
isPending _ _ = False

isOpen :: Int -> SocketState -> Bool
isOpen generation (OpenSocket transport) = generation == transportGeneration transport
isOpen _ _ = False

isCurrent :: Int -> SocketState -> Bool
isCurrent generation (PendingSocket transport) = generation == transportGeneration transport
isCurrent generation (OpenSocket transport) = generation == transportGeneration transport
isCurrent _ NoSocket = False

socketTransport :: SocketState -> Transport
socketTransport (PendingSocket transport) = transport
socketTransport (OpenSocket transport) = transport
socketTransport NoSocket = error "socketTransport called without a socket"

parseTextArray :: Text -> Object -> Either Text [Text]
parseTextArray key payload = case KM.lookup (Key.fromText key) payload of
    Nothing -> Right []
    Just (Array values) -> traverse textValue (foldr (:) [] values)
    Just _ -> Left (key <> " must be an array of strings")
  where
    textValue (String value) = Right value
    textValue _ = Left (key <> " must contain only strings")

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
