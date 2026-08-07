/-
Tests for the conformance adapter itself.

The shared controller validates every emitted event strictly, so the shapes are
pinned here rather than discovered during a shared run. The output queue and
the relay barriers are driven directly, which is the only way to hold an update
in the exact window between dequeue and publication.
-/

import Tests.Support
import Tests.Fixture
import Tests.Conformance.Adapter

namespace Tests.AdapterTests

open Convex
open Tests.Conformance
open Lean (Json)

def roomArgs : Json := jsonObject [("room", Json.str "fixture")]

/-- An adapter whose output goes to a pipe nobody reads, so admission pressure
is real rather than simulated. -/
def stoppedReaderAdapter : IO (Adapter × Ffi.Conn) := do
  -- A socket pair made from a loopback listener: the client end is written to
  -- and never read, so the kernel buffer fills and stays full.
  let listener ← Ffi.listen "127.0.0.1" 0
  let port ← Ffi.listenPort listener
  let writer ← Ffi.connect "127.0.0.1" port false "127.0.0.1" "" ((← Ffi.nowMs) + 5000)
  let reader ← Ffi.accept listener ((← Ffi.nowMs) + 5000)
  Ffi.connClose listener
  let descriptor ← Ffi.connFd writer
  let readerFd ← Ffi.connFd reader
  -- A machine's autotuned TCP buffers can absorb megabytes before a write to
  -- an unread socket ever blocks, which would make "nobody reads this" an
  -- unreliable way to force admission pressure. Shrinking both ends makes the
  -- point of saturation small and fixed instead of host-dependent.
  Ffi.setSocketBufferSize descriptor 2048
  Ffi.setSocketBufferSize readerFd 2048
  Ffi.setNonblocking descriptor
  let adapter ← IO.mkRef ({ inputFd := descriptor, outputFd := descriptor } : AdapterState)
  pure (adapter, reader)

-- `filler` doubles from 64 bytes until it reaches its argument, so this lands
-- at 65536 bytes: comfortably bigger than the small kernel socket buffers
-- `stoppedReaderAdapter` sets up (so a flood of these saturates fast), while
-- 16 of them (`outputCountLimit`) stays near 1 MiB -- well inside
-- `outputByteLimit` (6 MiB), so the count bound is what actually caps the
-- queue rather than the byte bound quietly capping it lower. A prior version
-- of this used 300000, which doubles to 524288: 16 of *those* is 8 MiB, over
-- the byte budget on its own, so the queue could never reach 16 regardless
-- of anything else this test does.
def bigEvent (index : Nat) : Json :=
  jsonObject
    [ ("type", Json.str "subscription")
    , ("subscriptionId", Json.str "flood")
    , ("value", Json.str (filler 40000))
    , ("index", jsonOfNat index) ]

