{-# LANGUAGE OverloadedStrings #-}

-- Deterministic HTTP fixtures exercise the real socket and JSON envelope. They
-- intentionally sit outside Convex internals so a passing test proves the
-- public client sent and decoded actual HTTP bytes.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Concurrent.STM
import Control.Exception (SomeException, bracket, catch, try)
import Control.Monad (replicateM_)
import Convex
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as B8
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketBytes

main :: IO ()
main = do
    requests <- newTQueueIO
    withHttpServer 19241 requests $ do
        client <- newClient "http://127.0.0.1:19241"

        first <- query client "fixture:success" (object ["number" .= (1 :: Int)])
        assert (resultValue first == object ["count" .= (1 :: Int)]) "success value was decoded incorrectly"
        assert (resultLogs first == ["query log"]) "success logs were lost"
        firstRequest <- atomically (readTQueue requests)
        assertRequest firstRequest "query" "fixture:success" Nothing

        setAuth client "fixture-token"
        failed <- try (mutation client "fixture:failure" (object []))
        case failed of
            Left (FunctionError "fixture failed" (Just details) ["mutation log"])
                | details == object ["code" .= (7 :: Int)] -> pure ()
            other -> fail ("structured function error was wrong: " <> show other)
        secondRequest <- atomically (readTQueue requests)
        assertRequest secondRequest "mutation" "fixture:failure" (Just "Bearer fixture-token")

        clearAuth client
        _ <- query client "fixture:success" (object ["number" .= (2 :: Int)])
        thirdRequest <- atomically (readTQueue requests)
        assertRequest thirdRequest "query" "fixture:success" Nothing

        malformed <- try (action client "fixture:malformed" (object []))
        case malformed of
            Left (ProtocolError _) -> pure ()
            other -> fail ("malformed response did not become ProtocolError: " <> show other)
        fourthRequest <- atomically (readTQueue requests)
        assertRequest fourthRequest "action" "fixture:malformed" Nothing
        closeClient client

    unavailable <- newClient "http://127.0.0.1:19242"
    transport <- try (query unavailable "fixture:none" (object []))
    case transport of
        Left (TransportError _) -> pure ()
        other -> fail ("connection failure did not become TransportError: " <> show other)
    closeClient unavailable
    putStrLn "haskell HTTP socket fixtures pass"

data CapturedRequest = CapturedRequest
    { capturedTarget :: BS.ByteString
    , capturedHeaders :: [(BS.ByteString, BS.ByteString)]
    , capturedBody :: Value
    }

assertRequest :: CapturedRequest -> Text -> Text -> Maybe BS.ByteString -> IO ()
assertRequest request operation path expectedAuth = do
    assert (capturedTarget request == "/api/" <> TE.encodeUtf8 operation) "HTTP operation path was wrong"
    assert (lookup "convex-client" (capturedHeaders request) == Just "haskell-0.1.0") "Convex-Client header was wrong"
    assert (lookup "authorization" (capturedHeaders request) == expectedAuth) "Authorization header lifecycle was wrong"
    case capturedBody request of
        Object body -> do
            assert (KM.lookup "path" body == Just (String path)) "function path was wrong"
            assert (KM.lookup "format" body == Just (String "json")) "format was not json"
        _ -> fail "HTTP request body was not an object"

withHttpServer :: Int -> TQueue CapturedRequest -> IO a -> IO a
withHttpServer port requests test = Socket.withSocketsDo $ bracket open Socket.close $ \listener -> do
    worker <- async (replicateM_ 4 (serveOne listener requests))
    threadDelay 50000
    outcome <- tryAny test
    cancel worker
    either (fail . show) pure outcome
  where
    open = do
        listener <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
        Socket.setSocketOption listener Socket.ReuseAddr 1
        Socket.bind listener (Socket.SockAddrInet (fromIntegral port) (Socket.tupleToHostAddress (127, 0, 0, 1)))
        Socket.listen listener 4
        pure listener

serveOne :: Socket.Socket -> TQueue CapturedRequest -> IO ()
serveOne listener requests = do
    (peer, _) <- Socket.accept listener
    ( do
            (headerBytes, initialBody) <- receiveHeaders peer BS.empty
            let headerLines = B8.lines headerBytes
                target = case headerLines of
                    requestLine : _ -> case B8.words requestLine of
                        _method : value : _ -> value
                        _ -> ""
                    _ -> ""
                headers = mapMaybeHeader (drop 1 headerLines)
                bodyLength = maybe 0 readInt (lookup "content-length" headers)
            remaining <- receiveExactly peer (max 0 (bodyLength - BS.length initialBody))
            body <- case eitherDecodeStrict' (BS.take bodyLength (initialBody <> remaining)) of
                Right value -> pure value
                Left problem -> fail ("fixture could not decode request body: " <> problem)
            atomically (writeTQueue requests (CapturedRequest target headers body))
            let path = case body of
                    Object value -> KM.lookup "path" value
                    _ -> Nothing
                responseBody = case path of
                    Just (String "fixture:failure") ->
                        encode
                            ( object
                                [ "status" .= ("error" :: Text)
                                , "errorMessage" .= ("fixture failed" :: Text)
                                , "errorData" .= object ["code" .= (7 :: Int)]
                                , "logLines" .= ["mutation log" :: Text]
                                ]
                            )
                    Just (String "fixture:malformed") -> "{not-json"
                    _ -> encode (object ["status" .= ("success" :: Text), "value" .= object ["count" .= (1 :: Int)], "logLines" .= ["query log" :: Text]])
                response =
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: "
                        <> LBS.fromStrict (B8.pack (show (LBS.length responseBody)))
                        <> "\r\n\r\n"
                        <> responseBody
            SocketBytes.sendAll peer (LBS.toStrict response)
        )
        `catch` ignorePeerClose
    Socket.close peer
  where
    ignorePeerClose :: SomeException -> IO ()
    ignorePeerClose _ = pure ()

receiveHeaders :: Socket.Socket -> BS.ByteString -> IO (BS.ByteString, BS.ByteString)
receiveHeaders peer accumulated = case B8.breakSubstring "\r\n\r\n" accumulated of
    (headers, rest)
        | not (BS.null rest) -> pure (headers, BS.drop 4 rest)
    _ -> do
        chunk <- SocketBytes.recv peer 4096
        if BS.null chunk
            then fail "peer closed before HTTP headers"
            else receiveHeaders peer (accumulated <> chunk)

receiveExactly :: Socket.Socket -> Int -> IO BS.ByteString
receiveExactly peer wanted = go BS.empty
  where
    go accumulated
        | BS.length accumulated >= wanted = pure accumulated
        | otherwise = do
            chunk <- SocketBytes.recv peer (wanted - BS.length accumulated)
            if BS.null chunk
                then fail "peer closed before HTTP body"
                else go (accumulated <> chunk)

mapMaybeHeader :: [BS.ByteString] -> [(BS.ByteString, BS.ByteString)]
mapMaybeHeader = foldr collect []
  where
    collect line result = case B8.break (== ':') line of
        (name, value)
            | not (BS.null value) ->
                ( B8.map lowerAscii name
                , B8.takeWhile (/= '\r') (B8.dropWhile (== ' ') (BS.drop 1 value))
                )
                    : result
        _ -> result
    lowerAscii byte
        | byte >= 'A' && byte <= 'Z' = toEnum (fromEnum byte + 32)
        | otherwise = byte

readInt :: BS.ByteString -> Int
readInt = read . B8.unpack

tryAny :: IO a -> IO (Either SomeException a)
tryAny task = (Right <$> task) `catch` (pure . Left)

assert :: Bool -> String -> IO ()
assert condition problem = if condition then pure () else fail problem
