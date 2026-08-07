{-# OPTIONS --without-K #-}

-- Buffered, deadline-bounded reads.
--
-- Both the HTTP exchange and the RFC6455 frame reader are written against this
-- module, and both depend on the same two properties.
--
-- The deadline is absolute. It is computed once from the monotonic clock, so a
-- peer that dribbles one octet at a time cannot extend an operation by
-- refreshing a per-read timeout, and `close` stays bounded whether the peer is
-- idle, chatty, or stalled halfway through a frame.
--
-- The buffer is caller-owned and never rewound. A read that times out returns
-- the buffer it has accumulated so far, so a partially consumed frame keeps
-- its parser position instead of restarting at a false boundary.
module Convex.Reader where

open import Convex.Prelude
open import Convex.Prim
open import Convex.Bytes

-- The largest single socket read. Bigger reads are just more buffer churn;
-- the real ceiling is the per-operation cap the caller passes in.
chunkOctets : Nat
chunkOctets = 16384

-- No individual socket read blocks longer than this, so a shutdown request
-- observed by the owning worker is acted on promptly even while a read is
-- outstanding.
sliceMillis : Nat
sliceMillis = 200

data Fill : Set where
  filled : Bytes → Fill
  fillTimeout : Fill
  fillEof : Fill
  fillFailed : String → Fill

private
  classify : Bytes → RecvResult → Fill
  classify buffer (recvData chunk) = filled (buffer +++ chunk)
  classify _ recvTimeout = fillTimeout
  classify _ recvEof = fillEof
  classify _ (recvError diagnostic) = fillFailed diagnostic

readChunk : Socket → Bytes → Nat → Nat → IO Fill
readChunk sock buffer wanted timeoutMs =
  socketRecv sock wanted timeoutMs >>= λ outcome → return (classify buffer outcome)

-- Milliseconds left before an absolute monotonic deadline.
remainingMillis : Nat → IO Nat
remainingMillis deadline = monotonicMillis >>= λ now → return (deadline - now)

deadlineFrom : Nat → IO Nat
deadlineFrom budget = monotonicMillis >>= λ now → return (now + budget)

-- Read until `ready` accepts the buffer, the absolute deadline passes, or the
-- accumulated buffer exceeds `cap`. `ready` returns the offset the caller
-- cares about so a second scan is unnecessary.
readUntil : Nat → Socket → Bytes → (Bytes → Maybe Nat) → Nat → Nat →
            IO (Either String (Nat × Bytes))
readUntil zero _ _ _ _ _ = return (left "bounded read did not make progress")
readUntil (suc fuel) sock buffer ready deadline cap = check (ready buffer)
  where
    step : Fill → IO (Either String (Nat × Bytes))
    step (filled grown) = readUntil fuel sock grown ready deadline cap
    step fillTimeout = readUntil fuel sock buffer ready deadline cap
    step fillEof = return (left "peer closed the connection")
    step (fillFailed diagnostic) = return (left diagnostic)

    pull : Nat → IO (Either String (Nat × Bytes))
    pull remaining =
      if remaining ==ⁿ 0 then return (left "read deadline expired")
      else readChunk sock buffer chunkOctets (min remaining sliceMillis) >>= step

    check : Maybe Nat → IO (Either String (Nat × Bytes))
    check (just offset) = return (right (offset , buffer))
    check nothing =
      if size buffer >ⁿ cap then return (left "peer exceeded the response byte budget")
      else remainingMillis deadline >>= pull

-- Buffer at least `need` octets.
readAtLeast : Socket → Bytes → Nat → Nat → Nat → IO (Either String Bytes)
readAtLeast sock buffer need deadline cap =
  readUntil (cap + 64) sock buffer ready deadline cap >>= λ outcome → return (strip outcome)
  where
    ready : Bytes → Maybe Nat
    ready current = if size current ≥ⁿ need then just need else nothing

    strip : Either String (Nat × Bytes) → Either String Bytes
    strip (left message) = left message
    strip (right (_ , current)) = right current

-- Buffer up to and including the next CRLF, returning the index of the CR.
readLine : Socket → Bytes → Nat → Nat → Nat → IO (Either String (Nat × Bytes))
readLine sock buffer from deadline cap =
  readUntil (cap + 64) sock buffer (λ current → findCRLF current from) deadline cap

-- Read until the peer closes, which is how a `Connection: close` response
-- without a declared length is framed.
readToEnd : Nat → Socket → Bytes → Nat → Nat → IO (Either String Bytes)
readToEnd zero _ _ _ _ = return (left "bounded read did not make progress")
readToEnd (suc fuel) sock buffer deadline cap =
  if size buffer >ⁿ cap then return (left "peer exceeded the response byte budget")
  else remainingMillis deadline >>= pull
  where
    step : Fill → IO (Either String Bytes)
    step (filled grown) = readToEnd fuel sock grown deadline cap
    step fillTimeout = readToEnd fuel sock buffer deadline cap
    step fillEof = return (right buffer)
    step (fillFailed diagnostic) = return (left diagnostic)

    pull : Nat → IO (Either String Bytes)
    pull remaining =
      if remaining ==ⁿ 0 then return (left "read deadline expired")
      else readChunk sock buffer chunkOctets (min remaining sliceMillis) >>= step

-- Write with its own bounded deadline, so a peer that stops reading cannot
-- pin a worker inside a send.
writeAll : Socket → Bytes → Nat → IO (Either String ⊤)
writeAll sock payload timeoutMs = socketSend sock payload timeoutMs >>= λ outcome → return (unwrap outcome)
  where
    unwrap : IOResult ⊤ → Either String ⊤
    unwrap (ioOk _) = right tt
    unwrap (ioErr diagnostic) = left diagnostic
