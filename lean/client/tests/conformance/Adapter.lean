/-
The test-only conformance executable.

This is adapter infrastructure, not client code. It speaks NDJSON protocol v1
over stdin and stdout, or over one `ADAPTER_LISTEN` connection, and every
operation goes through the real Lean client.

Two properties get the most care here. Commands are validated strictly, so a
command with an unknown, duplicated, or missing field is a reported error
rather than something quietly tolerated. And output is admitted through a
queue with a count bound, a byte bound that includes the write currently in
flight, and an admission deadline, so a controller that stops reading cannot
turn into unbounded memory.
-/

import Convex

namespace Tests.Conformance

open Convex
open Lean (Json)

def protocolVersion : Nat := 1
def languageId : String := "lean"
def implementationName : String := "native-lean4"
def maxCommandBytes : Nat := 2 * 1024 * 1024
def outputCountLimit : Nat := 16
def outputByteLimit : Nat := 6 * 1024 * 1024
def admissionBudgetMs : UInt64 := 5000
def relayBatchPerTurn : Nat := 16

structure OutputItem where
  bytes : ByteArray
  /-- Subscription values may be dropped under pressure; acknowledgements and
  errors may not. -/
  droppable : Bool
  deriving Inhabited

structure Relay where
  key : String
  subscription : Subscription
  /-- The registration this relay was published under. A later replacement,
  unsubscribe, or close bumps the key's generation, which is what makes an
  update dequeued before the barrier unpublishable. -/
  registration : Nat
  deriving Inhabited

structure AdapterState where
  client : Option Client := none
  relays : Array Relay := #[]
  generations : Array (String × Nat) := #[]
  /-- Updates produced by a connection older than this are dropped. -/
  minimumLiveGeneration : Nat := 0
  helloSeen : Bool := false
  closing : Bool := false
  inputFd : UInt32 := 0
  outputFd : UInt32 := 1
  queue : Array OutputItem := #[]
  /-- Bytes of the head item already handed to the kernel. The item stays
  charged until the whole of it has been written. -/
  headOffset : Nat := 0
  queuedBytes : Nat := 0

abbrev Adapter := IO.Ref AdapterState

/-! ### Strict command shapes -/

/-- Collect the top-level member names from the raw text. `Lean.Json` folds a
duplicated key into one entry, so a duplicate can only be caught before the
parse result is inspected. -/
def topLevelKeys (text : String) : Except String (Array String) := Id.run do
  let bytes := text.toUTF8
  let mut keys : Array String := #[]
  let mut index := 0
  let mut depth := 0
  let mut inString := false
  let mut escaped := false
  let mut current := ByteArray.empty
  let mut expectingKey := false
  -- Whether the *next* depth-1 string is a key rather than a value: true
  -- right after `{` or a depth-1 `,`, false right after a depth-1 `:`.
  -- Without this, a depth-1 string VALUE (e.g. "ack" in {"type":"ack"})
  -- looks identical to a key at the point its opening quote is seen (both
  -- are simply "a string starting while depth == 1"), and was being counted
  -- as one -- doubling the key count whenever values happened to be strings.
  let mut atKeyPosition := true
  while index < bytes.size do
    let byte := bytes.get! index
    index := index + 1
    if inString then
      if escaped then
        escaped := false
        current := current.push byte
      else if byte == 0x5C then
        escaped := true
        current := current.push byte
      else if byte == 0x22 then
        inString := false
        if expectingKey && depth == 1 then
          match Bytes.utf8Decode current with
          | .ok name => keys := keys.push name
          | .error problem => return .error problem
      else
        current := current.push byte
    else if byte == 0x22 then
      inString := true
      current := ByteArray.empty
      expectingKey := depth == 1 && atKeyPosition
    else if byte == 0x7B || byte == 0x5B then
      depth := depth + 1
    else if byte == 0x7D || byte == 0x5D then
      if depth == 0 then
        return .error "unbalanced JSON"
      depth := depth - 1
    else if byte == 0x3A then
      if depth == 1 then atKeyPosition := false
    else if byte == 0x2C then
      if depth == 1 then atKeyPosition := true
  return .ok keys

