{-# OPTIONS --without-K #-}

-- Convex Live over the pinned `/api/sync` profile.
--
-- One worker owns the socket. It is the only code that connects, reads,
-- writes, retires, reconnects, or changes the query-set version. Public API
-- calls never touch the socket: they append an acknowledged command and wait
-- for the worker's reply, so a subscribe racing a reconnect cannot interleave
-- two writers on one connection.
--
-- Ordering is enforced with a monotonically increasing transport generation.
-- Every published update is stamped with the generation of the connection that
-- produced it, and every barrier -- unsubscribe, same-identifier replacement,
-- and the adapter-only debug disconnect -- advances that generation before the
-- acknowledgement is published. A consumer that already dequeued an update
-- from a retired connection can therefore still recognise and drop it.
module Convex.Live where

open import Convex.Prelude
open import Convex.Prim
open import Convex.Bytes
open import Convex.Reader
open import Convex.Error
open import Convex.Json
open import Convex.Http using (Deployment; secure; host; port; authority; findBlankLine)
open import Convex.WebSocket
open import Convex.Base64 using (timestampEncode; timestampDecode; initialTimestamp)
import Convex.Base64 as Base64
open import Convex.Digest using (fnv1a64)
import Convex.Utf8 as Utf8

--------------------------------------------------------------------------------
-- Bounds and timings
--------------------------------------------------------------------------------

maxSubscriptions : Nat
maxSubscriptions = 64

-- Four times the exact encoded wire length pays for the decoded value, the
-- encoded copy, and the queue record; 4096 octets covers the fixed overhead of
-- the record itself.
subscriptionByteLimit : Nat
subscriptionByteLimit = 8388608

deliveryCountLimit : Nat
deliveryCountLimit = 16

deliveryByteLimit : Nat
deliveryByteLimit = 20971520

initialBackoffMillis : Nat
initialBackoffMillis = 100

maximumBackoffMillis : Nat
maximumBackoffMillis = 15000

commandTimeoutMillis : Nat
commandTimeoutMillis = 6000

writeTimeoutMillis : Nat
writeTimeoutMillis = 2000

connectTimeoutMillis : Nat
connectTimeoutMillis = 4000

maxUint32 : Nat
maxUint32 = 4294967295

--------------------------------------------------------------------------------
-- Shared state
--------------------------------------------------------------------------------

record Subscription : Set where
  constructor subscription
  field
    queryId : Nat
    subPath : String
    subArgs : JSON
    subCharge : Nat
    subActive : Bool
    subSignature : Maybe Nat

open Subscription public

record Update : Set where
  constructor update
  field
    updValue : JSON
    updLogs : List String
    updError : Maybe ConvexError
    updGeneration : Nat

open Update public

record Delivery : Set where
  constructor deliveryOf
  field
    delQueryId : Nat
    delUpdate : Update
    delCharge : Nat

open Delivery public

data Command : Set where
  cmdSubscribe : String → JSON → Command
  cmdUnsubscribe : Nat → Command
  cmdDebugDisconnect : Command
  cmdClose : Command

record Pending : Set where
  constructor pendingOf
  field
    ticket : Nat
    request : Command

open Pending public

record Answer : Set where
  constructor answerOf
  field
    answerTicket : Nat
    answerValue : Either ConvexError Nat

open Answer public

record LiveState : Set where
  constructor liveState
  field
    subs : List Subscription
    activeBytes : Nat
    nextQueryId : Nat
    queue : List Delivery
    queueBytes : Nat
    commands : List Pending
    answers : List Answer
    nextTicket : Nat
    generation : Nat
    connectionCount : Nat
    lastCloseReason : String
    maxObservedTimestamp : Nat
    stopped : Bool

open LiveState public

record Live : Set where
  constructor liveOf
  field
    cell : MVar LiveState
    lvHost : String
    lvPort : Nat
    lvSecure : Bool
    lvAuthority : String
    lvVersion : String

open Live public

emptyState : LiveState
emptyState = liveState [] 0 0 [] 0 [] [] 0 0 0 "InitialConnect" 0 false

-- All shared mutation funnels through here. Taking the cell is the lock, so a
-- reader popping a delivery and the worker publishing one are serialised.
withState : {A : Set} → Live → (LiveState → LiveState × A) → IO A
withState {A} manager step = takeMVar (cell manager) >>= λ current → applyStep (step current)
  where
    applyStep : LiveState × A → IO A
    applyStep (next , result) = putMVar (cell manager) next >> return result

readState : Live → IO LiveState
readState manager = readMVar (cell manager)

--------------------------------------------------------------------------------
-- Update accounting
--------------------------------------------------------------------------------

-- The exact shape that is hashed for the hydration signature and charged for
-- the delivery budget, so the two can never disagree about what an update is.
updateEnvelope : Update → JSON
updateEnvelope u = envelopeOf (updError u)
  where
    logField : JSON
    logField = jarr (map jstr (updLogs u))

    envelopeOf : Maybe ConvexError → JSON
    envelopeOf nothing = jobj (("value" , updValue u) ∷ ("logs" , logField) ∷ [])
    envelopeOf (just e) =
      jobj (("error" , jobj (("name" , jstr (errorName e))
                              ∷ ("message" , jstr (message e))
                              ∷ ("data" , payload e) ∷ []))
              ∷ ("logs" , logField) ∷ [])

updateCharge : Update → Nat
updateCharge u = 4096 + (4 * encodedOctets (updateEnvelope u))

updateSignature : Update → Nat
updateSignature u = fnv1a64 (encodeBytes (updateEnvelope u))

subscriptionCharge : String → JSON → Nat
subscriptionCharge path args = 4096 + (4 * (Utf8.octetLength path + encodedOctets args))

findSub : Nat → List Subscription → Maybe Subscription
findSub _ [] = nothing
findSub target (s ∷ rest) = if queryId s ==ⁿ target then just s else findSub target rest

activeSubs : List Subscription → List Subscription
activeSubs = filter subActive

replaceSub : Subscription → List Subscription → List Subscription
replaceSub _ [] = []
replaceSub updated (s ∷ rest) =
  if queryId s ==ⁿ queryId updated then updated ∷ rest else s ∷ replaceSub updated rest

removeSubById : Nat → List Subscription → List Subscription
removeSubById _ [] = []
removeSubById target (s ∷ rest) =
  if queryId s ==ⁿ target then rest else s ∷ removeSubById target rest

--------------------------------------------------------------------------------
-- The bounded delivery queue
--------------------------------------------------------------------------------

private
  dropOldest : List Delivery → Nat → List Delivery × Nat
  dropOldest [] bytes = ([] , bytes)
  dropOldest (d ∷ rest) bytes = (rest , bytes - delCharge d)

  -- Make room for one more delivery by discarding the globally oldest queued
  -- states. A slow consumer therefore loses intermediate values instead of
  -- growing the queue without bound.
  makeRoom : Nat → List Delivery → Nat → Nat → List Delivery × Nat
  makeRoom zero queued bytes _ = (queued , bytes)
  makeRoom (suc fuel) queued bytes incoming =
    if (length queued ≥ⁿ deliveryCountLimit) ∨ ((bytes + incoming) >ⁿ deliveryByteLimit)
      then trimmed (dropOldest queued bytes)
      else (queued , bytes)
    where
      trimmed : List Delivery × Nat → List Delivery × Nat
      trimmed (rest , remaining) = makeRoom fuel rest remaining incoming

  pushDelivery : LiveState → Delivery → LiveState
  pushDelivery state d =
    placed (makeRoom (suc deliveryCountLimit) (queue state) (queueBytes state) (delCharge d))
    where
      placed : List Delivery × Nat → LiveState
      placed (queued , bytes) =
        record state { queue = queued ++ (d ∷ []) ; queueBytes = bytes + delCharge d }

  popFor : Nat → List Delivery → Maybe (Delivery × List Delivery)
  popFor _ [] = nothing
  popFor target (d ∷ rest) =
    if delQueryId d ==ⁿ target then just (d , rest) else keep (popFor target rest)
    where
      keep : Maybe (Delivery × List Delivery) → Maybe (Delivery × List Delivery)
      keep nothing = nothing
      keep (just (found , remaining)) = just (found , d ∷ remaining)

  purgeFor : Nat → List Delivery → Nat → List Delivery × Nat
  purgeFor _ [] bytes = ([] , bytes)
  purgeFor target (d ∷ rest) bytes =
    if delQueryId d ==ⁿ target
      then purgeFor target rest (bytes - delCharge d)
      else keep (purgeFor target rest bytes)
    where
      keep : List Delivery × Nat → List Delivery × Nat
      keep (kept , remaining) = (d ∷ kept , remaining)

  -- A valid value received just before a transport failure must stay ahead of
  -- the structured failure event, so retiring restamps queued deliveries with
  -- the new generation instead of discarding them. Explicit barriers still
  -- purge.
  rebase : Nat → List Delivery → List Delivery
  rebase _ [] = []
  rebase g (d ∷ rest) =
    deliveryOf (delQueryId d)
      (update (updValue (delUpdate d)) (updLogs (delUpdate d)) (updError (delUpdate d)) g)
      (delCharge d)
      ∷ rebase g rest

--------------------------------------------------------------------------------
-- Publishing
--------------------------------------------------------------------------------

-- Publish a whole Transition atomically. Signatures and charges are computed
-- first, so one malformed member rejects the batch rather than exposing a
-- partially applied state, and an unchanged rehydration is suppressed.
publishBatch : Live → List (Nat × Update) → IO ⊤
publishBatch manager batch = withState manager step
  where
    admit : LiveState → Nat × Update → LiveState
    admit state entry = onSub (findSub (fst entry) (subs state))
      where
        u : Update
        u = snd entry

        signature : Nat
        signature = updateSignature u

        onSub : Maybe Subscription → LiveState
        onSub nothing = state
        onSub (just s) =
          if not (subActive s) then state
          else if isJust (subSignature s) ∧ (fromMaybe 0 (subSignature s) ==ⁿ signature) then state
          else if updateCharge u >ⁿ deliveryByteLimit then state
          else
            pushDelivery
              (record state
                 { subs = replaceSub (record s { subSignature = just signature }) (subs state) })
              (deliveryOf (fst entry) u (updateCharge u))

    step : LiveState → LiveState × ⊤
    step state = (foldl admit state batch , tt)

--------------------------------------------------------------------------------
-- Command plumbing
--------------------------------------------------------------------------------

private
  answerFor : Nat → List Answer → Maybe (Either ConvexError Nat)
  answerFor _ [] = nothing
  answerFor t (a ∷ rest) = if answerTicket a ==ⁿ t then just (answerValue a) else answerFor t rest

  removeAnswer : Nat → List Answer → List Answer
  removeAnswer _ [] = []
  removeAnswer t (a ∷ rest) = if answerTicket a ==ⁿ t then rest else a ∷ removeAnswer t rest

  takeAnswer : Nat → LiveState → LiveState × Maybe (Either ConvexError Nat)
  takeAnswer t state = onFound (answerFor t (answers state))
    where
      onFound : Maybe (Either ConvexError Nat) → LiveState × Maybe (Either ConvexError Nat)
      onFound nothing = (state , nothing)
      onFound (just value) = (record state { answers = removeAnswer t (answers state) } , just value)

  submit : Command → LiveState → LiveState × Either ConvexError Nat
  submit request state =
    if stopped state
      then (state , left (closedFailure "Live client is closed"))
      else
        (record state
           { commands = commands state ++ (pendingOf (nextTicket state) request ∷ [])
           ; nextTicket = suc (nextTicket state) }
        , right (nextTicket state))

  awaitAnswer : Live → Nat → Nat → IO (Either ConvexError Nat)
  awaitStep : Live → Nat → Nat → Maybe (Either ConvexError Nat) → IO (Either ConvexError Nat)

  awaitAnswer _ zero _ = return (left (transportFailure "timed out waiting for the Live worker"))
  awaitAnswer manager (suc fuel) t = withState manager (takeAnswer t) >>= awaitStep manager fuel t

  awaitStep _ _ _ (just value) = return value
  awaitStep manager fuel t nothing = sleepMillis 5 >> awaitAnswer manager fuel t

enqueueCommand : Live → Command → Task Nat
enqueueCommand manager request = withState manager (submit request) >>= dispatch
  where
    dispatch : Either ConvexError Nat → Task Nat
    dispatch (left e) = taskFail e
    dispatch (right t) = awaitAnswer manager ((commandTimeoutMillis div 5) + 16) t

answerCommand : Live → Nat → Either ConvexError Nat → IO ⊤
answerCommand manager t value = withState manager step
  where
    step : LiveState → LiveState × ⊤
    step state = (record state { answers = answers state ++ (answerOf t value ∷ []) } , tt)

--------------------------------------------------------------------------------
-- Public reader API
--------------------------------------------------------------------------------

private
  popUpdate : Nat → LiveState → LiveState × Maybe Update
  popUpdate qid state = onPop (popFor qid (queue state))
    where
      onPop : Maybe (Delivery × List Delivery) → LiveState × Maybe Update
      onPop nothing = (state , nothing)
      onPop (just (d , rest)) =
        (record state { queue = rest ; queueBytes = queueBytes state - delCharge d }
        , just (delUpdate d))

  awaitUpdate : Live → Nat → Nat → Nat → IO (Maybe Update)
  awaitUpdateStep : Live → Nat → Nat → Nat → Maybe Update → IO (Maybe Update)

  awaitUpdate _ zero _ _ = return nothing
  awaitUpdate manager (suc fuel) qid deadline =
    withState manager (popUpdate qid) >>= awaitUpdateStep manager fuel qid deadline

  awaitUpdateStep _ _ _ _ (just u) = return (just u)
  awaitUpdateStep manager fuel qid deadline nothing =
    remainingMillis deadline >>= λ remaining →
    if remaining ==ⁿ 0 then return nothing
    else sleepMillis 5 >> awaitUpdate manager fuel qid deadline

-- Pop the next update for one subscription, or report that the deadline
-- passed. The wait is a bounded poll rather than a condition variable, so the
-- shared state has exactly one synchronisation primitive to audit.
nextUpdate : Live → Nat → Nat → IO (Maybe Update)
nextUpdate manager qid timeoutMs =
  deadlineFrom timeoutMs >>= awaitUpdate manager ((timeoutMs div 5) + 16) qid

liveGeneration : Live → IO Nat
liveGeneration manager = readState manager >>= λ state → return (generation state)

--------------------------------------------------------------------------------
-- Envelope construction
--------------------------------------------------------------------------------

addModification : Subscription → JSON
addModification s =
  jobj (("type" , jstr "Add") ∷ ("queryId" , jnat (queryId s))
          ∷ ("udfPath" , jstr (subPath s)) ∷ ("args" , jarr (subArgs s ∷ [])) ∷ [])

removeModification : Nat → JSON
removeModification qid = jobj (("type" , jstr "Remove") ∷ ("queryId" , jnat qid) ∷ [])

modifyQuerySet : Nat → Nat → List JSON → JSON
modifyQuerySet base next modifications =
  jobj (("type" , jstr "ModifyQuerySet") ∷ ("baseVersion" , jnat base)
          ∷ ("newVersion" , jnat next) ∷ ("modifications" , jarr modifications) ∷ [])

connectMessage : String → Nat → String → Nat → JSON
connectMessage sessionId connections closeReason observed =
  jobj (("type" , jstr "Connect") ∷ ("sessionId" , jstr sessionId)
          ∷ ("connectionCount" , jnat connections)
          ∷ ("lastCloseReason" , jstr closeReason)
          ∷ ("clientTs" , jnat 0)
          ∷ (if observed >ⁿ 0
               then (("maxObservedTimestamp" , jstr (timestampEncode observed)) ∷ [])
               else []))

--------------------------------------------------------------------------------
-- Transition validation
--------------------------------------------------------------------------------

record Version : Set where
  constructor versionOf
  field
    verQuerySet : Nat
    verIdentity : Nat
    verTimestamp : String

open Version public

zeroVersion : Version
zeroVersion = versionOf 0 0 initialTimestamp

sameVersion : Version → Version → Bool
sameVersion a b =
  (verQuerySet a ==ⁿ verQuerySet b) ∧ (verIdentity a ==ⁿ verIdentity b)
    ∧ (verTimestamp a ==ˢ verTimestamp b)

uint32Of : JSON → Maybe Nat
uint32Of value = bounded (asNat value)
  where
    bounded : Maybe Nat → Maybe Nat
    bounded nothing = nothing
    bounded (just n) = if n >ⁿ maxUint32 then nothing else just n

parseVersion : JSON → Either String Version
parseVersion value =
  combine (uint32Of (objOr value "querySet" jnull))
          (uint32Of (objOr value "identity" jnull))
          (asString (objOr value "ts" jnull))
  where
    checked : Nat → Nat → String → Either String Version
    checked qs identity ts =
      if isJust (timestampDecode ts) then right (versionOf qs identity ts)
      else left "Live version timestamp is not canonical"

    combine : Maybe Nat → Maybe Nat → Maybe String → Either String Version
    combine (just qs) (just identity) (just ts) = checked qs identity ts
    combine _ _ _ = left "Live version is malformed"

-- Later modifications for the same query replace earlier ones, which is what
-- makes a Transition carrying several states for one query publish only the
-- final one.
coalesce : List (Nat × Update) → Nat × Update → List (Nat × Update)
coalesce acc entry = filter (λ existing → not (fst existing ==ⁿ fst entry)) acc ++ (entry ∷ [])

private
  logsOf : JSON → Either String (List String)
  logsOf change = fromLogs (asStringList (objOr change "logLines" (jarr [])))
    where
      fromLogs : Maybe (List String) → Either String (List String)
      fromLogs nothing = left "Live logLines must be an array of strings"
      fromLogs (just entries) = right entries

  parsedUpdated : Nat → Nat → JSON → Either String (Maybe (Nat × Update))
  parsedUpdated g qid change =
    if not (objHas change "value") then left "Live QueryUpdated has no value"
    else onLogs (logsOf change)
    where
      onLogs : Either String (List String) → Either String (Maybe (Nat × Update))
      onLogs (left m) = left m
      onLogs (right entries) =
        right (just (qid , update (objOr change "value" jnull) entries nothing g))

  parsedFailed : Nat → Nat → JSON → Either String (Maybe (Nat × Update))
  parsedFailed g qid change = onLogs (logsOf change)
    where
      withMessage : List String → Maybe String → Either String (Maybe (Nat × Update))
      withMessage _ nothing = left "Live QueryFailed errorMessage must be a string"
      withMessage entries (just text) =
        right (just (qid , update jnull entries
                            (just (convexError functionError text
                                     (objOr change "errorData" jnull) entries)) g))

      onLogs : Either String (List String) → Either String (Maybe (Nat × Update))
      onLogs (left m) = left m
      onLogs (right entries) = withMessage entries (asString (objOr change "errorMessage" jnull))

parseModification : Nat → JSON → Either String (Maybe (Nat × Update))
parseModification g change =
  onKind (asString (objOr change "type" jnull)) (uint32Of (objOr change "queryId" jnull))
  where
    onKind : Maybe String → Maybe Nat → Either String (Maybe (Nat × Update))
    onKind _ nothing = left "Live modification queryId is malformed"
    onKind (just "QueryUpdated") (just qid) = parsedUpdated g qid change
    onKind (just "QueryFailed") (just qid) = parsedFailed g qid change
    onKind (just "QueryRemoved") (just _) = right nothing
    onKind _ _ = left "unsupported Live modification"

collectModifications : Nat → List JSON → List (Nat × Update) → Either String (List (Nat × Update))
collectModifications _ [] acc = right acc
collectModifications g (change ∷ rest) acc = onOne (parseModification g change)
  where
    onOne : Either String (Maybe (Nat × Update)) → Either String (List (Nat × Update))
    onOne (left m) = left m
    onOne (right nothing) = collectModifications g rest acc
    onOne (right (just entry)) = collectModifications g rest (coalesce acc entry)

--------------------------------------------------------------------------------
-- Worker-local state
--------------------------------------------------------------------------------

record Owner : Set where
  constructor ownerOf
  field
    sock : Maybe Socket
    inbox : Bytes
    frameDeadline : Maybe Nat
    remote : Version
    querySetVersion : Nat
    fragOpen : Bool
    fragBytes : Bytes
    fragCount : Nat
    backoff : Nat
    connectAt : Maybe Nat

open Owner public

freshOwner : Owner
freshOwner = ownerOf nothing emptyBytes nothing zeroVersion 0 false emptyBytes 0 initialBackoffMillis nothing

-- Everything a retired connection must forget. Keeping it in one place is what
-- guarantees a reconnect cannot inherit a stale query-set version or half a
-- fragmented message.
clearConnection : Owner → Owner
clearConnection owner =
  record owner
    { sock = nothing ; inbox = emptyBytes ; frameDeadline = nothing
    ; remote = zeroVersion ; querySetVersion = 0
    ; fragOpen = false ; fragBytes = emptyBytes ; fragCount = 0 }

--------------------------------------------------------------------------------
-- State transitions used by the worker
--------------------------------------------------------------------------------

private
  bumpGeneration : Live → String → IO Nat
  bumpGeneration manager reason = withState manager step
    where
      step : LiveState → LiveState × Nat
      step state =
        (record state
           { generation = suc (generation state)
           ; connectionCount = suc (connectionCount state)
           ; lastCloseReason = reason }
        , suc (generation state))

  clearQueue : Live → IO ⊤
  clearQueue manager = withState manager step
    where
      step : LiveState → LiveState × ⊤
      step state = (record state { queue = [] ; queueBytes = 0 } , tt)

  rebaseQueue : Live → IO ⊤
  rebaseQueue manager = withState manager step
    where
      step : LiveState → LiveState × ⊤
      step state = (record state { queue = rebase (generation state) (queue state) } , tt)

  dropQuery : Live → Nat → IO ⊤
  dropQuery manager qid = withState manager step
    where
      step : LiveState → LiveState × ⊤
      step state = purged (purgeFor qid (queue state) (queueBytes state))
        where
          purged : List Delivery × Nat → LiveState × ⊤
          purged (kept , bytes) =
            (record state
               { subs = removeSubById qid (subs state)
               ; activeBytes = activeBytes state - fromMaybe 0 (mapMaybe subCharge (findSub qid (subs state)))
               ; queue = kept ; queueBytes = bytes }
            , tt)

  snapshotActive : Live → IO (List Subscription)
  snapshotActive manager = readState manager >>= λ state → return (activeSubs (subs state))

  takeCommands : Live → IO (List Pending)
  takeCommands manager = withState manager step
    where
      step : LiveState → LiveState × List Pending
      step state = (record state { commands = [] } , commands state)

  observeTimestamp : Live → Nat → IO ⊤
  observeTimestamp manager ts = withState manager step
    where
      step : LiveState → LiveState × ⊤
      step state =
        (record state { maxObservedTimestamp = max (maxObservedTimestamp state) ts } , tt)

  connectFields : Live → IO (String × Nat × String × Nat)
  connectFields manager = readState manager >>= λ state →
    randomBytes 16 >>= λ entropy →
    return (hexString entropy , connectionCount state , lastCloseReason state ,
            maxObservedTimestamp state)

  allocate : Live → String → JSON → IO (Either ConvexError Subscription)
  allocate manager path args = withState manager step
    where
      charge : Nat
      charge = subscriptionCharge path args

      step : LiveState → LiveState × Either ConvexError Subscription
      step state =
        if length (activeSubs (subs state)) ≥ⁿ maxSubscriptions then
          (state , left (protocolFailure "Live subscription capacity exceeded"))
        else if (activeBytes state + charge) >ⁿ subscriptionByteLimit then
          (state , left (protocolFailure "Live subscription capacity exceeded"))
        else if nextQueryId state ≥ⁿ maxUint32 then
          (state , left (protocolFailure "Live query identifier space exhausted"))
        else
          (record state
             { subs = subs state ++ (created ∷ [])
             ; activeBytes = activeBytes state + charge
             ; nextQueryId = suc (nextQueryId state) }
          , right created)
        where
          created : Subscription
          created = subscription (nextQueryId state) path args charge true nothing

  markStopped : Live → IO ⊤
  markStopped manager = withState manager step
    where
      step : LiveState → LiveState × ⊤
      step state =
        (record state
           { stopped = true ; subs = [] ; activeBytes = 0 ; queue = [] ; queueBytes = 0 }
        , tt)

--------------------------------------------------------------------------------
-- Retiring and reconnecting
--------------------------------------------------------------------------------

private
  closeSocket : Maybe Socket → Bool → IO ⊤
  closeSocket nothing _ = return tt
  closeSocket (just s) graceful =
    (if graceful then sendClose s writeTimeoutMillis >> return tt else return tt)
      >> socketClose s

  scheduleReconnect : Live → Owner → IO Owner
  scheduleReconnect manager owner =
    snapshotActive manager >>= λ active →
    if length active ==ⁿ 0 then return (record owner { connectAt = nothing })
    else monotonicMillis >>= λ now →
      return (record owner
                { connectAt = just (now + backoff owner)
                ; backoff = min maximumBackoffMillis (backoff owner * 2) })

  -- Retire the current connection. The generation is advanced before anything
  -- else so no consumer can attribute a later value to the old transport.
  retire : Live → Owner → String → Bool → Bool → IO Owner
  retire manager owner reason reconnect graceful =
    closeSocket (sock owner) graceful
      >> bumpGeneration manager reason
      >> after (clearConnection owner)
    where
      after : Owner → IO Owner
      after cleared =
        if reconnect then scheduleReconnect manager cleared
        else return (record cleared { connectAt = nothing })

  -- Publish one recoverable error to every active subscription. The
  -- subscription itself stays alive, which is what lets a later valid value
  -- arrive on the same identifier after a protocol or transport reconnect.
  publishRecoverable : Live → ErrorKind → String → IO ⊤
  publishRecoverable manager k text =
    readState manager >>= λ state →
    publishBatch manager
      (map (λ s → (queryId s , update jnull [] (just (convexError k text jnull [])) (generation state)))
           (activeSubs (subs state)))

  failConnection : Live → Owner → ErrorKind → String → IO Owner
  failConnection manager owner k text =
    retire manager owner text true false
      >>= λ retired → rebaseQueue manager >> publishRecoverable manager k text >> return retired

--------------------------------------------------------------------------------
-- Connecting
--------------------------------------------------------------------------------

private
  sendJson : Socket → JSON → IO (Either String ⊤)
  sendJson s value = sendText s (encode value) writeTimeoutMillis

  resendAdds : Socket → List Subscription → IO (Either String Nat)
  resendAdds _ [] = return (right 0)
  resendAdds s active =
    sendJson s (modifyQuerySet 0 1 (map addModification active)) >>= λ outcome → return (toVersion outcome)
    where
      toVersion : Either String ⊤ → Either String Nat
      toVersion (left m) = left m
      toVersion (right _) = right 1

  -- Read the upgrade response, then verify both the 101 status line and the
  -- accept key derived from the key this client generated.
  finishHandshake : Socket → String → Nat → IO (Either String ⊤)
  finishHandshake s clientKey deadline =
    readUntil 65536 s emptyBytes (λ current → findBlankLine current 0) deadline 16384
      >>= verify
    where
      verify : Either String (Nat × Bytes) → IO (Either String ⊤)
      verify (left m) = return (left m)
      verify (right (headerEnd , buffer)) =
        return (verifyHandshake buffer headerEnd (expectedAccept clientKey))

  openSocket : Live → IO (Either String Socket)
  openSocket manager =
    socketConnect (lvHost manager) (lvPort manager) (lvSecure manager) connectTimeoutMillis
      >>= λ outcome → return (unwrap outcome)
    where
      unwrap : IOResult Socket → Either String Socket
      unwrap (ioOk s) = right s
      unwrap (ioErr diagnostic) = left diagnostic

  handshake : Live → Socket → IO (Either String ⊤)
  handshake manager s =
    randomBytes 16 >>= λ entropy →
    deadlineFrom handshakeMillis >>= λ deadline →
    sendHandshake (Base64.encode entropy) deadline
    where
      sent : String → Nat → Either String ⊤ → IO (Either String ⊤)
      sent _ _ (left m) = return (left m)
      sent clientKey deadline (right _) = finishHandshake s clientKey deadline

      -- Named `sendHandshake`, not `request`: a local binding cannot reuse a
      -- name this module already exports at top level via `open Pending
      -- public` (the `request : Pending → Command` field projection), even
      -- though this `where` clause is otherwise its own scope.
      sendHandshake : String → Nat → IO (Either String ⊤)
      sendHandshake clientKey deadline =
        writeAll s (Utf8.encode (handshakeRequest (lvAuthority manager) "/api/sync"
                                   (lvVersion manager) clientKey))
                writeTimeoutMillis
          >>= sent clientKey deadline

  greet : Live → Socket → IO (Either String Nat)
  greet manager s = connectFields manager >>= send
    where
      adds : Either String ⊤ → IO (Either String Nat)
      adds (left m) = return (left m)
      adds (right _) = snapshotActive manager >>= resendAdds s

      send : String × Nat × String × Nat → IO (Either String Nat)
      send (sessionId , connections , reason , observed) =
        sendJson s (connectMessage sessionId connections reason observed) >>= adds

connectNow : Live → Owner → IO Owner
connectNow manager owner = openSocket manager >>= opened
  where
    give-up : String → IO Owner
    give-up reason =
      bumpGeneration manager reason >> scheduleReconnect manager (clearConnection owner)

    ready : Socket → Nat → IO Owner
    ready s version =
      return (record (clearConnection owner)
                { sock = just s ; querySetVersion = version
                ; backoff = initialBackoffMillis ; connectAt = nothing })

    greeted : Socket → Either String Nat → IO Owner
    greeted s (left m) = socketClose s >> give-up m
    greeted s (right version) = ready s version

    shaken : Socket → Either String ⊤ → IO Owner
    shaken s (left m) = socketClose s >> give-up m
    shaken s (right _) = greet manager s >>= greeted s

    opened : Either String Socket → IO Owner
    opened (left m) = give-up m
    opened (right s) = handshake manager s >>= shaken s

--------------------------------------------------------------------------------
-- Inbound messages
--------------------------------------------------------------------------------

private
  applyTransition : Live → Owner → JSON → IO (Either String Owner)
  applyTransition manager owner event =
    withVersions (parseVersion (objOr event "startVersion" jnull))
                 (parseVersion (objOr event "endVersion" jnull))
    where
      commit : Version → List (Nat × Update) → Nat → IO (Either String Owner)
      commit endVersion batch endTs =
        observeTimestamp manager endTs
          >> publishBatch manager batch
          -- A valid server transition is proof of a healthy connection, so the
          -- transport backoff starts again from its floor.
          >> return (right (record owner
                              { remote = endVersion
                              ; backoff = initialBackoffMillis
                              ; connectAt = nothing }))

      withBatch : Version → Nat → Either String (List (Nat × Update)) → IO (Either String Owner)
      withBatch _ _ (left m) = return (left m)
      withBatch endVersion endTs (right batch) = commit endVersion batch endTs

      ordered : Version → Version → Nat → Nat → IO (Either String Owner)
      ordered startVersion endVersion startTs endTs =
        if endTs <ⁿ startTs then return (left "Live timestamp moved backwards")
        else if not (sameVersion startVersion (remote owner)) then
          return (left "Live transition start version did not match local state")
        else onList (asArray (objOr event "modifications" jnull))
        where
          onList : Maybe (List JSON) → IO (Either String Owner)
          onList nothing = return (left "Live modifications must be an array")
          onList (just changes) =
            readState manager >>= λ state →
            withBatch endVersion endTs (collectModifications (generation state) changes [])

      timestamps : Version → Version → Maybe Nat → Maybe Nat → IO (Either String Owner)
      timestamps startVersion endVersion (just startTs) (just endTs) =
        ordered startVersion endVersion startTs endTs
      timestamps _ _ _ _ = return (left "Live version timestamp is not canonical")

      withVersions : Either String Version → Either String Version → IO (Either String Owner)
      withVersions (left m) _ = return (left m)
      withVersions _ (left m) = return (left m)
      withVersions (right startVersion) (right endVersion) =
        timestamps startVersion endVersion
          (timestampDecode (verTimestamp startVersion))
          (timestampDecode (verTimestamp endVersion))

  handleMessage : Live → Owner → Bytes → IO (Either String Owner)
  handleMessage manager owner body =
    if size body >ⁿ maxMessageOctets then return (left "Live message exceeds the byte budget")
    else decoded (decodeBytes body)
    where
      dispatch : JSON → Maybe String → IO (Either String Owner)
      dispatch event (just "Transition") = applyTransition manager owner event
      dispatch _ (just "Ping") = return (right owner)
      dispatch _ (just "MutationResponse") = return (right owner)
      dispatch _ (just "ActionResponse") = return (right owner)
      dispatch _ _ = return (left "unsupported Live server message")

      decoded : Either String JSON → IO (Either String Owner)
      decoded (left m) = return (left m)
      decoded (right event) = dispatch event (asString (objOr event "type" jnull))

  appendFragment : Owner → Bytes → Either String Owner
  appendFragment owner body =
    if (size (fragBytes owner) + size body) >ⁿ maxMessageOctets then
      left "fragmented Live message exceeds the byte budget"
    else if fragCount owner ≥ⁿ maxFragments then
      left "fragmented Live message has too many frames"
    else
      right (record owner
               { fragBytes = fragBytes owner +++ body ; fragCount = suc (fragCount owner) })

  handleFrame : Live → Owner → Socket → Frame → IO (Either String Owner)
  handleFrame manager owner s f =
    if frameOpcode f ==ⁿ opPing then ponged
    else if frameOpcode f ==ⁿ opPong then return (right owner)
    else if frameOpcode f ==ⁿ opClose then closed
    else if frameOpcode f ==ⁿ opBinary then return (left "binary Live messages are unsupported")
    else if frameOpcode f ==ⁿ opText then textFrame
    else if frameOpcode f ==ⁿ opContinuation then continuationFrame
    else return (left "unsupported WebSocket opcode")
    where
      -- A ping is answered on the same connection. A failed pong means the
      -- transport is already gone, so it is reported rather than swallowed.
      ponged : IO (Either String Owner)
      ponged = sendPong s (framePayload f) writeTimeoutMillis >>= sent
        where
          sent : Either String ⊤ → IO (Either String Owner)
          sent (left m) = return (left m)
          sent (right _) = return (right owner)

      closed : IO (Either String Owner)
      closed =
        if not (closeFrameValid (framePayload f)) then
          return (left "invalid WebSocket close payload")
        else
          failConnection manager owner transportError "Live server closed the WebSocket"
            >>= λ retired → return (right retired)

      assembled : Either String Owner → IO (Either String Owner)
      assembled (left m) = return (left m)
      assembled (right grown) =
        if frameFinal f
          then handleMessage manager
                 (record grown { fragOpen = false ; fragBytes = emptyBytes ; fragCount = 0 })
                 (fragBytes grown)
          else return (right grown)

      textFrame : IO (Either String Owner)
      textFrame =
        if fragOpen owner then return (left "WebSocket fragments arrived out of order")
        else if frameFinal f then handleMessage manager owner (framePayload f)
        else
          assembled (appendFragment
                       (record owner { fragOpen = true ; fragBytes = emptyBytes ; fragCount = 0 })
                       (framePayload f))

      continuationFrame : IO (Either String Owner)
      continuationFrame =
        if not (fragOpen owner) then return (left "WebSocket continuation has no start")
        else assembled (appendFragment owner (framePayload f))

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

private
  sendModification : Owner → JSON → IO (Either String Owner)
  sendModification owner modification = onSocket (sock owner)
    where
      bumped : Nat
      bumped = suc (querySetVersion owner)

      advanced : Either String ⊤ → Either String Owner
      advanced (left m) = left m
      advanced (right _) = right (record owner { querySetVersion = bumped })

      onSocket : Maybe Socket → IO (Either String Owner)
      onSocket nothing = return (left "Live socket is not connected")
      onSocket (just s) =
        if querySetVersion owner ≥ⁿ maxUint32 then return (left "Live query-set version exhausted")
        else
          sendJson s (modifyQuerySet (querySetVersion owner) bumped (modification ∷ []))
            >>= λ outcome → return (advanced outcome)

  doSubscribe : Live → Owner → Nat → String → JSON → IO Owner
  doSubscribe manager owner t path args = allocate manager path args >>= allocated
    where
      -- A partially written Add must not survive: retire first, drop the new
      -- subscription, then fail the acknowledgement.
      failed : Subscription → String → IO Owner
      failed s m =
        dropQuery manager (queryId s)
          >> retire manager owner m true false
          >>= λ retired →
            answerCommand manager t (left (transportFailure ("Live subscribe failed: " <> m)))
              >> return retired

      sent : Subscription → Either String Owner → IO Owner
      sent s (left m) = failed s m
      sent s (right updated) = answerCommand manager t (right (queryId s)) >> return updated

      connected : Subscription → Owner → IO Owner
      connected s attempted = onSocket (sock attempted)
        where
          onSocket : Maybe Socket → IO Owner
          onSocket nothing =
            dropQuery manager (queryId s)
              >> answerCommand manager t
                   (left (transportFailure "Live WebSocket connection failed"))
              >> return attempted
          -- A fresh connection already carried this subscription in its
          -- initial Add batch, so no extra modification is written here.
          onSocket (just _) = answerCommand manager t (right (queryId s)) >> return attempted

      allocated : Either ConvexError Subscription → IO Owner
      allocated (left e) = answerCommand manager t (left e) >> return owner
      allocated (right s) =
        if isJust (sock owner)
          then sendModification owner (addModification s) >>= sent s
          else connectNow manager owner >>= connected s

  doUnsubscribe : Live → Owner → Nat → Nat → IO Owner
  doUnsubscribe manager owner t qid =
    if isJust (sock owner) then sendModification owner (removeModification qid) >>= sent
    else finish owner
    where
      -- Dropping the subscription and advancing the generation happens before
      -- the acknowledgement, so no queued or in-flight value for this query can
      -- cross the acknowledgement barrier.
      finish : Owner → IO Owner
      finish current =
        dropQuery manager qid
          >> bumpGeneration manager "Unsubscribe"
          >> answerCommand manager t (right 0)
          >> return current

      sent : Either String Owner → IO Owner
      sent (left m) = retire manager owner m true false >>= finish
      sent (right updated) = finish updated

  doDebugDisconnect : Live → Owner → Nat → IO Owner
  doDebugDisconnect manager owner t = onSocket (sock owner)
    where
      -- Fault injection is a hard drop with no close frame. The
      -- acknowledgement is published only after the old transport is retired,
      -- the queue is purged, and the reconnect is scheduled.
      onSocket : Maybe Socket → IO Owner
      onSocket nothing =
        answerCommand manager t (left (transportFailure "Live WebSocket is not connected"))
          >> return owner
      onSocket (just s) =
        socketClose s
          >> bumpGeneration manager "DebugDisconnect"
          >>= λ g → clearQueue manager
          >> monotonicMillis >>= λ now →
            answerCommand manager t (right g)
              >> return (record (clearConnection owner)
                           { connectAt = just (now + initialBackoffMillis)
                           ; backoff = 2 * initialBackoffMillis })

  doClose : Live → Owner → Nat → IO Owner
  doClose manager owner t =
    markStopped manager
      >> retire manager owner "ClientClosed" false true
      >>= λ retired → answerCommand manager t (right 0) >> return retired

  runCommand : Live → Owner → Pending → IO Owner
  runCommand manager owner p = dispatch (request p)
    where
      dispatch : Command → IO Owner
      dispatch (cmdSubscribe path args) = doSubscribe manager owner (ticket p) path args
      dispatch (cmdUnsubscribe qid) = doUnsubscribe manager owner (ticket p) qid
      dispatch cmdDebugDisconnect = doDebugDisconnect manager owner (ticket p)
      dispatch cmdClose = doClose manager owner (ticket p)

  runCommands : List Pending → Live → Owner → IO Owner
  runCommands [] _ owner = return owner
  runCommands (p ∷ rest) manager owner = runCommand manager owner p >>= runCommands rest manager

--------------------------------------------------------------------------------
-- The worker loop
--------------------------------------------------------------------------------

private
  -- The connection is only allowed to be silent for this long once octets of a
  -- frame have been consumed.
  armDeadline : Owner → IO Owner
  armDeadline owner =
    if isJust (frameDeadline owner) then return owner
    else monotonicMillis >>= λ now → return (record owner { frameDeadline = just (now + frameMillis) })

  expired : Owner → IO Bool
  expired owner = onDeadline (frameDeadline owner)
    where
      onDeadline : Maybe Nat → IO Bool
      onDeadline nothing = return false
      onDeadline (just deadline) = monotonicMillis >>= λ now → return (now >ⁿ deadline)

  dueToConnect : Owner → IO Bool
  dueToConnect owner = onSchedule (connectAt owner)
    where
      onSchedule : Maybe Nat → IO Bool
      onSchedule nothing = return true
      onSchedule (just at) = monotonicMillis >>= λ now → return (now ≥ⁿ at)

{-# TERMINATING #-}
-- This is a service loop: it runs until a `close` command sets the stopped
-- flag. The recursion is deliberately unbounded, and every step inside it is
-- bounded by a deadline or a fuelled helper.
workerLoop : Live → Owner → IO ⊤
workerLoop manager owner =
  takeCommands manager >>= λ pending →
  runCommands pending manager owner >>= afterCommands
  where
    onFrame : Owner → Either String Owner → IO ⊤
    onFrame current (left m) =
      failConnection manager current protocolError m >>= workerLoop manager
    onFrame _ (right updated) = workerLoop manager (record updated { frameDeadline = nothing })

    onStep : Owner → Step → IO ⊤
    onStep current (stepFrame f rest) = onSocket (sock current)
      where
        onSocket : Maybe Socket → IO ⊤
        onSocket nothing = workerLoop manager (record current { inbox = rest })
        onSocket (just s) =
          handleFrame manager (record current { inbox = rest }) s f
            >>= onFrame (record current { inbox = rest })
    onStep current (stepPending grown) =
      armDeadline (record current { inbox = grown }) >>= λ armed →
      expired armed >>= λ late →
      if late
        then failConnection manager armed transportError "Live frame deadline expired"
               >>= workerLoop manager
        else workerLoop manager armed
    onStep current (stepIdle grown) =
      workerLoop manager (record current { inbox = grown ; frameDeadline = nothing })
    onStep current (stepFailed m) =
      failConnection manager current transportError m >>= workerLoop manager

    pump : Owner → Socket → IO ⊤
    pump current s = frameStep s (inbox current) sliceMillis >>= onStep current

    idle : Owner → IO ⊤
    idle current =
      snapshotActive manager >>= λ active →
      dueToConnect current >>= λ due →
      if (length active >ⁿ 0) ∧ due then connectNow manager current >>= workerLoop manager
      else sleepMillis 10 >> workerLoop manager current

    running : Owner → LiveState → IO ⊤
    running current state =
      if stopped state then return tt
      else onSocket (sock current)
      where
        onSocket : Maybe Socket → IO ⊤
        onSocket (just s) = pump current s
        onSocket nothing = idle current

    afterCommands : Owner → IO ⊤
    afterCommands current = readState manager >>= running current

--------------------------------------------------------------------------------
-- Starting a manager
--------------------------------------------------------------------------------

startLive : Deployment → String → IO Live
startLive dep version =
  newMVar emptyState >>= λ manager →
  started (liveOf manager (host dep) (port dep) (secure dep) (authority dep) version)
  where
    started : Live → IO Live
    started manager = forkThread (workerLoop manager freshOwner) >> return manager

--------------------------------------------------------------------------------
-- Public Live API
--------------------------------------------------------------------------------

subscribe : Live → String → JSON → Task Nat
subscribe manager path args = enqueueCommand manager (cmdSubscribe path args)

unsubscribe : Live → Nat → Task Nat
unsubscribe manager qid = enqueueCommand manager (cmdUnsubscribe qid)

-- Adapter-only fault injection. It is deliberately absent from the educational
-- client surface in `Convex`; only the conformance executable reaches it.
debugDisconnect : Live → Task Nat
debugDisconnect manager = enqueueCommand manager cmdDebugDisconnect

closeLive : Live → Task Nat
closeLive manager = enqueueCommand manager cmdClose
