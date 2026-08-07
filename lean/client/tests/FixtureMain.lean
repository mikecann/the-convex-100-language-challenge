/-
The fixture executable: one scripted peer per scenario.

Every scenario binds an ephemeral port, prints it, and then follows a fixed
sequence. Where a test needs to control timing it writes `step` on stdin, so no
scenario relies on a sleep to be reproducible.
-/

import Tests.Fixture
import Tests.Support

namespace Tests.FixtureMain

open Convex
open Tests.Fixture

def accept (listener : Ffi.Conn) : IO Stream := do
  let deadline := (← Ffi.nowMs) + 20000
  let connection ← Ffi.accept listener deadline
  Stream.ofConnection connection

/-! ### HTTP scenarios -/

def httpErrorEnvelope (listener : Ffi.Conn) : IO Unit := do
  let stream ← accept listener
  let _ ← readRequestHead stream
  -- A Convex function failure arrives as a structured envelope with a non-2xx
  -- status. The client has to read the envelope, not the status code.
  writeAll stream (httpResponse "400 Bad Request"
    ("{\"status\":\"error\",\"errorMessage\":\"Uncaught ConvexError\"," ++
     "\"errorData\":{\"code\":\"FIXTURE_FAIL\",\"message\":\"deliberate\"}," ++
     "\"logLines\":[\"[LOG] fixture failing on purpose\"]}"))
  run stream.close

def httpPlainError (listener : Ffi.Conn) : IO Unit := do
  let stream ← accept listener
  let _ ← readRequestHead stream
  -- Not an envelope at all: the client must report drift including the status.
  writeAll stream (httpResponse "503 Service Unavailable" "upstream is down" "text/plain")
  run stream.close

def httpChunked (listener : Ffi.Conn) : IO Unit := do
  let stream ← accept listener
  let _ ← readRequestHead stream
  let body := successEnvelope 7
  let characters := body.toList
  let firstHalf := String.mk (characters.take (characters.length / 2))
  let secondHalf := String.mk (characters.drop (characters.length / 2))
  writeAll stream
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
  writeAll stream (hex firstHalf.toUTF8.size ++ "\r\n" ++ firstHalf ++ "\r\n")
  writeAll stream (hex secondHalf.toUTF8.size ++ "\r\n" ++ secondHalf ++ "\r\n")
  writeAll stream "0\r\n\r\n"
  run stream.close

def httpOversize (listener : Ffi.Conn) : IO Unit := do
  let stream ← accept listener
  let _ ← readRequestHead stream
  -- The declared length alone must be refused, before any body is buffered.
  writeAll stream
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 999999999\r\n\r\n"
  awaitStep
  run stream.close

def httpEndlessChunks (listener : Ffi.Conn) : IO Unit := do
  let stream ← accept listener
  let _ ← readRequestHead stream
  writeAll stream "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
  let chunkBody := filler 65536
  let mut sent := 0
  try
    while sent < 512 do
      writeAll stream ("10000\r\n" ++ chunkBody ++ "\r\n")
      sent := sent + 1
  catch _ =>
    announce "note client stopped reading the endless body"
  run stream.close