/-- The fields protocol v1 permits and requires for each operation. -/
def commandShape (operation : String) : Option (List String × List String) :=
  match operation with
  | "hello" => some (["protocolVersion", "id", "op"], ["protocolVersion", "id", "op"])
  | "query" | "mutation" | "action" =>
      some (["id", "op", "path", "args"], ["id", "op", "path", "args"])
  | "subscribe" | "unsubscribe" =>
      some (["id", "op", "subscriptionId", "path", "args"], ["id", "op", "subscriptionId"])
  | "setAuth" => some (["id", "op", "token"], ["id", "op", "token"])
  | "close" | "debugDisconnect" => some (["id", "op"], ["id", "op"])
  | _ => none

def validShortString (value : String) : Bool :=
  let length := value.length
  length ≥ 1 && length ≤ 128

/-! ### Event serialisation -/

/-- Optional members are omitted rather than serialised as null, because the
shared controller validates every event strictly. -/
def errorPayload (problem : ConvexError) : Json :=
  let base : List (String × Json) :=
    [("name", Json.str problem.name), ("message", Json.str problem.message)]
  jsonObject (match problem.data with
    | none => base
    | some data => base ++ [("data", data)])

def errorEvent (problem : ConvexError) (id : Option String) : Json :=
  jsonObject
    ((match id with
      | none => []
      | some value => [("id", Json.str value)]) ++
     [("type", Json.str "error"), ("error", errorPayload problem)])

def resultEvent (id : String) (value : Json) (logs : Array String) : Json :=
  jsonObject
    ([("id", Json.str id), ("type", Json.str "result"), ("value", value)] ++
     (if logs.isEmpty then [] else [("logs", jsonOfStrings logs)]))

def ackEvent (id : String) : Json :=
  jsonObject [("id", Json.str id), ("type", Json.str "ack")]

def closedEvent (id : String) : Json :=
  jsonObject [("id", Json.str id), ("type", Json.str "closed")]

def readyEvent (id : String) (runtime : String) : Json :=
  jsonObject
    [ ("protocolVersion", jsonOfNat protocolVersion)
    , ("id", Json.str id)
    , ("type", Json.str "ready")
    , ("language", Json.str languageId)
    , ("implementation", Json.str implementationName)
    , ("runtime", Json.str runtime) ]

def subscriptionEvent (key : String) (update : Update) : Json :=
  match update.error with
  | some problem =>
      jsonObject
        [ ("type", Json.str "subscription")
        , ("subscriptionId", Json.str key)
        , ("error", errorPayload problem) ]
  | none =>
      jsonObject
        ([ ("type", Json.str "subscription")
         , ("subscriptionId", Json.str key)
         , ("value", update.value.getD Json.null) ] ++
         (if update.logs.isEmpty then [] else [("logs", jsonOfStrings update.logs)]))

/-! ### Bounded output -/

/-- Hand the head of the queue to the kernel without blocking. A partial write
leaves the remainder, and its full charge, in place. -/
def flushOutput (adapter : Adapter) : ConvexM Unit := do
  let mut progressing := true
  while progressing do
    let state ← adapter.get
    match state.queue[0]? with
    | none => progressing := false
    | some item =>
        let written ← ConvexM.attempt "writing an adapter event"
          (Ffi.writeFd state.outputFd item.bytes (UInt32.ofNat state.headOffset))
        if written == 0 then
          progressing := false
        else
          let advanced := state.headOffset + written.toNat
          if advanced ≥ item.bytes.size then
            adapter.set { state with
              queue := state.queue.extract 1 state.queue.size
              headOffset := 0
              queuedBytes := state.queuedBytes - item.bytes.size }
          else
            adapter.set { state with headOffset := advanced }

private def dropFirstDroppable (state : AdapterState) : Option AdapterState :=
  -- The head may already be partly written, so it is never a drop candidate.
  match state.queue.findIdx? (fun item => item.droppable) with
  | none => none
  | some index =>
      if index == 0 && state.headOffset > 0 then
        match (state.queue.extract 1 state.queue.size).findIdx? (fun item => item.droppable) with
        | none => none
        | some later =>
            let position := later + 1
            let item := state.queue[position]!
            some { state with
              queue := (state.queue.extract 0 position) ++
                       (state.queue.extract (position + 1) state.queue.size)
              queuedBytes := state.queuedBytes - item.bytes.size }
      else
        let item := state.queue[index]!
        some { state with
          queue := (state.queue.extract 0 index) ++
                   (state.queue.extract (index + 1) state.queue.size)
          queuedBytes := state.queuedBytes - item.bytes.size }

