{-# LANGUAGE OverloadedStrings #-}

-- Deterministic language-local fixtures exercise the real WebSocket transport.
-- They never call the owner's mailbox or transition helpers directly.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, concurrently_, waitCatch)
import Control.Concurrent.STM
import Control.Exception (SomeException, bracket, catch)
import Control.Monad (foldM_, forM_, forever, replicateM)
import Convex
import Crypto.Hash.SHA1 qualified as SHA1
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Bits (shiftR, (.&.), (.|.))
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Char8 qualified as BSC
import Data.ByteString.Lazy qualified as LBS
import Data.List (find)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Word (Word64, Word8)
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketBytes
import Network.WebSockets qualified as WS
import System.Timeout (timeout)

main :: IO ()
main = do
    putStrLn "live: QueryFailed recovery and bounded queue"
    testFailureRecoveryAndBoundedQueue
    putStrLn "live: transition coalescing"
    testTransitionCoalescing
    putStrLn "live: reconnect hydration dedup"
    testFiveReconnectsAndHydrationDedup
    putStrLn "live: refused reconnects"
    testFiveFailedReconnectsThenSuccess
    putStrLn "live: protocol and transport recovery"
    testProtocolAndTransportRecovery
    putStrLn "live: malformed transition atomicity"
    testMalformedTransitionAtomicity
    putStrLn "live: timestamp semantics"
    testTimestampSemantics
    putStrLn "live: bounded unsubscribe and close"
    testBoundedUnsubscribeAndClose
    putStrLn "live: concurrent close"
    testConcurrentClose
    putStrLn "live: stalled handshake and continuous peer"
    testStalledHandshakeAndContinuousPeer
    putStrLn "live: fragmented UTF-8 and half frame"
    testFragmentedUtf8AndHalfFrame
    putStrLn "haskell Live WebSocket fixtures pass"

testFailureRecoveryAndBoundedQueue :: IO ()
testFailureRecoveryAndBoundedQueue = do
    initialConsumed <- newEmptyTMVarIO
    failureConsumed <- newEmptyTMVarIO
    recoveryConsumed <- newEmptyTMVarIO
    updatesSent <- newEmptyTMVarIO
    withServer 19231 (fixture initialConsumed failureConsumed recoveryConsumed updatesSent) $ do
        client <- newClient "http://127.0.0.1:19231"
        subscription <- subscribe client "counter:get" (object ["room" .= ("bounded" :: Text)])
        assertCount 0 =<< awaitUpdate subscription
        atomically (putTMVar initialConsumed ())
        failure <- awaitUpdate subscription
        case updateError failure of
            Just (FunctionError "fixture failure" (Just (Object _)) ["failed once"]) -> pure ()
            other -> fail ("expected structured QueryFailed, got " <> show other)
        atomically (putTMVar failureConsumed ())
        recovered <- awaitUpdate subscription
        assertCount 0 recovered
        atomically (putTMVar recoveryConsumed ())
        atomically (takeTMVar updatesSent)
        -- This deliberate pause gives the owner time to fill its queue while
        -- the consumer is slow. Only newest values 4 through 19 survive.
        threadDelay 1000000
        values <- replicateM 16 (awaitUpdate subscription)
        mapM_ (uncurry assertCount) (zip [4 .. 19] values)
        assertCompletes "unsubscribe" (unsubscribe client subscription)
        assertClosed subscription
        closeClient client
  where
    fixture initialConsumed failureConsumed recoveryConsumed updatesSent pending = do
        assertHeader pending
        connection <- WS.acceptRequest pending
        _ <- receiveObject connection -- Connect
        add <- receiveObject connection
        let ident = queryIdFromModify add
            zero = version 0 "AAAAAAAAAAA="
            one = version 1 "AQAAAAAAAAA="
            two = version 1 "AgAAAAAAAAA="
            three = version 1 "AwAAAAAAAAA="
        sendTransition connection zero one [updated ident 0]
        _ <- atomically (takeTMVar initialConsumed)
        sendTransition
            connection
            one
            two
            [ object
                [ "type" .= ("QueryFailed" :: Text)
                , "queryId" .= ident
                , "errorMessage" .= ("fixture failure" :: Text)
                , "errorData" .= object ["code" .= (7 :: Int)]
                , "logLines" .= ["failed once" :: Text]
                ]
            ]
        _ <- atomically (takeTMVar failureConsumed)
        -- Recovery to the exact pre-failure value must still be delivered. The
        -- error state, rather than only the JSON value, participates in dedup.
        sendTransition connection two three [updated ident 0]
        _ <- atomically (takeTMVar recoveryConsumed)
        -- Overflow comes from twenty distinct valid transitions. One server
        -- transition is one public state, even if it contains duplicate IDs.
        foldM_
            ( \start (timestampValue, count) -> do
                let end = version 1 (timestamp timestampValue)
                sendTransition connection start end [updated ident count]
                -- Let the real socket owner ingest each transition while the
                -- public consumer remains stopped, making overflow deterministic.
                threadDelay 20000
                pure end
            )
            three
            (zip [4 .. 23] [0 .. 19])
        atomically (putTMVar updatesSent ())
        remove <- receiveObject connection
        assert (modificationType remove == Just "Remove") "peer did not receive Remove"
        forever (WS.receiveData connection :: IO LBS.ByteString)

testTransitionCoalescing :: IO ()
testTransitionCoalescing = do
    firstAddSeen <- newEmptyTMVarIO
    withServer 19243 (fixture firstAddSeen) $ do
        client <- newClient "http://127.0.0.1:19243"
        first <- subscribe client "counter:first" (object [])
        atomically (takeTMVar firstAddSeen)
        second <- subscribe client "counter:second" (object [])
        assertCount 11 =<< awaitUpdate first
        assertCount 21 =<< awaitUpdate second
        assertNoUpdate "duplicate first query modification" first
        assertNoUpdate "duplicate second query modification" second
        closeClient client
  where
    fixture firstAddSeen pending = do
        connection <- WS.acceptRequest pending
        _ <- receiveObject connection
        firstAdd <- receiveObject connection
        atomically (putTMVar firstAddSeen ())
        secondAdd <- receiveObject connection
        let firstId = queryIdFromModify firstAdd
            secondId = queryIdFromModify secondAdd
        sendTransition
            connection
            (version 0 (timestamp 0))
            (version 2 (timestamp 1))
            [ updated secondId 20
            , updated firstId 10
            , updated secondId 21
            , updated firstId 11
            ]
        forever (WS.receiveData connection :: IO LBS.ByteString)

testFiveReconnectsAndHydrationDedup :: IO ()
testFiveReconnectsAndHydrationDedup = do
    records <- newTQueueIO
    count <- newTVarIO (0 :: Int)
    withServer 19232 (fixture records count) $ do
        client <- newClient "http://127.0.0.1:19232"
        subscription <- subscribe client "counter:get" (object ["room" .= ("reconnect" :: Text)])
        assertCount 0 =<< awaitUpdate subscription
        first <- awaitRecord records
        assertConnect 0 "InitialConnect" Nothing first
        forM_ [1 .. 5 :: Int] $ \attempt -> do
            debugDisconnectForAdapter client
            connected <- awaitRecord records
            assertConnect attempt "DebugDisconnect" (Just (timestamp attempt)) connected
        -- All five reconnect hydrations repeated count 0 and were suppressed. The
        -- sixth connection's external count 1 is therefore the next public event.
        assertCount 1 =<< awaitUpdate subscription
        unsubscribe client subscription
        closeClient client
  where
    fixture records count pending = do
        assertHeader pending
        connection <- WS.acceptRequest pending
        connectMessage <- receiveObject connection
        add <- receiveObject connection
        current <- atomically $ do
            value <- readTVar count
            writeTVar count (value + 1)
            pure value
        let ident = queryIdFromModify add
            delivered = if current < 5 then 0 else 1
        sendTransition connection (version 0 "AAAAAAAAAAA=") (version 1 (timestamp (current + 1))) [updated ident delivered]
        -- Do not let the controller request the next debug disconnect until the
        -- client has had a deterministic chance to commit this rehydration.
        threadDelay 300000
        atomically (writeTQueue records connectMessage)
        forever (WS.receiveData connection :: IO LBS.ByteString)

testProtocolAndTransportRecovery :: IO ()
testProtocolAndTransportRecovery = do
    count <- newTVarIO (0 :: Int)
    withServer 19233 (fixture count) $ do
        client <- newClient "http://127.0.0.1:19233"
        subscription <- subscribe client "counter:get" (object ["room" .= ("protocol" :: Text)])
        protocol <- awaitUpdate subscription
        case updateError protocol of
            Just (ProtocolError _) -> pure ()
            other -> fail ("expected ProtocolError, got " <> show other)
        assertCount 7 =<< awaitUpdate subscription
        closeClient client
  where
    fixture count pending = do
        connection <- WS.acceptRequest pending
        _ <- receiveObject connection
        add <- receiveObject connection
        current <- atomically $ do
            value <- readTVar count
            writeTVar count (value + 1)
            pure value
        if current == 0
            then do
                WS.sendTextData connection ("{not-json" :: Text)
                forever (WS.receiveData connection :: IO LBS.ByteString)
            else do
                sendTransition
                    connection
                    (version 0 "AAAAAAAAAAA=")
                    (version 1 "BwAAAAAAAAA=")
                    [updated (queryIdFromModify add) 7]
                forever (WS.receiveData connection :: IO LBS.ByteString)

testMalformedTransitionAtomicity :: IO ()
testMalformedTransitionAtomicity = do
    connectionNumber <- newTVarIO (0 :: Int)
    withServer 19246 (fixture connectionNumber) $ do
        client <- newClient "http://127.0.0.1:19246"
        subscription <- subscribe client "counter:atomic" (object [])
        assertProtocolUpdate =<< awaitUpdate subscription
        -- The valid modification that preceded the malformed one was not
        -- published. Recovery on the rehydrated connection is the next value.
        assertCount 7 =<< awaitValue subscription
        assertNoUpdate "partially committed malformed transition" subscription
        closeClient client
  where
    fixture connectionNumber pending = do
        connection <- WS.acceptRequest pending
        _ <- receiveObject connection
        add <- receiveObject connection
        current <- atomically $ do
            value <- readTVar connectionNumber
            writeTVar connectionNumber (value + 1)
            pure value
        let ident = queryIdFromModify add
            zero = version 0 (timestamp 0)
        if current == 0
            then
                sendTransition
                    connection
                    zero
                    (version 1 (timestamp 1))
                    [ updated ident 88
                    , object
                        [ "type" .= ("QueryUpdated" :: Text)
                        , "queryId" .= ident
                        , "value" .= object ["count" .= (99 :: Int)]
                        , "logLines" .= [String "valid", Number 2]
                        ]
                    ]
            else sendTransition connection zero (version 1 (timestamp 2)) [updated ident 7]
        forever (WS.receiveData connection :: IO LBS.ByteString)

testTimestampSemantics :: IO ()
testTimestampSemantics = do
    connectionNumber <- newTVarIO (0 :: Int)
    connects <- newTQueueIO
    withServer 19244 (fixture connectionNumber connects) $ do
        client <- newClient "http://127.0.0.1:19244"
        subscription <- subscribe client "counter:timestamp" (object [])

        initialConnect <- awaitRecord connects
        assert (textAt "maxObservedTimestamp" initialConnect == Nothing) "initial Connect sent a timestamp"
        assertCount 1 =<< awaitUpdate subscription
        assertCount 2 =<< awaitUpdate subscription

        -- Crossing 255 to 256 proves comparison uses Convex's little-endian
        -- uint64 semantics rather than lexical or raw-byte order.
        debugDisconnectForAdapter client
        afterBoundary <- awaitRecord connects
        assert (textAt "maxObservedTimestamp" afterBoundary == Just (timestamp 256)) "255 -> 256 timestamp maximum was wrong"

        assertProtocolUpdate =<< awaitUpdate subscription -- fractional querySet
        malformedConnect <- awaitRecord connects
        assert (textAt "maxObservedTimestamp" malformedConnect == Just (timestamp 256)) "invalid version changed timestamp maximum"

        assertProtocolUpdate =<< awaitUpdate subscription -- non-canonical timestamp
        backwardConnect <- awaitRecord connects
        assert (textAt "maxObservedTimestamp" backwardConnect == Just (timestamp 256)) "malformed timestamp changed maximum"

        assertCount 3 =<< awaitUpdate subscription
        assertProtocolUpdate =<< awaitUpdate subscription -- 200 -> 199
        malformedIdConnect <- awaitRecord connects
        assert (textAt "maxObservedTimestamp" malformedIdConnect == Just (timestamp 256)) "lower rehydration replaced timestamp maximum"
        assertProtocolUpdate =<< awaitUpdate subscription -- fractional queryId
        missingMessageConnect <- awaitRecord connects
        assert (textAt "maxObservedTimestamp" missingMessageConnect == Just (timestamp 256)) "invalid queryId changed timestamp maximum"
        assertProtocolUpdate =<< awaitUpdate subscription -- QueryFailed without message
        recoveryConnect <- awaitRecord connects
        assert (textAt "maxObservedTimestamp" recoveryConnect == Just (timestamp 256)) "invalid QueryFailed changed timestamp maximum"
        assertCount 4 =<< awaitUpdate subscription
        closeClient client
  where
    fixture connectionNumber connects pending = do
        connection <- WS.acceptRequest pending
        connectMessage <- receiveObject connection
        add <- receiveObject connection
        current <- atomically $ do
            value <- readTVar connectionNumber
            writeTVar connectionNumber (value + 1)
            pure value
        atomically (writeTQueue connects connectMessage)
        let ident = queryIdFromModify add
            zero = version 0 (timestamp 0)
        case current of
            0 -> do
                let at255 = version 1 (timestamp 255)
                    at256 = version 1 (timestamp 256)
                sendTransition connection zero at255 [updated ident 1]
                sendTransition connection at255 at256 [updated ident 2]
            1 ->
                WS.sendTextData
                    connection
                    ( encode
                        ( object
                            [ "type" .= ("Transition" :: Text)
                            , "startVersion" .= zero
                            , "endVersion" .= object ["querySet" .= (1.5 :: Double), "identity" .= (0 :: Int), "ts" .= timestamp 1]
                            , "modifications" .= [updated ident 99]
                            ]
                        )
                    )
            2 ->
                sendTransition
                    connection
                    zero
                    (version 1 "AAAAAAAAAAB=")
                    [updated ident 99]
            3 -> do
                let at200 = version 1 (timestamp 200)
                sendTransition connection zero at200 [updated ident 3]
                sendTransition connection at200 (version 1 (timestamp 199)) [updated ident 99]
            4 ->
                sendTransition
                    connection
                    zero
                    (version 1 (timestamp 300))
                    [ object
                        [ "type" .= ("QueryUpdated" :: Text)
                        , "queryId" .= (0.5 :: Double)
                        , "value" .= object ["count" .= (99 :: Int)]
                        ]
                    ]
            5 ->
                sendTransition
                    connection
                    zero
                    (version 1 (timestamp 300))
                    [ object
                        [ "type" .= ("QueryFailed" :: Text)
                        , "queryId" .= ident
                        ]
                    ]
            _ -> sendTransition connection zero (version 1 (timestamp 300)) [updated ident 4]
        forever (WS.receiveData connection :: IO LBS.ByteString)

testConcurrentClose :: IO ()
testConcurrentClose = withServer 19245 fixture $ do
    client <- newClient "http://127.0.0.1:19245"
    subscription <- subscribe client "counter:close" (object [])
    result <- timeout 1000000 (concurrently_ (closeClient client) (closeClient client))
    assert (result == Just ()) "concurrent close exceeded one second"
    assertClosed subscription
  where
    fixture pending = do
        connection <- WS.acceptRequest pending
        _ <- receiveObject connection
        _ <- receiveObject connection
        forever (threadDelay 1000000)

testFiveFailedReconnectsThenSuccess :: IO ()
testFiveFailedReconnectsThenSuccess = do
    stopServer <- newEmptyTMVarIO
    connections <- newTQueueIO
    server <- async $ do
        -- Five refused connections occur by 1.5 seconds. Starting the real
        -- fixture before the sixth scheduled attempt lets subscribe prove its
        -- Add write barrier without hiding the failed reconnects.
        threadDelay 2000000
        withServer 19235 (fixture connections) (atomically (takeTMVar stopServer))
    client <- newClient "http://127.0.0.1:19235"
    subscription <- subscribe client "counter:get" (object ["room" .= ("failed-reconnects" :: Text)])
    forM_ [1 .. 5 :: Int] $ \_ -> do
        update <- awaitUpdate subscription
        case updateError update of
            Just (TransportError _) -> pure ()
            other -> fail ("failed reconnect did not emit TransportError: " <> show other)
    first <- awaitRecordWithin 4000000 connections
    assert (numberAt "connectionCount" first == Just 5) "failed attempts did not advance connectionCount"
    assertCount 9 =<< awaitUpdate subscription
    -- The fixture closes after valid protocol traffic. Backoff must have reset,
    -- so the next re-add arrives in under one second rather than inheriting the
    -- multi-second delay accumulated by the five failed attempts.
    second <- awaitRecordWithin 1000000 connections
    assert (numberAt "connectionCount" second == Just 6) "post-success reconnect metadata was wrong"
    assertCount 10 =<< awaitValue subscription
    closeClient client
    atomically (putTMVar stopServer ())
    cancel server
  where
    fixture connections pending = do
        connection <- WS.acceptRequest pending
        connectMessage <- receiveObject connection
        add <- receiveObject connection
        atomically (writeTQueue connections connectMessage)
        let ident = queryIdFromModify add
            connectionNumber = maybe 0 id (numberAt "connectionCount" connectMessage)
            count = if connectionNumber == 5 then 9 else 10
        sendTransition connection (version 0 "AAAAAAAAAAA=") (version 1 (timestamp (connectionNumber + 1))) [updated ident count]
        threadDelay 100000
        WS.sendClose connection ("fixture reconnect" :: Text)

testBoundedUnsubscribeAndClose :: IO ()
testBoundedUnsubscribeAndClose = withServer 19234 fixture $ do
    client <- newClient "http://127.0.0.1:19234"
    subscription <- subscribe client "counter:get" (object ["room" .= ("idle" :: Text)])
    -- The peer remains idle forever after Add. The receive pump is blocked, but
    -- the owner must still process Remove and close within a fixed deadline.
    threadDelay 100000
    assertCompletes "unsubscribe against idle peer" (unsubscribe client subscription)
    assertCompletes "close against idle peer" (closeClient client)
  where
    fixture pending = do
        connection <- WS.acceptRequest pending
        _ <- receiveObject connection
        _ <- receiveObject connection
        forever (threadDelay 1000000)

testStalledHandshakeAndContinuousPeer :: IO ()
testStalledHandshakeAndContinuousPeer = do
    -- The server deliberately never accepts the parsed upgrade. Closing the
    -- client must detach the pending generation instead of waiting on handshake.
    withServer 19236 (\_ -> threadDelay 5000000) $ do
        stalled <- newClient "http://127.0.0.1:19236"
        pendingSubscribe <- async (subscribe stalled "counter:get" (object []))
        threadDelay 100000
        assertCompletes "close during stalled handshake" (closeClient stalled)
        finished <- timeout 1000000 (waitCatch pendingSubscribe)
        assert (case finished of Just (Left _) -> True; _ -> False) "pending subscribe survived client close"
    withServer 19237 continuous $ do
        client <- newClient "http://127.0.0.1:19237"
        subscription <- subscribe client "counter:get" (object [])
        threadDelay 100000
        assertCompletes "unsubscribe against continuous peer" (unsubscribe client subscription)
        assertCompletes "close against continuous peer" (closeClient client)
  where
    continuous pending = do
        connection <- WS.acceptRequest pending
        _ <- receiveObject connection
        _ <- receiveObject connection
        forever $ WS.sendTextData connection (encode (object ["type" .= ("Ping" :: Text)])) >> threadDelay 1000

testFragmentedUtf8AndHalfFrame :: IO ()
testFragmentedUtf8AndHalfFrame = do
    pongSeen <- newEmptyTMVarIO
    withRawServer 19238 (fragmentPeer pongSeen) $ do
        client <- newClient "http://127.0.0.1:19238"
        subscription <- subscribe client "counter:get" (object [])
        update <- awaitUpdate subscription
        assertCount 42 update
        assert (updateLogs update == ["hé🙂"]) "fragmented multibyte UTF-8 logs were corrupted"
        pong <- timeout 1000000 (atomically (takeTMVar pongSeen))
        assert (pong == Just ()) "client did not process interleaved Ping control frame"
        closeClient client
    withRawServer 19240 halfFramePeer $ do
        client <- newClient "http://127.0.0.1:19240"
        subscription <- subscribe client "counter:get" (object [])
        threadDelay 100000
        assertCompletes "unsubscribe during partial frame" (unsubscribe client subscription)
        assertCompletes "close during partial frame" (closeClient client)
  where
    fragmentPeer pongSeen peer = do
        rawHandshake peer
        _ <- receiveClientFrame peer -- Connect
        _ <- receiveClientFrame peer -- Add
        let payload =
                LBS.toStrict
                    ( encode
                        ( object
                            [ "type" .= ("Transition" :: Text)
                            , "startVersion" .= version 0 "AAAAAAAAAAA="
                            , "endVersion" .= version 1 "KgAAAAAAAAA="
                            , "modifications"
                                .= [ object
                                        [ "type" .= ("QueryUpdated" :: Text)
                                        , "queryId" .= (0 :: Int)
                                        , "value" .= object ["count" .= (42 :: Int)]
                                        , "logLines" .= ["hé🙂" :: Text]
                                        ]
                                   ]
                            ]
                        )
                    )
            emoji = TE.encodeUtf8 "🙂"
            (beforeEmoji, fromEmoji) = BS.breakSubstring emoji payload
            (emojiPrefix, afterPrefix) = BS.splitAt 2 fromEmoji
        assert (not (BS.null fromEmoji)) "fixture payload omitted multibyte marker"
        sendRawFrame peer False 1 (beforeEmoji <> emojiPrefix)
        sendRawFrame peer True 9 "control"
        sendRawFrame peer True 0 afterPrefix
        opcode <- fst <$> receiveClientFrame peer
        assert (opcode == 10) "fixture expected Pong control frame"
        atomically (putTMVar pongSeen ())
        threadDelay 1000000
    halfFramePeer peer = do
        rawHandshake peer
        _ <- receiveClientFrame peer
        _ <- receiveClientFrame peer
        -- Declare a 100-byte text frame, send one byte, then stall forever. The
        -- client's parser has consumed frame state and teardown must abandon this
        -- generation instead of restarting at a false boundary.
        SocketBytes.sendAll peer (BS.pack [0x81, 100, 0x7b])
        threadDelay 5000000

withRawServer :: Int -> (Socket.Socket -> IO ()) -> IO a -> IO a
withRawServer port handler test = Socket.withSocketsDo $ bracket open Socket.close $ \listener -> do
    worker <- async $ do
        (peer, _) <- Socket.accept listener
        handler peer `finallyClose` peer
    threadDelay 50000
    test `finallyCancel` worker
  where
    open = do
        listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
        Socket.setSocketOption listener Socket.ReuseAddr 1
        Socket.bind listener (Socket.SockAddrInet (fromIntegral port) (Socket.tupleToHostAddress (127, 0, 0, 1)))
        Socket.listen listener 1
        pure listener
    finallyClose task peer = task `catch` ignore >> Socket.close peer
    finallyCancel task worker = task `finallyIO` cancel worker
    ignore :: SomeException -> IO ()
    ignore _ = pure ()

finallyIO :: IO a -> IO b -> IO a
finallyIO task cleanup = do
    outcome <- tryAny task
    _ <- cleanup
    either (fail . show) pure outcome

tryAny :: IO a -> IO (Either SomeException a)
tryAny task = (Right <$> task) `catch` (pure . Left)

rawHandshake :: Socket.Socket -> IO ()
rawHandshake peer = do
    headers <- receiveHeaders peer BS.empty
    assert ("Convex-Client: haskell-0.1.0" `BS.isInfixOf` headers) "raw upgrade omitted Convex-Client"
    keyLine <- maybe (fail "raw upgrade omitted Sec-WebSocket-Key") pure (find ("Sec-WebSocket-Key:" `BS.isPrefixOf`) (BSC.lines headers))
    let key = BSC.takeWhile (/= '\r') (BSC.dropWhile (== ' ') (BS.drop (BS.length "Sec-WebSocket-Key:") keyLine))
        accept = Base64.encode (SHA1.hash (key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
        response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " <> accept <> "\r\n\r\n"
    SocketBytes.sendAll peer response

receiveHeaders :: Socket.Socket -> BS.ByteString -> IO BS.ByteString
receiveHeaders peer accumulated
    | "\r\n\r\n" `BS.isInfixOf` accumulated = pure accumulated
    | otherwise = do
        chunk <- SocketBytes.recv peer 4096
        if BS.null chunk then fail "peer closed during handshake" else receiveHeaders peer (accumulated <> chunk)

receiveClientFrame :: Socket.Socket -> IO (Word8, BS.ByteString)
receiveClientFrame peer = do
    header <- receiveExactly peer 2
    let opcode = BS.index header 0 .&. 0x0f
        shortLength = fromIntegral (BS.index header 1 .&. 0x7f) :: Int
    lengthValue <- case shortLength of
        126 -> do
            bytes <- receiveExactly peer 2
            pure (fromIntegral (BS.index bytes 0) * 256 + fromIntegral (BS.index bytes 1))
        127 -> fail "fixture does not accept huge client frames"
        value -> pure value
    mask <- receiveExactly peer 4
    payload <- receiveExactly peer lengthValue
    let unmasked = BS.pack [byte `xorByte` BS.index mask (index `mod` 4) | (index, byte) <- zip [0 ..] (BS.unpack payload)]
    pure (opcode, unmasked)
  where
    xorByte left right = (left .|. right) .&. complementByte (left .&. right)
    complementByte value = 255 - value

receiveExactly :: Socket.Socket -> Int -> IO BS.ByteString
receiveExactly peer wanted = go BS.empty
  where
    go accumulated
        | BS.length accumulated >= wanted = pure accumulated
        | otherwise = do
            chunk <- SocketBytes.recv peer (wanted - BS.length accumulated)
            if BS.null chunk then fail "peer closed during frame" else go (accumulated <> chunk)

sendRawFrame :: Socket.Socket -> Bool -> Word8 -> BS.ByteString -> IO ()
sendRawFrame peer final opcode payload = do
    let first = (if final then 0x80 else 0) .|. opcode
        size = BS.length payload
        header
            | size < 126 = BS.pack [first, fromIntegral size]
            | otherwise = BS.pack [first, 126, fromIntegral (size `div` 256), fromIntegral (size `mod` 256)]
    SocketBytes.sendAll peer (header <> payload)

withServer :: Int -> WS.ServerApp -> IO a -> IO a
withServer port application test =
    bracket
        (async (WS.runServer "127.0.0.1" port (quiet application)))
        cancel
        (\_ -> threadDelay 100000 >> test)
  where
    quiet handler pending = handler pending `catch` ignorePeerClose
    ignorePeerClose :: SomeException -> IO ()
    ignorePeerClose _ = pure ()

assertHeader :: WS.PendingConnection -> IO ()
assertHeader pending =
    assert
        (lookup "Convex-Client" (WS.requestHeaders (WS.pendingRequest pending)) == Just "haskell-0.1.0")
        "WebSocket upgrade omitted Convex-Client header"

receiveObject :: WS.Connection -> IO Object
receiveObject connection = do
    bytes <- WS.receiveData connection
    case eitherDecode bytes of
        Right (Object value) -> pure value
        other -> fail ("expected JSON object from client, got " <> show other)

sendTransition :: WS.Connection -> Value -> Value -> [Value] -> IO ()
sendTransition connection start end changes =
    WS.sendTextData
        connection
        ( encode
            ( object
                [ "type" .= ("Transition" :: Text)
                , "startVersion" .= start
                , "endVersion" .= end
                , "modifications" .= changes
                ]
            )
        )

version :: Int -> Text -> Value
version querySet timestampValue =
    object ["querySet" .= querySet, "identity" .= (0 :: Int), "ts" .= timestampValue]

updated :: Int -> Int -> Value
updated ident count =
    object
        [ "type" .= ("QueryUpdated" :: Text)
        , "queryId" .= ident
        , "value" .= object ["count" .= count]
        , "logLines" .= ([] :: [Text])
        ]

queryIdFromModify :: Object -> Int
queryIdFromModify message = case KM.lookup "modifications" message of
    Just (Array modifications) -> case foldr (:) [] modifications of
        Object first : _ -> case KM.lookup "queryId" first of
            Just (Number value) -> floor value
            _ -> error "fixture Add omitted queryId"
        _ -> error "fixture ModifyQuerySet had no modification"
    _ -> error "fixture expected ModifyQuerySet"

modificationType :: Object -> Maybe Text
modificationType message = case KM.lookup "modifications" message of
    Just (Array modifications) -> case foldr (:) [] modifications of
        Object first : _ -> case KM.lookup "type" first of
            Just (String value) -> Just value
            _ -> Nothing
        _ -> Nothing
    _ -> Nothing

awaitUpdate :: Subscription -> IO Update
awaitUpdate subscription = do
    result <- timeout 3000000 (nextUpdate subscription)
    maybe (fail "timed out waiting for Live update") pure result

awaitValue :: Subscription -> IO Update
awaitValue subscription = do
    update <- awaitUpdate subscription
    if updateValue update == Nothing then awaitValue subscription else pure update

assertCount :: Int -> Update -> IO ()
assertCount expected update = case (updateValue update, updateError update) of
    (Just (Object value), Nothing) -> case KM.lookup "count" value of
        Just (Number actual) -> assert (floor actual == expected) ("count was " <> show actual <> ", expected " <> show expected)
        _ -> fail "Live value omitted count"
    _ -> fail ("expected Live value, got " <> show update)

assertClosed :: Subscription -> IO ()
assertClosed subscription = do
    result <- timeout 500000 ((nextUpdate subscription >> pure False) `catch` closed)
    assert (result == Just True) "nextUpdate did not observe subscription closure"
  where
    closed :: ConvexError -> IO Bool
    closed (ClosedError _) = pure True
    closed failure = fail ("unexpected close error: " <> show failure)

assertNoUpdate :: String -> Subscription -> IO ()
assertNoUpdate label subscription = do
    result <- timeout 100000 (nextUpdate subscription)
    assert (result == Nothing) (label <> " was delivered instead of coalesced")

assertProtocolUpdate :: Update -> IO ()
assertProtocolUpdate update = case updateError update of
    Just (ProtocolError _) -> pure ()
    other -> fail ("expected ProtocolError update, got " <> show other)

assertCompletes :: String -> IO () -> IO ()
assertCompletes label operation = do
    result <- timeout 2500000 operation
    assert (result == Just ()) (label <> " exceeded the 2.5 second teardown deadline")

assertConnect :: Int -> Text -> Maybe Text -> Object -> IO ()
assertConnect expectedCount expectedReason expectedTimestamp message = do
    assert (numberAt "connectionCount" message == Just expectedCount) "wrong connectionCount"
    assert (textAt "lastCloseReason" message == Just expectedReason) "wrong lastCloseReason"
    assert
        (textAt "maxObservedTimestamp" message == expectedTimestamp)
        ("wrong maxObservedTimestamp: got " <> show (textAt "maxObservedTimestamp" message) <> ", expected " <> show expectedTimestamp)

awaitRecord :: TQueue Object -> IO Object
awaitRecord records = maybe (fail "timed out waiting for reconnect") pure =<< timeout 3000000 (atomically (readTQueue records))

awaitRecordWithin :: Int -> TQueue Object -> IO Object
awaitRecordWithin micros records = maybe (fail "timed out waiting for reconnect") pure =<< timeout micros (atomically (readTQueue records))

textAt :: Text -> Object -> Maybe Text
textAt key value = case KM.lookup (Key.fromText key) value of
    Just (String result) -> Just result
    _ -> Nothing

numberAt :: Text -> Object -> Maybe Int
numberAt key value = case KM.lookup (Key.fromText key) value of
    Just (Number result) -> Just (floor result)
    _ -> Nothing

timestamp :: Int -> Text
timestamp value =
    let numeric = fromIntegral value :: Word64
        bytes = BS.pack [fromIntegral (numeric `shiftR` (index * 8)) | index <- [0 .. 7]]
     in TE.decodeUtf8 (Base64.encode bytes)

assert :: Bool -> String -> IO ()
assert condition problem = if condition then pure () else fail problem
