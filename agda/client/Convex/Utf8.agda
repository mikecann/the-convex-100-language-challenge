{-# OPTIONS --without-K #-}

-- UTF-8 in Agda.
--
-- Convex text arrives as octets: HTTP bodies, WebSocket text frames that may
-- be split across TCP reads and RFC6455 fragments, and NDJSON adapter lines.
-- Decoding those octets is protocol behaviour, not transport, so the whole
-- codec lives here rather than behind the foreign boundary. The decoder
-- rejects over-long forms, surrogates, and values above U+10FFFF, which is
-- what makes a truncated multi-byte sequence at a fragment edge detectable
-- instead of silently replaced.
module Convex.Utf8 where

open import Convex.Prelude
open import Convex.Bytes

--------------------------------------------------------------------------------
-- Encoding
--------------------------------------------------------------------------------

encodeCodePoint : Nat → List Nat
encodeCodePoint c =
  if c ≤ⁿ 127 then c ∷ []
  else if c ≤ⁿ 2047 then
    (192 + (c div 64)) ∷ (128 + (c mod 64)) ∷ []
  else if c ≤ⁿ 65535 then
    (224 + (c div 4096)) ∷ (128 + ((c div 64) mod 64)) ∷ (128 + (c mod 64)) ∷ []
  else
    (240 + (c div 262144)) ∷ (128 + ((c div 4096) mod 64)) ∷
    (128 + ((c div 64) mod 64)) ∷ (128 + (c mod 64)) ∷ []

encodeOctets : String → List Nat
encodeOctets text = concat (map (λ c → encodeCodePoint (charCode c)) (stringToList text))

encode : String → Bytes
encode text = fromOctets (encodeOctets text)

-- Wire size in octets. Every byte budget in this client is charged with this,
-- never with a code-point count.
octetLength : String → Nat
octetLength text = length (encodeOctets text)

--------------------------------------------------------------------------------
-- Decoding
--------------------------------------------------------------------------------

private
  continuation : Bytes → Nat → Bool
  continuation buffer index =
    let b = octet buffer index in (128 ≤ⁿ b) ∧ (b ≤ⁿ 191)

  within : Bytes → Nat → Nat → Nat → Bool
  within buffer index low high =
    let b = octet buffer index in (low ≤ⁿ b) ∧ (b ≤ⁿ high)

-- Decode one code point starting at `index`, refusing to look past `limit`.
-- The returned width lets the caller advance without re-deriving the length,
-- which is what keeps a resumed read from restarting mid-sequence.
decodeAt : Bytes → Nat → Nat → Maybe (Nat × Nat)
decodeAt buffer index limit =
  let b0 = octet buffer index
      b1 = octet buffer (index + 1)
      b2 = octet buffer (index + 2)
      b3 = octet buffer (index + 3)
  in
  if index ≥ⁿ limit then nothing
  else if b0 ≤ⁿ 127 then just (b0 , 1)
  else if (194 ≤ⁿ b0) ∧ (b0 ≤ⁿ 223) ∧ (index + 1 <ⁿ limit) ∧ continuation buffer (index + 1)
    then just (((b0 - 192) * 64) + (b1 - 128) , 2)
  else if (b0 ==ⁿ 224) ∧ (index + 2 <ⁿ limit)
        ∧ within buffer (index + 1) 160 191 ∧ continuation buffer (index + 2)
    then just (((b0 - 224) * 4096) + ((b1 - 128) * 64) + (b2 - 128) , 3)
  else if (((225 ≤ⁿ b0) ∧ (b0 ≤ⁿ 236)) ∨ ((238 ≤ⁿ b0) ∧ (b0 ≤ⁿ 239)))
        ∧ (index + 2 <ⁿ limit)
        ∧ continuation buffer (index + 1) ∧ continuation buffer (index + 2)
    then just (((b0 - 224) * 4096) + ((b1 - 128) * 64) + (b2 - 128) , 3)
  else if (b0 ==ⁿ 237) ∧ (index + 2 <ⁿ limit)
        ∧ within buffer (index + 1) 128 159 ∧ continuation buffer (index + 2)
    then just (((b0 - 224) * 4096) + ((b1 - 128) * 64) + (b2 - 128) , 3)
  else if (b0 ==ⁿ 240) ∧ (index + 3 <ⁿ limit)
        ∧ within buffer (index + 1) 144 191
        ∧ continuation buffer (index + 2) ∧ continuation buffer (index + 3)
    then just (((b0 - 240) * 262144) + ((b1 - 128) * 4096) + ((b2 - 128) * 64) + (b3 - 128) , 4)
  else if (241 ≤ⁿ b0) ∧ (b0 ≤ⁿ 243) ∧ (index + 3 <ⁿ limit)
        ∧ continuation buffer (index + 1)
        ∧ continuation buffer (index + 2) ∧ continuation buffer (index + 3)
    then just (((b0 - 240) * 262144) + ((b1 - 128) * 4096) + ((b2 - 128) * 64) + (b3 - 128) , 4)
  else if (b0 ==ⁿ 244) ∧ (index + 3 <ⁿ limit)
        ∧ within buffer (index + 1) 128 143
        ∧ continuation buffer (index + 2) ∧ continuation buffer (index + 3)
    then just (((b0 - 240) * 262144) + ((b1 - 128) * 4096) + ((b2 - 128) * 64) + (b3 - 128) , 4)
  else nothing

-- Decode the region [from , from + count) into a string, or reject it. The
-- fuel is the region length, so a malformed prefix cannot loop.
decodeRegion : Bytes → Nat → Nat → Maybe String
decodeRegion buffer from count = go (suc count) from []
  where
    limit : Nat
    limit = from + count

    go : Nat → Nat → List Char → Maybe String
    go zero _ _ = nothing
    go (suc fuel) index acc with index ≥ⁿ limit
    ... | true = just (stringFromList (reverse acc))
    ... | false with decodeAt buffer index limit
    ...   | nothing = nothing
    ...   | just (code , width) = go fuel (index + width) (charFromCode code ∷ acc)

decode : Bytes → Maybe String
decode buffer = decodeRegion buffer 0 (size buffer)

valid : Bytes → Bool
valid buffer = isJust (decode buffer)

validRegion : Bytes → Nat → Nat → Bool
validRegion buffer from count = isJust (decodeRegion buffer from count)
