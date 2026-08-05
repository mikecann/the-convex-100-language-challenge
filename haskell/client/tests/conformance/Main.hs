{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Test-only NDJSON adapter. stdout belongs exclusively to protocol events;
diagnostics go to stderr. The same byte-stream parser serves stdin/stdout
and the TCP transport used by the shared controller.
-}
module Main (main) where

import Control.Concurrent.Async (Async, async, cancel, waitCatch)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (Exception, SomeException, bracket, bracketOnError, displayException, fromException, throwIO, try)
import Control.Monad (forM_, unless, void)
import Convex
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Char8 qualified as B8
import Data.ByteString.Lazy.Char8 qualified as L8
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Network.Socket
import System.Environment (lookupEnv)
import System.IO

data Relay = Relay
    { relayGeneration :: Int
    , relaySubscription :: Subscription
    , relayWorker :: Async ()
    }

newtype AdapterProtocolFailure = AdapterProtocolFailure Text
    deriving (Show)

instance Exception AdapterProtocolFailure

data AdapterState = AdapterState
    { adapterClient :: Client
    , adapterRelays :: TVar (Map Text Relay)
    , adapterNextGeneration :: TVar Int
    , adapterWriterLock :: MVar ()
    , adapterOutput :: Handle
    , adapterTestRelayPause :: Maybe String
    }

main :: IO ()
main =
    lookupEnv "ADAPTER_LISTEN" >>= \case
        Nothing -> runAdapter stdin stdout
        Just address -> withSocketsDo (runTCP address)

runTCP :: String -> IO ()
runTCP address = do
    let (host, port) = splitAddress address
        hints = defaultHints{addrFlags = [AI_PASSIVE], addrSocketType = Stream}
    candidates <- getAddrInfo (Just hints) (if null host then Nothing else Just host) (Just port)
    case candidates of
        [] -> fail ("no TCP address resolved for " <> address)
        candidate : _ -> bracket (open candidate) close $ \server -> do
            hPutStrLn stderr ("adapter listening on " <> address)
            (peer, _) <- accept server
            bracket (socketToHandle peer ReadWriteMode) hClose $ \stream -> do
                hSetBuffering stream NoBuffering
                runAdapter stream stream
  where
    open candidate = do
        server <- socket (addrFamily candidate) (addrSocketType candidate) (addrProtocol candidate)
        setSocketOption server ReuseAddr 1
        bind server (addrAddress candidate)
        listen server 1
        pure server

splitAddress :: String -> (String, String)
splitAddress address =
    let (backwardsPort, backwardsHost) = break (== ':') (reverse address)
     in if null backwardsHost || null backwardsPort
            then error ("ADAPTER_LISTEN must be host:port, got " <> address)
            else (reverse (drop 1 backwardsHost), reverse backwardsPort)

runAdapter :: Handle -> Handle -> IO ()
runAdapter input output = do
    deployment <- fromMaybe "http://127.0.0.1" <$> lookupEnv "CONVEX_URL"
    testRelayPause <- lookupEnv "CONVEX_ADAPTER_TEST_RELAY_PAUSE"
    bracket (newClient deployment) closeClient $ \client -> do
        state <- AdapterState client <$> newTVarIO Map.empty <*> newTVarIO 0 <*> newMVar () <*> pure output <*> pure testRelayPause
        commandLoop state input
        closeRelays state

-- hGetLine assembles arbitrary partial reads. At EOF it still returns a final
-- non-empty unterminated record, which gives stdin and TCP identical NDJSON
-- semantics without assuming controller writes align with packets.
commandLoop :: AdapterState -> Handle -> IO ()
commandLoop state input = do
    eof <- hIsEOF input
    unless eof $ do
        lineResult <- try (B8.hGetLine input) :: IO (Either SomeException B8.ByteString)
        continue <- case lineResult of
            Left failure -> writeProtocolError state Nothing ("read command: " <> T.pack (displayException failure)) >> pure False
            Right line -> case eitherDecodeStrict' line of
                Left problem -> writeProtocolError state Nothing ("decode command: " <> T.pack problem) >> pure True
                Right command -> handleCommand state command
        whenContinue continue (commandLoop state input)
  where
    whenContinue True continuation = continuation
    whenContinue False _ = pure ()

handleCommand :: AdapterState -> Value -> IO Bool
handleCommand state (Object command) = do
    let requestId = textField "id" command
    outcome <- try (dispatch state command) :: IO (Either SomeException Bool)
    case outcome of
        Right continue -> pure continue
        Left failure -> writeException state requestId failure >> pure True
