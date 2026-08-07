/-
The Live engine.

The whole client runs on one thread driven by `poll(2)`, so the "single owner"
rule that concurrent clients enforce with locks is structural here: there is
exactly one place that opens, reads, writes, retires, and reconnects the
socket, and exactly one place that changes the query set. Subscribers only ever
pop from a bounded queue that the same loop filled.

Every wait is an absolute deadline, every queue has both a count bound and a
byte bound, and every update is stamped with the connection generation that
produced it so a consumer can reject one that a later barrier invalidated.
-/

import Convex.Sync
import Convex.WebSocket

namespace Convex

open Lean (Json)

/-- One reactive delivery: either a value or a structured failure, never both,
plus the connection generation that produced it. -/
structure Update where
  value : Option Json := none
  error : Option ConvexError := none
  logs : Array String := #[]
  generation : Nat := 0
  deriving Inhabited

structure QueuedUpdate where
  update : Update
  /-- Conservative charge for this entry. An event count alone is not a memory
  bound when one value can approach the frame limit. -/
  bytes : Nat
  /-- Global ordering, so the oldest entry across every subscription can be
  identified when the shared byte budget is exceeded. -/
  serial : Nat
  deriving Inhabited

structure SubState where
  id : Nat
  path : String
  args : Json
  /-- Signature of the last delivered payload. Rehydration after a reconnect
  that produced the same value is suppressed rather than republished. -/
  lastSignature : Option UInt64
  queue : Array QueuedUpdate
  deriving Inhabited

structure LiveConfig where
  endpoint : Endpoint
  tls : TlsOptions := {}
  clientVersion : String := "lean-0.1.0"
  maxSubscriptions : Nat := 8
  maxUpdatesPerSubscription : Nat := 16
  maxQueuedBytes : Nat := 16 * 1024 * 1024
  maxFrameBytes : Nat := 2 * 1024 * 1024
  maxSubscriptionArgsBytes : Nat := 256 * 1024
  connectTimeoutMs : UInt64 := 10000
  writeTimeoutMs : UInt64 := 5000
  closeTimeoutMs : UInt64 := 2000
  inactivityMs : UInt64 := 30000
  initialBackoffMs : Nat := 100
  maxBackoffMs : Nat := 15000
  deriving Inhabited

structure LiveState where
  subs : Array SubState := #[]
  nextId : Nat := 0
  querySetVersion : Nat := 0
  remoteVersion : Sync.StateVersion := Sync.zeroVersion
  maxObservedTimestamp : Option String := none
  maxObservedTimestampValue : Nat := 0
  connectionCount : Nat := 0
  lastCloseReason : String := "InitialConnect"
  backoffMs : Nat := 100
  /-- Incremented for every connection, and stamped onto every update. -/
  generation : Nat := 0
  lastActivityMs : UInt64 := 0
  reconnectAt : Option UInt64 := none
  socket : Option WebSocket := none
  queuedBytes : Nat := 0
  serial : Nat := 0
  closed : Bool := false
  deriving Inhabited

structure Live where
  config : LiveConfig
  state : IO.Ref LiveState

namespace Live

/-- A fixed-width signature, so suppressing an unchanged rehydration does not
mean retaining a second copy of the value. -/
def fnv1a (bytes : ByteArray) : UInt64 := Id.run do
  let mut hash : UInt64 := 14695981039346656037
  let mut index := 0
  while index < bytes.size do
    hash := (hash ^^^ (bytes.get! index).toUInt64) * 1099511628211
    index := index + 1
  return hash

private def updateShape (update : Update) : Json :=
  jsonObject
    [ ("value", update.value.getD Json.null)
    , ("error", match update.error with
        | none => Json.null
        | some problem => Json.str s!"{problem.name}: {problem.message}")
    , ("logs", jsonOfStrings update.logs) ]

def new (config : LiveConfig) : IO Live := do
  let state ← IO.mkRef ({ backoffMs := config.initialBackoffMs } : LiveState)
  pure { config, state }

def nowMs : ConvexM UInt64 := ConvexM.attempt "reading the clock" Ffi.nowMs

private def findIndex? (state : LiveState) (id : Nat) : Option Nat :=
  state.subs.findIdx? fun sub => sub.id == id

/-! ### Bounded delivery -/

