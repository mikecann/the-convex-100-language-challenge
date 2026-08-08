/-
Deterministic raw HTTP and WebSocket peers, written in Lean against the same
socket shim the client uses.

Each scenario is a script rather than a general server. It advances only when
the test writes `step` on stdin, and it prints a `note` line for every protocol
fact it observed, so a test can assert what the client actually put on the wire
instead of inferring it from a successful outcome.

Nothing here is linked into the client: these are test peers that happen to
misbehave on purpose.
-/

import Convex

namespace Tests.Fixture

open Convex
open Lean (Json)

-- Named `announce`, not `note`: `Tests.Support` separately defines
-- `Fixture.note` as a method on its own `Fixture` process-handle structure
-- (the parent test's side, reading a line this function writes), and Lean
-- rejects two same-named declarations under `Tests.Fixture` once a test file
-- imports both modules together.
def announce (text : String) : IO Unit := do
  let stdout ← IO.getStdout
  stdout.putStr s!"{text}\n"
  stdout.flush

/-- Block until the test releases the next scripted action. -/
def awaitStep : IO Unit := do
  let stdin ← IO.getStdin
  let line ← stdin.getLine
  if line.isEmpty then
    throw (IO.userError "fixture stdin closed before the script finished")

def farFuture : IO UInt64 := do pure ((← Ffi.nowMs) + 30000)

def shortFuture (ms : UInt64) : IO UInt64 := do pure ((← Ffi.nowMs) + ms)

def sleepMs (ms : UInt32) : IO Unit := do
  let _ ← Ffi.poll Ffi.noDescriptor Ffi.wantNothing Ffi.noDescriptor Ffi.wantNothing
    Ffi.noDescriptor Ffi.wantNothing ms

def run {α : Type} (action : ConvexM α) : IO α := ConvexM.orThrowIO action

/-! ### Raw request and response helpers -/

def readRequestHead (stream : Stream) : IO String := run do
  -- The request head must arrive inside a generous but finite window.
  let deadline := (← Live.nowMs) + 10000
  let block ← stream.readUntil "\r\n\r\n".toUTF8 65536 deadline
  liftExcept "fixture request" (Bytes.asciiToString block)

def writeAll (stream : Stream) (text : String) : IO Unit := run do
  stream.writeString text ((← Live.nowMs) + 10000)

def writeBytes (stream : Stream) (bytes : ByteArray) : IO Unit := run do
  stream.write bytes ((← Live.nowMs) + 10000)

/-- Read until the client has gone away. A reconnect scenario uses this so the
next `accept` belongs to a genuinely new connection rather than racing the old
one's shutdown. -/
def drainUntilPeerGone (stream : Stream) : IO Unit := do
  let deadline := (← Ffi.nowMs) + 20000
  let mut waiting := true
  while waiting do
    match ← (stream.fill deadline).run with
    | .ok true => pure ()
    | _ => waiting := false

def successEnvelope (count : Nat) (fractional : Bool := false)
    (room : String := "fixture") : String :=
  let countText := if fractional then s!"{count}.5" else s!"{count}.0"
  "{\"status\":\"success\",\"value\":{\"room\":\"" ++ room ++
    "\",\"count\":" ++ countText ++
    ",\"lastLanguage\":null,\"latestRunId\":null,\"updatedAt\":null}," ++
    "\"logLines\":[\"[LOG] fixture served demo:state\"]}"

def mutationEnvelope (count : Nat) (room : String := "fixture") : String :=
  "{\"status\":\"success\",\"value\":{\"applied\":true,\"state\":{\"room\":\"" ++ room ++
    "\",\"count\":" ++ s!"{count}.0" ++
    ",\"lastLanguage\":\"lean\",\"latestRunId\":\"fixture\",\"updatedAt\":0}}," ++
    "\"logLines\":[]}"

def httpResponse (status : String) (body : String) (contentType : String := "application/json") :
    String :=
  s!"HTTP/1.1 {status}\r\nContent-Type: {contentType}\r\n" ++
    s!"Content-Length: {body.toUTF8.size}\r\nConnection: close\r\n\r\n" ++ body

/-! ### Server-side WebSocket framing -/

private def serverFrame (opcode : UInt8) (payload : ByteArray) : ByteArray := Id.run do
  let mut frame := ByteArray.empty
  frame := frame.push (0x80 ||| opcode)
  let size := payload.size
  if size < 126 then
    frame := frame.push (UInt8.ofNat size)
  else if size < 65536 then
    frame := frame.push 126
    frame := frame.push (UInt8.ofNat (size / 256))
    frame := frame.push (UInt8.ofNat (size % 256))
  else
    frame := frame.push 127
    let mut index := 0
    while index < 8 do
      frame := frame.push (UInt8.ofNat ((size / (2 ^ (56 - index * 8))) % 256))
      index := index + 1
  return frame ++ payload

def sendServerText (stream : Stream) (text : String) : IO Unit :=
  writeBytes stream (serverFrame 0x1 text.toUTF8)

/-- Complete the RFC 6455 handshake, computing the accept token exactly as a
real server would so the client's own verification is exercised. -/
def acceptWebSocket (stream : Stream) : IO Unit := do
  let head ← readRequestHead stream
  let lines := head.splitOn "\r\n"
  let key := lines.foldl (init := "") fun found line =>
    if (Bytes.asciiLower line).startsWith "sec-websocket-key:" then
      (line.drop 18).trim
    else
      found
  if key.isEmpty then
    throw (IO.userError "fixture saw no Sec-WebSocket-Key")
  let digest ← Ffi.sha1 (key ++ WebSocket.handshakeGuid).toUTF8
  let accept := Bytes.base64Encode digest
  writeAll stream
    ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" ++
     s!"Connection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n")

