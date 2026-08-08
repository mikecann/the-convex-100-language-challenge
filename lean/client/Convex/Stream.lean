/-
A buffered byte stream over one socket.

Two properties matter more than convenience here. Every read carries an
absolute deadline, so a peer that dribbles one byte at a time cannot extend a
bound indefinitely. And bytes are only removed from the buffer once a complete
protocol unit has been recognised, so a deadline that fires part way through a
frame leaves the parser exactly where it was instead of resynchronising on a
byte that merely looks like a frame boundary.
-/

import Convex.Error
import Convex.Ffi

namespace Convex

/-- Where a deployment URL points, once split into the pieces a socket needs. -/
structure Endpoint where
  secure : Bool
  host : String
  port : UInt32
  path : String
  deriving Inhabited, Repr

private def splitAtFirst (text : String) (separator : Char) : String × String :=
  let characters := text.toList
  let before := characters.takeWhile (· != separator)
  (String.mk before, String.mk (characters.drop before.length))

private def stripTrailingSlashes (text : String) : String :=
  String.mk (text.toList.reverse.dropWhile (· == '/')).reverse

private def splitAuthority (authority : String) (defaultPort : UInt32) :
    Option (String × UInt32) :=
  match authority.splitOn ":" with
  | [host] => if host.isEmpty then none else some (host, defaultPort)
  | [host, digits] =>
      if host.isEmpty || digits.isEmpty then
        none
      else
        match digits.toNat? with
        | some port => if port ≥ 1 && port ≤ 65535 then some (host, UInt32.ofNat port) else none
        | none => none
  | _ => none

/-- Parse a Convex deployment URL. `suffix` is the path this endpoint needs, so
the same function produces both the HTTP origin and the `/api/sync` target
without a second URL parser. -/
def parseEndpoint (url : String) (suffix : String) : Except String Endpoint := do
  let (secure, rest) ←
    if url.startsWith "https://" then
      Except.ok (true, url.drop 8)
    else if url.startsWith "http://" then
      Except.ok (false, url.drop 7)
    else
      Except.error "Convex deployment URL must start with http:// or https://"
  let (authority, rawPath) := splitAtFirst rest '/'
  match splitAuthority authority (if secure then 443 else 80) with
  | none => Except.error "Convex deployment URL has an unusable host or port"
  | some (host, port) =>
      Except.ok { secure, host, port, path := stripTrailingSlashes rawPath ++ suffix }

/-- Options that decide what a TLS handshake will accept. `caFile` exists so a
deterministic fixture can present its own chain; production leaves it empty and
uses the container's trust store. -/
structure TlsOptions where
  caFile : String := ""
  deriving Inhabited

structure Stream where
  connection : Ffi.Conn
  /-- Unconsumed bytes, with `offset` marking how much the parser accepted. -/
  buffer : IO.Ref ByteArray
  offset : IO.Ref Nat
  atEnd : IO.Ref Bool
  closed : IO.Ref Bool
  /-- Nothing may buffer more than this, so an oversized declared length is a
  rejection rather than an allocation. -/
  capacity : Nat

namespace Stream

def readChunk : UInt32 := 65536

private def make (connection : Ffi.Conn) (capacity : Nat) : IO Stream := do
  let buffer ← IO.mkRef ByteArray.empty
  let offset ← IO.mkRef 0
  let atEnd ← IO.mkRef false
  let closed ← IO.mkRef false
  pure { connection, buffer, offset, atEnd, closed, capacity }

def connect (endpoint : Endpoint) (tls : TlsOptions) (deadline : UInt64)
    (capacity : Nat := 4 * 1024 * 1024) : ConvexM Stream := do
  let connection ← ConvexM.attempt s!"connecting to {endpoint.host}"
    (Ffi.connect endpoint.host endpoint.port endpoint.secure endpoint.host tls.caFile deadline)
  make connection capacity

def ofConnection (connection : Ffi.Conn) (capacity : Nat := 4 * 1024 * 1024) : IO Stream :=
  make connection capacity

def fd (stream : Stream) : ConvexM UInt32 :=
  ConvexM.attempt "reading the socket descriptor" (Ffi.connFd stream.connection)

/-- Bytes recognised but not yet consumed by the parser. -/
def available (stream : Stream) : ConvexM Nat := do
  let buffer ← stream.buffer.get
  let offset ← stream.offset.get
  pure (buffer.size - offset)

/-- Reclaim the consumed prefix once it is worth the copy. -/
private def compact (stream : Stream) : ConvexM Unit := do
  let offset ← stream.offset.get
  if offset ≥ 65536 then
    let buffer ← stream.buffer.get
    stream.buffer.set (buffer.extract offset buffer.size)
    stream.offset.set 0