private def dropOldestIn (state : LiveState) (index : Nat) : LiveState :=
  match state.subs[index]? with
  | none => state
  | some sub =>
      match sub.queue[0]? with
      | none => state
      | some entry =>
          { state with
            subs := state.subs.set! index { sub with queue := sub.queue.extract 1 sub.queue.size }
            queuedBytes := state.queuedBytes - entry.bytes }

/-- Trim the per-subscription count first, then the shared byte budget by
dropping the globally oldest intermediate state. A stopped reader therefore
costs a bounded amount of memory no matter how large each value is. -/
private def trim (config : LiveConfig) (state : LiveState) : LiveState := Id.run do
  let mut current := state
  let mut index := 0
  while index < current.subs.size do
    while (current.subs[index]!).queue.size > config.maxUpdatesPerSubscription do
      current := dropOldestIn current index
    index := index + 1
  let mut guard := 0
  while current.queuedBytes > config.maxQueuedBytes && guard < 100000 do
    guard := guard + 1
    let mut oldestIndex : Option Nat := none
    let mut oldestSerial := 0
    let mut scan := 0
    while scan < current.subs.size do
      match (current.subs[scan]!).queue[0]? with
      | none => pure ()
      | some entry =>
          if oldestIndex.isNone || entry.serial < oldestSerial then
            oldestIndex := some scan
            oldestSerial := entry.serial
      scan := scan + 1
    match oldestIndex with
    | none => current := { current with queuedBytes := 0 }
    -- Named oldestI, not index: the outer `mut index` from the loop above is
    -- still in scope here, and Lean disallows a pattern binding shadowing a
    -- mutable variable.
    | some oldestI => current := dropOldestIn current oldestI
  return current

private def enqueue (live : Live) (index : Nat) (update : Update) (encodedBytes : Nat) :
    ConvexM Unit := do
  let state ← live.state.get
  match state.subs[index]? with
  | none => pure ()
  | some sub =>
      let serial := state.serial + 1
      -- Four times the encoded length plus a fixed record allowance keeps the
      -- estimate comfortably above what the runtime actually retains.
      let bytes := encodedBytes * 4 + 4096
      let entry : QueuedUpdate := { update, bytes, serial }
      let updated := { state with
        subs := state.subs.set! index { sub with queue := sub.queue.push entry }
        queuedBytes := state.queuedBytes + bytes
        serial }
      live.state.set (trim live.config updated)

private def deliver (live : Live) (id : Nat) (update : Update) (suppressUnchanged : Bool) :
    ConvexM Unit := do
  let state ← live.state.get
  match findIndex? state id with
  | none => pure ()
  | some index =>
      let encoded := renderJsonBytes (updateShape update)
      let signature := fnv1a encoded
      let sub := state.subs[index]!
      if suppressUnchanged && sub.lastSignature == some signature then
        pure ()
      else
        if suppressUnchanged then
          live.state.set { state with
            subs := state.subs.set! index { sub with lastSignature := some signature } }
        enqueue live index update encoded.size

/-- Transport and protocol failures reach every active subscription, and they
deliberately leave the suppression signature alone: a later identical value is
a real recovery and must still be delivered. -/
private def broadcast (live : Live) (problem : ConvexError) : ConvexM Unit := do
  let state ← live.state.get
  for sub in state.subs do
    deliver live sub.id { error := some problem, generation := state.generation } false

def take (live : Live) (id : Nat) : ConvexM (Option Update) := do
  let state ← live.state.get
  match findIndex? state id with
  | none => throw (ConvexError.closed "Convex subscription is closed")
  | some index =>
      let sub := state.subs[index]!
      match sub.queue[0]? with
      | none => pure none
      | some entry =>
          live.state.set { state with
            subs := state.subs.set! index { sub with queue := sub.queue.extract 1 sub.queue.size }
            queuedBytes := state.queuedBytes - entry.bytes }
          pure (some entry.update)

def queuedCount (live : Live) (id : Nat) : ConvexM Nat := do
  let state ← live.state.get
  match findIndex? state id with
  | none => pure 0
  | some index => pure (state.subs[index]!).queue.size

def queuedBytes (live : Live) : ConvexM Nat := do
  pure (← live.state.get).queuedBytes

/-! ### Socket lifecycle -/

