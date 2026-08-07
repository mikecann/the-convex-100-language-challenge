{-# OPTIONS --without-K #-}

-- Base64 and the Convex Live timestamp codec.
--
-- Two callers need this. The RFC6455 handshake base64-encodes a random client
-- key and the SHA-1 of the server's reply. The Live envelope carries `ts` as a
-- base64 little-endian unsigned 64-bit value, and the client must both produce
-- and validate the canonical spelling: a peer that pads differently, or that
-- leaves non-zero bits in the final group, is protocol drift rather than a
-- timestamp the client may accept.
module Convex.Base64 where

open import Convex.Prelude
open import Convex.Bytes

private
  alphabet : List Char
  alphabet = stringToList "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

  digitAt : Nat → Char
  digitAt n = go n alphabet
    where
      go : Nat → List Char → Char
      go _ [] = 'A'
      go zero (c ∷ _) = c
      go (suc k) (_ ∷ rest) = go k rest

  valueOf : Char → Maybe Nat
  valueOf c =
    let n = charCode c in
    if (65 ≤ⁿ n) ∧ (n ≤ⁿ 90) then just (n - 65)
    else if (97 ≤ⁿ n) ∧ (n ≤ⁿ 122) then just (n - 71)
    else if (48 ≤ⁿ n) ∧ (n ≤ⁿ 57) then just (n + 4)
    else if n ==ⁿ 43 then just 62
    else if n ==ⁿ 47 then just 63
    else nothing

encodeOctets : List Nat → List Char
encodeOctets [] = []
encodeOctets (a ∷ []) =
  digitAt (a div 4) ∷ digitAt ((a mod 4) * 16) ∷ '=' ∷ '=' ∷ []
encodeOctets (a ∷ b ∷ []) =
  digitAt (a div 4) ∷ digitAt (((a mod 4) * 16) + (b div 16))
    ∷ digitAt ((b mod 16) * 4) ∷ '=' ∷ []
encodeOctets (a ∷ b ∷ c ∷ rest) =
  digitAt (a div 4) ∷ digitAt (((a mod 4) * 16) + (b div 16))
    ∷ digitAt (((b mod 16) * 4) + (c div 64)) ∷ digitAt (c mod 64)
    ∷ encodeOctets rest

encode : Bytes → String
encode buffer = stringFromList (encodeOctets (toOctets buffer))

private
  triple : Maybe Nat → Maybe Nat → Maybe Nat → Maybe Nat → Maybe (List Nat)
  triple (just a) (just b) (just c) (just d) =
    just (((a * 4) + (b div 16)) ∷ (((b mod 16) * 16) + (c div 4)) ∷ (((c mod 4) * 64) + d) ∷ [])
  triple _ _ _ _ = nothing

  pair : Maybe Nat → Maybe Nat → Maybe Nat → Maybe (List Nat)
  pair (just a) (just b) (just c) =
    if (c mod 4) ==ⁿ 0
      then just (((a * 4) + (b div 16)) ∷ (((b mod 16) * 16) + (c div 4)) ∷ [])
      else nothing
  pair _ _ _ = nothing

  single : Maybe Nat → Maybe Nat → Maybe (List Nat)
  single (just a) (just b) =
    if (b mod 16) ==ⁿ 0 then just (((a * 4) + (b div 16)) ∷ []) else nothing
  single _ _ = nothing

  appendMaybe : Maybe (List Nat) → Maybe (List Nat) → Maybe (List Nat)
  appendMaybe (just xs) (just ys) = just (xs ++ ys)
  appendMaybe _ _ = nothing

-- Strict decoding: the padded groups must have zero padding bits, and no
-- character outside the standard alphabet is tolerated.
decodeChars : List Char → Maybe (List Nat)
decodeChars [] = just []
decodeChars (a ∷ b ∷ '=' ∷ '=' ∷ []) = single (valueOf a) (valueOf b)
decodeChars (a ∷ b ∷ c ∷ '=' ∷ []) = pair (valueOf a) (valueOf b) (valueOf c)
decodeChars (a ∷ b ∷ c ∷ d ∷ rest) =
  appendMaybe (triple (valueOf a) (valueOf b) (valueOf c) (valueOf d)) (decodeChars rest)
decodeChars _ = nothing

decode : String → Maybe (List Nat)
decode text = decodeChars (stringToList text)

--------------------------------------------------------------------------------
-- Live timestamps
--------------------------------------------------------------------------------

private
  littleEndian64 : Nat → List Nat
  littleEndian64 value =
    value mod 256 ∷ (value div 256) mod 256 ∷ (value div 65536) mod 256
      ∷ (value div 16777216) mod 256 ∷ (value div pow2 32) mod 256
      ∷ (value div pow2 40) mod 256 ∷ (value div pow2 48) mod 256
      ∷ (value div pow2 56) mod 256 ∷ []

  fromLittleEndian : List Nat → Nat → Nat → Nat
  fromLittleEndian [] _ acc = acc
  fromLittleEndian (b ∷ rest) weight acc =
    fromLittleEndian rest (weight * 256) (acc + (b * weight))

timestampEncode : Nat → String
timestampEncode value = stringFromList (encodeOctets (littleEndian64 (value mod pow2 64)))

-- The initial `ts` the client sends before any Transition has been observed.
initialTimestamp : String
initialTimestamp = timestampEncode 0

-- A timestamp is only accepted when re-encoding the decoded value reproduces
-- the exact text the peer sent.
timestampDecode : String → Maybe Nat
timestampDecode text =
  if not (stringLength text ==ⁿ 12) then nothing else check (decode text)
  where
    canonical : Nat → Maybe Nat
    canonical value = if timestampEncode value ==ˢ text then just value else nothing

    check : Maybe (List Nat) → Maybe Nat
    check nothing = nothing
    check (just octets) =
      if length octets ==ⁿ 8 then canonical (fromLittleEndian octets 1 0) else nothing