def httpDribble (listener : Ffi.Conn) : IO Unit := do
  let stream ← accept listener
  let _ ← readRequestHead stream
  writeAll stream
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1000000\r\n\r\n"
  -- One byte at a time forever: only an absolute deadline stops this.
  let mut sent := 0
  try
    while sent < 400 do
      writeBytes stream (ByteArray.mk #[(120 : UInt8)])
      sleepMs 100
      sent := sent + 1
  catch _ =>
    announce "note client abandoned the dribbling body"
  run stream.close

def tlsEcho (listener : Ffi.Conn) (certificate key : String) : IO Unit := do
  let deadline := (← Ffi.nowMs) + 20000
  let connection ← Ffi.accept listener deadline
  try
    Ffi.serverHandshake connection certificate key deadline
    let stream ← Stream.ofConnection connection
    let _ ← readRequestHead stream
    writeAll stream (httpResponse "200 OK" (successEnvelope 3))
    run stream.close
  catch problem =>
    -- A client that correctly refuses the chain aborts during the handshake.
    announce s!"note tls handshake ended: {problem}"

/-! ### WebSocket scenarios -/

def wsHugeFrame (listener : Ffi.Conn) : IO Unit := do
  let stream ← accept listener
  acceptWebSocket stream
  -- A 64-bit length of about one terabyte with no payload behind it. The
  -- client must reject on the header rather than try to buffer it.
  writeBytes stream (ByteArray.mk
    #[(0x81 : UInt8), 0x7F, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00])
  awaitStep
  run stream.close

def wsFragmentedUtf8 (listener : Ffi.Conn) : IO Unit := do
  let stream ← accept listener
  acceptWebSocket stream
  -- "ab世界" split so the three bytes of 世 straddle two frames, and the frames
  -- themselves straddle two TCP writes.
  let full := "ab世界".toUTF8
  let firstPart := full.extract 0 3
  let secondPart := full.extract 3 full.size
  let mut frame := ByteArray.empty
  frame := frame.push 0x01
  frame := frame.push (UInt8.ofNat firstPart.size)
  frame := frame ++ firstPart
  frame := frame.push 0x80
  frame := frame.push (UInt8.ofNat secondPart.size)
  frame := frame ++ secondPart
  writeBytes stream (frame.extract 0 4)
  sleepMs 40
  writeBytes stream (frame.extract 4 frame.size)
  awaitStep
  run stream.close

def wsHalfFrame (listener : Ffi.Conn) : IO Unit := do
  let stream ← accept listener
  acceptWebSocket stream
  -- A declared ten byte payload with only four bytes behind it, then silence.
  writeBytes stream (ByteArray.mk #[(0x81 : UInt8), 0x0A, 0x68, 0x65, 0x6C, 0x6C])
  awaitStep
  -- The rest arrives only after the client has already given up, proving it
  -- never resumed the abandoned frame.
  writeBytes stream (ByteArray.mk #[(0x6F : UInt8), 0x20, 0x74, 0x68, 0x65, 0x72])
  awaitStep
  run stream.close

def wsPingThenText (listener : Ffi.Conn) : IO Unit := do
  let stream ← accept listener
  acceptWebSocket stream
  writeBytes stream (ByteArray.mk #[(0x89 : UInt8), 0x02, 0x41, 0x42])
  sendServerText stream "after ping"
  let deadline := (← Ffi.nowMs) + 10000
  let pong ← readClientText stream deadline
  announce s!"note client replied {pong}"
  awaitStep
  run stream.close

/-! ### Convex sync scenarios -/

/-- Initial hydration, then a changed value, then an unchanged repeat the
client must suppress, then a changed value again. -/
def syncBasic (listener : Ffi.Conn) : IO Unit := do
  let stream ← accept listener
  acceptWebSocket stream
  let deadline := (← Ffi.nowMs) + 20000
  observeSyncOpening stream deadline
  sendServerText stream (transitionMessage 0 0 1 1 (queryUpdated 0 0))
  awaitStep
  sendServerText stream (transitionMessage 1 1 1 2 (queryUpdated 0 1))
  awaitStep
  sendServerText stream (transitionMessage 1 2 1 3 (queryUpdated 0 1))
  awaitStep
  sendServerText stream (transitionMessage 1 3 1 4 (queryUpdated 0 2))
  awaitStep
  run stream.close

/-- A failing query, then the same subscription recovering with a value. -/
def syncFailedRecovery (listener : Ffi.Conn) : IO Unit := do
  let stream ← accept listener
  acceptWebSocket stream
  let deadline := (← Ffi.nowMs) + 20000
  observeSyncOpening stream deadline
  sendServerText stream (transitionMessage 0 0 1 1 (queryFailed 0))
  awaitStep
  sendServerText stream (transitionMessage 1 1 1 2 (queryUpdated 0 1))
  awaitStep
  run stream.close

/-- Six connections in a row. Each reports the Connect metadata it received and
the operations that were resent on it. -/
def syncReconnect (listener : Ffi.Conn) : IO Unit := do
  let mut round := 0
  while round < 6 do
    let stream ← accept listener
    acceptWebSocket stream
    let deadline := (← Ffi.nowMs) + 20000
    observeSyncOpening stream deadline
    -- A different value each round, so a delivered update proves this
    -- connection produced it rather than a suppressed rehydration.
    sendServerText stream (transitionMessage 0 0 1 (round + 1) (queryUpdated 0 (round + 1)))
    awaitStep
    -- The client retires this connection itself; waiting for that keeps the
    -- next accept from racing the old socket's shutdown.
    drainUntilPeerGone stream
    run stream.close
    round := round + 1

/-- Drift the client must treat as recoverable rather than fatal. -/
def syncDrift (listener : Ffi.Conn) (kind : String) : IO Unit := do
  let stream ← accept listener
  acceptWebSocket stream
  let deadline := (← Ffi.nowMs) + 20000
  observeSyncOpening stream deadline
  if kind == "chunk" then
    sendServerText stream "{\"type\":\"TransitionChunk\",\"parts\":[]}"
  else if kind == "mismatch" then
    sendServerText stream (transitionMessage 1 5 1 6 (queryUpdated 0 1))
  else
    sendServerText stream "{\"type\":\"Nonsense\"}"
  -- The client retires this connection and comes back; the replacement must be
  -- able to deliver a real value on the same subscription.
  let second ← accept listener
  acceptWebSocket second
  let secondDeadline := (← Ffi.nowMs) + 20000
  observeSyncOpening second secondDeadline
  sendServerText second (transitionMessage 0 0 1 9 (queryUpdated 0 5))
  awaitStep
  run second.close
  run stream.close

/-- Large values with no consumer, to show the delivery queue stays bounded. -/
def syncFlood (listener : Ffi.Conn) : IO Unit := do
  let stream ← accept listener
  acceptWebSocket stream
  let deadline := (← Ffi.nowMs) + 20000
  observeSyncOpening stream deadline
  let payloadFiller := filler 200000 'z'
  let mut round := 0
  while round < 40 do
    let payload :=
      "{\"type\":\"QueryUpdated\",\"queryId\":0,\"value\":{\"count\":" ++ s!"{round}" ++
        ",\"filler\":\"" ++ payloadFiller ++ "\"},\"logLines\":[]}"
    -- A fresh client's remoteVersion starts at querySet 0, matching every
    -- other scenario's first transition; only round 0 crosses that boundary,
    -- and every subsequent round chains from where the previous one ended.
    let startQuerySet := if round == 0 then 0 else 1
    sendServerText stream (transitionMessage startQuerySet round 1 (round + 1) payload)
    round := round + 1
  announce "note flood complete"
  awaitStep
  run stream.close

/-- The journey the canonical example performs, served over the three
connections it makes, in order. -/
def exampleBackend (listener : Ffi.Conn) (fractional : Bool) : IO Unit := do
  let room := "fixture"
  let queryStream ← accept listener
  let _ ← readRequestHead queryStream
  writeAll queryStream (httpResponse "200 OK" (successEnvelope 0 fractional room))
  run queryStream.close

  if fractional then
    -- The example must refuse a fractional count, so nothing further happens.
    announce "note fractional count served"
    return ()

  let socketStream ← accept listener
  acceptWebSocket socketStream
  let deadline := (← Ffi.nowMs) + 20000
  observeSyncOpening socketStream deadline
  sendServerText socketStream (transitionMessage 0 0 1 1 (queryUpdated 0 0))

  let mutationStream ← accept listener
  let mutationHead ← readRequestHead mutationStream
  if !(Bytes.findSub? mutationHead.toUTF8 "/api/mutation".toUTF8).isSome then
    throw (IO.userError "fixture expected a mutation request")
  writeAll mutationStream (httpResponse "200 OK" (mutationEnvelope 1 room))
  run mutationStream.close

  sendServerText socketStream (transitionMessage 1 1 1 2 (queryUpdated 0 1))
  announce "note example journey served"
  awaitStep
  run socketStream.close

/-! ### Entry point -/

def dispatch (scenario : String) (extra : List String) (listener : Ffi.Conn) : IO Unit :=
  match scenario, extra with
  | "http-error-envelope", _ => httpErrorEnvelope listener
  | "http-plain-error", _ => httpPlainError listener
  | "http-chunked", _ => httpChunked listener
  | "http-oversize", _ => httpOversize listener
  | "http-endless-chunks", _ => httpEndlessChunks listener
  | "http-dribble", _ => httpDribble listener
  | "tls-echo", [certificate, key] => tlsEcho listener certificate key
  | "ws-huge-frame", _ => wsHugeFrame listener
  | "ws-fragmented-utf8", _ => wsFragmentedUtf8 listener
  | "ws-half-frame", _ => wsHalfFrame listener
  | "ws-ping", _ => wsPingThenText listener
  | "sync-basic", _ => syncBasic listener
  | "sync-failed-recovery", _ => syncFailedRecovery listener
  | "sync-reconnect", _ => syncReconnect listener
  | "sync-drift", [kind] => syncDrift listener kind
  | "sync-flood", _ => syncFlood listener
  | "example-backend", _ => exampleBackend listener false
  | "example-fractional", _ => exampleBackend listener true
  | other, _ => throw (IO.userError s!"unknown fixture scenario: {other}")

def fixtureMain (arguments : List String) : IO UInt32 := do
  match arguments with
  | [] =>
      announce "error a scenario name is required"
      pure 2
  | scenario :: extra => do
      let listener ← Ffi.listen "127.0.0.1" 0
      let port ← Ffi.listenPort listener
      announce s!"port {port}"
      try
        dispatch scenario extra listener
        Ffi.connClose listener
        pure 0
      catch problem =>
        announce s!"error {problem}"
        pure 1

end Tests.FixtureMain

def main (arguments : List String) : IO UInt32 := Tests.FixtureMain.fixtureMain arguments