private def retire (live : Live) (reason : String) : ConvexM Unit := do
  let state ← live.state.get
  match state.socket with
  | none => pure ()
  | some socket =>
      let deadline := (← nowMs) + live.config.closeTimeoutMs
      ConvexM.ignoreFailure (WebSocket.close socket deadline)
      live.state.set { state with
        socket := none
        connectionCount := state.connectionCount + 1
        lastCloseReason := reason
        querySetVersion := 0
        remoteVersion := Sync.zeroVersion }

private def scheduleReconnect (live : Live) (delayMs : Nat) : ConvexM Unit := do
  let now ← nowMs
  live.state.modify fun state =>
    { state with reconnectAt := some (now + UInt64.ofNat delayMs) }

private def backOffAndRetry (live : Live) (reason : String) : ConvexM Unit := do
  retire live reason
  let state ← live.state.get
  let delay := state.backoffMs
  live.state.set { state with
    backoffMs := min live.config.maxBackoffMs (max live.config.initialBackoffMs (delay * 2)) }
  scheduleReconnect live delay

private def sendJson (live : Live) (socket : WebSocket) (message : Json) : ConvexM Unit := do
  let deadline := (← nowMs) + live.config.writeTimeoutMs
  WebSocket.sendText socket (renderJson message) deadline

private def randomSessionId : ConvexM String := do
  let bytes ← ConvexM.attempt "generating a session id" (Ffi.randomBytes 16)
  pure (Bytes.toHex bytes)

/-- Open a connection and immediately restore the whole query set on it. The
`Add` operations are written before this returns, so a caller waiting on a
subscription is never told it is live before the server has been told. -/
private def connectNow (live : Live) : ConvexM Unit := do
  let attempt : ConvexM Unit := do
    let state ← live.state.get
    let deadline := (← nowMs) + live.config.connectTimeoutMs
    let socket ← WebSocket.connect live.config.endpoint live.config.tls live.config.clientVersion
      deadline live.config.maxFrameBytes live.config.maxFrameBytes
    let opened ← nowMs
    live.state.set { state with
      socket := some socket
      generation := state.generation + 1
      reconnectAt := none
      querySetVersion := 0
      remoteVersion := Sync.zeroVersion
      lastActivityMs := opened }
    let sessionId ← randomSessionId
    sendJson live socket
      (Sync.connectMessage sessionId state.connectionCount state.lastCloseReason
        state.maxObservedTimestamp)
    if state.subs.size > 0 then
      let modifications := state.subs.map fun sub => Sync.addModification sub.id sub.path sub.args
      sendJson live socket (Sync.modifyQuerySetMessage 0 modifications)
      live.state.modify fun current => { current with querySetVersion := 1 }
  try
    attempt
  catch problem =>
    backOffAndRetry live s!"connection failed: {problem.message}"
    throw problem

private def ensureConnected (live : Live) : ConvexM Unit := do
  let state ← live.state.get
  if state.closed || state.socket.isSome || state.subs.isEmpty then
    pure ()
  else
    let now ← nowMs
    match state.reconnectAt with
    | some due => if now ≥ due then connectNow live else pure ()
    | none => connectNow live

/-! ### Inbound messages -/

private def applyTransition (live : Live) (transition : Sync.Transition) : ConvexM Unit := do
  let state ← live.state.get
  let activeIds := state.subs.map fun sub => sub.id
  liftExcept "Live transition"
    (Sync.validateTransition transition state.remoteVersion state.querySetVersion activeIds)
  -- Commit the version before publishing anything, so a partially applied
  -- transition can never become visible.
  let advances := transition.endVersion.tsValue > state.maxObservedTimestampValue
  live.state.set { state with
    remoteVersion := transition.endVersion
    maxObservedTimestamp :=
      if advances then some transition.endVersion.ts else state.maxObservedTimestamp
    maxObservedTimestampValue :=
      if advances then transition.endVersion.tsValue else state.maxObservedTimestampValue }
  let generation := state.generation
  for change in Sync.coalesce transition.changes do
    match change with
    | .removed _ => pure ()
    | .updated id value logs =>
        deliver live id { value := some value, logs, generation } true
    | .failed id message data logs =>
        deliver live id
          { error := some (ConvexError.function message data logs), logs, generation } true

