{-# OPTIONS --without-K #-}

-- The test-only conformance executable.
--
-- This is not public client code. It speaks NDJSON adapter protocol v1 over
-- stdin/stdout, or over one accepted connection when `ADAPTER_LISTEN` is set,
-- and calls the real `Convex.Client` for every operation.
--
-- Two properties are the reason this file is longer than a thin shim.
--
-- Admission control: every event is encoded once, charged its exact octet
-- length, and only then admitted to a bounded queue. The charge is retained
-- while a write is in flight, so a controller that stops reading cannot park
-- unaccounted bytes inside a blocked writer. Subscription values are
-- droppable under pressure; acknowledgements and errors wait for room until a
-- deadline and then fail the connection rather than being silently lost.
--
-- Barriers: replacement, unsubscribe, and `debugDisconnect` each advance a
-- generation under the publication lock before their acknowledgement is
-- queued. A relay that had already dequeued an update re-checks both its own
-- generation and the client's transport generation before publishing, so no
-- stale value can cross an acknowledgement.
module Adapter where

open import Convex.Prelude
open import Convex.Prim
open import Convex.Bytes
open import Convex.Reader
open import Convex.Json
open import Convex.Error
open import Convex.Client
open import Convex.Live using (Update; updValue; updLogs; updError; updGeneration)
import Convex.Utf8 as Utf8

--------------------------------------------------------------------------------
-- Bounds
--------------------------------------------------------------------------------

adapterLineOctets : Nat
adapterLineOctets = 1048576

outputCountLimit : Nat
outputCountLimit = 16

outputByteLimit : Nat
outputByteLimit = 6291456

admissionMillis : Nat
admissionMillis = 5000

relayPollMillis : Nat
relayPollMillis = 50

--------------------------------------------------------------------------------
-- Channels
--------------------------------------------------------------------------------

data Channel : Set where
  stdioChannel : Channel
  socketChannel : Socket → Channel

channelRecv : Channel → Nat → Nat → IO RecvResult
channelRecv stdioChannel wanted timeoutMs = stdinRecv wanted timeoutMs
channelRecv (socketChannel s) wanted timeoutMs = socketRecv s wanted timeoutMs

channelSend : Channel → Bytes → IO (Either String ⊤)
channelSend stdioChannel body = stdoutWrite body >>= λ outcome → return (unwrap outcome)
  where
    unwrap : IOResult ⊤ → Either String ⊤
    unwrap (ioOk _) = right tt
    unwrap (ioErr diagnostic) = left diagnostic
channelSend (socketChannel s) body = writeAll s body 5000

--------------------------------------------------------------------------------
-- Bounded output
--------------------------------------------------------------------------------

record OutItem : Set where
  constructor outItem
  field
    itemBytes : Bytes
    itemCharge : Nat
    itemDroppable : Bool

open OutItem public

record Sink : Set where
  constructor sinkOf
  field
    items : List OutItem
    queuedBytes : Nat
    inFlightBytes : Nat
    sinkClosed : Bool
    sinkFailed : Bool

open Sink public

initialSink : Sink
initialSink = sinkOf [] 0 0 false false

sinkCount : Sink → Nat
sinkCount s = length (items s) + (if inFlightBytes s >ⁿ 0 then 1 else 0)

sinkTotal : Sink → Nat
sinkTotal s = queuedBytes s + inFlightBytes s

private
  -- Drop the oldest droppable item. Only subscription values are droppable, so
  -- an acknowledgement never disappears to make room.
  dropDroppable : List OutItem → Nat → Maybe (List OutItem × Nat)
  dropDroppable [] _ = nothing
  dropDroppable (x ∷ rest) bytes =
    if itemDroppable x then just (rest , bytes - itemCharge x) else keep (dropDroppable rest bytes)
    where
      keep : Maybe (List OutItem × Nat) → Maybe (List OutItem × Nat)
      keep nothing = nothing
      keep (just (kept , remaining)) = just (x ∷ kept , remaining)

data Admission : Set where
  admitted : Admission
  coalesced : Admission
  backpressured : Admission
  sinkGone : Admission

tryAdmit : OutItem → Sink → Sink × Admission
tryAdmit item s =
  if sinkClosed s ∨ sinkFailed s then (s , sinkGone)
  else if itemCharge item >ⁿ outputByteLimit then (s , sinkGone)
  else fit (suc outputCountLimit) s
  where
    room : Sink → Bool
    room current =
      (sinkCount current <ⁿ outputCountLimit)
        ∧ ((sinkTotal current + itemCharge item) ≤ⁿ outputByteLimit)

    place : Sink → Sink × Admission
    place current =
      (record current
         { items = items current ++ (item ∷ [])
         ; queuedBytes = queuedBytes current + itemCharge item }
      , admitted)

    fit : Nat → Sink → Sink × Admission
    fit zero current = (current , backpressured)
    fit (suc fuel) current =
      if room current then place current
      else shed (dropDroppable (items current) (queuedBytes current))
      where
        shed : Maybe (List OutItem × Nat) → Sink × Admission
        shed nothing =
          if itemDroppable item then (current , coalesced) else (current , backpressured)
        shed (just (kept , bytes)) =
          fit fuel (record current { items = kept ; queuedBytes = bytes })

-- Moving one item into the writer keeps its charge accounted for while the
-- write is outstanding, which is what stops a stopped reader from hiding bytes
-- inside a blocked syscall.
takeItem : Sink → Sink × Maybe OutItem
takeItem s = onItems (items s)
  where
    onItems : List OutItem → Sink × Maybe OutItem
    onItems [] = (s , nothing)
    onItems (x ∷ rest) =
      (record s
         { items = rest
         ; queuedBytes = queuedBytes s - itemCharge x
         ; inFlightBytes = itemCharge x }
      , just x)

clearInFlight : Sink → Sink × ⊤
clearInFlight s = (record s { inFlightBytes = 0 } , tt)

private
  markFailed : Sink → Sink × ⊤
  markFailed s = (record s { sinkFailed = true ; inFlightBytes = 0 } , tt)

  markClosed : Sink → Sink × ⊤
  markClosed s = (record s { sinkClosed = true } , tt)

--------------------------------------------------------------------------------
-- Adapter state
--------------------------------------------------------------------------------

record Relay : Set where
  constructor relayOf
  field
    relayId : String
    relayQuery : Nat
    relayGeneration : Nat
    relayActive : Bool

open Relay public

record Adapter : Set where
  constructor adapterOf
  field
    relays : List Relay
    counters : List (String × Nat)
    minGeneration : Nat
    adapterClosed : Bool
    greeted : Bool

open Adapter public

initialAdapter : Adapter
initialAdapter = adapterOf [] [] 0 false false

record Runtime : Set where
  constructor runtimeOf
  field
    channel : Channel
    sinkCell : MVar Sink
    adapterCell : MVar Adapter
    -- One publication lock orders acknowledgements against relay events, and
    -- one dequeue lock ensures at most one relay holds an uncharged update.
    publishLock : MVar ⊤
    dequeueLock : MVar ⊤
    clientCell : MVar (Maybe Client)

open Runtime public

private
  modifySink : {A : Set} → Runtime → (Sink → Sink × A) → IO A
  modifySink {A} rt step = takeMVar (sinkCell rt) >>= λ current → apply (step current)
    where
      apply : Sink × A → IO A
      apply (next , result) = putMVar (sinkCell rt) next >> return result

  modifyState : {A : Set} → Runtime → (Adapter → Adapter × A) → IO A
  modifyState {A} rt step = takeMVar (adapterCell rt) >>= λ current → apply (step current)
    where
      apply : Adapter × A → IO A
      apply (next , result) = putMVar (adapterCell rt) next >> return result

  acquire : MVar ⊤ → IO ⊤
  acquire lockRef = takeMVar lockRef

  releaseLock : MVar ⊤ → IO ⊤
  releaseLock lockRef = putMVar lockRef tt

--------------------------------------------------------------------------------
-- The writer worker
--------------------------------------------------------------------------------

{-# TERMINATING #-}
-- A service loop: it drains the queue until the sink is closed and empty.
writerLoop : Runtime → IO ⊤
writerLoop rt = modifySink rt takeItem >>= dispatch
  where
    afterWrite : Either String ⊤ → IO ⊤
    afterWrite (left _) = modifySink rt markFailed >> return tt
    afterWrite (right _) = modifySink rt clearInFlight >> writerLoop rt

    idle : IO ⊤
    idle =
      readMVar (sinkCell rt) >>= λ current →
      if sinkClosed current then return tt else sleepMillis 5 >> writerLoop rt

    dispatch : Maybe OutItem → IO ⊤
    dispatch nothing = idle
    dispatch (just item) = channelSend (channel rt) (itemBytes item) >>= afterWrite

-- Encode once, charge the exact octet length, then admit. Encoding under the
-- publication lock also bounds the uncharged encoder working set to one event
-- even when several relays publish at the same time.
publish : Runtime → JSON → Bool → IO Admission
publish rt event droppable = deadlineFrom admissionMillis >>= attempt ((admissionMillis div 5) + 16)
  where
    body : Bytes
    body = Utf8.encode (encode event <> "\n")

    item : OutItem
    item = outItem body (size body) droppable

    attempt : Nat → Nat → IO Admission
    onOutcome : Nat → Nat → Admission → IO Admission

    attempt zero _ = return backpressured
    attempt (suc fuel) deadline = modifySink rt (tryAdmit item) >>= onOutcome fuel deadline

    onOutcome _ _ admitted = return admitted
    onOutcome _ _ coalesced = return coalesced
    onOutcome _ _ sinkGone = return sinkGone
    onOutcome fuel deadline backpressured =
      remainingMillis deadline >>= λ remaining →
      if remaining ==ⁿ 0 then return backpressured
      else sleepMillis 5 >> attempt fuel deadline

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

-- Optional fields are omitted rather than serialised as null, which is what
-- the shared schema requires.
resultEvent : String → CallResult → JSON
resultEvent commandId result =
  jobj (("id" , jstr commandId) ∷ ("type" , jstr "result")
          ∷ ("value" , resultValue result)
          ∷ (if length (resultLogs result) >ⁿ 0
               then (("logs" , jarr (map jstr (resultLogs result))) ∷ [])
               else []))

ackEvent : String → JSON
ackEvent commandId = jobj (("id" , jstr commandId) ∷ ("type" , jstr "ack") ∷ [])

closedEvent : String → JSON
closedEvent commandId = jobj (("id" , jstr commandId) ∷ ("type" , jstr "closed") ∷ [])

readyEvent : String → JSON
readyEvent commandId =
  jobj (("protocolVersion" , jnat 1) ∷ ("id" , jstr commandId) ∷ ("type" , jstr "ready")
          ∷ ("language" , jstr "agda")
          ∷ ("implementation" , jstr "native-agda-2.7.0.1")
          ∷ ("runtime" , jstr "Agda 2.7.0.1 (GHC 9.10.1)") ∷ [])

errorBody : ConvexError → JSON
errorBody e =
  jobj (("name" , jstr (errorName e)) ∷ ("message" , jstr (message e))
          ∷ ("data" , payload e) ∷ [])

errorEvent : Maybe String → ConvexError → JSON
errorEvent commandId e =
  jobj ((if isJust commandId then (("id" , jstr (fromMaybe "" commandId)) ∷ []) else [])
          ++ (("type" , jstr "error") ∷ ("error" , errorBody e) ∷ [])
          ++ (if length (logs e) >ⁿ 0 then (("logs" , jarr (map jstr (logs e))) ∷ []) else []))

subscriptionEvent : String → Update → JSON
subscriptionEvent subscriptionId u = onError (updError u)
  where
    logFields : List (String × JSON)
    logFields =
      if length (updLogs u) >ⁿ 0 then (("logs" , jarr (map jstr (updLogs u))) ∷ []) else []

    onError : Maybe ConvexError → JSON
    onError nothing =
      jobj ((("type" , jstr "subscription") ∷ ("subscriptionId" , jstr subscriptionId)
               ∷ ("value" , updValue u) ∷ []) ++ logFields)
    onError (just e) =
      jobj ((("type" , jstr "subscription") ∷ ("subscriptionId" , jstr subscriptionId)
               ∷ ("error" , errorBody e) ∷ []) ++ logFields)

--------------------------------------------------------------------------------
-- Generations and relays
--------------------------------------------------------------------------------

private
  counterFor : String → List (String × Nat) → Nat
  counterFor _ [] = 0
  counterFor target ((k , v) ∷ rest) = if k ==ˢ target then v else counterFor target rest

  bumpCounter : String → List (String × Nat) → List (String × Nat)
  bumpCounter target [] = (target , 1) ∷ []
  bumpCounter target ((k , v) ∷ rest) =
    if k ==ˢ target then (k , suc v) ∷ rest else (k , v) ∷ bumpCounter target rest

  findRelay : String → List Relay → Maybe Relay
  findRelay _ [] = nothing
  findRelay target (r ∷ rest) = if relayId r ==ˢ target then just r else findRelay target rest

  dropRelay : String → List Relay → List Relay
  dropRelay _ [] = []
  dropRelay target (r ∷ rest) = if relayId r ==ˢ target then rest else r ∷ dropRelay target rest

  -- Advance the identifier's generation and forget the record. Callers hold
  -- the publication lock, so the barrier is established before any
  -- acknowledgement is queued.
  invalidate : String → Adapter → Adapter × Maybe Relay
  invalidate subscriptionId state =
    (record state
       { counters = bumpCounter subscriptionId (counters state)
       ; relays = dropRelay subscriptionId (relays state) }
    , findRelay subscriptionId (relays state))

  registerRelay : String → Nat → Adapter → Adapter × Nat
  registerRelay subscriptionId qid state = (next , counterFor subscriptionId (counters next))
    where
      next : Adapter
      next =
        record state
          { counters = bumpCounter subscriptionId (counters state)
          ; relays = relayOf subscriptionId qid (suc (counterFor subscriptionId (counters state))) true
                       ∷ dropRelay subscriptionId (relays state) }

  currentGeneration : String → Adapter → Adapter × Nat
  currentGeneration subscriptionId state = (state , counterFor subscriptionId (counters state))

  setMinimum : Nat → Adapter → Adapter × ⊤
  setMinimum g state = (record state { minGeneration = max (minGeneration state) g } , tt)

  liveRelay : String → Adapter → Adapter × Maybe Relay
  liveRelay subscriptionId state = (state , findRelay subscriptionId (relays state))

  isClosed : Adapter → Adapter × Bool
  isClosed state = (state , adapterClosed state)

--------------------------------------------------------------------------------
-- The relay worker
--------------------------------------------------------------------------------

private
  clientOr : Runtime → IO (Maybe Client)
  clientOr rt = readMVar (clientCell rt)

  -- Re-check both generations under the publication lock. An update dequeued
  -- before a replacement, unsubscribe, or debug barrier fails this check and
  -- is discarded instead of crossing the acknowledgement.
  publishRelay : Runtime → Client → String → Nat → Update → IO ⊤
  publishRelay rt client subscriptionId generation u =
    acquire (publishLock rt)
      >> modifyState rt (currentGeneration subscriptionId)
      >>= λ live →
        readMVar (adapterCell rt) >>= λ state →
        clientLiveGeneration client >>= λ transport →
        decide live state transport
    where
      finish : IO ⊤
      finish = releaseLock (publishLock rt)

      decide : Nat → Adapter → Nat → IO ⊤
      decide live state transport =
        if not (live ==ⁿ generation) then finish
        else if updGeneration u <ⁿ max (minGeneration state) transport then finish
        else publish rt (subscriptionEvent subscriptionId u) true >> finish

{-# TERMINATING #-}
-- A service loop: it polls one subscription until the identifier is
-- invalidated or the adapter closes.
relayLoop : Runtime → String → Nat → Nat → IO ⊤
relayLoop rt subscriptionId qid generation =
  modifyState rt (liveRelay subscriptionId) >>= alive
  where
    resume : IO ⊤
    resume = relayLoop rt subscriptionId qid generation

    onUpdate : Client → Maybe Update → IO ⊤
    onUpdate _ nothing = releaseLock (dequeueLock rt) >> resume
    onUpdate client (just u) =
      publishRelay rt client subscriptionId generation u
        >> releaseLock (dequeueLock rt)
        >> resume

    poll : Maybe Client → IO ⊤
    poll nothing = return tt
    poll (just client) =
      acquire (dequeueLock rt)
        >> clientNext client qid relayPollMillis
        >>= onUpdate client

    alive : Maybe Relay → IO ⊤
    alive nothing = return tt
    alive (just r) =
      if not (relayGeneration r ==ⁿ generation) then return tt
      else modifyState rt isClosed >>= λ stopped →
        if stopped then return tt else clientOr rt >>= poll

--------------------------------------------------------------------------------
-- Command validation
--------------------------------------------------------------------------------

private
  fieldNames : JSON → List String
  fieldNames value = map fst (fromMaybe [] (objectFields value))

  elemString : String → List String → Bool
  elemString target = any (λ x → x ==ˢ target)

  duplicated : List String → Bool
  duplicated [] = false
  duplicated (x ∷ rest) = elemString x rest ∨ duplicated rest

  shapeFor : String → Maybe (List String × List String)
  shapeFor "hello" = just (("protocolVersion" ∷ "id" ∷ "op" ∷ []) , ("protocolVersion" ∷ "id" ∷ "op" ∷ []))
  shapeFor "query" = just (("id" ∷ "op" ∷ "path" ∷ "args" ∷ []) , ("id" ∷ "op" ∷ "path" ∷ "args" ∷ []))
  shapeFor "mutation" = shapeFor "query"
  shapeFor "action" = shapeFor "query"
  shapeFor "subscribe" =
    just (("id" ∷ "op" ∷ "subscriptionId" ∷ "path" ∷ "args" ∷ []) , ("id" ∷ "op" ∷ "subscriptionId" ∷ []))
  shapeFor "unsubscribe" = shapeFor "subscribe"
  shapeFor "setAuth" = just (("id" ∷ "op" ∷ "token" ∷ []) , ("id" ∷ "op" ∷ "token" ∷ []))
  shapeFor "close" = just (("id" ∷ "op" ∷ []) , ("id" ∷ "op" ∷ []))
  shapeFor "debugDisconnect" = shapeFor "close"
  shapeFor _ = nothing

  shortString : Maybe JSON → Maybe String
  shortString nothing = nothing
  shortString (just value) = bounded (asString value)
    where
      bounded : Maybe String → Maybe String
      bounded nothing = nothing
      bounded (just text) =
        if (stringLength text ≥ⁿ 1) ∧ (stringLength text ≤ⁿ 128) then just text else nothing

  -- Strict shape validation: unknown fields, duplicate fields, missing
  -- required fields, and mistyped `args`/`path` are all rejected before the
  -- client is called.
  validateShapeInner : JSON → String → Maybe String
  validateShapeInner command operation = onShape (shapeFor operation)
    where
      names : List String
      names = fieldNames command

      missing : List String → Maybe String
      missing [] = nothing
      missing (k ∷ rest) =
        if objHas command k then missing rest else just "adapter command is missing a required field"

      unknown : List String → List String → Maybe String
      unknown _ [] = nothing
      unknown allowed (k ∷ rest) =
        if elemString k allowed then unknown allowed rest
        else just "adapter command contains an unknown field"

      typed : Maybe String
      typed =
        if objHas command "args" ∧ not (isObject (objOr command "args" jnull)) then
          just "adapter args must be a JSON object"
        else if objHas command "path" ∧ not (isJust (asString (objOr command "path" jnull))) then
          just "adapter path must be a string"
        else if elemString operation ("query" ∷ "mutation" ∷ "action" ∷ [])
                 ∧ (stringLength (fromMaybe "" (asString (objOr command "path" jnull))) <ⁿ 3) then
          just "adapter path must contain at least three characters"
        else nothing

      onShape : Maybe (List String × List String) → Maybe String
      onShape nothing = just "unknown adapter operation"
      onShape (just (allowed , required)) =
        if duplicated names then just "adapter command contains a duplicate field"
        else combine (unknown allowed names) (missing required)
        where
          combine : Maybe String → Maybe String → Maybe String
          combine (just m) _ = just m
          combine nothing (just m) = just m
          combine nothing nothing = typed

validateShape : JSON → String → Maybe String
validateShape = validateShapeInner

--------------------------------------------------------------------------------
-- Command handling
--------------------------------------------------------------------------------

private
  publishLocked : Runtime → JSON → IO ⊤
  publishLocked rt event =
    acquire (publishLock rt) >> publish rt event false >> releaseLock (publishLock rt)

  reportError : Runtime → Maybe String → ConvexError → IO ⊤
  reportError rt commandId e = publishLocked rt (errorEvent commandId e)

  ensureClient : Runtime → IO (Either ConvexError Client)
  ensureClient rt = takeMVar (clientCell rt) >>= dispatch
    where
      restore : Maybe Client → Either ConvexError Client → IO (Either ConvexError Client)
      restore stored outcome = putMVar (clientCell rt) stored >> return outcome

      built : Either ConvexError Client → IO (Either ConvexError Client)
      built (left e) = restore nothing (left e)
      built (right client) = restore (just client) (right client)

      created : Maybe String → IO (Either ConvexError Client)
      created nothing = restore nothing (left (protocolFailure "CONVEX_URL is required"))
      created (just url) = newClient url "agda-0.1.0" >>= built

      dispatch : Maybe Client → IO (Either ConvexError Client)
      dispatch (just existing) = restore (just existing) (right existing)
      dispatch nothing = getEnvironment "CONVEX_URL" >>= created

  runCall : Runtime → String → String → JSON → String → Client → IO ⊤
  runCall rt commandId operation command path client = chosen >>= publishOutcome
    where
      args : JSON
      args = objOr command "args" (jobj [])

      chosen : Task CallResult
      chosen =
        if operation ==ˢ "query" then clientQuery client path args
        else if operation ==ˢ "mutation" then clientMutation client path args
        else clientAction client path args

      publishOutcome : Either ConvexError CallResult → IO ⊤
      publishOutcome (left e) = reportError rt (just commandId) e
      publishOutcome (right result) = publishLocked rt (resultEvent commandId result)

  -- Registration and the acknowledgement are one publication transaction. The
  -- relay starts afterwards, so an already-hydrated value cannot overtake a
  -- replacement acknowledgement.
  doSubscribe : Runtime → String → String → String → JSON → Client → IO ⊤
  doSubscribe rt commandId subscriptionId path args client =
    acquire (publishLock rt)
      >> modifyState rt (invalidate subscriptionId)
      >>= λ previous →
        releaseLock (publishLock rt)
          >> retirePrevious previous
          >> clientSubscribe client path args
          >>= subscribed
    where
      -- The replaced subscription is removed from the client before the new
      -- one is created, so the old query cannot keep delivering values.
      retirePrevious : Maybe Relay → IO ⊤
      retirePrevious nothing = return tt
      retirePrevious (just old) = clientUnsubscribe client (relayQuery old) >> return tt

      registered : Nat → IO ⊤
      registered qid =
        acquire (publishLock rt)
          >> modifyState rt (registerRelay subscriptionId qid)
          >>= λ generation →
            publish rt (ackEvent commandId) false
              >> releaseLock (publishLock rt)
              >> forkThread (relayLoop rt subscriptionId qid generation)

      subscribed : Either ConvexError Nat → IO ⊤
      subscribed (left e) = reportError rt (just commandId) e
      subscribed (right qid) = registered qid

  doUnsubscribe : Runtime → String → String → Client → IO ⊤
  doUnsubscribe rt commandId subscriptionId client =
    acquire (publishLock rt)
      >> modifyState rt (invalidate subscriptionId)
      >>= dropped
    where
      finish : IO ⊤
      finish = publish rt (ackEvent commandId) false >> releaseLock (publishLock rt)

      dropped : Maybe Relay → IO ⊤
      dropped nothing = finish
      dropped (just r) = clientUnsubscribe client (relayQuery r) >> finish

  -- The publication lock is held across the client barrier, so a relay that
  -- already dequeued an old update can only resume after the new minimum
  -- generation and the acknowledgement have been published.
  doDebugDisconnect : Runtime → String → Client → IO ⊤
  doDebugDisconnect rt commandId client =
    acquire (publishLock rt) >> clientDebugDisconnect client >>= dropped
    where
      dropped : Either ConvexError Nat → IO ⊤
      dropped (left e) =
        releaseLock (publishLock rt) >> reportError rt (just commandId) e
      dropped (right generation) =
        modifyState rt (setMinimum generation)
          >> publish rt (ackEvent commandId) false
          >> releaseLock (publishLock rt)

  markAdapterClosed : Adapter → Adapter × ⊤
  markAdapterClosed state = (record state { adapterClosed = true ; relays = [] } , tt)

  markGreeted : Adapter → Adapter × Bool
  markGreeted state = (record state { greeted = true } , greeted state)

  needsGreeting : Adapter → Adapter × Bool
  needsGreeting state = (state , greeted state)

handleCommand : Runtime → JSON → IO ⊤
handleCommand rt command = onId (shortString (objGet command "id")) (asString (objOr command "op" jnull))
  where
    withClient : String → (Client → IO ⊤) → IO ⊤
    withClient commandId body = ensureClient rt >>= dispatch
      where
        dispatch : Either ConvexError Client → IO ⊤
        dispatch (left e) = reportError rt (just commandId) e
        dispatch (right client) = body client

    hello : String → IO ⊤
    hello commandId = modifyState rt markGreeted >>= dispatch
      where
        dispatch : Bool → IO ⊤
        dispatch true =
          reportError rt (just commandId) (protocolFailure "hello may only be sent once")
        dispatch false =
          if not (fromMaybe 0 (asNat (objOr command "protocolVersion" jnull)) ==ⁿ 1) then
            reportError rt (just commandId) (protocolFailure "unsupported adapter protocol version")
          else publishLocked rt (readyEvent commandId)

    subscribeOp : String → IO ⊤
    subscribeOp commandId = onSubscriptionId (shortString (objGet command "subscriptionId"))
      where
        onSubscriptionId : Maybe String → IO ⊤
        onSubscriptionId nothing =
          reportError rt (just commandId)
            (protocolFailure "subscriptionId must contain 1 to 128 characters")
        onSubscriptionId (just subscriptionId) =
          withClient commandId
            (doSubscribe rt commandId subscriptionId
               (fromMaybe "" (asString (objOr command "path" jnull)))
               (objOr command "args" (jobj [])))

    unsubscribeOp : String → IO ⊤
    unsubscribeOp commandId = onSubscriptionId (shortString (objGet command "subscriptionId"))
      where
        onSubscriptionId : Maybe String → IO ⊤
        onSubscriptionId nothing =
          reportError rt (just commandId)
            (protocolFailure "subscriptionId must contain 1 to 128 characters")
        onSubscriptionId (just subscriptionId) =
          withClient commandId (doUnsubscribe rt commandId subscriptionId)

    setAuthOp : String → IO ⊤
    setAuthOp commandId = onToken (asString (objOr command "token" jnull))
      where
        applied : Client → Either ConvexError ⊤ → IO ⊤
        applied _ (left e) = reportError rt (just commandId) e
        applied _ (right _) = publishLocked rt (ackEvent commandId)

        onToken : Maybe String → IO ⊤
        onToken nothing =
          reportError rt (just commandId) (protocolFailure "token must be a string")
        onToken (just value) =
          withClient commandId (λ client → setAuth client value >>= applied client)

    closeOp : String → IO ⊤
    closeOp commandId =
      modifyState rt markAdapterClosed
        >> readMVar (clientCell rt) >>= shutdown
        >> publishLocked rt (closedEvent commandId)
      where
        shutdown : Maybe Client → IO ⊤
        shutdown nothing = return tt
        shutdown (just client) = clientClose client >> return tt

    dispatchOp : String → String → IO ⊤
    dispatchOp commandId operation =
      if operation ==ˢ "hello" then hello commandId
      else if elemString operation ("query" ∷ "mutation" ∷ "action" ∷ []) then
        withClient commandId
          (runCall rt commandId operation command
             (fromMaybe "" (asString (objOr command "path" jnull))))
      else if operation ==ˢ "setAuth" then setAuthOp commandId
      else if operation ==ˢ "subscribe" then subscribeOp commandId
      else if operation ==ˢ "unsubscribe" then unsubscribeOp commandId
      else if operation ==ˢ "debugDisconnect" then
        withClient commandId (doDebugDisconnect rt commandId)
      else if operation ==ˢ "close" then closeOp commandId
      else reportError rt (just commandId) (protocolFailure "unknown adapter operation")

    validated : String → String → IO ⊤
    validated commandId operation = onProblem (validateShape command operation)
      where
        onProblem : Maybe String → IO ⊤
        onProblem (just m) = reportError rt (just commandId) (protocolFailure m)
        onProblem nothing = dispatchOp commandId operation

    ordered : String → String → IO ⊤
    ordered commandId operation = modifyState rt needsGreeting >>= dispatch
      where
        dispatch : Bool → IO ⊤
        dispatch true = validated commandId operation
        dispatch false =
          if operation ==ˢ "hello" then validated commandId operation
          else reportError rt (just commandId)
                 (protocolFailure "hello must be the first adapter command")

    onId : Maybe String → Maybe String → IO ⊤
    onId nothing _ =
      reportError rt nothing (protocolFailure "adapter command requires a non-empty id")
    onId (just commandId) nothing =
      reportError rt (just commandId) (protocolFailure "adapter command requires op")
    onId (just commandId) (just operation) = ordered commandId operation

--------------------------------------------------------------------------------
-- Line framing
--------------------------------------------------------------------------------

private
  -- A trailing carriage return is tolerated so a controller writing CRLF still
  -- produces the exact same command.
  trimCR : Bytes → Bytes
  trimCR line =
    if (size line >ⁿ 0) ∧ (octet line (size line - 1) ==ⁿ 13)
      then slice line 0 (size line - 1)
      else line

  processLine : Runtime → Bytes → IO ⊤
  processLine rt raw = onDecoded (decodeBytes (trimCR raw))
    where
      onDecoded : Either String JSON → IO ⊤
      onDecoded (left m) = reportError rt nothing (protocolFailure m)
      onDecoded (right command) =
        if not (isObject command) then
          reportError rt nothing (protocolFailure "adapter command must be an object")
        else handleCommand rt command

{-# TERMINATING #-}
-- A service loop over the NDJSON stream. Lines longer than the ceiling are
-- reported and discarded up to the next newline rather than buffered.
readLoop : Runtime → Bytes → Bool → IO ⊤
readLoop rt buffer discarding = modifyState rt isClosed >>= dispatch
  where
    consume : Nat → Bytes → IO ⊤
    consume at grown =
      (if discarding then return tt else processLine rt (slice grown 0 at))
        >> readLoop rt (dropBytes (suc at) grown) false

    onNewline : Bytes → Maybe Nat → IO ⊤
    onNewline grown (just at) = consume at grown
    onNewline grown nothing =
      if size grown >ⁿ adapterLineOctets then
        reportError rt nothing (protocolFailure "adapter command exceeds the line budget")
          >> readLoop rt emptyBytes true
      else readLoop rt grown discarding

    grownWith : Bytes → IO ⊤
    grownWith grown = onNewline grown (findOctet grown 10 0 (size grown))

    onRecv : RecvResult → IO ⊤
    onRecv (recvData chunk) = grownWith (buffer +++ chunk)
    onRecv recvTimeout = readLoop rt buffer discarding
    onRecv recvEof =
      if (size buffer >ⁿ 0) ∧ not discarding
        then reportError rt nothing (protocolFailure "adapter command must end with a newline")
        else return tt
    onRecv (recvError m) = stderrLine ("adapter input failed: " <> m)

    -- A single `recv` can return several NDJSON lines at once (a controller
    -- is free to write them back to back, and a pipe or socket has no
    -- obligation to split reads at line boundaries). `grownWith` only ever
    -- consumes the first line it finds and carries the rest over as the
    -- next `buffer`, so before waiting on more input this must re-scan
    -- that carried-over buffer for a newline already inside it. Skipping
    -- this check was the original bug: a second, already-complete line
    -- would sit in `buffer` while `dispatch` blocked on a `recv` that will
    -- never come (the writer already closed its end), and the eventual
    -- EOF then misreported that still-unprocessed, newline-terminated line
    -- as an unterminated one.
    onBuffered : Bytes → Maybe Nat → IO ⊤
    onBuffered grown (just at) = consume at grown
    onBuffered grown nothing = channelRecv (channel rt) chunkOctets 200 >>= onRecv

    dispatch : Bool → IO ⊤
    dispatch true = return tt
    dispatch false = onBuffered buffer (findOctet buffer 10 0 (size buffer))

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

private
  newRuntime : Channel → IO Runtime
  newRuntime ch =
    newMVar initialSink >>= λ sinkRef →
    newMVar initialAdapter >>= λ stateRef →
    newMVar tt >>= λ publishRef →
    newMVar tt >>= λ dequeueRef →
    newMVar nothing >>= λ clientRef →
    return (runtimeOf ch sinkRef stateRef publishRef dequeueRef clientRef)

  -- Close the sink, then wait for the writer to finish what is already
  -- queued. The wait is bounded so a controller that has stopped reading
  -- cannot hold the process open.
  drain : Nat → Runtime → IO ⊤
  drain zero _ = return tt
  drain (suc fuel) rt = readMVar (sinkCell rt) >>= dispatch
    where
      dispatch : Sink → IO ⊤
      dispatch current =
        if sinkFailed current then return tt
        else if (length (items current) ==ⁿ 0) ∧ (inFlightBytes current ==ⁿ 0) then return tt
        else sleepMillis 10 >> drain fuel rt

  serve : Channel → IO ⊤
  serve ch =
    newRuntime ch >>= λ rt →
    forkThread (writerLoop rt) >> readLoop rt emptyBytes false
      >> modifySink rt markClosed >> drain 200 rt

  -- `ADAPTER_LISTEN` is `host:port`. The shared controller connects once, and
  -- the adapter carries the same NDJSON stream over that connection.
  splitAddress : String → Maybe (String × Nat)
  splitAddress text = onSplit (breakLast (stringToList text) [] nothing)
    where
      breakLast : List Char → List Char → Maybe (List Char × List Char) → Maybe (List Char × List Char)
      breakLast [] _ found = found
      breakLast (c ∷ rest) seen found =
        if c ==ᶜ ':' then breakLast rest (seen ++ (c ∷ [])) (just (seen , rest))
        else breakLast rest (seen ++ (c ∷ [])) found

      digitsOf : List Char → Maybe Nat
      digitsOf [] = nothing
      digitsOf chars = go chars 0
        where
          go : List Char → Nat → Maybe Nat
          go [] acc = just acc
          go (c ∷ rest) acc =
            if isDigit c then go rest ((acc * 10) + (charCode c - 48)) else nothing

      onSplit : Maybe (List Char × List Char) → Maybe (String × Nat)
      onSplit nothing = nothing
      onSplit (just (hostChars , portChars)) = onPort (digitsOf portChars)
        where
          onPort : Maybe Nat → Maybe (String × Nat)
          onPort nothing = nothing
          onPort (just p) =
            if (p ==ⁿ 0) ∨ (p >ⁿ 65535) ∨ (length hostChars ==ⁿ 0) then nothing
            else just (stringFromList hostChars , p)

  listenAndServe : String → Nat → IO ⊤
  listenAndServe listenHost listenPort = listenerOpen listenHost listenPort >>= opened
    where
      accepted : Listener → IOResult Socket → IO ⊤
      accepted listener (ioErr m) = listenerClose listener >> stderrLine ("adapter accept failed: " <> m)
      accepted listener (ioOk s) =
        listenerClose listener >> serve (socketChannel s) >> socketClose s

      opened : IOResult Listener → IO ⊤
      opened (ioErr m) = stderrLine ("adapter listen failed: " <> m) >> exitProcess 1
      opened (ioOk listener) =
        stderrLine ("adapter listening on " <> listenHost <> ":" <> showNat listenPort)
          >> listenerAccept listener >>= accepted listener

main : IO ⊤
main = initStandardStreams >> getEnvironment "ADAPTER_LISTEN" >>= dispatch >> exitProcess 0
  where
    onAddress : Maybe (String × Nat) → IO ⊤
    onAddress nothing = stderrLine "ADAPTER_LISTEN must be host:port" >> exitProcess 1
    onAddress (just (listenHost , listenPort)) = listenAndServe listenHost listenPort

    dispatch : Maybe String → IO ⊤
    dispatch nothing = serve stdioChannel
    dispatch (just listen) =
      if stringLength listen ==ⁿ 0 then serve stdioChannel else onAddress (splitAddress listen)