def runShapes (runner : Runner) : IO Unit := do
  runner.test "adapter/ready-event-shape" do
    let event := renderJson (readyEvent "hello-1" "Lean 4")
    expectContains "protocol version" event "\"protocolVersion\":1"
    expectContains "language" event "\"language\":\"lean\""
    expectContains "type" event "\"type\":\"ready\""
    expectContains "implementation" event "\"implementation\":\"native-lean4\""

  runner.test "adapter/result-omits-empty-logs" do
    let without := renderJson (resultEvent "q-1" (jsonOfNat 3) #[])
    expect "no logs member" (Bytes.findSub? without.toUTF8 "logs".toUTF8).isNone
    let carried := renderJson (resultEvent "q-1" (jsonOfNat 3) #["[LOG] demo:echo"])
    expectContains "logs member" carried "\"logs\":[\"[LOG] demo:echo\"]"

  runner.test "adapter/error-omits-absent-data-and-id" do
    let bare := renderJson (errorEvent (ConvexError.protocol "broken") none)
    expect "no id member" (Bytes.findSub? bare.toUTF8 "\"id\"".toUTF8).isNone
    expect "no data member" (Bytes.findSub? bare.toUTF8 "\"data\"".toUTF8).isNone
    expectContains "name" bare "\"name\":\"ProtocolError\""
    let structured := renderJson
      (errorEvent (ConvexError.function "boom" (some (jsonObject [("code", Json.str "X")])) #[])
        (some "q-2"))
    expectContains "id" structured "\"id\":\"q-2\""
    expectContains "data" structured "\"data\":{\"code\":\"X\"}"

  runner.test "adapter/subscription-event-shapes" do
    let value := renderJson (subscriptionEvent "s-1" { value := some (jsonOfNat 1) })
    expectContains "subscriptionId" value "\"subscriptionId\":\"s-1\""
    expectContains "value" value "\"value\":1"
    expect "no error member" (Bytes.findSub? value.toUTF8 "\"error\"".toUTF8).isNone
    let failed := renderJson
      (subscriptionEvent "s-1" { error := some (ConvexError.transport "gone") })
    expectContains "error" failed "\"name\":\"TransportError\""
    expect "no value member" (Bytes.findSub? failed.toUTF8 "\"value\"".toUTF8).isNone

  runner.test "adapter/closed-and-ack-shapes" do
    -- `Json.compress` does not preserve field insertion order, so pinning an
    -- exact serialised string (as this test originally did) is fragile
    -- against however Lean's own Json type happens to order fields
    -- internally; `ready-event-shape` above pins shape the same
    -- order-independent way this does, via substring checks for values plus
    -- an exact key set via `topLevelKeys`.
    let ack := renderJson (ackEvent "c-1")
    expectContains "ack id" ack "\"id\":\"c-1\""
    expectContains "ack type" ack "\"type\":\"ack\""
    match topLevelKeys ack with
    | .error problem => failure s!"ack scan failed: {problem}"
    | .ok keys => expectEq "ack has exactly id and type" keys.size 2

    let closed := renderJson (closedEvent "c-2")
    expectContains "closed id" closed "\"id\":\"c-2\""
    expectContains "closed type" closed "\"type\":\"closed\""
    match topLevelKeys closed with
    | .error problem => failure s!"closed scan failed: {problem}"
    | .ok keys => expectEq "closed has exactly id and type" keys.size 2

def runStrictness (runner : Runner) : IO Unit := do
  runner.test "adapter/top-level-keys-see-duplicates" do
    match topLevelKeys "{\"id\":\"a\",\"id\":\"b\",\"op\":\"hello\"}" with
    | .error problem => failure s!"scan failed: {problem}"
    | .ok keys => do
        expectEq "three keys" keys.size 3
        expect "duplicate visible" (keys[0]! == "id" && keys[1]! == "id")

  runner.test "adapter/top-level-keys-ignore-nested-and-escaped" do
    match topLevelKeys "{\"op\":\"query\",\"args\":{\"room\":\"r\"},\"path\":\"a\\\"b\"}" with
    | .error problem => failure s!"scan failed: {problem}"
    | .ok keys => do
        expectEq "three top-level keys" keys.size 3
        expect "no nested key" (!keys.contains "room")

  runner.test "adapter/command-shapes-are-pinned" do
    expect "hello known" (commandShape "hello").isSome
    expect "subscribe known" (commandShape "subscribe").isSome
    expect "unknown operation rejected" (commandShape "teleport").isNone
    match commandShape "subscribe" with
    | none => failure "subscribe shape missing"
    | some (allowed, required) => do
        expect "path is optional" (allowed.contains "path" && !required.contains "path")
        expect "subscriptionId is required" (required.contains "subscriptionId")

  runner.test "adapter/id-length-is-bounded" do
    expect "empty id rejected" (!validShortString "")
    expect "long id rejected" (!validShortString (String.mk (List.replicate 129 'a')))
    expect "ordinary id accepted" (validShortString "client-subscribe-1")

def runOutputQueue (runner : Runner) : IO Unit := do
  runner.test "adapter/stopped-reader-drops-only-droppable-events" do
    let (adapter, reader) ← stoppedReaderAdapter
    -- Flood the queue with subscription events nobody will read.
    let mut index := 0
    while index < 60 do
      let _ ← expectOk "publish" (publish adapter (bigEvent index) true)
      index := index + 1
    let state ← adapter.get
    expect s!"count bound held, saw {state.queue.size}" (state.queue.size ≤ outputCountLimit)
    expect s!"byte bound held, saw {state.queuedBytes}" (state.queuedBytes ≤ outputByteLimit)
    Ffi.connClose reader

  runner.test "adapter/non-droppable-event-fails-on-its-admission-deadline" do
    let (adapter, reader) ← stoppedReaderAdapter
    -- Fill the kernel buffer and the queue with droppable events first.
    let mut index := 0
    let mut refused := 0
    while index < 40 do
      let admitted ← expectOk "flood" (publish adapter (bigEvent index) true)
      if !admitted then refused := refused + 1
      index := index + 1
    let flooded ← adapter.get
    expect "flood admitted every droppable event" (refused == 0)
    expect "flood saturated the queue" (flooded.queue.size == outputCountLimit)
    -- Acknowledgements may not be dropped, so each one evicts a droppable
    -- event until the queue holds nothing but acknowledgements -- unless the
    -- event sitting at the head of the queue is itself a droppable one that a
    -- prior write already partly sent. That head can never be evicted (the
    -- peer already has the start of its bytes; skipping the rest would
    -- desync the whole NDJSON stream for good), so a non-droppable publish
    -- that lands on that exact state has nothing left to evict and correctly
    -- times out right here instead of later. Both outcomes exercise the same
    -- admission-deadline guarantee this test is named for, so both are
    -- accepted: the loop below stops the moment either happens.
    let mut refusedDuringAcks := false
    index := 0
    while index < outputCountLimit && !refusedDuringAcks do
      let admitted ← expectOk "publish ack" (ConvexM.catchError
        (do let _ ← publish adapter (ackEvent s!"a-{index}") false; pure true)
        (fun problem => do
          expectContains "backpressure reported" problem.message "backpressured"
          pure false))
      if !admitted then
        refusedDuringAcks := true
      index := index + 1
    if !refusedDuringAcks then
      let state ← adapter.get
      expect "queue is full of undroppable events" (state.queue.size == outputCountLimit)
      -- One more has to fail on its admission deadline rather than block
      -- forever or silently disappear.
      let admitted ← expectWithin "admission deadline" 12000 (expectOk "extra publish"
        (ConvexM.catchError
          (do let _ ← publish adapter (ackEvent "one-too-many") false; pure true)
          (fun problem => do
            expectContains "backpressure reported" problem.message "backpressured"
            pure false)))
      expect "admission was refused" (!admitted)
    Ffi.connClose reader

  runner.test "adapter/oversized-event-is-refused-outright" do
    let (adapter, reader) ← stoppedReaderAdapter
    let enormous := jsonObject
      [ ("type", Json.str "subscription")
      , ("subscriptionId", Json.str "s")
      , ("value", Json.str (filler (outputByteLimit + 16) 'y')) ]
    let _ ← expectFailure "publish" "output budget" (publish adapter enormous true)
    Ffi.connClose reader

def runRelayBarriers (runner : Runner) : IO Unit := do
  runner.test "adapter/unsubscribe-invalidates-a-dequeued-update" do
    let fixture ← startFixture "sync-basic"
    let (adapter, reader) ← stoppedReaderAdapter
    let client ← expectOk "client" (Client.new fixture.url)
    adapter.modify fun state => { state with client := some client, helloSeen := true }
    let subscription ← expectOk "subscribe" (client.subscribe "demo:state" roomArgs)
    fixture.expectNote "connect" "note Connect connectionCount=0 lastCloseReason=InitialConnect"
    fixture.expectNote "add" "note ModifyQuerySet Add:0:demo:state"
    let registration := 1
    adapter.modify fun state =>
      { state with
        relays := #[{ key := "s-1", subscription, registration }]
        generations := #[("s-1", registration)]
        queue := #[]
        queuedBytes := 0 }

    -- Hold a real update in the window a relay would occupy: dequeued from the
    -- client, not yet published.
    let update ← expectOk "await update" (do
      let mut held : Option Update := none
      let mut attempts := 0
      while held.isNone && attempts < 400 do
        client.pump
        held ← client.takeUpdate subscription
        attempts := attempts + 1
      pure held)
    match update with
    | none => failure "no update was delivered to hold"
    | some held => do
        -- The unsubscribe barrier runs while that update is still in hand.
        let _ ← expectOk "invalidate" (invalidateRelay adapter "s-1")
        let published ← expectOk "publish stale"
          (publishRelayUpdate adapter "s-1" registration held)
        expect "stale update was refused" (!published)
        let state ← adapter.get
        expect "nothing was queued" state.queue.isEmpty
    expectOk "close" client.close
    Ffi.connClose reader
    fixture.stop

  runner.test "adapter/debug-disconnect-floor-drops-retired-generations" do
    let (adapter, _reader) ← stoppedReaderAdapter
    adapter.modify fun state =>
      { state with
        relays := #[{ key := "s-2", subscription := { id := 0 }, registration := 1 }]
        generations := #[("s-2", 1)]
        minimumLiveGeneration := 4 }
    let stale ← expectOk "publish stale"
      (publishRelayUpdate adapter "s-2" 1 { value := some (jsonOfNat 1), generation := 3 })
    expect "older generation refused" (!stale)
    let fresh ← expectOk "publish fresh"
      (publishRelayUpdate adapter "s-2" 1 { value := some (jsonOfNat 2), generation := 4 })
    expect "current generation accepted" fresh

  runner.test "adapter/listen-address-parsing" do
    match splitHostPort "0.0.0.0:8080" with
    | some (host, port) => do
        expectEq "host" host "0.0.0.0"
        expectEq "port" port 8080
    | none => failure "0.0.0.0:8080 should parse"
    expect "missing port rejected" (splitHostPort "0.0.0.0").isNone
    expect "out of range port rejected" (splitHostPort "0.0.0.0:70000").isNone
    expect "empty host rejected" (splitHostPort ":8080").isNone

def adapterMainTests : IO UInt32 := do
  let runner ← Runner.new "adapter"
  runShapes runner
  runStrictness runner
  runOutputQueue runner
  runRelayBarriers runner
  runner.finish

end Tests.AdapterTests

def main : IO UInt32 := Tests.AdapterTests.adapterMainTests