/-- Read one masked client frame. The fixture needs its own reader because the
client's reader deliberately rejects masked frames. -/
def readClientText (stream : Stream) (deadline : UInt64) : IO String := run do
  let header ← stream.take 2 deadline
  let first := (header.get! 0).toNat
  let second := (header.get! 1).toNat
  let short := second &&& 0x7F
  let size ←
    if short < 126 then
      pure short
    else if short == 126 then do
      let extra ← stream.take 2 deadline
      pure ((extra.get! 0).toNat * 256 + (extra.get! 1).toNat)
    else do
      let extra ← stream.take 8 deadline
      let mut value := 0
      let mut index := 0
      while index < 8 do
        value := value * 256 + (extra.get! index).toNat
        index := index + 1
      pure value
  let mask ← if (second &&& 0x80) != 0 then stream.take 4 deadline else pure ByteArray.empty
  let payload ← stream.take size deadline
  let mut plain := ByteArray.empty
  let mut index := 0
  while index < payload.size do
    if mask.size == 4 then
      plain := plain.push (payload.get! index ^^^ mask.get! (index % 4))
    else
      plain := plain.push (payload.get! index)
    index := index + 1
  if (first &&& 0x0F) == 0x8 then
    pure "__close__"
  else
    liftExcept "fixture frame" (Bytes.utf8Decode plain)

/-! ### Convex sync helpers -/

def timestampFor (value : Nat) : String := Id.run do
  let mut bytes := ByteArray.empty
  let mut remaining := value
  let mut index := 0
  while index < 8 do
    bytes := bytes.push (UInt8.ofNat (remaining % 256))
    remaining := remaining / 256
    index := index + 1
  return Bytes.base64Encode bytes

def hex (value : Nat) : String := String.mk (Nat.toDigits 16 value)

/-- A `Transition` has to start exactly where the client believes it is, so
both versions are given explicitly rather than assumed. -/
def transitionMessage (startQuerySet startTs endQuerySet endTs : Nat)
    (modifications : String) : String :=
  "{\"type\":\"Transition\",\"startVersion\":{\"querySet\":" ++ s!"{startQuerySet}" ++
    ",\"identity\":0,\"ts\":\"" ++ timestampFor startTs ++
    "\"},\"endVersion\":{\"querySet\":" ++ s!"{endQuerySet}" ++
    ",\"identity\":0,\"ts\":\"" ++ timestampFor endTs ++
    "\"},\"modifications\":[" ++ modifications ++ "]}"

def queryUpdated (queryId : Nat) (count : Nat) : String :=
  "{\"type\":\"QueryUpdated\",\"queryId\":" ++ s!"{queryId}" ++
    ",\"value\":{\"room\":\"fixture\",\"count\":" ++ s!"{count}.0" ++
    ",\"lastLanguage\":null,\"latestRunId\":null,\"updatedAt\":null},\"logLines\":[]}"

def queryFailed (queryId : Nat) : String :=
  "{\"type\":\"QueryFailed\",\"queryId\":" ++ s!"{queryId}" ++
    ",\"errorMessage\":\"Uncaught ConvexError\",\"errorData\":{\"code\":\"ROOM_EMPTY\"," ++
    "\"message\":\"Increment the room to repair this reactive query\"},\"logLines\":[]}"

/-- Report the parts of a Connect and a ModifyQuerySet the tests care about, so
each reconnect can be shown to have resent the active operations. -/
def observeSyncOpening (stream : Stream) (deadline : UInt64) : IO Unit := do
  let connectText ← readClientText stream deadline
  let connect ← match parseJsonString connectText with
    | .ok value => pure value
    | .error problem => throw (IO.userError s!"fixture could not parse Connect: {problem}")
  let kind := (jsonObjVal? connect "type" >>= jsonStr?).getD "?"
  let count := (jsonObjVal? connect "connectionCount" >>= jsonNat?).getD 9999
  let reason := (jsonObjVal? connect "lastCloseReason" >>= jsonStr?).getD "?"
  announce s!"note {kind} connectionCount={count} lastCloseReason={reason}"
  let modifyText ← readClientText stream deadline
  let modify ← match parseJsonString modifyText with
    | .ok value => pure value
    | .error problem => throw (IO.userError s!"fixture could not parse ModifyQuerySet: {problem}")
  let modifyKind := (jsonObjVal? modify "type" >>= jsonStr?).getD "?"
  let modifications := (jsonObjVal? modify "modifications" >>= jsonArr?).getD #[]
  let described := modifications.foldl (init := "") fun text item =>
    let kind := (jsonObjVal? item "type" >>= jsonStr?).getD "?"
    let queryId := (jsonObjVal? item "queryId" >>= jsonNat?).getD 9999
    let path := (jsonObjVal? item "udfPath" >>= jsonStr?).getD ""
    text ++ s!" {kind}:{queryId}:{path}"
  announce s!"note {modifyKind}{described}"

end Tests.Fixture