/-- Admit one encoded event. A droppable event yields to pressure; anything
else waits for room until the admission deadline and then fails rather than
silently disappearing. -/
def publish (adapter : Adapter) (event : Json) (droppable : Bool) : ConvexM Bool := do
  let encoded := (renderJson event ++ "\n").toUTF8
  if encoded.size > outputByteLimit then
    throw (ConvexError.protocol "adapter event exceeds the encoded output budget")
  let deadline := (← Live.nowMs) + admissionBudgetMs
  let mut admitted := false
  let mut deciding := true
  while deciding do
    flushOutput adapter
    let state ← adapter.get
    let hasRoom :=
      state.queue.size < outputCountLimit && state.queuedBytes + encoded.size ≤ outputByteLimit
    if hasRoom then
      adapter.set { state with
        queue := state.queue.push { bytes := encoded, droppable }
        queuedBytes := state.queuedBytes + encoded.size }
      admitted := true
      deciding := false
    else
      match dropFirstDroppable state with
      | some trimmed => adapter.set trimmed
      | none =>
          if droppable then
            deciding := false
          else
            let now ← Live.nowMs
            if now ≥ deadline then
              throw (ConvexError.transport "adapter output stayed backpressured")
            let _ ← ConvexM.attempt "waiting for adapter output room"
              (Ffi.poll state.outputFd Ffi.wantWrite Ffi.noDescriptor Ffi.wantNothing
                Ffi.noDescriptor Ffi.wantNothing 50)
  pure admitted

/-! ### Relay barriers -/

def generationFor (state : AdapterState) (key : String) : Nat :=
  match state.generations.find? (fun entry => entry.1 == key) with
  | some entry => entry.2
  | none => 0

private def bumpGeneration (adapter : Adapter) (key : String) : ConvexM Nat := do
  let state ← adapter.get
  let next := generationFor state key + 1
  let generations :=
    match state.generations.findIdx? (fun entry => entry.1 == key) with
    | some index => state.generations.set! index (key, next)
    | none => state.generations.push (key, next)
  adapter.set { state with generations }
  pure next

/-- Invalidate a key's relay before any acknowledgement is published. An update
already dequeued under the old registration can no longer be published, which
is what a replacement or unsubscribe has to guarantee. -/
def invalidateRelay (adapter : Adapter) (key : String) : ConvexM (Option Relay) := do
  let state ← adapter.get
  let existing := state.relays.find? (fun relay => relay.key == key)
  adapter.set { state with relays := state.relays.filter fun relay => relay.key != key }
  let _ ← bumpGeneration adapter key
  pure existing

/-- The one place a subscription event may be published. Both barriers are
rechecked here rather than at dequeue time. -/
def publishRelayUpdate (adapter : Adapter) (key : String) (registration : Nat) (update : Update) :
    ConvexM Bool := do
  let state ← adapter.get
  if registration != generationFor state key then
    return false
  if update.generation < state.minimumLiveGeneration then
    return false
  if !(state.relays.any fun relay => relay.key == key && relay.registration == registration) then
    return false
  publish adapter (subscriptionEvent key update) true

/-- Move whatever the client has already delivered into the output queue. -/
def relayTurn (adapter : Adapter) : ConvexM Unit := do
  let state ← adapter.get
  match state.client with
  | none => pure ()
  | some client =>
      for relay in state.relays do
        let mut taken := 0
        let mut draining := true
        while draining && taken < relayBatchPerTurn do
          let taking := client.takeUpdate relay.subscription
          match ← ConvexM.catchError taking (fun _ => pure none) with
          | none => draining := false
          | some update =>
              taken := taken + 1
              let _ ← publishRelayUpdate adapter relay.key relay.registration update

/-! ### Command handling -/