private def admit (stream : Stream) (chunk : ByteArray) : ConvexM Unit := do
  if chunk.size > 0 then
    let buffer ← stream.buffer.get
    let offset ← stream.offset.get
    if buffer.size - offset + chunk.size > stream.capacity then
      throw (ConvexError.protocol
        s!"peer sent more than the {stream.capacity} byte read budget")
    stream.buffer.set (buffer ++ chunk)

/-- Block until more bytes arrive or the deadline passes. Returns `false` only
at a clean end of stream. -/
def fill (stream : Stream) (deadline : UInt64) : ConvexM Bool := do
  if ← stream.atEnd.get then
    return false
  compact stream
  match ← ConvexM.attempt "reading from the socket"
      (Ffi.connRead stream.connection readChunk deadline) with
  | none =>
      stream.atEnd.set true
      pure false
  | some bytes =>
      admit stream bytes
      pure true

/-- Take whatever has already arrived without waiting. Used by the Live event
loop, which polls the descriptor itself. -/
def fillAvailable (stream : Stream) : ConvexM Bool := do
  if ← stream.atEnd.get then
    return false
  compact stream
  match ← ConvexM.attempt "reading from the socket"
      (Ffi.connReadAvailable stream.connection readChunk) with
  | none =>
      stream.atEnd.set true
      pure false
  | some bytes =>
      admit stream bytes
      pure (bytes.size > 0)

def isAtEnd (stream : Stream) : ConvexM Bool := do
  stream.atEnd.get

/-- A TLS record can already hold the next message, so descriptor readiness
alone would sometimes leave a decoded message sitting unnoticed. -/
def pending (stream : Stream) : ConvexM Bool := do
  if (← stream.available) > 0 then
    return true
  ConvexM.attempt "checking buffered TLS data" (Ffi.connPending stream.connection)

/-- Look at the next `count` bytes without consuming them, waiting until they
have all arrived. Returns `none` at end of stream. -/
def peek (stream : Stream) (count : Nat) (deadline : UInt64) : ConvexM (Option ByteArray) := do
  if count > stream.capacity then
    throw (ConvexError.protocol
      s!"peer declared {count} bytes, beyond the {stream.capacity} byte budget")
  let mut more := true
  while (← stream.available) < count && more do
    more ← stream.fill deadline
  if (← stream.available) < count then
    return none
  let buffer ← stream.buffer.get
  let offset ← stream.offset.get
  pure (some (buffer.extract offset (offset + count)))

/-- Accept bytes the parser has already recognised. -/
def consume (stream : Stream) (count : Nat) : ConvexM Unit := do
  let offset ← stream.offset.get
  stream.offset.set (offset + count)

def take (stream : Stream) (count : Nat) (deadline : UInt64) : ConvexM ByteArray := do
  match ← stream.peek count deadline with
  | none => throw (ConvexError.transport "peer closed before sending the expected bytes")
  | some bytes =>
      stream.consume count
      pure bytes

/-- Read up to and including `delimiter`, returning the text before it. The
limit applies to the buffered prefix, so an endless header block fails on size
rather than growing. -/
def readUntil (stream : Stream) (delimiter : ByteArray) (limit : Nat) (deadline : UInt64) :
    ConvexM ByteArray := do
  let mut result := ByteArray.empty
  let mut finished := false
  while !finished do
    let buffer ← stream.buffer.get
    let offset ← stream.offset.get
    match Bytes.findSub? buffer delimiter offset with
    | some position =>
        result := buffer.extract offset position
        stream.consume (position - offset + delimiter.size)
        finished := true
    | none =>
        if buffer.size - offset > limit then
          throw (ConvexError.protocol
            s!"peer sent more than {limit} bytes without the expected delimiter")
        if !(← stream.fill deadline) then
          throw (ConvexError.transport "peer closed before completing the message")
  pure result

def write (stream : Stream) (bytes : ByteArray) (deadline : UInt64) : ConvexM Unit :=
  ConvexM.attempt "writing to the socket" (Ffi.connWrite stream.connection bytes deadline)

def writeString (stream : Stream) (text : String) (deadline : UInt64) : ConvexM Unit :=
  stream.write text.toUTF8 deadline

def close (stream : Stream) : ConvexM Unit := do
  if !(← stream.closed.get) then
    stream.closed.set true
    ConvexM.attempt "closing the socket" (Ffi.connClose stream.connection)

def shutdownWrite (stream : Stream) : ConvexM Unit :=
  ConvexM.attempt "half-closing the socket" (Ffi.connShutdownWrite stream.connection)

end Stream

end Convex
