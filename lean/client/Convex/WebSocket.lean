/-
An RFC 6455 client written on top of the buffered stream.

The frame reader never consumes a byte until the whole frame is buffered, and
it rejects an oversized declared payload the moment the header is readable.
Together those two rules give the property the Live tests check: a deadline
that fires half way through a frame leaves the parser suspended exactly where
it was, and a peer that announces a gigabyte gets an error rather than an
allocation.
-/

import Convex.Http

namespace Convex

namespace WebSocket

/-- The fixed GUID RFC 6455 mixes into the handshake key. -/
def handshakeGuid : String := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

def opcodeContinuation : UInt8 := 0x0
def opcodeText : UInt8 := 0x1
def opcodeBinary : UInt8 := 0x2
def opcodeClose : UInt8 := 0x8
def opcodePing : UInt8 := 0x9
def opcodePong : UInt8 := 0xA

structure Frame where
  final : Bool
  opcode : UInt8
  payload : ByteArray
  deriving Inhabited

inductive Message where
  | text (content : String)
  | binary (content : ByteArray)
  | peerClose (code : Nat) (reason : String)
  deriving Inhabited

end WebSocket

structure WebSocket where
  stream : Stream
  /-- A single frame may not declare more than this. -/
  maxFrameBytes : Nat
  /-- Reassembled fragments may not exceed this in total. -/
  maxMessageBytes : Nat
  /-- Opcode of the message currently being reassembled, if any. -/
  fragmentOpcode : IO.Ref (Option UInt8)
  fragmentBytes : IO.Ref ByteArray
  /-- A multi-byte character may straddle two continuation frames, so the
  decoder state survives between them rather than restarting. -/
  fragmentUtf8 : IO.Ref Bytes.Utf8State
  fragmentText : IO.Ref String
  closeSent : IO.Ref Bool
  sawPeerClose : IO.Ref Bool

namespace WebSocket

private def readBigEndian (bytes : ByteArray) (start count : Nat) : Nat := Id.run do
  let mut value := 0
  let mut index := 0
  while index < count do
    value := value * 256 + (bytes.get! (start + index)).toNat
    index := index + 1
  return value

private def newSocket (stream : Stream) (maxFrameBytes maxMessageBytes : Nat) : IO WebSocket := do
  let fragmentOpcode ← IO.mkRef none
  let fragmentBytes ← IO.mkRef ByteArray.empty
  let fragmentUtf8 ← IO.mkRef Bytes.Utf8State.empty
  let fragmentText ← IO.mkRef ""
  let closeSent ← IO.mkRef false
  let sawPeerClose ← IO.mkRef false
  pure {
    stream, maxFrameBytes, maxMessageBytes,
    fragmentOpcode, fragmentBytes, fragmentUtf8, fragmentText, closeSent, sawPeerClose
  }

private def splitHeaderLine (line : String) : Option (String × String) :=
  let name := line.takeWhile (· != ':')
  let rest := line.dropWhile (· != ':')
  if rest.isEmpty then none else some (Bytes.asciiLower name, (rest.drop 1).trim)

