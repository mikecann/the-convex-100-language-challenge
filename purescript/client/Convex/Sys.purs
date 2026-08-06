-- | The OTP surface this client is allowed to use.
-- |
-- | Everything Convex-specific — JSON, HTTP/1.1, the WebSocket handshake and
-- | framing, and the whole sync protocol — is written in PureScript. What
-- | PureScript cannot reach on its own is here: BSD sockets, TLS with
-- | certificate and hostname verification, the two crypto primitives the
-- | WebSocket handshake needs, a monotonic clock, the standard streams, and
-- | processes with their mailboxes and timers.
-- |
-- | Messages are tagged by channel rather than by type. A process that is
-- | waiting for a reply must not accidentally take a subscription event out of
-- | its own mailbox, so there are three separate channels — commands, events,
-- | and replies — and replies additionally carry a unique reference so an
-- | Erlang selective receive can pick exactly the answer that was awaited.
module Convex.Sys
  ( Socket
  , Pid
  , Ref
  , Timer
  , RecvResult(..)
  , ReadResult(..)
  , connect
  , send
  , recv
  , close
  , listen
  , listenPort
  , accept
  , controllingProcess
  , monotonicMs
  , remainingMs
  , randomBytes
  , stdinRead
  , stdoutWrite
  , println
  , stderrWrite
  , otpRelease
  , plainArguments
  , getenv
  , env
  , halt
  , fatal
  , spawnProcess
  , selfPid
  , sendCommand
  , receiveCommand
  , sendEvent
  , receiveEvent
  , newRef
  , sendReply
  , awaitReply
  , sendCommandAfter
  , cancelTimer
  , killAndWait
  ) where

import Convex.Prelude
import Convex.Bytes (Bytes)
import Convex.Bytes as Bytes

-- | An open socket. Plain TCP and TLS sockets are different OTP types, so the
-- | transport tag stays on the Erlang side of this handle.
foreign import data Socket :: Type

foreign import data Pid :: Type

-- | A unique token that makes a reply addressable. Erlang's `make_ref/0`.
foreign import data Ref :: Type

foreign import data Timer :: Type

-- | One read attempt. A timeout is deliberately distinct from a close: the
-- | caller may be part-way through a WebSocket frame and has to decide whether
-- | to keep its parser state or abandon the connection.
data RecvResult
  = Received Bytes
  | RecvTimeout
  | RecvClosed
  | RecvFailed String

-- | One read attempt on standard input.
data ReadResult
  = ReadChunk Bytes
  | ReadEnd
  | ReadFailed String

-- | Open a connection. `secure` selects TLS; `verifyPeer` decides whether the
-- | certificate chain and hostname are checked, and is true for every real
-- | deployment. Plain TCP is what the repository's local self-hosted backend
-- | and the in-process test fixtures use.
connect
  :: Boolean -> String -> Int -> Int -> Boolean -> Effect (Either String Socket)
connect secure host port timeout verifyPeer =
  connectImpl secure host port timeout verifyPeer Left Right

foreign import connectImpl
  :: Boolean
  -> String
  -> Int
  -> Int
  -> Boolean
  -> (String -> Either String Socket)
  -> (Socket -> Either String Socket)
  -> Effect (Either String Socket)

send :: Socket -> Bytes -> Int -> Effect (Either String Unit)
send socket payload timeout = sendImpl socket payload timeout Left Right

foreign import sendImpl
  :: Socket
  -> Bytes
  -> Int
  -> (String -> Either String Unit)
  -> (Unit -> Either String Unit)
  -> Effect (Either String Unit)

-- | Read up to `length` bytes, or whatever has already arrived when `length`
-- | is zero. A short read is normal: the caller owns frame reassembly.
recv :: Socket -> Int -> Int -> Effect RecvResult
recv socket length timeout =
  recvImpl socket length timeout Received RecvTimeout RecvClosed RecvFailed

foreign import recvImpl
  :: Socket
  -> Int
  -> Int
  -> (Bytes -> RecvResult)
  -> RecvResult
  -> RecvResult
  -> (String -> RecvResult)
  -> Effect RecvResult

foreign import close :: Socket -> Effect Unit

-- | Listen on loopback. Port 0 asks the kernel to pick, which keeps the
-- | fixture servers in the language-local tests from colliding.
listen :: Int -> Effect (Either String Socket)
listen port = listenImpl port Left Right

foreign import listenImpl
  :: Int
  -> (String -> Either String Socket)
  -> (Socket -> Either String Socket)
  -> Effect (Either String Socket)

listenPort :: Socket -> Effect (Either String Int)
listenPort socket = listenPortImpl socket Left Right

foreign import listenPortImpl
  :: Socket
  -> (String -> Either String Int)
  -> (Int -> Either String Int)
  -> Effect (Either String Int)

accept :: Socket -> Int -> Effect (Either String Socket)
accept socket timeout = acceptImpl socket timeout Left Right

foreign import acceptImpl
  :: Socket
  -> Int
  -> (String -> Either String Socket)
  -> (Socket -> Either String Socket)
  -> Effect (Either String Socket)

