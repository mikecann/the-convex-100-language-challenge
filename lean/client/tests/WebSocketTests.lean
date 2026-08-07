/-
RFC 6455 framing against deliberately awkward peers.

The interesting cases are the ones where a frame is not a tidy unit: a header
that declares more than the client will ever hold, a character split across two
continuation frames and two TCP writes, and a frame that stops half way and
never resumes.
-/

import Tests.Support
import Tests.Fixture

namespace Tests.WebSocketTests

open Convex

def connectTo (fixture : Fixture) : ConvexM WebSocket := do
  let endpoint := fixture.endpoint "/api/sync"
  let deadline := (← Live.nowMs) + 10000
  WebSocket.connect endpoint {} "lean-test" deadline

def runWebSocket (runner : Runner) : IO Unit := do
  runner.test "websocket/handshake-is-verified" do
    -- The fixture computes the accept token the way a server does, so a
    -- successful connect is evidence the client checked it rather than
    -- accepting any 101.
    let fixture ← startFixture "ws-ping"
    let socket ← expectOk "connect" (connectTo fixture)
    let message ← expectOk "receive" (do
      let deadline := (← Live.nowMs) + 10000
      WebSocket.receive socket deadline)
    match message with
    | some (.text text) => expectEq "text after ping" text "after ping"
    | _ => failure "expected a text message after the ping"
    -- The client answered the ping with a pong before delivering the text.
    let note ← fixture.note
    expectEq "pong observed" note "note client replied AB"
    fixture.step
    expectOk "close" (WebSocket.close socket ((← nowMs) + 2000))
    expectEq "fixture exit" (← fixture.finish) (0 : UInt32)

  runner.test "websocket/oversized-declared-frame-is-refused-before-buffering" do
    let fixture ← startFixture "ws-huge-frame"
    let socket ← expectOk "connect" (connectTo fixture)
    -- One terabyte is declared and nothing follows it. Rejecting quickly is
    -- the evidence that the bound was applied to the header, not to bytes that
    -- had already been read.
    let problem ← expectWithin "frame bound" 3000 do
      expectFailure "receive" "beyond the" (do
        let deadline := (← Live.nowMs) + 10000
        WebSocket.receive socket deadline)
    expect "reported as protocol drift" (problem.name == "ProtocolError")
    fixture.step
    expectOk "close" (WebSocket.close socket ((← nowMs) + 2000))
    expectEq "fixture exit" (← fixture.finish) (0 : UInt32)

  runner.test "websocket/fragmented-utf8-is-reassembled" do
    let fixture ← startFixture "ws-fragmented-utf8"
    let socket ← expectOk "connect" (connectTo fixture)
    let message ← expectOk "receive" (do
      let deadline := (← Live.nowMs) + 10000
      WebSocket.receive socket deadline)
    match message with
    | some (.text text) => expectEq "reassembled text" text "ab世界"
    | _ => failure "expected the reassembled text message"
    fixture.step
    expectOk "close" (WebSocket.close socket ((← nowMs) + 2000))
    expectEq "fixture exit" (← fixture.finish) (0 : UInt32)

  runner.test "websocket/half-frame-deadline-preserves-parser-state" do
    let fixture ← startFixture "ws-half-frame"
    let socket ← expectOk "connect" (connectTo fixture)
    -- Four of the ten declared payload bytes arrive, then silence. The read
    -- must end on its deadline rather than on the peer's goodwill.
    let problem ← expectWithin "half frame deadline" 4000 do
      expectFailure "receive" "deadline" (do
        let deadline := (← Live.nowMs) + 1500
        WebSocket.receive socket deadline)
    expect "reported as transport" (problem.name == "TransportError")
    -- The fixture now sends the remaining six bytes. A parser that had
    -- resynchronised would read `0x6F 0x20` as a fresh frame header and
    -- deliver nonsense; this one resumes the suspended frame instead.
    fixture.step
    let message ← expectOk "resumed receive" (do
      let deadline := (← Live.nowMs) + 5000
      WebSocket.receive socket deadline)
    match message with
    | some (.text text) => expectEq "resumed payload" text "hello ther"
    | _ => failure "expected the suspended frame to complete"
    fixture.step
    expectOk "close" (WebSocket.close socket ((← nowMs) + 2000))
    expectEq "fixture exit" (← fixture.finish) (0 : UInt32)

def webSocketMain : IO UInt32 := do
  let runner ← Runner.new "websocket"
  runWebSocket runner
  runner.finish

end Tests.WebSocketTests

def main : IO UInt32 := Tests.WebSocketTests.webSocketMain