handleCommand state _ = writeProtocolError state Nothing "command must be a JSON object" >> pure True

dispatch :: AdapterState -> Object -> IO Bool
dispatch state command = do
    requestId <- requiredText "id" command
    operation <- requiredText "op" command
    let client = adapterClient state
        arguments = fromMaybe (Object mempty) (KM.lookup "args" command)
        ack = writeEvent state (object ["id" .= requestId, "type" .= ("ack" :: Text)])
    case operation of
        "hello" -> do
            unless (KM.lookup "protocolVersion" command == Just (Number 1)) (commandFailure "unsupported adapter protocol version")
            writeEvent
                state
                ( object
                    [ "protocolVersion" .= (1 :: Int)
                    , "id" .= requestId
                    , "type" .= ("ready" :: Text)
                    , "language" .= ("haskell" :: Text)
                    , "implementation" .= ("native-haskell-0.1.0" :: Text)
                    , "runtime" .= ("ghc-9.10.1" :: Text)
                    ]
                )
            pure True
        "query" -> requiredText "path" command >>= \path -> callAndWrite requestId (query client path arguments) >> pure True
        "mutation" -> requiredText "path" command >>= \path -> callAndWrite requestId (mutation client path arguments) >> pure True
        "action" -> requiredText "path" command >>= \path -> callAndWrite requestId (action client path arguments) >> pure True
        "setAuth" -> do
            token <- requiredText "token" command
            if T.null token then clearAuth client else setAuth client token
            ack
            pure True
        "subscribe" -> do
            subscriptionName <- requiredText "subscriptionId" command
            path <- requiredText "path" command
            replaceRelay state subscriptionName path arguments
            ack
            pure True
        "unsubscribe" -> do
            subscriptionName <- requiredText "subscriptionId" command
            removeRelay state subscriptionName
            ack
            pure True
        "debugDisconnect" -> debugDisconnectForAdapter client >> ack >> pure True
        "close" -> do
            closeRelays state
            closeClient client
            writeEvent state (object ["id" .= requestId, "type" .= ("closed" :: Text)])
            pure False
        _ -> commandFailure ("unknown adapter operation " <> operation)
  where
    callAndWrite requestId clientCall = do
        result <- clientCall
        writeEvent
            state
            ( object
                [ "id" .= requestId
                , "type" .= ("result" :: Text)
                , "value" .= resultValue result
                , "logs" .= resultLogs result
                ]
            )

