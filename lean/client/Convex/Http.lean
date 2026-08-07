/-
A small HTTP/1.1 client written directly against the buffered stream.

Convex's documented JSON endpoints only need one request shape, but the reply
still has to be read like real HTTP: a status line, a bounded header block,
then either a declared length or chunked framing. Every stage carries the same
absolute deadline and the same byte budget, so a server that stalls or streams
forever fails on a bound instead of on memory.
-/

import Convex.Json
import Convex.Stream

namespace Convex

open Lean (Json)

structure HttpResponse where
  status : Nat
  reason : String
  headers : Array (String × String)
  body : ByteArray
  deriving Inhabited

namespace Http

/-- Nothing about a response may exceed these, and each is checked while
reading rather than after buffering. -/
structure Limits where
  maxHeaderBytes : Nat := 64 * 1024
  maxHeaderCount : Nat := 100
  maxBodyBytes : Nat := 8 * 1024 * 1024
  deriving Inhabited

def findHeader (headers : Array (String × String)) (name : String) : Option String :=
  let wanted := Bytes.asciiLower name
  (headers.find? fun (key, _) => Bytes.asciiLower key == wanted).map Prod.snd

private def crlf : ByteArray := "\r\n".toUTF8

private def headerTerminator : ByteArray := "\r\n\r\n".toUTF8

private def parseStatusLine (line : String) : Except String (Nat × String) :=
  match line.splitOn " " with
  | version :: code :: rest =>
      if !(version.startsWith "HTTP/1.") then
        .error "response did not start with an HTTP/1.x status line"
      else
        match code.toNat? with
        | some status =>
            if status < 100 || status > 599 then
              .error "response status code is out of range"
            else
              .ok (status, " ".intercalate rest)
        | none => .error "response status code was not a number"
  | _ => .error "response status line was malformed"

private def parseHeaderLines (block : String) (limits : Limits) :
    Except String (Array (String × String)) := Id.run do
  let mut headers : Array (String × String) := #[]
  for line in block.splitOn "\r\n" do
    if line.isEmpty then
      continue
    if headers.size ≥ limits.maxHeaderCount then
      return .error s!"response carried more than {limits.maxHeaderCount} headers"
    let (name, rest) := (line.takeWhile (· != ':'), line.dropWhile (· != ':'))
    if rest.isEmpty then
      return .error "response header line had no colon"
    if name.isEmpty || name.any (· == ' ') then
      return .error "response header name was malformed"
    headers := headers.push (name, (rest.drop 1).trim)
  return .ok headers

/-- Chunked bodies are read one declared chunk at a time so the running total
can be rejected the moment it passes the budget, rather than after the peer
decides to stop. -/
private def readChunkedBody (stream : Stream) (limits : Limits) (deadline : UInt64) :
    ConvexM ByteArray := do
  let mut body := ByteArray.empty
  let mut finished := false
  while !finished do
    let sizeLine ← stream.readUntil crlf 1024 deadline
    let sizeText ← liftExcept "chunk size" (Bytes.asciiToString sizeLine)
    let digits := (sizeText.takeWhile (· != ';')).trim
    let mut size := 0
    if digits.isEmpty then
      throw (ConvexError.protocol "chunked response omitted a chunk size")
    for character in digits.toList do
      let value :=
        if character ≥ '0' && character ≤ '9' then some (character.toNat - 48)
        else if character ≥ 'a' && character ≤ 'f' then some (character.toNat - 87)
        else if character ≥ 'A' && character ≤ 'F' then some (character.toNat - 55)
        else none
      match value with
      | none => throw (ConvexError.protocol "chunked response had a non-hexadecimal size")
      | some digit =>
          size := size * 16 + digit
          if size > limits.maxBodyBytes then
            throw (ConvexError.protocol
              s!"chunked response exceeded the {limits.maxBodyBytes} byte body budget")
    if size == 0 then
      -- Consume the trailer section, which is usually just the final CRLF.
      let _ ← stream.readUntil crlf limits.maxHeaderBytes deadline
      finished := true
    else
      if body.size + size > limits.maxBodyBytes then
        throw (ConvexError.protocol
          s!"chunked response exceeded the {limits.maxBodyBytes} byte body budget")
      let chunk ← stream.take size deadline
      let terminator ← stream.take 2 deadline
      if !Bytes.bytesEqual terminator crlf then
        throw (ConvexError.protocol "chunked response omitted the chunk terminator")
      body := body ++ chunk
  pure body

private def readBody (stream : Stream) (headers : Array (String × String)) (limits : Limits)
    (deadline : UInt64) : ConvexM ByteArray := do
  let encoding := (findHeader headers "transfer-encoding").map Bytes.asciiLower
  if encoding == some "chunked" then
    readChunkedBody stream limits deadline
  else
    match findHeader headers "content-length" with
    | some declared =>
        match declared.trim.toNat? with
        | none => throw (ConvexError.protocol "response had a non-numeric Content-Length")
        | some length =>
            if length > limits.maxBodyBytes then
              throw (ConvexError.protocol
                s!"response declared {length} bytes, beyond the {limits.maxBodyBytes} byte budget")
            stream.take length deadline
    | none => do
        -- No framing at all: read until the peer closes, still under budget.
        let mut more := true
        while more do
          if (← stream.available) > limits.maxBodyBytes then
            throw (ConvexError.protocol
              s!"response exceeded the {limits.maxBodyBytes} byte body budget")
          more ← stream.fill deadline
        let size ← stream.available
        stream.take size deadline

def readResponse (stream : Stream) (limits : Limits) (deadline : UInt64) :
    ConvexM HttpResponse := do
  let headerBlock ← stream.readUntil headerTerminator limits.maxHeaderBytes deadline
  let headerText ← liftExcept "response headers" (Bytes.asciiToString headerBlock)
  let (statusLine, rest) :=
    match headerText.splitOn "\r\n" with
    | first :: remaining => (first, "\r\n".intercalate remaining)
    | [] => (headerText, "")
  let (status, reason) ← liftExcept "response status" (parseStatusLine statusLine)
  let headers ← liftExcept "response headers" (parseHeaderLines rest limits)
  let body ← readBody stream headers limits deadline
  pure { status, reason, headers, body }

/-- One request over one connection. Convex responses are small and this client
never pipelines, so `Connection: close` keeps framing unambiguous; persistent
connections are deferred rather than half-implemented. -/
def request (endpoint : Endpoint) (tls : TlsOptions) (method : String)
    (headers : Array (String × String)) (body : ByteArray) (deadline : UInt64)
    (limits : Limits := {}) : ConvexM HttpResponse := do
  let stream ← Stream.connect endpoint tls deadline (limits.maxBodyBytes + 128 * 1024)
  let outcome ← ConvexM.catchError
    (do
      let hostHeader :=
        if (endpoint.secure && endpoint.port == 443)
            || (!endpoint.secure && endpoint.port == 80) then
          endpoint.host
        else
          s!"{endpoint.host}:{endpoint.port}"
      let mut request := s!"{method} {endpoint.path} HTTP/1.1\r\nHost: {hostHeader}\r\n"
      request := request ++ "Connection: close\r\n"
      request := request ++ s!"Content-Length: {body.size}\r\n"
      for (name, value) in headers do
        request := request ++ s!"{name}: {value}\r\n"
      stream.writeString (request ++ "\r\n") deadline
      stream.write body deadline
      let response ← readResponse stream limits deadline
      pure (Except.ok response))
    (fun problem => pure (Except.error problem))
  ConvexM.ignoreFailure stream.close
  match outcome with
  | .ok response => pure response
  | .error problem => throw problem

end Http

end Convex
