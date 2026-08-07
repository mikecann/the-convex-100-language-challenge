{-# OPTIONS --without-K #-}

-- The reviewed foreign boundary.
--
-- This is the only module in the client that contains a FOREIGN or COMPILE
-- pragma. Everything Convex-specific -- HTTP framing, the JSON codec, RFC6455
-- framing, the Live envelope and state machine, and the NDJSON adapter -- is
-- written in Agda above these primitives.
--
-- Agda's runtime has no packed byte buffer, no sockets, no TLS, no threads, no
-- monotonic clock, and no entropy source, so each primitive below exists for
-- exactly one of those gaps. None of them understands Convex, HTTP, or the
-- WebSocket wire format: `socketSend` and `socketRecv` move opaque octets and
-- nothing else.
module Convex.Prim where

open import Convex.Prelude
open import Agda.Builtin.IO public using (IO)

{-# FOREIGN GHC
import qualified Control.Concurrent as Conc
import qualified Control.Concurrent.MVar as MV
import qualified Control.Exception as Exc
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as LBS
import qualified Data.IORef as Ref
import qualified Data.Text as T
import qualified GHC.Clock as Clock
import qualified Network.Socket as Net
import qualified Network.Socket.ByteString as NetBS
import qualified Network.TLS as TLS
import qualified Network.TLS.Extra.Cipher as TLSCipher
import qualified System.Environment as Env
import qualified System.Exit as Exit
import qualified System.IO as SIO
import qualified System.IO.Error as IOErr
import qualified System.Timeout as TO
import qualified System.X509 as X509
#-}

{-# FOREIGN GHC
-- | Result of a primitive that either produced a value or failed with a
-- diagnostic string. The Agda side turns the string into a structured
-- TransportError; the boundary itself never classifies Convex failures.
data AgdaIOResult a = IOOk a | IOErr T.Text

-- | Result of one bounded read. The four cases are exactly what the Agda
-- parsers must distinguish: progress, a deadline, an orderly end of stream,
-- and a broken transport.
data AgdaRecv
  = RecvData BS.ByteString
  | RecvTimeout
  | RecvEof
  | RecvError T.Text

-- | A byte transport. Plain TCP and TLS produce the same three operations, so
-- the Agda WebSocket and HTTP code is written once against octets.
data ConvexSocket = ConvexSocket
  { csSend  :: BS.ByteString -> IO ()
  , csRecv  :: Int -> IO BS.ByteString
  , csClose :: IO ()
  }

convexClampIndex :: Integer -> Int -> Int
convexClampIndex value limit
  | value <= 0 = 0
  | value >= toInteger limit = limit
  | otherwise = fromInteger value

-- Bound every foreign size argument before it reaches a machine Int so a
-- hostile length in a frame header can never wrap or pre-allocate.
convexClampSize :: Integer -> Int
convexClampSize value
  | value <= 0 = 0
  | value >= 67108864 = 67108864
  | otherwise = fromInteger value

convexClampMicros :: Integer -> Int
convexClampMicros milliseconds
  | milliseconds <= 0 = 0
  | milliseconds >= 600000 = 600000000
  | otherwise = fromInteger milliseconds * 1000

convexShow :: Exc.SomeException -> T.Text
convexShow = T.pack . Exc.displayException

convexTry :: IO a -> IO (AgdaIOResult a)
convexTry action = do
  outcome <- Exc.try action
  pure $ case outcome of
    Left err -> IOErr (convexShow err)
    Right value -> IOOk value

convexPlainSocket :: Net.Socket -> ConvexSocket
convexPlainSocket sock =
  ConvexSocket
    { csSend = NetBS.sendAll sock
    , csRecv = NetBS.recv sock
    , csClose = Exc.handle (\e -> const (pure ()) (e :: Exc.SomeException)) (Net.close sock)
    }

-- TLS is delegated to the pure-Haskell `tls` package. Certificate-chain and
-- hostname verification are the library defaults for `defaultParamsClient`,
-- with the system CA store supplied explicitly so a read-only runtime image
-- only has to carry a certificate bundle.
convexTlsSocket :: String -> Integer -> Net.Socket -> IO ConvexSocket
convexTlsSocket host port sock = do
  store <- X509.getSystemCertificateStore
  let base = TLS.defaultParamsClient host (BSC.pack (show port))
      params =
        base
          { TLS.clientSupported =
              (TLS.clientSupported base) { TLS.supportedCiphers = TLSCipher.ciphersuite_default }
          , TLS.clientShared =
              (TLS.clientShared base) { TLS.sharedCAStore = store }
          }
  context <- TLS.contextNew sock params
  TLS.handshake context
  leftover <- Ref.newIORef BS.empty
  let recvUpTo wanted = do
        pending <- Ref.readIORef leftover
        if BS.null pending
          then do
            chunk <- TLS.recvData context
            let (now, rest) = BS.splitAt wanted chunk
            Ref.writeIORef leftover rest
            pure now
          else do
            let (now, rest) = BS.splitAt wanted pending
            Ref.writeIORef leftover rest
            pure now
  pure
    ConvexSocket
      { csSend = TLS.sendData context . LBS.fromStrict
      , csRecv = recvUpTo
      , csClose =
          Exc.handle
            (\e -> const (Net.close sock) (e :: Exc.SomeException))
            (TLS.bye context >> Net.close sock)
      }

convexConnect :: T.Text -> Integer -> Bool -> Integer -> IO (AgdaIOResult ConvexSocket)
convexConnect host port secure timeoutMs = convexTry $ do
  let hostString = T.unpack host
      hints = Net.defaultHints { Net.addrSocketType = Net.Stream }
  addresses <- Net.getAddrInfo (Just hints) (Just hostString) (Just (show port))
  case addresses of
    [] -> ioError (userError "no address for host")
    (address : _) -> do
      sock <- Net.socket (Net.addrFamily address) Net.Stream Net.defaultProtocol
      connected <-
        TO.timeout (convexClampMicros timeoutMs) (Net.connect sock (Net.addrAddress address))
      case connected of
        Nothing -> Net.close sock >> ioError (userError "connect timed out")
        Just () ->
          if secure
            then Exc.onException (convexTlsSocket hostString port sock) (Net.close sock)
            else pure (convexPlainSocket sock)

convexListen :: T.Text -> Integer -> IO (AgdaIOResult Net.Socket)
convexListen host port = convexTry $ do
  let hints =
        Net.defaultHints
          { Net.addrSocketType = Net.Stream
          , Net.addrFlags = [Net.AI_PASSIVE, Net.AI_NUMERICHOST]
          }
  addresses <- Net.getAddrInfo (Just hints) (Just (T.unpack host)) (Just (show port))
  case addresses of
    [] -> ioError (userError "no bind address")
    (address : _) -> do
      sock <- Net.socket (Net.addrFamily address) Net.Stream Net.defaultProtocol
      Net.setSocketOption sock Net.ReuseAddr 1
      Net.bind sock (Net.addrAddress address)
      Net.listen sock 1
      pure sock

convexListenerPort :: Net.Socket -> IO Integer
convexListenerPort sock = do
  address <- Net.getSocketName sock
  pure $ case address of
    Net.SockAddrInet portNumber _ -> toInteger portNumber
    Net.SockAddrInet6 portNumber _ _ _ -> toInteger portNumber
    _ -> 0

convexAccept :: Net.Socket -> IO (AgdaIOResult ConvexSocket)
convexAccept listener = convexTry $ do
  (sock, _) <- Net.accept listener
  pure (convexPlainSocket sock)

convexSend :: ConvexSocket -> BS.ByteString -> Integer -> IO (AgdaIOResult ())
convexSend sock payload timeoutMs = do
  outcome <- Exc.try (TO.timeout (convexClampMicros timeoutMs) (csSend sock payload))
  pure $ case outcome of
    Left err -> IOErr (convexShow err)
    Right Nothing -> IOErr (T.pack "socket write timed out")
    Right (Just ()) -> IOOk ()

convexRecv :: ConvexSocket -> Integer -> Integer -> IO AgdaRecv
convexRecv sock wanted timeoutMs = do
  outcome <- Exc.try (TO.timeout (convexClampMicros timeoutMs) (csRecv sock (convexClampSize wanted)))
  pure $ case outcome of
    Left err -> RecvError (convexShow err)
    Right Nothing -> RecvTimeout
    Right (Just chunk)
      | BS.null chunk -> RecvEof
      | otherwise -> RecvData chunk

convexStdinRecv :: Integer -> Integer -> IO AgdaRecv
convexStdinRecv wanted timeoutMs = do
  ready <- Exc.try (SIO.hWaitForInput SIO.stdin (fromInteger (max 0 (min 600000 timeoutMs))))
  case ready of
    Left err
      | IOErr.isEOFError err -> pure RecvEof
      | otherwise -> pure (RecvError (T.pack (show err)))
    Right False -> pure RecvTimeout
    Right True -> do
      outcome <- Exc.try (BS.hGetSome SIO.stdin (convexClampSize wanted))
      pure $ case outcome of
        Left err -> RecvError (convexShow err)
        Right chunk
          | BS.null chunk -> RecvEof
          | otherwise -> RecvData chunk

convexStdoutWrite :: BS.ByteString -> IO (AgdaIOResult ())
convexStdoutWrite payload = convexTry (BS.hPut SIO.stdout payload >> SIO.hFlush SIO.stdout)

convexRandomBytes :: Integer -> IO BS.ByteString
convexRandomBytes count =
  SIO.withBinaryFile "/dev/urandom" SIO.ReadMode (\h -> BS.hGet h (convexClampSize count))

convexFork :: IO () -> IO ()
convexFork action =
  Conc.forkIO
    ( Exc.handle
        (\e -> SIO.hPutStrLn SIO.stderr ("convex worker stopped: " ++ Exc.displayException (e :: Exc.SomeException)))
        action
    )
    >> pure ()
#-}

--------------------------------------------------------------------------------
-- The IO monad
--------------------------------------------------------------------------------

postulate
  ioReturn : {A : Set} → A → IO A
  ioBind : {A B : Set} → IO A → (A → IO B) → IO B

{-# COMPILE GHC ioReturn = \ _ x -> pure x #-}
{-# COMPILE GHC ioBind = \ _ _ m f -> m >>= f #-}

infixl 1 _>>=_ _>>_

_>>=_ : {A B : Set} → IO A → (A → IO B) → IO B
_>>=_ = ioBind

_>>_ : {A B : Set} → IO A → IO B → IO B
m >> n = m >>= λ _ → n

return : {A : Set} → A → IO A
return = ioReturn

--------------------------------------------------------------------------------
-- Foreign result types
--------------------------------------------------------------------------------

data IOResult (A : Set) : Set where
  ioOk : A → IOResult A
  ioErr : String → IOResult A

{-# COMPILE GHC IOResult = data AgdaIOResult (IOOk | IOErr) #-}

--------------------------------------------------------------------------------
-- Packed byte buffers
--
-- Agda's lists of naturals are boxed, so a megabyte-sized wire buffer would
-- cost far more than the shared 128 MiB container budget allows. `Bytes` is an
-- opaque packed buffer with O(1) length and indexing; every parser in this
-- client walks it by index in Agda rather than converting it to a list.
--------------------------------------------------------------------------------

postulate
  Bytes : Set

{-# COMPILE GHC Bytes = type BS.ByteString #-}

data RecvResult : Set where
  recvData : Bytes → RecvResult
  recvTimeout : RecvResult
  recvEof : RecvResult
  recvError : String → RecvResult

{-# COMPILE GHC RecvResult = data AgdaRecv (RecvData | RecvTimeout | RecvEof | RecvError) #-}

postulate
  bytesEmpty : Bytes
  bytesLength : Bytes → Nat
  bytesIndex : Bytes → Nat → Nat
  bytesSlice : Bytes → Nat → Nat → Bytes
  bytesAppend : Bytes → Bytes → Bytes
  bytesFromOctets : List Nat → Bytes
  bytesToOctets : Bytes → List Nat

{-# COMPILE GHC bytesEmpty = BS.empty #-}
{-# COMPILE GHC bytesLength = toInteger . BS.length #-}
{-# COMPILE GHC bytesIndex = \ b i -> if i < 0 || i >= toInteger (BS.length b) then 0 else toInteger (BS.index b (fromInteger i)) #-}
{-# COMPILE GHC bytesSlice = \ b off len -> let n = BS.length b; o = convexClampIndex off n in BS.take (convexClampIndex len (n - o)) (BS.drop o b) #-}
{-# COMPILE GHC bytesAppend = BS.append #-}
{-# COMPILE GHC bytesFromOctets = BS.pack . map (fromInteger . (`mod` 256)) #-}
{-# COMPILE GHC bytesToOctets = map toInteger . BS.unpack #-}

--------------------------------------------------------------------------------
-- Sockets and TLS
--------------------------------------------------------------------------------

postulate
  Socket : Set
  Listener : Set

{-# COMPILE GHC Socket = type ConvexSocket #-}
{-# COMPILE GHC Listener = type Net.Socket #-}

postulate
  -- host, port, use TLS, connect deadline in milliseconds
  socketConnect : String → Nat → Bool → Nat → IO (IOResult Socket)
  -- payload and a write deadline in milliseconds
  socketSend : Socket → Bytes → Nat → IO (IOResult ⊤)
  -- maximum octets and a read deadline in milliseconds
  socketRecv : Socket → Nat → Nat → IO RecvResult
  socketClose : Socket → IO ⊤
  listenerOpen : String → Nat → IO (IOResult Listener)
  listenerPort : Listener → IO Nat
  listenerAccept : Listener → IO (IOResult Socket)
  listenerClose : Listener → IO ⊤

{-# COMPILE GHC socketConnect = convexConnect #-}
{-# COMPILE GHC socketSend = convexSend #-}
{-# COMPILE GHC socketRecv = convexRecv #-}
{-# COMPILE GHC socketClose = csClose #-}
{-# COMPILE GHC listenerOpen = convexListen #-}
{-# COMPILE GHC listenerPort = convexListenerPort #-}
{-# COMPILE GHC listenerAccept = convexAccept #-}
{-# COMPILE GHC listenerClose = \ s -> Exc.handle (\e -> const (pure ()) (e :: Exc.SomeException)) (Net.close s) #-}

--------------------------------------------------------------------------------
-- Concurrency, time, and entropy
--------------------------------------------------------------------------------

postulate
  MVar : Set → Set

{-# COMPILE GHC MVar = type MV.MVar #-}

postulate
  newMVar : {A : Set} → A → IO (MVar A)
  takeMVar : {A : Set} → MVar A → IO A
  putMVar : {A : Set} → MVar A → A → IO ⊤
  readMVar : {A : Set} → MVar A → IO A
  forkThread : IO ⊤ → IO ⊤
  sleepMillis : Nat → IO ⊤
  monotonicMillis : IO Nat
  randomBytes : Nat → IO Bytes

{-# COMPILE GHC newMVar = \ _ x -> MV.newMVar x #-}
{-# COMPILE GHC takeMVar = \ _ v -> MV.takeMVar v #-}
{-# COMPILE GHC putMVar = \ _ v x -> MV.putMVar v x #-}
{-# COMPILE GHC readMVar = \ _ v -> MV.readMVar v #-}
{-# COMPILE GHC forkThread = convexFork #-}
{-# COMPILE GHC sleepMillis = \ ms -> Conc.threadDelay (convexClampMicros ms) #-}
{-# COMPILE GHC monotonicMillis = fmap (\ ns -> toInteger ns `div` 1000000) Clock.getMonotonicTimeNSec #-}
{-# COMPILE GHC randomBytes = convexRandomBytes #-}

--------------------------------------------------------------------------------
-- Process I/O
--------------------------------------------------------------------------------

postulate
  initStandardStreams : IO ⊤
  stdinRecv : Nat → Nat → IO RecvResult
  stdoutWrite : Bytes → IO (IOResult ⊤)
  stderrLine : String → IO ⊤
  getEnvironment : String → IO (Maybe String)
  getArguments : IO (List String)
  exitProcess : Nat → IO ⊤

{-# COMPILE GHC initStandardStreams = SIO.hSetBinaryMode SIO.stdin True >> SIO.hSetBinaryMode SIO.stdout True >> SIO.hSetBuffering SIO.stdout SIO.NoBuffering #-}
{-# COMPILE GHC stdinRecv = convexStdinRecv #-}
{-# COMPILE GHC stdoutWrite = convexStdoutWrite #-}
{-# COMPILE GHC stderrLine = \ t -> SIO.hPutStrLn SIO.stderr (T.unpack t) >> SIO.hFlush SIO.stderr #-}
{-# COMPILE GHC getEnvironment = \ t -> Env.lookupEnv (T.unpack t) >>= \ v -> pure (fmap T.pack v) #-}
{-# COMPILE GHC getArguments = fmap (map T.pack) Env.getArgs #-}
{-# COMPILE GHC exitProcess = \ code -> if code == 0 then Exit.exitWith Exit.ExitSuccess else Exit.exitWith (Exit.ExitFailure (fromInteger code)) #-}
