/-
Live behaviour against a scripted Convex sync peer.

These are the failure modes an ordinary happy-path test never reaches: a query
that fails and then recovers on the same subscription, five real reconnects
each of which has to resend the active operations, protocol drift that must be
survivable, and a stopped reader that must not turn into unbounded memory.
-/

import Tests.Support
import Tests.Fixture

namespace Tests.LiveTests

open Convex
open Lean (Json)

def roomArgs : Json := jsonObject [("room", Json.str "fixture")]

def clientFor (fixture : Fixture) : ConvexM Client :=
  Client.new fixture.url { clientVersion := "lean-test" }

/-- Wait for a delivered value, failing the test rather than hanging. -/
def nextValue (client : Client) (subscription : Subscription) (label : String) : IO Json := do
  match ← expectOk label (client.nextUpdate subscription 10000) with
  | none => failure s!"{label}: no update arrived"
  | some update =>
      match update.error with
      | some problem => failure s!"{label}: unexpected {problem.name}: {problem.message}"
      | none =>
          match update.value with
          | some value => pure value
          | none => failure s!"{label}: update carried neither value nor error"

def countOf (label : String) (value : Json) : IO Int := do
  match jsonObjVal? value "count" >>= jsonIntegral? with
  | some count => pure count
  | none => failure s!"{label}: no whole count in {renderJson value}"