/-- Complete the HTTP upgrade and check the server's proof that it understood
this exact request, rather than accepting any 101. -/
def connect (endpoint : Endpoint) (tls : TlsOptions) (clientVersion : String) (deadline : UInt64)
    (maxFrameBytes : Nat := 2 * 1024 * 1024) (maxMessageBytes : Nat := 2 * 1024 * 1024) :
    ConvexM WebSocket := do
  let stream ← Stream.connect endpoint tls deadline (maxFrameBytes + 64 * 1024)
  let keyBytes ← ConvexM.attempt "generating a WebSocket key" (Ffi.randomBytes 16)
  let key := Bytes.base64Encode keyBytes
  let hostHeader :=
    if (endpoint.secure && endpoint.port == 443) || (!endpoint.secure && endpoint.port == 80) then
      endpoint.host
    else
      s!"{endpoint.host}:{endpoint.port}"
  let request :=
    s!"GET {endpoint.path} HTTP/1.1\r\n" ++
    s!"Host: {hostHeader}\r\n" ++
    "Upgrade: websocket\r\n" ++
    "Connection: Upgrade\r\n" ++
    s!"Sec-WebSocket-Key: {key}\r\n" ++
    "Sec-WebSocket-Version: 13\r\n" ++
    s!"Convex-Client: {clientVersion}\r\n\r\n"

  let handshake : ConvexM WebSocket := do
    stream.writeString request deadline
    let headerBlock ← stream.readUntil "\r\n\r\n".toUTF8 32768 deadline
    let headerText ← liftExcept "Live handshake response" (Bytes.asciiToString headerBlock)
    let lines := headerText.splitOn "\r\n"
    let statusLine := lines.headD ""
    if !statusLine.startsWith "HTTP/1.1 101" then
      throw (ConvexError.protocol s!"Live handshake was refused: {statusLine}")
    let headers := (lines.drop 1).filterMap splitHeaderLine
    let digest ← ConvexM.attempt "hashing the handshake key"
      (Ffi.sha1 (key ++ handshakeGuid).toUTF8)
    let expected := Bytes.base64Encode digest
    match headers.find? (fun entry => entry.1 == "sec-websocket-accept") with
    | none => throw (ConvexError.protocol "Live handshake omitted Sec-WebSocket-Accept")
    | some entry =>
        if entry.2 != expected then
          throw (ConvexError.protocol "Live handshake returned the wrong Sec-WebSocket-Accept")
    let upgraded := headers.any fun entry =>
      entry.1 == "upgrade" && Bytes.asciiLower entry.2 == "websocket"
    if !upgraded then
      throw (ConvexError.protocol "Live handshake did not upgrade to websocket")
    newSocket stream maxFrameBytes maxMessageBytes

  try
    handshake
  catch problem =>
    ConvexM.ignoreFailure stream.close
    throw problem

def ofStream (stream : Stream) (maxFrameBytes : Nat := 2 * 1024 * 1024)
    (maxMessageBytes : Nat := 2 * 1024 * 1024) : IO WebSocket :=
  newSocket stream maxFrameBytes maxMessageBytes

/-- Parse one frame from bytes that have already arrived. Returns `none` when
the frame is incomplete, leaving the stream untouched so the next attempt
resumes at the same header instead of hunting for a new boundary. -/
private def frameAvailable? (socket : WebSocket) : ConvexM (Option Frame) := do
  let buffer ← socket.stream.buffer.get
  let offset ← socket.stream.offset.get
  let size := buffer.size - offset
  if size < 2 then
    return none
  let first := (buffer.get! offset).toNat
  let second := (buffer.get! (offset + 1)).toNat
  let final := (first &&& 0x80) != 0
  if (first &&& 0x70) != 0 then
    throw (ConvexError.protocol "Live frame set a reserved bit")
  let opcode := UInt8.ofNat (first &&& 0x0F)
  if (second &&& 0x80) != 0 then
    throw (ConvexError.protocol "Live server sent a masked frame")
  let short := second &&& 0x7F
  let mut headerSize := 2
  let mut declared := short
  if short == 126 then
    if size < 4 then
      return none
    headerSize := 4
    declared := readBigEndian buffer (offset + 2) 2
  else if short == 127 then
    if size < 10 then
      return none
    headerSize := 10
    declared := readBigEndian buffer (offset + 2) 8
    if declared ≥ 0x8000000000000000 then
      throw (ConvexError.protocol "Live frame declared a payload with the high bit set")
  -- The bound is applied to the declared length, before a payload byte is kept.
  if declared > socket.maxFrameBytes then
    throw (ConvexError.protocol
      s!"Live frame declared {declared} bytes, beyond the {socket.maxFrameBytes} byte limit")
  if opcode.toNat ≥ 0x8 then
    if declared > 125 then
      throw (ConvexError.protocol "Live control frame exceeded 125 bytes")
    if !final then
      throw (ConvexError.protocol "Live control frame was fragmented")
  if size < headerSize + declared then
    return none
  let payload := buffer.extract (offset + headerSize) (offset + headerSize + declared)
  socket.stream.consume (headerSize + declared)
  return some { final, opcode, payload }

