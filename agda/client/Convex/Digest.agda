{-# OPTIONS --without-K #-}

-- SHA-1 and FNV-1a in Agda.
--
-- SHA-1 exists only to derive `Sec-WebSocket-Accept` during the RFC6455
-- handshake, so it always runs over the ~60 octet concatenation of the client
-- key and the protocol GUID. Keeping it here rather than behind the foreign
-- boundary means the handshake check that proves the peer really spoke
-- WebSocket is Agda code a reviewer can read.
--
-- FNV-1a produces the fixed-size signature the Live manager uses to suppress
-- an unchanged rehydration after a reconnect, so a duplicate value never has
-- to be kept around for comparison.
module Convex.Digest where

open import Convex.Prelude
open import Convex.Bytes

--------------------------------------------------------------------------------
-- Machine-word arithmetic over naturals
--------------------------------------------------------------------------------

private
  twoTo32 : Nat
  twoTo32 = 4294967296

  twoTo64 : Nat
  twoTo64 = 18446744073709551616

  -- Bitwise combination for `width` bits. Every use below is a fixed small
  -- width, so the loop is short and the recursion is structural.
  bitwise : (Nat → Nat → Nat) → Nat → Nat → Nat → Nat
  bitwise op width a b = go width a b 1 0
    where
      go : Nat → Nat → Nat → Nat → Nat → Nat
      go zero _ _ _ acc = acc
      go (suc k) x y weight acc =
        go k (x div 2) (y div 2) (weight * 2)
           (acc + (weight * op (x mod 2) (y mod 2)))

  xorBit : Nat → Nat → Nat
  xorBit a b = (a + b) mod 2

  andBit : Nat → Nat → Nat
  andBit a b = a * b

  orBit : Nat → Nat → Nat
  orBit a b = if (a + b) ==ⁿ 0 then 0 else 1

mask32 : Nat → Nat
mask32 n = n mod twoTo32

xor32 : Nat → Nat → Nat
xor32 = bitwise xorBit 32

and32 : Nat → Nat → Nat
and32 = bitwise andBit 32

or32 : Nat → Nat → Nat
or32 = bitwise orBit 32

not32 : Nat → Nat
not32 n = 4294967295 - mask32 n

-- Rotating left by `bits` never overlaps the two halves, so the shifted and
-- carried parts can simply be added.
rotl32 : Nat → Nat → Nat
rotl32 n bits = mask32 ((mask32 n * pow2 bits) + (mask32 n div pow2 (32 - bits)))

--------------------------------------------------------------------------------
-- SHA-1
--------------------------------------------------------------------------------

record Sha1State : Set where
  constructor sha1State
  field
    a : Nat
    b : Nat
    c : Nat
    d : Nat
    e : Nat

private
  nth : Nat → List Nat → Nat
  nth _ [] = 0
  nth zero (x ∷ _) = x
  nth (suc n) (_ ∷ xs) = nth n xs

  bigEndian32 : Bytes → Nat → Nat
  bigEndian32 buffer at =
    (octet buffer at * 16777216) + (octet buffer (at + 1) * 65536)
      + (octet buffer (at + 2) * 256) + octet buffer (at + 3)

  initialWords : Nat → Bytes → Nat → List Nat → List Nat
  initialWords zero _ _ acc = reverse acc
  initialWords (suc k) buffer at acc =
    initialWords k buffer (at + 4) (bigEndian32 buffer at ∷ acc)

  -- w[i] = rotl(w[i-3] xor w[i-8] xor w[i-14] xor w[i-16], 1) for 16 <= i < 80.
  expandWords : Nat → List Nat → List Nat
  expandWords zero ws = ws
  expandWords (suc k) ws =
    let i = length ws
        mixed = xor32 (xor32 (nth (i - 3) ws) (nth (i - 8) ws))
                      (xor32 (nth (i - 14) ws) (nth (i - 16) ws))
    in expandWords k (ws ++ (rotl32 mixed 1 ∷ []))

  roundFunction : Nat → Nat → Nat → Nat → Nat
  roundFunction i b c d =
    if i <ⁿ 20 then or32 (and32 b c) (and32 (not32 b) d)
    else if i <ⁿ 40 then xor32 (xor32 b c) d
    else if i <ⁿ 60 then or32 (or32 (and32 b c) (and32 b d)) (and32 c d)
    else xor32 (xor32 b c) d

  roundConstant : Nat → Nat
  roundConstant i =
    if i <ⁿ 20 then 1518500249
    else if i <ⁿ 40 then 1859775393
    else if i <ⁿ 60 then 2400959708
    else 3395469782

  roundStep : List Nat → Nat → Sha1State → Sha1State
  roundStep ws i (sha1State a b c d e) =
    let temp = mask32 (rotl32 a 5 + roundFunction i b c d + e + roundConstant i + nth i ws)
    in sha1State temp a (rotl32 b 30) c d

  runRounds : Nat → Nat → List Nat → Sha1State → Sha1State
  runRounds zero _ _ state = state
  runRounds (suc k) i ws state = runRounds k (suc i) ws (roundStep ws i state)

  addStates : Sha1State → Sha1State → Sha1State
  addStates (sha1State a1 b1 c1 d1 e1) (sha1State a2 b2 c2 d2 e2) =
    sha1State (mask32 (a1 + a2)) (mask32 (b1 + b2)) (mask32 (c1 + c2))
              (mask32 (d1 + d2)) (mask32 (e1 + e2))

  processBlocks : Nat → Bytes → Nat → Sha1State → Sha1State
  processBlocks zero _ _ state = state
  processBlocks (suc k) buffer at state =
    let ws = expandWords 64 (initialWords 16 buffer at [])
        mixed = runRounds 80 0 ws state
    in processBlocks k buffer (at + 64) (addStates state mixed)

  zeros : Nat → List Nat
  zeros zero = []
  zeros (suc n) = 0 ∷ zeros n

  bigEndian64Octets : Nat → List Nat
  bigEndian64Octets value =
    (value div pow2 56) mod 256 ∷ (value div pow2 48) mod 256 ∷
    (value div pow2 40) mod 256 ∷ (value div pow2 32) mod 256 ∷
    (value div pow2 24) mod 256 ∷ (value div pow2 16) mod 256 ∷
    (value div pow2 8) mod 256 ∷ value mod 256 ∷ []

  bigEndian32Octets : Nat → List Nat
  bigEndian32Octets value =
    (value div 16777216) mod 256 ∷ (value div 65536) mod 256 ∷
    (value div 256) mod 256 ∷ value mod 256 ∷ []

-- Pad to a whole number of 64-octet blocks, then fold the blocks. The input is
-- the short handshake string, so materialising the padded copy is cheap.
sha1 : Bytes → Bytes
sha1 message =
  let messageLength = size message
      -- One 0x80 octet plus eight length octets must land on a block edge.
      padLength = (64 - ((messageLength + 9) mod 64)) mod 64
      padded = message +++ fromOctets ((128 ∷ zeros padLength) ++ bigEndian64Octets (messageLength * 8))
      final = processBlocks (size padded div 64) padded 0
                (sha1State 1732584193 4023233417 2562383102 271733878 3285377520)
  in digestBytes final
  where
    digestBytes : Sha1State → Bytes
    digestBytes (sha1State a b c d e) =
      fromOctets (bigEndian32Octets a ++ bigEndian32Octets b ++ bigEndian32Octets c
                    ++ bigEndian32Octets d ++ bigEndian32Octets e)

--------------------------------------------------------------------------------
-- FNV-1a, 64 bit
--------------------------------------------------------------------------------

-- Also used by the RFC6455 masking step, which exclusive-ors each payload
-- octet with one octet of the client's random mask.
xor8 : Nat → Nat → Nat
xor8 = bitwise xorBit 8

-- Only the low octet of the accumulator participates in each exclusive-or, so
-- the fixed 8-bit loop is all the bit arithmetic this hash needs.
fnv1a64 : Bytes → Nat
fnv1a64 buffer = go (size buffer) 0 14695981039346656037
  where
    go : Nat → Nat → Nat → Nat
    go zero _ hash = hash
    go (suc fuel) index hash =
      if index ≥ⁿ size buffer then hash
      else
        let low = hash mod 256
            mixed = (hash - low) + xor8 low (octet buffer index)
        in go fuel (suc index) ((mixed * 1099511628211) mod twoTo64)