/-- Returns whether the message counts as evidence that this peer is speaking
the pinned profile. Only such a message resets backoff or refreshes the
inactivity clock. -/
private def handleServerMessage (live : Live) (text : String) : ConvexM Bool := do
  let message ← liftExcept "Live message"
    (parseJsonString text { maxBytes := live.config.maxFrameBytes })
  match jsonObjVal? message "type" >>= jsonStr? with
  | none => throw (ConvexError.protocol "Live message omitted type")
  | some "Transition" => do
      let transition ← liftExcept "Live transition" (Sync.parseTransition message)
      applyTransition live transition
      pure true
  | some "Ping" => pure true
  -- This client never issues mutations or actions over the socket, so their
  -- envelopes are tolerated for drift compatibility but earn no health credit.
  | some "MutationResponse" => pure false
  | some "ActionResponse" => pure false
  | some "TransitionChunk" =>
      throw (ConvexError.protocol "TransitionChunk assembly is not implemented")
  | some "FatalError" =>
      let detail := (jsonObjVal? message "error" >>= jsonStr?).getD "no detail"
      throw (ConvexError.protocol s!"Live server reported a fatal error: {detail}")
  | some "AuthError" =>
      throw (ConvexError.protocol "Live server rejected the connection's identity")
  | some other => throw (ConvexError.protocol s!"unexpected Live message: {other}")

/-- One non-blocking turn of the loop: drain the socket, apply the timers, and
reconnect when the schedule says to. -/
def pump (live : Live) : ConvexM Unit := do
  let state ← live.state.get
  if state.closed then
    return ()
  match state.socket with
  | none => ConvexM.ignoreFailure (ensureConnected live)
  | some socket =>
      let deadline := (← nowMs) + live.config.writeTimeoutMs
      let work : ConvexM Bool := do
        let (messages, ended) ← WebSocket.drainAvailable socket deadline
        for message in messages do
          match message with
          | .text text =>
              if ← handleServerMessage live text then
                let now ← nowMs
                live.state.modify fun current =>
                  { current with
                    backoffMs := live.config.initialBackoffMs
                    lastActivityMs := now }
          | .binary _ => throw (ConvexError.protocol "Live server sent a binary message")
          | .peerClose code reason =>
              throw (ConvexError.transport s!"Live peer closed with {code} {reason}")
        pure ended
      try
        let closedByPeer ← work
        if closedByPeer then
          let problem := ConvexError.transport "Live connection ended"
          broadcast live problem
          backOffAndRetry live problem.message
        else
          let now ← nowMs
          let current ← live.state.get
          if now ≥ current.lastActivityMs + live.config.inactivityMs then
            let problem := ConvexError.transport "Live server was inactive for 30 seconds"
            broadcast live problem
            backOffAndRetry live problem.message
      catch problem =>
        broadcast live problem
        backOffAndRetry live problem.message
        -- This branch is a locally-detected protocol violation (an
        -- unsupported message shape, a parse failure, ...), not a transport
        -- failure -- the server did not signal distress, the client chose to
        -- abandon the connection. Nothing pumps this client in the
        -- background (single-threaded, caller-driven), so leaving the
        -- reconnect merely scheduled here can strand a caller that observes
        -- the connection externally (a test fixture reading what the peer
        -- saw, for instance) before making another client call of its own:
        -- nothing would ever get to the point of noticing the schedule came
        -- due. Attempting it immediately, and swallowing (not retrying
        -- inline) a failure so an unreachable server cannot recurse forever,
        -- keeps a real network failure still backed off by the schedule
        -- `backOffAndRetry` already set, while a healthy server sees a
        -- reconnect right away instead of stalling for a caller-driven pump
        -- that story does not guarantee will come.
        ConvexM.ignoreFailure (connectNow live)

/-! ### Controller operations -/