private def maskedFrame (opcode : UInt8) (payload : ByteArray) (maskKey : ByteArray) : ByteArray :=
  Id.run do
    let mut frame := ByteArray.empty
    frame := frame.push (0x80 ||| opcode)
    let size := payload.size
    if size < 126 then
      frame := frame.push (0x80 ||| UInt8.ofNat size)
    else if size < 65536 then
      frame := frame.push (0x80 ||| (126 : UInt8))
      frame := frame.push (UInt8.ofNat (size / 256))
      frame := frame.push (UInt8.ofNat (size % 256))
    else
      frame := frame.push (0x80 ||| (127 : UInt8))
      let mut index := 0
      while index < 8 do
        frame := frame.push (UInt8.ofNat ((size / (2 ^ (56 - index * 8))) % 256))
        index := index + 1
    frame := frame ++ maskKey
    let mut index := 0
    while index < size do
      frame := frame.push (payload.get! index ^^^ maskKey.get! (index % 4))
      index := index + 1
    return frame

private def sendFrame (socket : WebSocket) (opcode : UInt8) (payload : ByteArray)
    (deadline : UInt64) : ConvexM Unit := do
  let maskKey ← ConvexM.attempt "generating a frame mask" (Ffi.randomBytes 4)
  socket.stream.write (maskedFrame opcode payload maskKey) deadline

def sendText (socket : WebSocket) (text : String) (deadline : UInt64) : ConvexM Unit := do
  let encoded := text.toUTF8
  if encoded.size > socket.maxFrameBytes then
    throw (ConvexError.protocol "Live message exceeded the outbound frame limit")
  sendFrame socket opcodeText encoded deadline

def sendPong (socket : WebSocket) (payload : ByteArray) (deadline : UInt64) : ConvexM Unit :=
  sendFrame socket opcodePong payload deadline

/-- Send a close frame at most once, bounded by the caller's deadline so an
idle or stalled peer cannot hold the shutdown open. -/
def sendClose (socket : WebSocket) (code : Nat) (reason : String) (deadline : UInt64) :
    ConvexM Unit := do
  if ← socket.closeSent.get then
    return ()
  socket.closeSent.set true
  let mut payload := ByteArray.empty
  payload := payload.push (UInt8.ofNat (code / 256))
  payload := payload.push (UInt8.ofNat (code % 256))
  payload := payload ++ reason.toUTF8
  ConvexM.ignoreFailure (sendFrame socket opcodeClose payload deadline)

private def resetFragments (socket : WebSocket) : ConvexM Unit := do
  socket.fragmentOpcode.set none
  socket.fragmentBytes.set ByteArray.empty
  socket.fragmentUtf8.set Bytes.Utf8State.empty
  socket.fragmentText.set ""