def ensureClient (adapter : Adapter) : ConvexM Client := do
  let state ← adapter.get
  match state.client with
  | some client => pure client
  | none => do
      let url ← match ← IO.getEnv "CONVEX_URL" with
        | some value => pure value
        | none => throw (ConvexError.protocol "CONVEX_URL is required")
      let token ← IO.getEnv "CONVEX_AUTH_TOKEN"
      let client ← Client.new url {
        clientVersion := "lean-0.1.0"
        authToken := token }
      adapter.set { state with client := some client }
      pure client

private def requireString (command : Json) (field : String) : ConvexM String := do
  match jsonObjVal? command field >>= jsonStr? with
  | some value => pure value
  | none => throw (ConvexError.protocol s!"{field} must be a string")

private def requireArgs (command : Json) : ConvexM Json := do
  match jsonObjVal? command "args" with
  | none => pure (jsonObject [])
  | some value =>
      if jsonIsObj value then pure value
      else throw (ConvexError.protocol "args must be a JSON object")

private def validateShape (command : Json) (raw : String) (operation : String) : ConvexM Unit := do
  match commandShape operation with
  | none => throw (ConvexError.protocol s!"unknown adapter operation: {operation}")
  | some (allowed, required) => do
      let keys ← liftExcept "adapter command" (topLevelKeys raw)
      let mut seen : Array String := #[]
      for key in keys do
        if !allowed.contains key then
          throw (ConvexError.protocol s!"adapter command contains an unknown field: {key}")
        if seen.contains key then
          throw (ConvexError.protocol s!"adapter command contains a duplicate field: {key}")
        seen := seen.push key
      for key in required do
        if !jsonHasKey command key then
          throw (ConvexError.protocol s!"adapter command is missing a required field: {key}")
      if jsonHasKey command "path" then
        let path ← requireString command "path"
        if operation == "query" || operation == "mutation" || operation == "action" then
          if path.length < 3 then
            throw (ConvexError.protocol "path must contain at least three characters")
      if jsonHasKey command "args" then
        let _ ← requireArgs command

private def handleCall (adapter : Adapter) (command : Json) (id : String) (operation : String) :
    ConvexM Unit := do
  let client ← ensureClient adapter
  let path ← requireString command "path"
  let args ← requireArgs command
  let result ←
    if operation == "query" then client.query path args
    else if operation == "mutation" then client.mutation path args
    else client.action path args
  let _ ← publish adapter (resultEvent id result.value result.logs) false

private def handleSubscribe (adapter : Adapter) (command : Json) (id : String) : ConvexM Unit := do
  let key ← requireString command "subscriptionId"
  if !validShortString key then
    throw (ConvexError.protocol "subscriptionId must contain 1 to 128 characters")
  let client ← ensureClient adapter
  let path ← requireString command "path"
  let args ← requireArgs command
  -- Replacement invalidates the old relay first, then removes it from the
  -- client, and only then registers and acknowledges the new one.
  match ← invalidateRelay adapter key with
  | none => pure ()
  | some previous => ConvexM.ignoreFailure (client.unsubscribe previous.subscription)
  let subscription ← client.subscribe path args
  let registration ← bumpGeneration adapter key
  adapter.modify fun state =>
    { state with relays := state.relays.push { key, subscription, registration } }
  let _ ← publish adapter (ackEvent id) false

private def handleUnsubscribe (adapter : Adapter) (command : Json) (id : String) :
    ConvexM Unit := do
  let key ← requireString command "subscriptionId"
  if !validShortString key then
    throw (ConvexError.protocol "subscriptionId must contain 1 to 128 characters")
  match ← invalidateRelay adapter key with
  | none => pure ()
  | some previous => do
      let state ← adapter.get
      match state.client with
      | none => pure ()
      | some client => ConvexM.ignoreFailure (client.unsubscribe previous.subscription)
  let _ ← publish adapter (ackEvent id) false

private def handleDebugDisconnect (adapter : Adapter) (id : String) : ConvexM Unit := do
  let client ← ensureClient adapter
  -- The acknowledgement is published only after the old connection has been
  -- retired and its replacement scheduled, and after the generation floor has
  -- moved, so nothing the retired connection produced can still cross it.
  let nextGeneration ← client.debugDisconnect
  adapter.modify fun state => { state with minimumLiveGeneration := nextGeneration }
  let _ ← publish adapter (ackEvent id) false

private def runtimeDescription : String := s!"Lean 4 native client {implementationName}"