def add (live : Live) (path : String) (args : Json) : ConvexM Nat := do
  let state ← live.state.get
  if state.closed then
    throw (ConvexError.closed "Convex client is closed")
  if path.length < 3 then
    throw (ConvexError.protocol "Convex function path is required")
  if (renderJsonBytes args).size > live.config.maxSubscriptionArgsBytes then
    throw (ConvexError.protocol "Live subscription arguments exceeded the argument budget")
  if state.subs.size ≥ live.config.maxSubscriptions then
    throw (ConvexError.protocol
      s!"Live supports at most {live.config.maxSubscriptions} active subscriptions")
  let id := state.nextId
  let sub : SubState := { id, path, args, lastSignature := none, queue := #[] }
  live.state.set { state with subs := state.subs.push sub, nextId := id + 1 }
  let register : ConvexM Unit := do
    let current ← live.state.get
    match current.socket with
    | none =>
        -- A fresh connection hydrates the whole query set, including this one.
        live.state.modify fun latest => { latest with reconnectAt := none }
        connectNow live
    | some socket =>
        sendJson live socket
          (Sync.modifyQuerySetMessage current.querySetVersion #[Sync.addModification id path args])
        live.state.modify fun latest =>
          { latest with querySetVersion := current.querySetVersion + 1 }
  try
    register
    pure id
  catch problem =>
    -- The caller never sees a half-registered subscription.
    live.state.modify fun latest =>
      { latest with subs := latest.subs.filter fun candidate => candidate.id != id }
    throw problem

/-- Removal invalidates the local subscription first, so nothing already queued
for it can still be handed out, and only then tells the server. A write that
fails or times out retires the connection instead of blocking the caller. -/
def remove (live : Live) (id : Nat) : ConvexM Unit := do
  let state ← live.state.get
  match findIndex? state id with
  | none => pure ()
  | some index =>
      let sub := state.subs[index]!
      let reclaimed := sub.queue.foldl (fun total entry => total + entry.bytes) 0
      live.state.set { state with
        subs := state.subs.filter fun candidate => candidate.id != id
        queuedBytes := state.queuedBytes - reclaimed }
      match state.socket with
      | none => pure ()
      | some socket =>
          let send : ConvexM Unit := do
            sendJson live socket
              (Sync.modifyQuerySetMessage state.querySetVersion #[Sync.removeModification id])
            live.state.modify fun latest =>
              { latest with querySetVersion := state.querySetVersion + 1 }
          try
            send
          catch problem =>
            backOffAndRetry live s!"Remove failed: {problem.message}"

/-- Adapter-only. Retires the current connection and immediately attempts a
replacement, returning the generation the next connection will carry so a
consumer can reject anything the retired one produced.

This client is single-threaded and caller-driven: nothing pumps the socket in
the background, so merely scheduling the reconnect (`reconnectAt := now`,
without also calling `connectNow`) leaves it undone until the next call the
caller happens to make that pumps -- which may never come if that next call
is, say, reading a fixture's report of the very reconnect it is waiting on.
`register`'s handling of a missing socket calls `connectNow` directly for the
identical reason; this mirrors it instead of only scheduling. -/
def debugDisconnect (live : Live) : ConvexM Nat := do
  let state ← live.state.get
  if state.closed then
    throw (ConvexError.closed "Convex client is closed")
  retire live "DebugDisconnect"
  live.state.modify fun current => { current with backoffMs := live.config.initialBackoffMs }
  scheduleReconnect live 0
  connectNow live
  pure (state.generation + 1)

def currentGeneration (live : Live) : ConvexM Nat := do
  pure (← live.state.get).generation

def connectionCount (live : Live) : ConvexM Nat := do
  pure (← live.state.get).connectionCount

def lastCloseReason (live : Live) : ConvexM String := do
  pure (← live.state.get).lastCloseReason

def maxObservedTimestamp (live : Live) : ConvexM (Option String) := do
  pure (← live.state.get).maxObservedTimestamp

def backoffMs (live : Live) : ConvexM Nat := do
  pure (← live.state.get).backoffMs

def fd (live : Live) : ConvexM (Option UInt32) := do
  match (← live.state.get).socket with
  | none => pure none
  | some socket => do
      let descriptor ← WebSocket.fd socket
      pure (if descriptor == Ffi.noDescriptor then none else some descriptor)

/-- How long the caller may sleep before this engine needs attention again. -/
def waitBudgetMs (live : Live) (limit : Nat) : ConvexM Nat := do
  let state ← live.state.get
  if state.closed then
    return 0
  let now ← nowMs
  let untilReconnect :=
    match state.reconnectAt with
    | none => limit
    | some due => if due ≤ now then 0 else min limit (due - now).toNat
  let untilInactivity :=
    match state.socket with
    | none => limit
    | some _ =>
        let expiry := state.lastActivityMs + live.config.inactivityMs
        if expiry ≤ now then 0 else min limit (expiry - now).toNat
  pure (min untilReconnect untilInactivity)

def close (live : Live) : ConvexM Unit := do
  let state ← live.state.get
  if state.closed then
    return ()
  live.state.set { state with closed := true, subs := #[], queuedBytes := 0 }
  retire live "ClientClosed"

end Live

end Convex