/-- Fold one frame into the message under construction, returning a message
only when a final frame completes it. -/
private def acceptFrame (socket : WebSocket) (frame : Frame) (deadline : UInt64) :
    ConvexM (Option Message) := do
  if frame.opcode == opcodePing then
    sendPong socket frame.payload deadline
    return none
  if frame.opcode == opcodePong then
    return none
  if frame.opcode == opcodeClose then
    socket.sawPeerClose.set true
    let code := if frame.payload.size ≥ 2 then readBigEndian frame.payload 0 2 else 1005
    let tail := frame.payload.extract (min 2 frame.payload.size) frame.payload.size
    let reason := match Bytes.utf8Decode tail with
      | .ok text => text
      | .error _ => ""
    ConvexM.ignoreFailure (sendClose socket 1000 "" deadline)
    return some (Message.peerClose code reason)

  let started ← socket.fragmentOpcode.get
  let opcode ←
    if frame.opcode == opcodeContinuation then
      match started with
      | none => throw (ConvexError.protocol "Live continuation frame had no start frame")
      | some opcode => pure opcode
    else
      match started with
      | some _ => throw (ConvexError.protocol "Live start frame interrupted a fragmented message")
      | none => do
          if frame.opcode != opcodeText && frame.opcode != opcodeBinary then
            throw (ConvexError.protocol
              s!"Live frame used unsupported opcode {frame.opcode.toNat}")
          socket.fragmentOpcode.set (some frame.opcode)
          pure frame.opcode

  if opcode == opcodeText then
    let state ← socket.fragmentUtf8.get
    match Bytes.utf8Feed state frame.payload with
    | .error problem =>
        resetFragments socket
        throw (ConvexError.protocol s!"Live text message was not valid UTF-8: {problem}")
    | .ok (decoded, nextState) =>
        let accumulated ← socket.fragmentText.get
        let combined := accumulated ++ decoded
        if combined.utf8ByteSize > socket.maxMessageBytes then
          resetFragments socket
          throw (ConvexError.protocol "Live message exceeded the reassembly limit")
        socket.fragmentText.set combined
        socket.fragmentUtf8.set nextState
        if frame.final then
          if !nextState.isComplete then
            resetFragments socket
            throw (ConvexError.protocol "Live text message ended part way through a character")
          resetFragments socket
          return some (Message.text combined)
        return none
  else
    let accumulated ← socket.fragmentBytes.get
    if accumulated.size + frame.payload.size > socket.maxMessageBytes then
      resetFragments socket
      throw (ConvexError.protocol "Live message exceeded the reassembly limit")
    socket.fragmentBytes.set (accumulated ++ frame.payload)
    if frame.final then
      let combined ← socket.fragmentBytes.get
      resetFragments socket
      return some (Message.binary combined)
    return none

/-- Return a complete message if one has already arrived, without waiting. -/
def tryReceive (socket : WebSocket) (deadline : UInt64) : ConvexM (Option Message) := do
  let mut result : Option Message := none
  let mut scanning := true
  while scanning do
    match ← frameAvailable? socket with
    | none => scanning := false
    | some frame =>
        match ← acceptFrame socket frame deadline with
        | none => pure ()
        | some message =>
            result := some message
            scanning := false
  pure result

/-- Wait for a complete message. `none` means the peer ended the stream without
sending a close frame. -/
def receive (socket : WebSocket) (deadline : UInt64) : ConvexM (Option Message) := do
  let mut result : Option Message := none
  let mut waiting := true
  while waiting do
    match ← tryReceive socket deadline with
    | some message =>
        result := some message
        waiting := false
    | none =>
        if !(← socket.stream.fill deadline) then
          waiting := false
  pure result

/-- Read whatever has arrived on the descriptor and return every message it
completed. The Live loop calls this after its own poll, so nothing blocks.

The fill and scan steps alternate because one TLS record can carry several
messages: stopping after a single read would leave a decoded message sitting
in the session while the loop went back to sleep on the descriptor. -/
def drainAvailable (socket : WebSocket) (deadline : UInt64) : ConvexM (Array Message × Bool) := do
  let mut messages : Array Message := #[]
  let mut progressed := true
  while progressed do
    let mut scanning := true
    while scanning do
      match ← tryReceive socket deadline with
      | some message => messages := messages.push message
      | none => scanning := false
    progressed ← socket.stream.fillAvailable
  let ended ← socket.stream.isAtEnd
  pure (messages, ended)

def close (socket : WebSocket) (deadline : UInt64) : ConvexM Unit := do
  ConvexM.ignoreFailure (sendClose socket 1000 "client disconnect" deadline)
  ConvexM.ignoreFailure socket.stream.close

def fd (socket : WebSocket) : ConvexM UInt32 := socket.stream.fd

end WebSocket

end Convex