def handleCommand (adapter : Adapter) (raw : String) : ConvexM Unit := do
  let command ← liftExcept "adapter command"
    (parseJsonString raw { maxBytes := maxCommandBytes })
  if !jsonIsObj command then
    throw (ConvexError.protocol "adapter command must be an object")
  let id ←
    match jsonObjVal? command "id" >>= jsonStr? with
    | some value =>
        if validShortString value then pure value
        else throw (ConvexError.protocol "adapter command id must contain 1 to 128 characters")
    | none => throw (ConvexError.protocol "adapter command requires a non-empty id")
  let operation ← requireString command "op"
  let state ← adapter.get
  if !state.helloSeen && operation != "hello" then
    throw (ConvexError.protocol "hello must be the first adapter command")

  let dispatch : ConvexM Unit := do
    validateShape command raw operation
    if operation == "hello" then
      if (← adapter.get).helloSeen then
        throw (ConvexError.protocol "hello may only be sent once")
      match jsonObjVal? command "protocolVersion" >>= jsonNat? with
      | some 1 => pure ()
      | _ => throw (ConvexError.protocol "unsupported adapter protocol version")
      adapter.modify fun current => { current with helloSeen := true }
      let _ ← publish adapter (readyEvent id runtimeDescription) false
    else if operation == "query" || operation == "mutation" || operation == "action" then
      handleCall adapter command id operation
    else if operation == "setAuth" then
      let token ← requireString command "token"
      let client ← ensureClient adapter
      client.setAuth token
      let _ ← publish adapter (ackEvent id) false
    else if operation == "subscribe" then
      handleSubscribe adapter command id
    else if operation == "unsubscribe" then
      handleUnsubscribe adapter command id
    else if operation == "debugDisconnect" then
      handleDebugDisconnect adapter id
    else if operation == "close" then
      let current ← adapter.get
      match current.client with
      | none => pure ()
      | some client => ConvexM.ignoreFailure client.close
      adapter.modify fun latest => { latest with closing := true, relays := #[] }
      let _ ← publish adapter (closedEvent id) false
    else
      throw (ConvexError.protocol s!"unknown adapter operation: {operation}")

  try
    dispatch
  catch problem =>
    let _ ← publish adapter (errorEvent problem (some id)) false

/-- A line that could not even be attributed to a command reports an error
without an `id`, because the schema forbids serialising an absent one. -/
def reportUnattributed (adapter : Adapter) (message : String) : ConvexM Unit := do
  let _ ← ConvexM.catchError
    (do let _ ← publish adapter (errorEvent (ConvexError.protocol message) none) false)
    (fun _ => pure ())

/-! ### Event loop -/

structure InputState where
  pending : ByteArray := ByteArray.empty
  /-- Set after an over-long line, so the remainder of it is discarded rather
  than parsed as a fresh command. -/
  discarding : Bool := false
  atEnd : Bool := false
  deriving Inhabited

private def consumeLines (adapter : Adapter) (input : IO.Ref InputState) (chunk : ByteArray) :
    ConvexM Unit := do
  let state ← input.get
  let mut buffer := state.pending ++ chunk
  let mut discarding := state.discarding
  let mut searching := true
  while searching do
    match Bytes.indexOfByte? buffer 0x0A with
    | some position =>
        let line := buffer.extract 0 position
        buffer := buffer.extract (position + 1) buffer.size
        if discarding then
          discarding := false
        else
          let trimmed :=
            if line.size > 0 && line.get! (line.size - 1) == 0x0D then
              line.extract 0 (line.size - 1)
            else
              line
          if trimmed.size == 0 then
            reportUnattributed adapter "adapter command line must not be empty"
          else
            match Bytes.utf8Decode trimmed with
            | .error problem =>
                reportUnattributed adapter s!"adapter command is not valid UTF-8: {problem}"
            | .ok text => handleCommand adapter text
    | none =>
        if buffer.size > maxCommandBytes then
          reportUnattributed adapter "adapter command exceeds the 2 MiB line limit"
          buffer := ByteArray.empty
          discarding := true
        searching := false
  input.set { state with pending := buffer, discarding }

def eventLoop (adapter : Adapter) : ConvexM Unit := do
  let input ← IO.mkRef ({} : InputState)
  let mut running := true
  while running do
    let state ← adapter.get
    match state.client with
    | none => pure ()
    | some client => ConvexM.ignoreFailure client.pump
    relayTurn adapter
    flushOutput adapter

    let current ← adapter.get
    let finished ← input.get
    if (current.closing || finished.atEnd) && current.queue.isEmpty then
      running := false
    else
      let wantsInput := !current.closing && !finished.atEnd
      let liveFd ← match current.client with
        | none => pure Ffi.noDescriptor
        | some client => do pure ((← client.liveDescriptor).getD Ffi.noDescriptor)
      let budget ← match current.client with
        | none => pure 50
        | some client => client.waitBudgetMs 50
      let mask ← ConvexM.attempt "waiting for adapter work"
        (Ffi.poll
          (if wantsInput then current.inputFd else Ffi.noDescriptor) Ffi.wantRead
          (if current.queue.isEmpty then Ffi.noDescriptor else current.outputFd) Ffi.wantWrite
          liveFd Ffi.wantRead
          (UInt32.ofNat (max budget 1)))
      if wantsInput && (mask &&& (Ffi.pollReadable 0 ||| Ffi.pollFailed 0)) != 0 then
        match ← ConvexM.attempt "reading an adapter command"
            (Ffi.readFd current.inputFd 65536) with
        | none => input.modify fun latest => { latest with atEnd := true }
        | some chunk => consumeLines adapter input chunk

/-- `ADAPTER_LISTEN` is a `host:port` pair, and the host may itself contain
colons for IPv6, so the split is on the last one. -/
def splitHostPort (address : String) : Option (String × Nat) :=
  let characters := address.toList
  let portCharacters := (characters.reverse.takeWhile (· != ':')).reverse
  if portCharacters.length ≥ characters.length then
    none
  else
    let host := String.mk (characters.take (characters.length - portCharacters.length - 1))
    match (String.mk portCharacters).toNat? with
    | none => none
    | some port => if host.isEmpty || port < 1 || port > 65535 then none else some (host, port)

def runOverStdio (adapter : Adapter) : ConvexM Unit := do
  ConvexM.attempt "preparing stdin" (Ffi.setNonblocking 0)
  ConvexM.attempt "preparing stdout" (Ffi.setNonblocking 1)
  adapter.modify fun state => { state with inputFd := 0, outputFd := 1 }
  eventLoop adapter

def runOverTcp (adapter : Adapter) (address : String) : ConvexM Unit := do
  let (host, port) ← match splitHostPort address with
    | some parts => pure parts
    | none => throw (ConvexError.protocol "ADAPTER_LISTEN must be host:port")
  let listener ← ConvexM.attempt "binding the adapter listener"
    (Ffi.listen host (UInt32.ofNat port))
  let stderr ← IO.getStderr
  stderr.putStr s!"adapter listening on {address}\n"
  stderr.flush
  -- One controller connection carries the same NDJSON stream as stdio does.
  let deadline := (← Live.nowMs) + 120000
  let connection ← ConvexM.attempt "accepting the adapter controller"
    (Ffi.accept listener deadline)
  ConvexM.ignoreFailure (ConvexM.attempt "closing the listener" (Ffi.connClose listener))
  let descriptor ← ConvexM.attempt "reading the controller descriptor" (Ffi.connFd connection)
  adapter.modify fun state => { state with inputFd := descriptor, outputFd := descriptor }
  eventLoop adapter
  -- The bounded writer has already drained, so retiring the socket here cannot
  -- discard an event the controller was still owed.
  ConvexM.ignoreFailure (ConvexM.attempt "closing the controller connection"
    (Ffi.connClose connection))

def adapterMain (_arguments : List String) : IO UInt32 := do
  let listen ← IO.getEnv "ADAPTER_LISTEN"
  let adapter ← IO.mkRef ({} : AdapterState)
  let session : ConvexM Unit :=
    match listen with
    | some address => if address.isEmpty then runOverStdio adapter else runOverTcp adapter address
    | none => runOverStdio adapter
  match ← session.run with
  | .ok () => pure 0
  | .error problem =>
      let stderr ← IO.getStderr
      stderr.putStr s!"adapter failed: {problem}\n"
      stderr.flush
      pure 1

end Tests.Conformance