-- | Hand a socket to another process. A passive socket may only be read by
-- | the process that owns it, so the adapter transfers its accepted connection
-- | to the reader before that reader takes its first byte. Must be called by
-- | the current owner.
foreign import controllingProcess :: Socket -> Pid -> Effect Boolean

-- | Milliseconds from an arbitrary origin that never moves backwards. Every
-- | deadline and backoff interval is computed from this rather than from the
-- | wall clock, so adjusting the system time cannot extend a timeout.
foreign import monotonicMs :: Effect Int

-- | Milliseconds left before a deadline, never negative, so a socket call with
-- | an expired deadline returns promptly instead of blocking.
remainingMs :: Int -> Effect Int
remainingMs deadline = mapEffect (\now -> maxInt 0 (deadline - now)) monotonicMs

foreign import randomBytes :: Int -> Effect Bytes

-- | Read bytes, not characters: NDJSON framing is defined on bytes and one
-- | command may split a multi-byte character across two reads.
stdinRead :: Int -> Effect ReadResult
stdinRead count = stdinReadImpl count ReadChunk ReadEnd ReadFailed

foreign import stdinReadImpl
  :: Int
  -> (Bytes -> ReadResult)
  -> ReadResult
  -> (String -> ReadResult)
  -> Effect ReadResult

stdoutWrite :: Bytes -> Effect (Either String Unit)
stdoutWrite payload = stdoutWriteImpl payload Left Right

foreign import stdoutWriteImpl
  :: Bytes
  -> (String -> Either String Unit)
  -> (Unit -> Either String Unit)
  -> Effect (Either String Unit)

-- | Write one line to standard output. The canonical example uses this, and
-- | only this, so its transcript stays byte-for-byte what the shared verifier
-- | compares against.
println :: String -> Effect Unit
println text = voidEffect (stdoutWrite (Bytes.fromString (text <> "\n")))

-- | Diagnostics go to standard error, because standard output is either the
-- | adapter's protocol stream or the shared example transcript.
foreign import stderrWrite :: String -> Effect Unit

foreign import otpRelease :: Effect String

plainArguments :: Effect (List String)
plainArguments = plainArgumentsImpl Nil Cons

foreign import plainArgumentsImpl
  :: List String
  -> (String -> List String -> List String)
  -> Effect (List String)

getenv :: String -> Effect (Maybe String)
getenv name = getenvImpl name Nothing Just

foreign import getenvImpl
  :: String
  -> Maybe String
  -> (String -> Maybe String)
  -> Effect (Maybe String)

env :: String -> String -> Effect String
env name fallback = mapEffect (fromMaybe fallback) (getenv name)

foreign import halt :: forall a. Int -> Effect a

-- | Report on standard error and stop with a failing status. The canonical
-- | example uses this so an unexpected Convex value ends the run without
-- | writing anything to the shared stdout transcript.
fatal :: forall a. String -> Effect a
fatal message = do
  stderrWrite message
  halt 1

-- | Start an unlinked process. Nothing in this client wants a crashing worker
-- | to take its owner down; failures are reported as protocol or transport
-- | events instead.
foreign import spawnProcess :: Effect Unit -> Effect Pid

foreign import selfPid :: Effect Pid

-- | The command channel: what a worker's own loop consumes.
foreign import sendCommand :: forall m. Pid -> m -> Effect Unit

receiveCommand :: forall m. Int -> Effect (Maybe m)
receiveCommand timeout = receiveCommandImpl timeout Nothing Just

foreign import receiveCommandImpl
  :: forall m
   . Int
  -> Maybe m
  -> (m -> Maybe m)
  -> Effect (Maybe m)

-- | The event channel: Live deliveries to a subscriber. Kept separate so a
-- | subscriber waiting for a command reply cannot swallow an update.
foreign import sendEvent :: forall m. Pid -> m -> Effect Unit

receiveEvent :: forall m. Int -> Effect (Maybe m)
receiveEvent timeout = receiveEventImpl timeout Nothing Just

foreign import receiveEventImpl
  :: forall m
   . Int
  -> Maybe m
  -> (m -> Maybe m)
  -> Effect (Maybe m)

foreign import newRef :: Effect Ref

-- | The reply channel. The reference makes the receive selective, so an answer
-- | is taken out of the mailbox without disturbing anything else in it.
foreign import sendReply :: forall a. Pid -> Ref -> a -> Effect Unit

awaitReply :: forall a. Ref -> Int -> Effect (Maybe a)
awaitReply reference timeout = awaitReplyImpl reference timeout Nothing Just

foreign import awaitReplyImpl
  :: forall a
   . Ref
  -> Int
  -> Maybe a
  -> (a -> Maybe a)
  -> Effect (Maybe a)

-- | Deliver a command to a process later. Used for reconnect backoff, the
-- | handshake deadline, the partial-frame deadline, and the idle close.
foreign import sendCommandAfter :: forall m. Pid -> Int -> m -> Effect Timer

foreign import cancelTimer :: Timer -> Effect Unit

-- | Kill a worker and wait for its death certificate. This is a barrier
-- | rather than a hint: once it returns true the worker cannot deliver
-- | anything else, which is what makes unsubscribe and close real guarantees.
foreign import killAndWait :: Pid -> Int -> Effect Boolean
