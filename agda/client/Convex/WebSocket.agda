{-# OPTIONS --without-K #-}

-- RFC6455 in Agda.
--
-- The handshake, frame headers, masking, fragmentation, and control frames are
-- all handled here; the foreign boundary contributes only a byte stream. Three
-- properties this module is responsible for are easy to get wrong and are
-- called out where they are implemented:
--
--   * A declared payload length is checked against the frame ceiling before
--     any octet of that payload is buffered, so a header claiming 2^62 bytes
--     costs nothing.
--   * A read that makes no progress never rewinds the parser. The caller keeps
--     the partially filled buffer and an absolute deadline, so a peer that
--     dribbles a frame one octet at a time is abandoned rather than
--     re-synchronised at a false frame boundary.
--   * Control frames are validated (final, at most 125 octets, close payload
--     carrying a legal code and valid UTF-8 reason) instead of being trusted.
module Convex.WebSocket where

open import Convex.Prelude
open import Convex.Prim
open import Convex.Bytes
open import Convex.Reader
open import Convex.Base64 using (encode)
open import Convex.Digest using (sha1; xor8)
import Convex.Utf8 as Utf8

--------------------------------------------------------------------------------
-- Bounds
--------------------------------------------------------------------------------

-- Largest single frame payload the client will buffer.
maxFrameOctets : Nat
maxFrameOctets = 1048576

-- Largest reassembled message across continuation frames.
maxMessageOctets : Nat
maxMessageOctets = 1048576

-- A fragmented message may not be spread over more frames than this, so a peer
-- cannot spend the client's time on empty continuations.
maxFragments : Nat
maxFragments = 4096

handshakeMillis : Nat
handshakeMillis = 4000

-- Once any octet of a frame has been consumed, the whole frame must arrive
-- within this absolute window or the connection is abandoned.
frameMillis : Nat
frameMillis = 5000

--------------------------------------------------------------------------------
-- Opcodes and frames
--------------------------------------------------------------------------------

opContinuation : Nat
opContinuation = 0

opText : Nat
opText = 1

opBinary : Nat
opBinary = 2

opClose : Nat
opClose = 8

opPing : Nat
opPing = 9

opPong : Nat
opPong = 10

isControlOpcode : Nat → Bool
isControlOpcode code = (code ==ⁿ 8) ∨ (code ==ⁿ 9) ∨ (code ==ⁿ 10)

-- Field names are prefixed because `Convex.Live` opens this module alongside
-- `Convex.Error`, which also has a `payload`.
record Frame : Set where
  constructor frame
  field
    frameFinal : Bool
    frameOpcode : Nat
    framePayload : Bytes

open Frame public

data FrameScan : Set where
  frameNeed : Nat → FrameScan
  frameBad : String → FrameScan
  frameGot : Frame → Nat → FrameScan

private
  beValue : Bytes → Nat → Nat → Nat
  beValue buffer from count = go count from 0
    where
      go : Nat → Nat → Nat → Nat
      go zero _ acc = acc
      go (suc k) index acc = go k (suc index) ((acc * 256) + octet buffer index)

-- Inspect the front of `buffer` without consuming it.
scanFrame : Bytes → FrameScan
scanFrame buffer =
  if size buffer <ⁿ 2 then frameNeed 2
  else if not (reserved ==ⁿ 0) then frameBad "server set a reserved WebSocket bit"
  else if masked then frameBad "server WebSocket frame was masked"
  else sized
  where
    b0 : Nat
    b0 = octet buffer 0

    b1 : Nat
    b1 = octet buffer 1

    final? : Bool
    final? = (b0 div 128) ==ⁿ 1

    reserved : Nat
    reserved = (b0 div 16) mod 8

    code : Nat
    code = b0 mod 16

    masked : Bool
    masked = (b1 div 128) ==ⁿ 1

    marker : Nat
    marker = b1 mod 128

    -- The payload length is validated against the ceiling here, before the
    -- payload octets are required, so an absurd header is rejected without
    -- reserving anything.
    complete : Nat → Nat → FrameScan
    complete headerOctets declared =
      if isControlOpcode code ∧ (not final? ∨ (declared >ⁿ 125)) then
        frameBad "invalid WebSocket control frame"
      else if declared >ⁿ maxFrameOctets then frameBad "WebSocket frame exceeds the byte budget"
      else if size buffer <ⁿ (headerOctets + declared) then frameNeed (headerOctets + declared)
      else frameGot (frame final? code (slice buffer headerOctets declared)) (headerOctets + declared)

    sized : FrameScan
    sized =
      if marker <ⁿ 126 then complete 2 marker
      else if marker ==ⁿ 126 then
        (if size buffer <ⁿ 4 then frameNeed 4
         else if beValue buffer 2 2 <ⁿ 126 then frameBad "WebSocket length is not minimally encoded"
         else complete 4 (beValue buffer 2 2))
      else
        (if size buffer <ⁿ 10 then frameNeed 10
         else if beValue buffer 2 8 <ⁿ 65536 then frameBad "WebSocket length is not minimally encoded"
         else if beValue buffer 2 8 ≥ⁿ pow2 63 then frameBad "WebSocket length has the high bit set"
         else complete 10 (beValue buffer 2 8))

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

data Step : Set where
  stepFrame : Frame → Bytes → Step
  stepPending : Bytes → Step
  stepIdle : Bytes → Step
  stepFailed : String → Step

-- One bounded read attempt. The caller owns the buffer, so nothing is lost
-- when a slice expires: `stepPending` means octets of the current frame are
-- already held and the caller's absolute deadline stays armed, while
-- `stepIdle` means the stream is at a real frame boundary with nothing
-- buffered and no deadline is owed.
frameStep : Socket → Bytes → Nat → IO Step
frameStep sock buffer sliceMs = decide (scanFrame buffer)
  where
    onFill : Fill → IO Step
    onFill (filled grown) = return (stepPending grown)
    onFill fillTimeout = return (if isEmpty buffer then stepIdle buffer else stepPending buffer)
    onFill fillEof = return (stepFailed "peer closed the WebSocket")
    onFill (fillFailed diagnostic) = return (stepFailed diagnostic)

    decide : FrameScan → IO Step
    decide (frameGot f used) = return (stepFrame f (dropBytes used buffer))
    decide (frameBad message) = return (stepFailed message)
    decide (frameNeed _) = readChunk sock buffer chunkOctets sliceMs >>= onFill

--------------------------------------------------------------------------------
-- Writing
--------------------------------------------------------------------------------

private
  lengthPrefix : Nat → List Nat
  lengthPrefix n =
    if n <ⁿ 126 then (128 + n) ∷ []
    else if n <ⁿ 65536 then 254 ∷ (n div 256) ∷ (n mod 256) ∷ []
    else
      255 ∷ (n div pow2 56) mod 256 ∷ (n div pow2 48) mod 256 ∷ (n div pow2 40) mod 256
        ∷ (n div pow2 32) mod 256 ∷ (n div pow2 24) mod 256 ∷ (n div pow2 16) mod 256
        ∷ (n div pow2 8) mod 256 ∷ n mod 256 ∷ []

  maskAt : List Nat → Nat → Nat
  maskAt maskOctets index = go maskOctets (index mod 4)
    where
      go : List Nat → Nat → Nat
      go [] _ = 0
      go (x ∷ _) zero = x
      go (_ ∷ rest) (suc k) = go rest k

  applyMask : List Nat → Nat → List Nat → List Nat
  applyMask _ _ [] = []
  applyMask maskOctets index (b ∷ rest) =
    xor8 b (maskAt maskOctets index) ∷ applyMask maskOctets (suc index) rest

-- Every client frame is masked, as RFC6455 requires. The client only ever
-- sends short control frames and Live envelopes, so converting the payload to
-- octets for the exclusive-or is bounded by the outgoing message size rather
-- than by the much larger inbound ceiling.
buildFrame : Nat → Bytes → Bytes → Bytes
buildFrame code maskKey body =
  fromOctets ((128 + code) ∷ lengthPrefix (size body))
    +++ maskKey
    +++ fromOctets (applyMask (toOctets maskKey) 0 (toOctets body))

sendFrame : Socket → Nat → Bytes → Nat → IO (Either String ⊤)
sendFrame sock code body timeoutMs =
  randomBytes 4 >>= λ maskKey → writeAll sock (buildFrame code maskKey body) timeoutMs

sendText : Socket → String → Nat → IO (Either String ⊤)
sendText sock text timeoutMs = sendFrame sock opText (Utf8.encode text) timeoutMs

-- 1000 "normal closure", sent before the socket is retired.
sendClose : Socket → Nat → IO (Either String ⊤)
sendClose sock timeoutMs = sendFrame sock opClose (fromOctets (3 ∷ 232 ∷ [])) timeoutMs

sendPong : Socket → Bytes → Nat → IO (Either String ⊤)
sendPong sock body timeoutMs = sendFrame sock opPong body timeoutMs

--------------------------------------------------------------------------------
-- Close frames
--------------------------------------------------------------------------------

-- A close payload is either empty or a two-octet code from the registered set
-- followed by a valid UTF-8 reason.
closeFrameValid : Bytes → Bool
closeFrameValid body =
  if size body ==ⁿ 0 then true
  else if size body ==ⁿ 1 then false
  else legalCode ∧ Utf8.validRegion body 2 (size body - 2)
  where
    code : Nat
    code = (octet body 0 * 256) + octet body 1

    legalCode : Bool
    legalCode =
      (code ==ⁿ 1000) ∨ (code ==ⁿ 1001) ∨ (code ==ⁿ 1002) ∨ (code ==ⁿ 1003)
        ∨ (code ==ⁿ 1007) ∨ (code ==ⁿ 1008) ∨ (code ==ⁿ 1009) ∨ (code ==ⁿ 1010)
        ∨ (code ==ⁿ 1011) ∨ ((3000 ≤ⁿ code) ∧ (code ≤ⁿ 4999))

--------------------------------------------------------------------------------
-- Handshake
--------------------------------------------------------------------------------

-- The fixed GUID from RFC6455 section 1.3.
acceptGuid : String
acceptGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

expectedAccept : String → String
expectedAccept clientKey = encode (sha1 (Utf8.encode (clientKey <> acceptGuid)))

-- The key is threaded in explicitly so a reviewer can see that it comes from
-- the entropy source and is the same value `expectedAccept` is derived from.
handshakeRequest : String → String → String → String → String
handshakeRequest authority path version clientKey =
  "GET " <> path <> " HTTP/1.1\r\n"
    <> "Host: " <> authority <> "\r\n"
    <> "Upgrade: websocket\r\n"
    <> "Connection: Upgrade\r\n"
    <> "Sec-WebSocket-Key: " <> clientKey <> "\r\n"
    <> "Sec-WebSocket-Version: 13\r\n"
    <> "Convex-Client: " <> version <> "\r\n\r\n"

private
  -- Locate one header's trimmed value region inside a response head.
  headerRegion : Nat → Bytes → Nat → Nat → List Nat → Maybe (Nat × Nat)
  headerRegion zero _ _ _ _ = nothing
  headerRegion (suc fuel) buffer at headerEnd wanted =
    if at + 1 ≥ⁿ headerEnd then nothing
    else if (octet buffer at ==ⁿ 13) ∧ (octet buffer (suc at) ==ⁿ 10) then nothing
    else onLine (findCRLF buffer at)
    where
      onColon : Nat → Maybe Nat → Maybe (Nat × Nat)
      onColon crlf nothing = headerRegion fuel buffer (crlf + 2) headerEnd wanted
      onColon crlf (just colon) =
        if regionEqualsAsciiLower buffer at colon wanted
          then just (trimSpacesFrom buffer (suc colon) crlf ,
                     trimSpacesTo buffer (trimSpacesFrom buffer (suc colon) crlf) crlf)
          else headerRegion fuel buffer (crlf + 2) headerEnd wanted

      onLine : Maybe Nat → Maybe (Nat × Nat)
      onLine nothing = nothing
      onLine (just crlf) = onColon crlf (findOctet buffer 58 at crlf)

  regionEqualsExact : Bytes → Nat → Nat → List Nat → Bool
  regionEqualsExact buffer from to expected = go (to - from) from expected
    where
      go : Nat → Nat → List Nat → Bool
      go _ index [] = index ≥ⁿ to
      go zero _ (_ ∷ _) = false
      go (suc fuel) index (c ∷ rest) =
        if index ≥ⁿ to then false
        else if octet buffer index ==ⁿ c then go fuel (suc index) rest
        else false

-- The 101 status line and a matching `Sec-WebSocket-Accept` together prove the
-- peer really performed the RFC6455 upgrade rather than answering with an
-- ordinary HTTP response.
verifyHandshake : Bytes → Nat → String → Either String ⊤
verifyHandshake buffer headerEnd accept =
  if not (regionEqualsAsciiLower buffer 0 13 (asciiOctets "http/1.1 101 ")) then
    left "WebSocket upgrade was rejected"
  else found (headerRegion headerEnd buffer (statusLineEnd + 2) headerEnd
               (asciiOctets "sec-websocket-accept"))
  where
    statusLineEnd : Nat
    statusLineEnd = fromMaybe 0 (findCRLF buffer 0)

    found : Maybe (Nat × Nat) → Either String ⊤
    found nothing = left "WebSocket handshake has no accept header"
    found (just (valueFrom , valueTo)) =
      if regionEqualsExact buffer valueFrom valueTo (asciiOctets accept)
        then right tt
        else left "WebSocket accept key did not match"
