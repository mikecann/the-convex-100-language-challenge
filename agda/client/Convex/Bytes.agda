{-# OPTIONS --without-K #-}

-- Index-based helpers over the packed buffer supplied by `Convex.Prim`.
--
-- Everything above this module -- HTTP response framing, RFC6455 frames, and
-- the NDJSON line reader -- addresses the wire by offset and never converts a
-- large buffer into an Agda list.
module Convex.Bytes where

open import Convex.Prelude
open import Convex.Prim public using (Bytes)
open import Convex.Prim using (bytesEmpty; bytesLength; bytesIndex; bytesSlice;
                               bytesAppend; bytesFromOctets; bytesToOctets)

infixr 5 _+++_

_+++_ : Bytes → Bytes → Bytes
_+++_ = bytesAppend

size : Bytes → Nat
size = bytesLength

octet : Bytes → Nat → Nat
octet = bytesIndex

-- A half-open [from , from + count) view. `Convex.Prim` clamps both arguments,
-- so an out-of-range slice is empty rather than an error.
slice : Bytes → Nat → Nat → Bytes
slice = bytesSlice

emptyBytes : Bytes
emptyBytes = bytesEmpty

isEmpty : Bytes → Bool
isEmpty b = size b ==ⁿ 0

dropBytes : Nat → Bytes → Bytes
dropBytes n b = slice b n (size b - n)

fromOctets : List Nat → Bytes
fromOctets = bytesFromOctets

-- Only used on short, already-bounded regions such as a close-frame reason or
-- a test fixture payload.
toOctets : Bytes → List Nat
toOctets = bytesToOctets

-- Search for one octet in [from , limit). The fuel is the remaining span, so
-- the scan is structurally terminating and cannot outrun the buffer.
findOctet : Bytes → Nat → Nat → Nat → Maybe Nat
findOctet buffer target from limit = go (limit - from) from
  where
    go : Nat → Nat → Maybe Nat
    go zero _ = nothing
    go (suc fuel) index =
      if index ≥ⁿ limit then nothing
      else if octet buffer index ==ⁿ target then just index
      else go fuel (suc index)

-- Locate the first CRLF at or after `from`, returning the index of the CR.
findCRLF : Bytes → Nat → Maybe Nat
findCRLF buffer from = go (size buffer) from
  where
    go : Nat → Nat → Maybe Nat
    go zero _ = nothing
    go (suc fuel) index =
      if suc index ≥ⁿ size buffer then nothing
      else if (octet buffer index ==ⁿ 13) ∧ (octet buffer (suc index) ==ⁿ 10)
        then just index
        else go fuel (suc index)

-- Case-insensitive ASCII comparison of a buffer region against a lower-case
-- ASCII code-point list. HTTP header names arrive in whatever case the peer
-- chose, so header matching must not be case sensitive.
regionEqualsAsciiLower : Bytes → Nat → Nat → List Nat → Bool
regionEqualsAsciiLower buffer from to expected =
  go (to - from) from expected
  where
    lower : Nat → Nat
    lower c = if (65 ≤ⁿ c) ∧ (c ≤ⁿ 90) then c + 32 else c

    go : Nat → Nat → List Nat → Bool
    go _ index [] = index ≥ⁿ to
    go zero _ (_ ∷ _) = false
    go (suc fuel) index (c ∷ rest) =
      if index ≥ⁿ to then false
      else if lower (octet buffer index) ==ⁿ c then go fuel (suc index) rest
      else false

-- Lower-case hexadecimal text for a short buffer. Used for the Live session
-- identifier and for the example's idempotency key, both of which come from
-- the entropy source rather than from a delegated runtime.
hexString : Bytes → String
hexString buffer = stringConcat (map (λ o → showHex 2 o) (toOctets buffer))

-- Skip leading spaces and tabs in [from , to).
trimSpacesFrom : Bytes → Nat → Nat → Nat
trimSpacesFrom buffer from to = go (to - from) from
  where
    go : Nat → Nat → Nat
    go zero index = index
    go (suc fuel) index =
      if index ≥ⁿ to then index
      else if (octet buffer index ==ⁿ 32) ∨ (octet buffer index ==ⁿ 9) then go fuel (suc index)
      else index

-- Drop trailing spaces and tabs from [from , to).
trimSpacesTo : Bytes → Nat → Nat → Nat
trimSpacesTo buffer from to = go (to - from) to
  where
    go : Nat → Nat → Nat
    go zero index = index
    go (suc fuel) index =
      if index ≤ⁿ from then index
      else if (octet buffer (index - 1) ==ⁿ 32) ∨ (octet buffer (index - 1) ==ⁿ 9)
        then go fuel (index - 1)
        else index

-- Decimal digits in [from , to), stopping at the first non-digit. `nothing`
-- when no digit was read at all.
decimalIn : Bytes → Nat → Nat → Maybe Nat
decimalIn buffer from to = go (to - from) from 0 false
  where
    go : Nat → Nat → Nat → Bool → Maybe Nat
    go zero _ acc sawDigit = if sawDigit then just acc else nothing
    go (suc fuel) index acc sawDigit =
      if index ≥ⁿ to then (if sawDigit then just acc else nothing)
      else
        let c = octet buffer index in
        if (48 ≤ⁿ c) ∧ (c ≤ⁿ 57) then go fuel (suc index) ((acc * 10) + (c - 48)) true
        else if sawDigit then just acc
        else nothing

-- Hexadecimal digits in [from , to), used for chunked transfer sizes.
hexIn : Bytes → Nat → Nat → Maybe Nat
hexIn buffer from to = go (to - from) from 0 false
  where
    digitOf : Nat → Nat → Bool → Nat → Maybe Nat → Maybe Nat
    go : Nat → Nat → Nat → Bool → Maybe Nat

    digitOf _ acc sawDigit _ nothing = if sawDigit then just acc else nothing
    digitOf fuel acc _ index (just v) = go fuel (suc index) ((acc * 16) + v) true

    go zero _ acc sawDigit = if sawDigit then just acc else nothing
    go (suc fuel) index acc sawDigit =
      if index ≥ⁿ to then (if sawDigit then just acc else nothing)
      else digitOf fuel acc sawDigit index (hexDigitValue (charFromCode (octet buffer index)))

-- ASCII code points for the small set of fixed protocol tokens this client
-- writes or matches. Convex payload text always travels through the UTF-8
-- codec instead.
asciiOctets : String → List Nat
asciiOctets s = map charCode (stringToList s)
