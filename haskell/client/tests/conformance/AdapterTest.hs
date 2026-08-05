{-# LANGUAGE OverloadedStrings #-}

{- | Byte-stream lifecycle tests for the actual convex-adapter executable.
These fixtures intentionally use a child process rather than calling adapter
functions directly, because pipe buffering, UTF-8 boundaries, EOF, and TCP
packet boundaries are part of the adapter protocol contract.
-}
module Main (main) where

import Control.Concurrent (Chan, MVar, ThreadId, forkIO, killThread, newChan, newEmptyMVar, putMVar, readChan, takeMVar, threadDelay, writeChan)
import Control.Exception (IOException, SomeException, bracket, catch, try)
import Control.Monad (forM_, forever, unless, void)
import Data.Aeson (Object, Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
import Data.ByteString.Lazy qualified as LBS
import Data.Char (toLower)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as T
import Network.Socket qualified as Socket
import Network.WebSockets qualified as WS
import System.Environment (getEnv, getEnvironment)
import System.Exit (ExitCode (..))
import System.IO (BufferMode (NoBuffering), Handle, IOMode (ReadWriteMode), hClose, hSetBinaryMode, hSetBuffering)
import System.Process
import System.Timeout (timeout)

data Child = Child
    { childInput :: Handle
    , childOutput :: Handle
    , childProcess :: ProcessHandle
    }

data RelayGate = RelayGate
    { relayGateListener :: Socket.Socket
    , relayGateAddress :: String
    }

data PausedRelay = PausedRelay
    { pausedRelayNotice :: BS.ByteString
    , pausedRelayHandle :: Handle
    }

data WebSocketFixture = WebSocketFixture
    { fixtureThread :: ThreadId
    , fixtureConnection :: MVar WS.Connection
    , fixtureMessages :: Chan Object
    }

main :: IO ()
main = do
    executable <- getEnv "CONVEX_ADAPTER_BIN"
    testSplitUtf8AndBatchedRecords executable
    testFinalUnterminatedRecord executable
    testMalformedPartialRecord executable
    testCleanClose executable
    testTcpPartialWrites executable
    testStructuredHttpFailures executable
    testRelayAckBarriers executable
    putStrLn "haskell adapter process fixtures pass"

-- The first two UTF-8 code points are split inside their byte encodings. The
-- last write also contains the end of hello and a complete close record, which
-- proves the reader neither assumes one write per code point nor one write per
-- NDJSON record.
testSplitUtf8AndBatchedRecords :: FilePath -> IO ()
testSplitUtf8AndBatchedRecords executable = withChild executable [] $ \child -> do
    let prefix = "{\"protocolVersion\":1,\"id\":\"split-caf"
        suffix = "\",\"op\":\"hello\"}\n{\"id\":\"close\",\"op\":\"close\"}\n"
    writeChunk (childInput child) (B8.pack prefix <> BS.pack [0xc3])
    writeChunk (childInput child) (BS.pack [0xa9] <> "-" <> BS.pack [0xf0, 0x9f])
    writeChunk (childInput child) (BS.pack [0xa6, 0x98] <> B8.pack suffix)
    ready <- readEvent (childOutput child)
    closed <- readEvent (childOutput child)
    assertReady "split-café-🦘" ready
    assertClosed "close" closed
    expectExitSuccess child

-- POSIX-style producers are allowed to finish without a trailing newline. A
-- complete final JSON record still has to be processed before EOF shuts down
-- the adapter.
testFinalUnterminatedRecord :: FilePath -> IO ()
testFinalUnterminatedRecord executable = withChild executable [] $ \child -> do
    writeChunk (childInput child) "{\"protocolVersion\":1,\"id\":\"final\",\"op\":\"hello\"}"
    hClose (childInput child)
    assertReady "final" =<< readEvent (childOutput child)
    expectExitSuccess child

-- An incomplete final record is not silently discarded at EOF. It becomes a
-- structured protocol error without a made-up request id.
testMalformedPartialRecord :: FilePath -> IO ()
testMalformedPartialRecord executable = withChild executable [] $ \child -> do
    writeChunk (childInput child) "{\"id\":\"broken\",\"op\":"
    hClose (childInput child)
    assertProtocolError =<< readEvent (childOutput child)
    expectExitSuccess child

-- Keep the normal shutdown assertion separate so a future UTF-8 regression
-- cannot obscure whether close itself still flushes its event and exits zero.
testCleanClose :: FilePath -> IO ()
testCleanClose executable = withChild executable [] $ \child -> do
    writeChunk (childInput child) "{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n{\"id\":\"done\",\"op\":\"close\"}\n"
    assertReady "hello" =<< readEvent (childOutput child)
    assertClosed "done" =<< readEvent (childOutput child)
    expectExitSuccess child

-- TCP mode gets the same deliberately fragmented byte stream as stdio. The
-- adapter must accept one controller, serve the full lifecycle, then release
-- both the connection and listening socket when close completes.
testTcpPartialWrites :: FilePath -> IO ()
testTcpPartialWrites executable = do
    port <- reserveLoopbackPort
    let address = "127.0.0.1:" <> show port
    withChild executable [("ADAPTER_LISTEN", address)] $ \child -> do
        hClose (childInput child)
        socket <- connectEventually port
        bracket (Socket.socketToHandle socket ReadWriteMode) hClose $ \stream -> do
            hSetBinaryMode stream True
            hSetBuffering stream NoBuffering
            writeChunk stream "{\"protocolVersion\":1,\"id\":\"tcp"
            threadDelay 10000
            writeChunk stream "-hello\",\"op\":\"hello\"}\n{\"id\":\"tcp-close\","
            threadDelay 10000
            writeChunk stream "\"op\":\"close\"}\n"
            assertReady "tcp-hello" =<< readEvent stream
            assertClosed "tcp-close" =<< readEvent stream
        expectExitSuccess child

-- A real loopback HTTP peer proves FunctionError data and logs survive the
-- process boundary, while an actually absent errorData stays omitted rather
-- than becoming JSON null.
testStructuredHttpFailures :: FilePath -> IO ()
testStructuredHttpFailures executable =
    withHttpFailureFixture [withDetails, withoutDetails] $ \port ->
        withChild executable [("CONVEX_URL", "http://127.0.0.1:" <> show port)] $ \child -> do
            sendCommand child (queryCommand "http-detailed")
            assertHttpFunctionError "http-detailed" (Just (object ["code" .= ("HTTP_FIXTURE" :: Text)])) ["http fixture log"] =<< readEvent (childOutput child)
            sendCommand child (queryCommand "http-no-data")
            assertHttpFunctionError "http-no-data" Nothing [] =<< readEvent (childOutput child)
            sendCommand child (object ["id" .= ("bad-command" :: Text), "op" .= ("not-an-operation" :: Text)])
            assertProtocolErrorWithId "bad-command" =<< readEvent (childOutput child)
            sendCommand child (object ["id" .= ("http-close" :: Text), "op" .= ("close" :: Text)])
            assertClosed "http-close" =<< readEvent (childOutput child)
            expectExitSuccess child
  where
    queryCommand requestId =
        object
            [ "id" .= (requestId :: Text)
            , "op" .= ("query" :: Text)
            , "path" .= ("fixture:fail" :: Text)
            , "args" .= object []
            ]
    withDetails =
        object
            [ "status" .= ("error" :: Text)
            , "errorMessage" .= ("http fixture failure" :: Text)
            , "errorData" .= object ["code" .= ("HTTP_FIXTURE" :: Text)]
            , "logLines" .= ["http fixture log" :: Text]
            ]
    withoutDetails =
        object
            [ "status" .= ("error" :: Text)
            , "errorMessage" .= ("http fixture failure" :: Text)
            , "logLines" .= ([] :: [Text])
            ]

-- A loopback WebSocket supplies real Convex transitions while a separate
-- loopback gate pauses the adapter relay after dequeue. Replacement and
-- unsubscribe must cancel that paused worker before publishing their ACK, so
-- the stale value can never appear on either side of the acknowledgement.
testRelayAckBarriers :: FilePath -> IO ()
testRelayAckBarriers executable = withRelayGate $ \gate -> do
    websocketPort <- reserveLoopbackPort
    withWebSocketFixture websocketPort $ \fixture ->
        withChild
            executable
            [ ("CONVEX_URL", "http://127.0.0.1:" <> show websocketPort)
            , ("CONVEX_ADAPTER_TEST_RELAY_PAUSE", relayGateAddress gate)
            ]
            $ \child -> do
                sendCommand child (subscribeCommand "first-subscribe")
                assertAck "first-subscribe" =<< readEvent (childOutput child)

                connection <- awaitFixtureConnection fixture
                assertMessageType "Connect" =<< awaitFixtureMessage fixture
                oldAdd <- awaitFixtureMessage fixture
                oldQueryId <- modificationId "Add" oldAdd

                let zero = version 0 "AAAAAAAAAAA="
                    firstVersion = version 1 "AQAAAAAAAAA="
                    failedVersion = version 3 "AgAAAAAAAAA="
                    recoveredVersion = version 3 "AwAAAAAAAAA="
                    staleVersion = version 3 "BAAAAAAAAAA="
                sendTransition connection zero firstVersion [queryUpdated oldQueryId 1]
                oldRelay <- awaitPausedRelay gate
                assertNotice "same:1" oldRelay

                sendCommand child (subscribeCommand "replace")
                removedOld <- awaitFixtureMessage fixture
                assertModification "Remove" oldQueryId removedOld
                newAdd <- awaitFixtureMessage fixture
                newQueryId <- modificationId "Add" newAdd
                unless (newQueryId /= oldQueryId) (fail "same-ID replacement reused the retired client query id")
                assertAck "replace" =<< readEvent (childOutput child)
                assertPausedRelayCancelled oldRelay
                assertNoEventFor 100000 (childOutput child)

                -- QueryFailed is a public subscription event and the same subscription
                -- must subsequently recover with a normal QueryUpdated value.
                sendTransition connection firstVersion failedVersion [queryFailed newQueryId]
                failedRelay <- awaitPausedRelay gate
                assertNotice "same:2" failedRelay
                releasePausedRelay failedRelay
                assertSubscriptionFailure =<< readEvent (childOutput child)

                sendTransition connection failedVersion recoveredVersion [queryUpdated newQueryId 2]
                recoveredRelay <- awaitPausedRelay gate
                assertNotice "same:2" recoveredRelay
                releasePausedRelay recoveredRelay
                assertSubscriptionValue 2 ["recovered"] =<< readEvent (childOutput child)

                sendTransition connection recoveredVersion staleVersion [queryUpdated newQueryId 3]
                staleRelay <- awaitPausedRelay gate
                assertNotice "same:2" staleRelay
                sendCommand child (object ["id" .= ("unsubscribe" :: Text), "op" .= ("unsubscribe" :: Text), "subscriptionId" .= ("same" :: Text)])
                removedNew <- awaitFixtureMessage fixture
                assertModification "Remove" newQueryId removedNew
                assertAck "unsubscribe" =<< readEvent (childOutput child)
                assertPausedRelayCancelled staleRelay
                assertNoEventFor 100000 (childOutput child)

                sendCommand child (object ["id" .= ("relay-close" :: Text), "op" .= ("close" :: Text)])
                assertClosed "relay-close" =<< readEvent (childOutput child)
                expectExitSuccess child
  where
    subscribeCommand requestId =
        object
            [ "id" .= (requestId :: Text)
            , "op" .= ("subscribe" :: Text)
            , "subscriptionId" .= ("same" :: Text)
            , "path" .= ("counter:get" :: Text)
            , "args" .= object ["room" .= ("adapter-relay-race" :: Text)]
            ]

sendCommand :: Child -> Value -> IO ()
sendCommand child command = writeChunk (childInput child) (LBS.toStrict (encode command) <> "\n")

assertAck :: Text -> Value -> IO ()
assertAck expectedId actual =
    unless (actual == object ["id" .= expectedId, "type" .= ("ack" :: Text)]) $
        fail ("ACK was malformed: " <> show actual)

assertHttpFunctionError :: Text -> Maybe Value -> [Text] -> Value -> IO ()
assertHttpFunctionError expectedId expectedData expectedLogs actual = do
    let errorFields =
            [ "name" .= ("FunctionError" :: Text)
            , "message" .= ("http fixture failure" :: Text)
            ]
                <> maybe [] (pure . ("data" .=)) expectedData
        expected =
            object
                ( [ "id" .= expectedId
                  , "type" .= ("error" :: Text)
                  , "error" .= object errorFields
                  ]
                    <> ["logs" .= expectedLogs | not (null expectedLogs)]
                )
    unless (actual == expected) (fail ("HTTP FunctionError was malformed: " <> show actual))

assertSubscriptionFailure :: Value -> IO ()
assertSubscriptionFailure actual = do
    let expected =
            object
                [ "type" .= ("subscription" :: Text)
                , "subscriptionId" .= ("same" :: Text)
                , "error"
                    .= object
                        [ "name" .= ("FunctionError" :: Text)
                        , "message" .= ("fixture failure" :: Text)
                        , "data" .= object ["code" .= ("FAILED_ONCE" :: Text)]
                        ]
                , "logs" .= ["failed once" :: Text]
                ]
    unless (actual == expected) (fail ("subscription failure was malformed: " <> show actual))

assertSubscriptionValue :: Int -> [Text] -> Value -> IO ()
assertSubscriptionValue count logs actual = do
    let expected =
            object
                [ "type" .= ("subscription" :: Text)
                , "subscriptionId" .= ("same" :: Text)
                , "value" .= object ["count" .= count]
                , "logs" .= logs
                ]
    unless (actual == expected) (fail ("subscription value was malformed: " <> show actual))

assertNoEventFor :: Int -> Handle -> IO ()
assertNoEventFor microseconds handle = do
    unexpected <- timeout microseconds (B8.hGetLine handle)
    unless (unexpected == Nothing) (fail ("stale relay event crossed ACK: " <> show unexpected))

withHttpFailureFixture :: [Value] -> (Int -> IO a) -> IO a
withHttpFailureFixture responses action = bracket open closeFixture (action . fixturePort)
  where
    open = do
        listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
        Socket.setSocketOption listener Socket.ReuseAddr 1
        Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
        Socket.listen listener 2
        address <- Socket.getSocketName listener
        port <- case address of
            Socket.SockAddrInet actual _ -> pure (fromIntegral actual)
            other -> Socket.close listener >> fail ("unexpected HTTP fixture address " <> show other)
        thread <- forkIO (serveResponses listener responses)
        pure (HttpFixture listener thread port)
    closeFixture fixture = killThread (httpFixtureThread fixture) >> Socket.close (httpFixtureListener fixture)

data HttpFixture = HttpFixture
    { httpFixtureListener :: Socket.Socket
    , httpFixtureThread :: ThreadId
    , fixturePort :: Int
    }

serveResponses :: Socket.Socket -> [Value] -> IO ()
serveResponses listener responses = forM_ responses $ \response -> do
    (peer, _) <- Socket.accept listener
    bracket (Socket.socketToHandle peer ReadWriteMode) hClose $ \handle -> do
        hSetBinaryMode handle True
        hSetBuffering handle NoBuffering
        consumeHttpRequest handle
        let body = LBS.toStrict (encode response)
            headers =
                B8.pack
                    ( "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                        <> show (BS.length body)
                        <> "\r\nConnection: close\r\n\r\n"
                    )
        writeChunk handle (headers <> body)

consumeHttpRequest :: Handle -> IO ()
consumeHttpRequest handle = do
    headers <- readHeaders []
    let contentLength = case find (B8.isPrefixOf "content-length:" . B8.map toLower) headers of
            Nothing -> 0
            Just header -> case B8.readInt (B8.dropWhile (== ' ') (B8.drop 15 header)) of
                Just (value, _) -> value
                Nothing -> 0
    readExactly contentLength
  where
    readHeaders collected = do
        line <- stripCarriageReturn <$> B8.hGetLine handle
        if BS.null line then pure collected else readHeaders (line : collected)
    readExactly remaining
        | remaining <= 0 = pure ()
        | otherwise = do
            bytes <- BS.hGetSome handle remaining
            if BS.null bytes
                then fail "HTTP fixture request ended before its declared body"
                else readExactly (remaining - BS.length bytes)
    stripCarriageReturn bytes = fromMaybeBytes bytes (BS.stripSuffix "\r" bytes)
    fromMaybeBytes fallback Nothing = fallback
    fromMaybeBytes _ (Just value) = value

withRelayGate :: (RelayGate -> IO a) -> IO a
withRelayGate = bracket openRelayGate (Socket.close . relayGateListener)

openRelayGate :: IO RelayGate
openRelayGate = do
    listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    Socket.listen listener 4
    address <- Socket.getSocketName listener
    case address of
        Socket.SockAddrInet port _ -> pure (RelayGate listener ("127.0.0.1:" <> show (fromIntegral port :: Int)))
        other -> Socket.close listener >> fail ("unexpected relay gate address " <> show other)

awaitPausedRelay :: RelayGate -> IO PausedRelay
awaitPausedRelay gate = do
    accepted <- timeout 3000000 (Socket.accept (relayGateListener gate))
    (socket, _) <- maybe (fail "relay did not reach the post-dequeue pause gate") pure accepted
    handle <- Socket.socketToHandle socket ReadWriteMode
    hSetBinaryMode handle True
    hSetBuffering handle NoBuffering
    notice <- timeout 1000000 (B8.hGetLine handle)
    case notice of
        Just value -> pure (PausedRelay value handle)
        Nothing -> hClose handle >> fail "paused relay did not identify itself"

assertNotice :: BS.ByteString -> PausedRelay -> IO ()
assertNotice expected paused =
    unless (pausedRelayNotice paused == expected) $
        fail ("paused relay notice was " <> show (pausedRelayNotice paused) <> ", expected " <> show expected)

releasePausedRelay :: PausedRelay -> IO ()
releasePausedRelay paused = writeChunk (pausedRelayHandle paused) "continue\n" >> hClose (pausedRelayHandle paused)

assertPausedRelayCancelled :: PausedRelay -> IO ()
assertPausedRelayCancelled paused = do
    outcome <- timeout 1000000 (try (BS.hGetSome (pausedRelayHandle paused) 1) :: IO (Either IOException BS.ByteString))
    case outcome of
        Just (Left _) -> safeClose (pausedRelayHandle paused)
        Just (Right bytes) | BS.null bytes -> safeClose (pausedRelayHandle paused)
        Just (Right bytes) -> fail ("cancelled relay gate received unexpected bytes " <> show bytes)
        Nothing -> fail "relay gate remained open after ACK"

withWebSocketFixture :: Int -> (WebSocketFixture -> IO a) -> IO a
withWebSocketFixture port = bracket start stop
  where
    start = do
        connection <- newEmptyMVar
        messages <- newChan
        thread <- forkIO (WS.runServer "127.0.0.1" port (quiet (fixtureApp connection messages)))
        threadDelay 100000
        pure (WebSocketFixture thread connection messages)
    stop fixture = killThread (fixtureThread fixture)
    quiet application pending = application pending `catch` ignorePeerClose
    ignorePeerClose :: SomeException -> IO ()
    ignorePeerClose _ = pure ()

fixtureApp :: MVar WS.Connection -> Chan Object -> WS.ServerApp
fixtureApp connectionSlot messages pending = do
    connection <- WS.acceptRequest pending
    putMVar connectionSlot connection
    forever (receiveFixtureObject connection >>= writeChan messages)

awaitFixtureConnection :: WebSocketFixture -> IO WS.Connection
awaitFixtureConnection fixture =
    maybe (fail "adapter did not establish fixture WebSocket") pure =<< timeout 3000000 (takeMVar (fixtureConnection fixture))

awaitFixtureMessage :: WebSocketFixture -> IO Object
awaitFixtureMessage fixture =
    maybe (fail "timed out waiting for adapter WebSocket message") pure =<< timeout 3000000 (readChan (fixtureMessages fixture))

receiveFixtureObject :: WS.Connection -> IO Object
receiveFixtureObject connection = do
    bytes <- WS.receiveData connection :: IO LBS.ByteString
    case eitherDecodeStrict' (LBS.toStrict bytes) of
        Right (Object value) -> pure value
        other -> fail ("fixture expected a JSON object, got " <> show other)

sendTransition :: WS.Connection -> Value -> Value -> [Value] -> IO ()
sendTransition connection startVersion endVersion modifications =
    WS.sendTextData
        connection
        ( encode
            ( object
                [ "type" .= ("Transition" :: Text)
                , "startVersion" .= startVersion
                , "endVersion" .= endVersion
                , "modifications" .= modifications
                ]
            )
        )

version :: Int -> Text -> Value
version querySet timestampValue =
    object ["querySet" .= querySet, "identity" .= (0 :: Int), "ts" .= timestampValue]

queryUpdated :: Int -> Int -> Value
queryUpdated queryId count =
    object
        [ "type" .= ("QueryUpdated" :: Text)
        , "queryId" .= queryId
        , "value" .= object ["count" .= count]
        , "logLines" .= (if count == 2 then ["recovered" :: Text] else [])
        ]

queryFailed :: Int -> Value
queryFailed queryId =
    object
        [ "type" .= ("QueryFailed" :: Text)
        , "queryId" .= queryId
        , "errorMessage" .= ("fixture failure" :: Text)
        , "errorData" .= object ["code" .= ("FAILED_ONCE" :: Text)]
        , "logLines" .= ["failed once" :: Text]
        ]

assertMessageType :: Text -> Object -> IO ()
assertMessageType expected message =
    unless (KM.lookup "type" message == Just (String expected)) $
        fail ("WebSocket message type was not " <> T.unpack expected <> ": " <> show message)

modificationId :: Text -> Object -> IO Int
modificationId expected message = do
    (kind, queryId) <- firstModification message
    unless (kind == expected) (fail ("modification was " <> T.unpack kind <> ", expected " <> T.unpack expected))
    pure queryId

assertModification :: Text -> Int -> Object -> IO ()
assertModification expectedKind expectedId message = do
    actualId <- modificationId expectedKind message
    unless (actualId == expectedId) (fail ("modification query id was " <> show actualId <> ", expected " <> show expectedId))

firstModification :: Object -> IO (Text, Int)
firstModification message = case KM.lookup "modifications" message of
    Just (Array values) -> case foldr (:) [] values of
        Object modification : _ -> case (KM.lookup "type" modification, KM.lookup "queryId" modification) of
            (Just (String kind), Just (Number queryId)) -> pure (kind, floor queryId)
            _ -> fail ("modification omitted type or queryId: " <> show modification)
        _ -> fail "ModifyQuerySet contained no modifications"
    _ -> fail ("WebSocket message omitted modifications: " <> show message)

withChild :: FilePath -> [(String, String)] -> (Child -> IO a) -> IO a
withChild executable additions = bracket (startChild executable additions) stopChild

startChild :: FilePath -> [(String, String)] -> IO Child
startChild executable additions = do
    inherited <- getEnvironment
    let controlled = ["ADAPTER_LISTEN", "CONVEX_ADAPTER_TEST_RELAY_PAUSE", "CONVEX_URL"]
        configured = additions <> [("CONVEX_URL", "http://127.0.0.1") | "CONVEX_URL" `notElem` map fst additions]
        environment = configured <> filter ((`notElem` (controlled <> map fst additions)) . fst) inherited
        settings =
            (proc executable [])
                { std_in = CreatePipe
                , std_out = CreatePipe
                , std_err = Inherit
                , env = Just environment
                }
    (Just input, Just output, Nothing, process) <- createProcess settings
    mapM_ (`hSetBinaryMode` True) [input, output]
    mapM_ (`hSetBuffering` NoBuffering) [input, output]
    pure (Child input output process)

stopChild :: Child -> IO ()
stopChild child = do
    status <- getProcessExitCode (childProcess child)
    case status of
        Nothing -> do
            terminateProcess (childProcess child)
            void (timeout 2000000 (waitForProcess (childProcess child)))
        Just _ -> pure ()
    safeClose (childInput child)
    safeClose (childOutput child)

safeClose :: Handle -> IO ()
safeClose handle = do
    result <- try (hClose handle) :: IO (Either IOException ())
    either (const (pure ())) pure result

writeChunk :: Handle -> BS.ByteString -> IO ()
writeChunk handle bytes = BS.hPut handle bytes

readEvent :: Handle -> IO Value
readEvent handle = do
    line <- timeout 2000000 (B8.hGetLine handle)
    bytes <- maybe (fail "timed out waiting for adapter event") pure line
    case eitherDecodeStrict' bytes of
        Left problem -> fail ("adapter emitted invalid JSON: " <> problem <> "; bytes=" <> show bytes)
        Right value -> pure value

expectExitSuccess :: Child -> IO ()
expectExitSuccess child = do
    outcome <- timeout 2000000 (waitForProcess (childProcess child))
    case outcome of
        Just ExitSuccess -> pure ()
        Just failure -> fail ("adapter exited with " <> show failure)
        Nothing -> fail "adapter did not exit within two seconds"

assertReady :: Text -> Value -> IO ()
assertReady expectedId value = do
    objectValue <- expectObject "ready" value
    assertField "type" (String "ready") objectValue
    assertField "protocolVersion" (Number 1) objectValue
    assertField "id" (String expectedId) objectValue
    assertField "language" (String "haskell") objectValue
    assertNonEmptyText "implementation" objectValue
    assertNonEmptyText "runtime" objectValue
    assertAbsent ["subscriptionId", "value", "logs", "error"] objectValue
    assertOnly ["protocolVersion", "id", "type", "language", "implementation", "runtime"] objectValue

assertClosed :: Text -> Value -> IO ()
assertClosed expectedId value = do
    objectValue <- expectObject "closed" value
    assertField "type" (String "closed") objectValue
    assertField "id" (String expectedId) objectValue
    assertOnly ["id", "type"] objectValue

assertProtocolError :: Value -> IO ()
assertProtocolError value = do
    objectValue <- expectObject "protocol error" value
    assertField "type" (String "error") objectValue
    assertAbsent ["id", "subscriptionId", "value", "logs"] objectValue
    errorValue <- case KM.lookup "error" objectValue of
        Just candidate -> expectObject "protocol error body" candidate
        Nothing -> fail "protocol error omitted error body"
    assertField "name" (String "ProtocolError") errorValue
    assertNonEmptyText "message" errorValue
    assertOnly ["name", "message"] errorValue
    assertOnly ["type", "error"] objectValue

assertProtocolErrorWithId :: Text -> Value -> IO ()
assertProtocolErrorWithId expectedId value = do
    objectValue <- expectObject "identified protocol error" value
    assertField "type" (String "error") objectValue
    assertField "id" (String expectedId) objectValue
    errorValue <- case KM.lookup "error" objectValue of
        Just candidate -> expectObject "identified protocol error body" candidate
        Nothing -> fail "identified protocol error omitted error body"
    assertField "name" (String "ProtocolError") errorValue
    assertNonEmptyText "message" errorValue
    assertOnly ["name", "message"] errorValue
    assertOnly ["id", "type", "error"] objectValue

expectObject :: String -> Value -> IO Object
expectObject _ (Object value) = pure value
expectObject label value = fail (label <> " event was not an object: " <> show value)

assertField :: Text -> Value -> Object -> IO ()
assertField name expected objectValue =
    unless (KM.lookup (Key.fromText name) objectValue == Just expected) $
        fail ("field " <> T.unpack name <> " was " <> show (KM.lookup (Key.fromText name) objectValue) <> ", expected " <> show expected)

assertNonEmptyText :: Text -> Object -> IO ()
assertNonEmptyText name objectValue = case KM.lookup (Key.fromText name) objectValue of
    Just (String value) | not (T.null value) -> pure ()
    actual -> fail ("field " <> T.unpack name <> " was not non-empty text: " <> show actual)

assertAbsent :: [Text] -> Object -> IO ()
assertAbsent names objectValue = mapM_ assertOne names
  where
    assertOne name =
        unless (KM.lookup (Key.fromText name) objectValue == Nothing) $
            fail ("optional field " <> T.unpack name <> " must be omitted")

assertOnly :: [Text] -> Object -> IO ()
assertOnly expected objectValue = do
    let actual = map Key.toText (KM.keys objectValue)
    unless (all (`elem` expected) actual && all (`elem` actual) expected) $
        fail ("event fields were " <> show actual <> ", expected " <> show expected)

reserveLoopbackPort :: IO Int
reserveLoopbackPort = bracket open Socket.close $ \socket -> do
    Socket.bind socket (Socket.SockAddrInet 0 loopback)
    Socket.getSocketName socket >>= \caseAddress -> case caseAddress of
        Socket.SockAddrInet port _ -> pure (fromIntegral port)
        other -> fail ("unexpected loopback socket address " <> show other)
  where
    open = Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
    loopback = Socket.tupleToHostAddress (127, 0, 0, 1)

connectEventually :: Int -> IO Socket.Socket
connectEventually port = do
    connected <- timeout 3000000 retry
    maybe (fail "adapter did not begin listening within three seconds") pure connected
  where
    address = Socket.SockAddrInet (fromIntegral port) (Socket.tupleToHostAddress (127, 0, 0, 1))
    retry = do
        socket <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
        result <- try (Socket.connect socket address) :: IO (Either SomeException ())
        case result of
            Right () -> pure socket
            Left _ -> Socket.close socket >> threadDelay 20000 >> retry
