{-# OPTIONS --without-K #-}

-- The client object the example and the conformance executable share.
--
-- It owns the deployment configuration, the bearer token, and at most one Live
-- worker. The Live worker is started lazily on the first subscribe, so a
-- program that only issues HTTP calls never opens a WebSocket.
--
-- `clientDebugDisconnect` is test-only fault injection. It is intentionally
-- absent from the `Convex` module the README and website present, and is
-- reached only by `client/tests/conformance`.
module Convex.Client where

open import Convex.Prelude
open import Convex.Prim
open import Convex.Error
open import Convex.Json
open import Convex.Http using (Deployment; parseDeployment; safeHeaderValue; httpCall)
import Convex.Live as Live

record ClientState : Set where
  constructor clientState
  field
    token : String
    worker : Maybe Live.Live
    closed : Bool

open ClientState public

record Client : Set where
  constructor clientOf
  field
    deploymentOf : Deployment
    clientVersion : String
    stateCell : MVar ClientState

open Client public

private
  withClient : {A : Set} → Client → (ClientState → ClientState × A) → IO A
  withClient {A} client step =
    takeMVar (stateCell client) >>= λ current → applyStep (step current)
    where
      applyStep : ClientState × A → IO A
      applyStep (next , result) = putMVar (stateCell client) next >> return result

  peek : Client → IO ClientState
  peek client = readMVar (stateCell client)

-- Configure a client for one deployment. The URL, the client version, and any
-- later bearer token are all checked for header-injection characters before a
-- request can be built from them.
newClient : String → String → IO (Either ConvexError Client)
newClient url version =
  if not (safeHeaderValue version) ∨ (stringLength version ==ⁿ 0) then
    return (left (protocolFailure "client version must be a non-empty newline-free string"))
  else built (parseDeployment url)
  where
    built : Either String Deployment → IO (Either ConvexError Client)
    built (left m) = return (left (protocolFailure m))
    built (right dep) =
      newMVar (clientState "" nothing false)
        >>= λ cellRef → return (right (clientOf dep version cellRef))

--------------------------------------------------------------------------------
-- Authentication
--------------------------------------------------------------------------------

setAuth : Client → String → Task ⊤
setAuth client value =
  if not (safeHeaderValue value) then
    taskFail (protocolFailure "auth token must be a newline-free string")
  else withClient client step
  where
    step : ClientState → ClientState × Either ConvexError ⊤
    step current =
      if closed current then (current , left (closedFailure "client is closed"))
      else (record current { token = value } , right tt)

--------------------------------------------------------------------------------
-- HTTP
--------------------------------------------------------------------------------

private
  callWith : Client → String → String → JSON → Task CallResult
  callWith client operation path args = peek client >>= dispatch
    where
      dispatch : ClientState → Task CallResult
      dispatch current =
        if closed current then taskFail (closedFailure "client is closed")
        else
          httpCall (deploymentOf client) (clientVersion client) (token current)
                   operation path args

clientQuery : Client → String → JSON → Task CallResult
clientQuery client = callWith client "query"

clientMutation : Client → String → JSON → Task CallResult
clientMutation client = callWith client "mutation"

clientAction : Client → String → JSON → Task CallResult
clientAction client = callWith client "action"

--------------------------------------------------------------------------------
-- Live
--------------------------------------------------------------------------------

private
  -- Start the Live worker on demand and remember it, so repeated subscribes
  -- share one socket and one owner.
  ensureWorker : Client → Task Live.Live
  ensureWorker client = peek client >>= dispatch
    where
      adopt : Live.Live → Task Live.Live
      adopt started = withClient client step
        where
          step : ClientState → ClientState × Either ConvexError Live.Live
          step current = onExisting (worker current)
            where
              onExisting : Maybe Live.Live → ClientState × Either ConvexError Live.Live
              onExisting (just existing) = (current , right existing)
              onExisting nothing = (record current { worker = just started } , right started)

      dispatch : ClientState → Task Live.Live
      dispatch current =
        if closed current then taskFail (closedFailure "client is closed")
        else onWorker (worker current)
        where
          onWorker : Maybe Live.Live → Task Live.Live
          onWorker (just existing) = taskOk existing
          onWorker nothing =
            Live.startLive (deploymentOf client) (clientVersion client) >>= adopt

clientSubscribe : Client → String → JSON → Task Nat
clientSubscribe client path args = ensureWorker client >>=T λ manager → Live.subscribe manager path args

clientUnsubscribe : Client → Nat → Task Nat
clientUnsubscribe client qid = peek client >>= dispatch
  where
    dispatch : ClientState → Task Nat
    dispatch current = onWorker (worker current)
      where
        onWorker : Maybe Live.Live → Task Nat
        onWorker nothing = taskOk 0
        onWorker (just manager) = Live.unsubscribe manager qid

-- Wait up to `timeoutMs` for the next value on one subscription.
clientNext : Client → Nat → Nat → IO (Maybe Live.Update)
clientNext client qid timeoutMs = peek client >>= dispatch
  where
    dispatch : ClientState → IO (Maybe Live.Update)
    dispatch current = onWorker (worker current)
      where
        onWorker : Maybe Live.Live → IO (Maybe Live.Update)
        onWorker nothing = return nothing
        onWorker (just manager) = Live.nextUpdate manager qid timeoutMs

-- The transport generation the Live worker has published. The conformance
-- adapter compares it after dequeuing an update so a value produced by a
-- retired connection can never cross a barrier acknowledgement.
clientLiveGeneration : Client → IO Nat
clientLiveGeneration client = peek client >>= dispatch
  where
    dispatch : ClientState → IO Nat
    dispatch current = onWorker (worker current)
      where
        onWorker : Maybe Live.Live → IO Nat
        onWorker nothing = return 0
        onWorker (just manager) = Live.liveGeneration manager

-- Adapter-only fault injection; see the module header.
clientDebugDisconnect : Client → Task Nat
clientDebugDisconnect client = peek client >>= dispatch
  where
    dispatch : ClientState → Task Nat
    dispatch current = onWorker (worker current)
      where
        onWorker : Maybe Live.Live → Task Nat
        onWorker nothing = taskFail (protocolFailure "Live has not been started")
        onWorker (just manager) = Live.debugDisconnect manager

--------------------------------------------------------------------------------
-- Shutdown
--------------------------------------------------------------------------------

-- Closing retires the one Live worker and every subscription in a single
-- bounded operation rather than serialising a Remove per query.
clientClose : Client → Task ⊤
clientClose client = withClient client step >>= dispatch
  where
    step : ClientState → ClientState × Maybe Live.Live
    step current =
      if closed current then (current , nothing)
      else (record current { closed = true ; worker = nothing } , worker current)

    dispatch : Maybe Live.Live → Task ⊤
    dispatch nothing = taskOk tt
    dispatch (just manager) = Live.closeLive manager >>=T λ _ → taskOk tt