def runLive (runner : Runner) : IO Unit := do
  runner.test "live/initial-update-external-change-and-suppressed-rehydration" do
    let fixture ← startFixture "sync-basic"
    let client ← expectOk "client" (clientFor fixture)
    let subscription ← expectOk "subscribe" (client.subscribe "demo:state" roomArgs)
    -- The fixture reports what the client actually put on the wire.
    fixture.expectNote "connect" "note Connect connectionCount=0 lastCloseReason=InitialConnect"
    fixture.expectNote "add" "note ModifyQuerySet Add:0:demo:state"

    let initial ← countOf "initial" (← nextValue client subscription "initial")
    expectEq "initial value" initial (0 : Int)
    fixture.step
    let external ← countOf "external" (← nextValue client subscription "external")
    expectEq "external update" external (1 : Int)

    -- The third transition repeats the same value. It must be suppressed, so
    -- the next delivery is the fourth transition's new value.
    fixture.step
    fixture.step
    expectEq "unchanged value suppressed"
      (← countOf "suppressed" (← nextValue client subscription "after suppression")) (2 : Int)

    expectOk "unsubscribe" (client.unsubscribe subscription)
    expectOk "close" client.close
    fixture.stop

  runner.test "live/query-failure-then-recovery-on-the-same-subscription" do
    let fixture ← startFixture "sync-failed-recovery"
    let client ← expectOk "client" (clientFor fixture)
    let subscription ← expectOk "subscribe" (client.subscribe "demo:requiresNonzero" roomArgs)
    fixture.expectNote "connect" "note Connect connectionCount=0 lastCloseReason=InitialConnect"
    fixture.expectNote "add" "note ModifyQuerySet Add:0:demo:requiresNonzero"

    match ← expectOk "failure update" (client.nextUpdate subscription 10000) with
    | none => failure "no failure update arrived"
    | some update =>
        match update.error with
        | some (.function _ data _) =>
            match data >>= (jsonObjVal? · "code") >>= jsonStr? with
            | some code => expectEq "error code" code "ROOM_EMPTY"
            | none => failure "QueryFailed lost its structured data"
        | some other => failure s!"expected a function error, got {other.name}"
        | none => failure "expected a failure first"

    -- Recovery has to arrive on the same subscription, not a new one.
    fixture.step
    let recovered ← countOf "recovered" (← nextValue client subscription "recovered")
    expectEq "recovered value" recovered (1 : Int)

    expectOk "unsubscribe" (client.unsubscribe subscription)
    expectOk "close" client.close
    fixture.stop

  runner.test "live/five-real-reconnects-each-resend-the-active-operations" do
    let fixture ← startFixture "sync-reconnect"
    let client ← expectOk "client" (clientFor fixture)
    let subscription ← expectOk "subscribe" (client.subscribe "demo:state" roomArgs)
    fixture.expectNote "connect 1" "note Connect connectionCount=0 lastCloseReason=InitialConnect"
    fixture.expectNote "add 1" "note ModifyQuerySet Add:0:demo:state"
    expectEq "first value"
      (← countOf "first" (← nextValue client subscription "first")) (1 : Int)

    let mut round := 1
    while round ≤ 5 do
      fixture.step
      -- The acknowledgement comes back only after the old connection has been
      -- retired and its replacement scheduled.
      let generation ← expectOk "debugDisconnect" client.debugDisconnect
      expect "generation advances" (generation ≥ round + 1)
      -- Every replacement connection carries the growing connection count, the
      -- reason the last one ended, and the still-active Add.
      fixture.expectNote s!"connect {round + 1}"
        s!"note Connect connectionCount={round} lastCloseReason=DebugDisconnect"
      fixture.expectNote s!"add {round + 1}" "note ModifyQuerySet Add:0:demo:state"
      let value ← nextValue client subscription s!"reconnect {round}"
      let observed ← countOf "reconnect" value
      expectEq s!"value after reconnect {round}" observed (Int.ofNat (round + 1))
      round := round + 1

    expectEq "connection count" (← expectOk "count" (Live.connectionCount client.live)) 5
    let reason ← expectOk "reason" (Live.lastCloseReason client.live)
    expectEq "close reason" reason "DebugDisconnect"
    expect "timestamp carried forward"
      (← expectOk "timestamp" (Live.maxObservedTimestamp client.live)).isSome
    -- Healthy connections must not inherit an old maximum backoff.
    expectEq "backoff reset" (← expectOk "backoff" (Live.backoffMs client.live)) 100

    fixture.step
    expectOk "unsubscribe" (client.unsubscribe subscription)
    expectOk "close" client.close
    fixture.stop

  runner.test "live/protocol-drift-is-survivable" do
    let fixture ← startFixture "sync-drift" #["chunk"]
    let client ← expectOk "client" (clientFor fixture)
    let subscription ← expectOk "subscribe" (client.subscribe "demo:state" roomArgs)
    fixture.expectNote "connect" "note Connect connectionCount=0 lastCloseReason=InitialConnect"
    fixture.expectNote "add" "note ModifyQuerySet Add:0:demo:state"

    -- A TransitionChunk is deferred behaviour, so it is reported as protocol
    -- drift rather than silently dropped or treated as fatal.
    match ← expectOk "drift update" (client.nextUpdate subscription 10000) with
    | none => failure "no drift report arrived"
    | some update =>
        match update.error with
        | some problem => expect "protocol drift" (problem.name == "ProtocolError")
        | none => failure "expected a protocol error"

    -- The same subscription must still be able to deliver a later valid value,
    -- on a connection that counts the retired one and reports why it ended.
    fixture.expectNotePrefix "reconnect"
      "note Connect connectionCount=1 lastCloseReason=TransitionChunk"
    fixture.expectNote "re-add" "note ModifyQuerySet Add:0:demo:state"
    expectEq "recovered after drift"
      (← countOf "recovered" (← nextValue client subscription "after drift")) (5 : Int)

    fixture.step
    expectOk "unsubscribe" (client.unsubscribe subscription)
    expectOk "close" client.close
    fixture.stop

  runner.test "live/stopped-reader-stays-bounded" do
    let fixture ← startFixture "sync-flood"
    let client ← expectOk "client" (clientFor fixture)
    let subscription ← expectOk "subscribe" (client.subscribe "demo:state" roomArgs)
    fixture.expectNote "connect" "note Connect connectionCount=0 lastCloseReason=InitialConnect"
    fixture.expectNote "add" "note ModifyQuerySet Add:0:demo:state"

    -- Forty values of roughly 200 KB each arrive while nothing is consumed.
    -- Pumping has to run concurrently with the flood, because the fixture is
    -- blocked writing until the socket drains; the delivery queue is what has
    -- to stay bounded.
    let started ← nowMs
    while (← nowMs) < started + 4000 do
      expectOk "pump" client.pump
    fixture.expectNote "flood" "note flood complete"

    let queued ← expectOk "queued count" (Live.queuedCount client.live subscription.id)
    let bytes ← expectOk "queued bytes" (Live.queuedBytes client.live)
    expect s!"count bound held, saw {queued}" (queued ≤ 16)
    expect s!"byte bound held, saw {bytes}" (bytes ≤ 16 * 1024 * 1024)
    -- The newest state must survive the trimming, otherwise a slow consumer
    -- would be left permanently behind.
    let latest ← nextValue client subscription "newest retained"
    expect "a value is still available" (jsonObjVal? latest "count").isSome

    fixture.step
    expectOk "unsubscribe" (client.unsubscribe subscription)
    expectOk "close" client.close
    fixture.stop

  runner.test "live/unsubscribe-and-close-stay-bounded-against-a-silent-peer" do
    let fixture ← startFixture "sync-basic"
    let client ← expectOk "client" (clientFor fixture)
    let subscription ← expectOk "subscribe" (client.subscribe "demo:state" roomArgs)
    fixture.expectNote "connect" "note Connect connectionCount=0 lastCloseReason=InitialConnect"
    fixture.expectNote "add" "note ModifyQuerySet Add:0:demo:state"
    expectEq "initial"
      (← countOf "initial" (← nextValue client subscription "initial")) (0 : Int)

    -- The fixture is now parked on `awaitStep` and will never answer again.
    expectWithin "unsubscribe deadline" 4000
      (expectOk "unsubscribe" (client.unsubscribe subscription))
    expectWithin "close deadline" 4000 (expectOk "close" client.close)
    -- A closed client refuses further work instead of hanging.
    let problem ← expectFailure "query after close" "closed" (client.query "demo:state" roomArgs)
    expect "reported as closed" (problem.name == "ClosedError")
    fixture.stop

def liveMain : IO UInt32 := do
  let runner ← Runner.new "live"
  runLive runner
  runner.finish

end Tests.LiveTests

def main : IO UInt32 := Tests.LiveTests.liveMain