replaceRelay :: AdapterState -> Text -> Text -> Value -> IO ()
replaceRelay state name path arguments = do
    removeRelay state name
    subscription <- subscribe (adapterClient state) path arguments
    generation <- atomically $ do
        current <- readTVar (adapterNextGeneration state)
        let next = current + 1
        writeTVar (adapterNextGeneration state) next
        pure next
    startGate <- newEmptyMVar
    worker <- async (takeMVar startGate >> relayLoop state name generation subscription)
    atomically (modifyTVar' (adapterRelays state) (Map.insert name (Relay generation subscription worker)))
    putMVar startGate ()

removeRelay :: AdapterState -> Text -> IO ()
removeRelay state name = do
    previous <- atomically $ do
        relays <- readTVar (adapterRelays state)
        writeTVar (adapterRelays state) (Map.delete name relays)
        pure (Map.lookup name relays)
    forM_ previous $ \relay -> do
        -- The client owner invalidates its generation before returning. The writer
        -- lock below is a second barrier for a relay already between dequeue/write.
        unsubscribe (adapterClient state) (relaySubscription relay)
        cancel (relayWorker relay)
        void (waitCatch (relayWorker relay))
        withMVar (adapterWriterLock state) (const (pure ()))

closeRelays :: AdapterState -> IO ()
closeRelays state = do
    names <- Map.keys <$> readTVarIO (adapterRelays state)
    mapM_ (removeRelay state) names

relayLoop :: AdapterState -> Text -> Int -> Subscription -> IO ()
relayLoop state name generation subscription = do
    update <- nextUpdate subscription
    pauseRelayAfterDequeue state name generation
    withMVar (adapterWriterLock state) $ \_ -> do
        current <- readTVarIO (adapterRelays state)
        case Map.lookup name current of
            Just relay | relayGeneration relay == generation -> do
                let base = ["type" .= ("subscription" :: Text), "subscriptionId" .= name]
                    event = case (updateValue update, updateError update) of
                        (Just result, _) -> object (base <> ["value" .= result, "logs" .= updateLogs update])
                        (_, Just failure) -> object (base <> ["error" .= convexErrorObject failure, "logs" .= updateLogs update])
                        _ -> object (base <> ["error" .= object ["name" .= ("ProtocolError" :: Text), "message" .= ("empty Live update" :: Text)]])
                L8.hPutStrLn (adapterOutput state) (encode event)
                hFlush (adapterOutput state)
            _ -> pure ()
    relayLoop state name generation subscription

-- The process fixture uses a loopback-only gate to stop a real relay in the
-- narrow race between dequeue and publication. This hook exists only in the
-- test adapter executable and is inert unless its explicit test environment
-- variable is present. Cancelling the relay closes the gate connection, so an
-- unsubscribe or replacement ACK proves the old worker has really retired.
pauseRelayAfterDequeue :: AdapterState -> Text -> Int -> IO ()
pauseRelayAfterDequeue state name generation = forM_ (adapterTestRelayPause state) $ \address -> withSocketsDo $ do
    let (host, port) = splitAddress address
        hints = defaultHints{addrSocketType = Stream}
    candidates <- getAddrInfo (Just hints) (Just host) (Just port)
    case candidates of
        [] -> fail ("no relay pause address resolved for " <> address)
        candidate : _ -> bracket (openGate candidate) hClose $ \gate -> do
            hSetBinaryMode gate True
            hSetBuffering gate NoBuffering
            B8.hPutStrLn gate (B8.pack (T.unpack name <> ":" <> show generation))
            void (B8.hGetLine gate)
  where
    openGate candidate =
        bracketOnError
            (socket (addrFamily candidate) (addrSocketType candidate) (addrProtocol candidate))
            close
            (\gateSocket -> connect gateSocket (addrAddress candidate) >> socketToHandle gateSocket ReadWriteMode)

writeEvent :: AdapterState -> Value -> IO ()
writeEvent state event = withMVar (adapterWriterLock state) $ \_ -> do
    L8.hPutStrLn (adapterOutput state) (encode event)
    hFlush (adapterOutput state)

writeProtocolError :: AdapterState -> Maybe Text -> Text -> IO ()
writeProtocolError state requestId message =
    writeEvent
        state
        ( object
            ( maybe [] (pure . ("id" .=)) requestId
                <> ["type" .= ("error" :: Text), "error" .= object ["name" .= ("ProtocolError" :: Text), "message" .= message]]
            )
        )

writeException :: AdapterState -> Maybe Text -> SomeException -> IO ()
writeException state requestId failure = case fromException failure :: Maybe AdapterProtocolFailure of
    Just (AdapterProtocolFailure message) -> writeProtocolError state requestId message
    Nothing ->
        let convex = fromException failure :: Maybe ConvexError
            details =
                maybe
                    (object ["name" .= ("TransportError" :: Text), "message" .= T.pack (displayException failure)])
                    convexErrorObject
                    convex
            logs = maybe [] convexErrorLogs convex
         in writeEvent
                state
                ( object
                    ( maybe [] (pure . ("id" .=)) requestId
                        <> ["type" .= ("error" :: Text), "error" .= details]
                        <> ["logs" .= logs | not (null logs)]
                    )
                )

convexErrorObject :: ConvexError -> Value
convexErrorObject = \case
    FunctionError message details _ ->
        object
            ( ["name" .= ("FunctionError" :: Text), "message" .= message]
                <> maybe [] (pure . ("data" .=)) details
            )
    ProtocolError message -> object ["name" .= ("ProtocolError" :: Text), "message" .= message]
    TransportError message -> object ["name" .= ("TransportError" :: Text), "message" .= message]
    ClosedError message -> object ["name" .= ("ClosedError" :: Text), "message" .= message]

convexErrorLogs :: ConvexError -> [Text]
convexErrorLogs (FunctionError _ _ logs) = logs
convexErrorLogs _ = []

commandFailure :: Text -> IO a
commandFailure = throwIO . AdapterProtocolFailure

requiredText :: Text -> Object -> IO Text
requiredText key objectValue = maybe (commandFailure ("command omitted " <> key)) pure (textField key objectValue)

textField :: Text -> Object -> Maybe Text
textField key objectValue = case KM.lookup (Key.fromText key) objectValue of
    Just (String text) -> Just text
    _ -> Nothing
