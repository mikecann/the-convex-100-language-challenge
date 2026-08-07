||| Small binary codecs the Convex protocols need: Base64 for the WebSocket
||| handshake and for Convex's opaque timestamps, SHA-1 for verifying the
||| server's `Sec-WebSocket-Accept`, and hexadecimal for session identifiers.
|||
||| Everything here works on lists of byte values because the inputs are tiny
||| and fixed size. Bulk payloads never pass through this module.
module Convex.Codec

import Data.Bits
import Data.List
import Data.String

import Convex.Prim

alphabet : List Char
alphabet = unpack "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

nthOr : a -> Nat -> List a -> a
nthOr fallback _ [] = fallback
nthOr _ Z (value :: _) = value
nthOr fallback (S index) (_ :: rest) = nthOr fallback index rest

symbolFor : Int -> Char
symbolFor value = nthOr '=' (cast value) alphabet

||| The inverse alphabet. Anything outside it, including whitespace and the
||| URL-safe variants, is rejected rather than silently reinterpreted.
symbolValue : Char -> Maybe Int
symbolValue character =
  let point = ord character in
  if point >= 65 && point <= 90 then Just (point - 65)
  else if point >= 97 && point <= 122 then Just (point - 71)
  else if point >= 48 && point <= 57 then Just (point + 4)
  else if point == 43 then Just 62
  else if point == 47 then Just 63
  else Nothing

||| Standard Base64 with padding.
export
base64Encode : List Int -> String
base64Encode bytes = pack (go bytes)
  where
    go : List Int -> List Char
    go [] = []
    go (a :: b :: c :: rest) =
      symbolFor (div a 4)
        :: symbolFor (mod a 4 * 16 + div b 16)
        :: symbolFor (mod b 16 * 4 + div c 64)
        :: symbolFor (mod c 64)
        :: go rest
    go [a, b] =
      [ symbolFor (div a 4)
      , symbolFor (mod a 4 * 16 + div b 16)
      , symbolFor (mod b 16 * 4)
      , '='
      ]
    go [a] =
      [ symbolFor (div a 4)
      , symbolFor (mod a 4 * 16)
      , '='
      , '='
      ]

||| Decode standard Base64. Padding must be exact and unused padding bits must
||| be zero, so a Convex timestamp has exactly one accepted spelling.
export
base64Decode : String -> Maybe (List Int)
base64Decode text =
  let symbols = unpack text in
  if mod (cast {to = Int} (length symbols)) 4 /= 0 || null symbols
     then Nothing
     else go symbols
  where
    quad : Char -> Char -> Char -> Char -> Maybe (List Int)
    quad a b c d =
      do first <- symbolValue a
         second <- symbolValue b
         case (c == '=', d == '=') of
              (True, True) =>
                if mod second 16 /= 0
                   then Nothing
                   else Just [first * 4 + div second 16]
              (True, False) => Nothing
              (False, True) =>
                do third <- symbolValue c
                   if mod third 4 /= 0
                      then Nothing
                      else Just [ first * 4 + div second 16
                                , mod second 16 * 16 + div third 4
                                ]
              (False, False) =>
                do third <- symbolValue c
                   fourth <- symbolValue d
                   Just [ first * 4 + div second 16
                        , mod second 16 * 16 + div third 4
                        , mod third 4 * 64 + fourth
                        ]

    go : List Char -> Maybe (List Int)
    go [] = Just []
    go (a :: b :: c :: d :: rest) =
      do decoded <- quad a b c d
         -- Padding is only legal in the final quantum.
         if (c == '=' || d == '=') && not (null rest)
            then Nothing
            else do tail' <- go rest
                    Just (decoded ++ tail')
    go _ = Nothing

export
hexEncode : List Int -> String
hexEncode bytes = pack (concatMap digits bytes)
  where
    digit : Int -> Char
    digit value = if value < 10 then chr (48 + value) else chr (87 + value)

    digits : Int -> List Char
    digits value = [digit (div value 16), digit (mod value 16)]

||| Cryptographically strong bytes from the shim, used for WebSocket masking
||| keys, handshake nonces, and session identifiers.
export
randomByteList : Int -> IO (Maybe (List Int))
randomByteList count =
  do buffer <- bufNew count
     if buffer < 0
        then pure Nothing
        else do filled <- randomBytes buffer 0 count
                if filled /= 0
                   then do bufFree buffer
                           pure Nothing
                   else do bytes <- collect buffer 0 []
                           bufFree buffer
                           pure (Just bytes)
  where
    covering
    collect : Int -> Int -> List Int -> IO (List Int)
    collect buffer index acc =
      if index >= count
         then pure (reverse acc)
         else do value <- bufGet buffer index
                 collect buffer (index + 1) (value :: acc)

--------------------------------------------------------------------------------
-- SHA-1
--------------------------------------------------------------------------------

-- `Bits32` multiplication wraps modulo 2^32 and its division is unsigned, so a
-- rotation is expressed arithmetically. That avoids the shift operators, whose
-- index type differs between Idris releases, without changing the result: the
-- shifted-out and shifted-in halves never overlap, so addition is a bitwise or.

rotl1 : Bits32 -> Bits32
rotl1 value = value * 2 + div value 2147483648

rotl5 : Bits32 -> Bits32
rotl5 value = value * 32 + div value 134217728

rotl30 : Bits32 -> Bits32
rotl30 value = value * 1073741824 + div value 4

wordAt : Nat -> List Bits32 -> Bits32
wordAt = nthOr 0

||| The 80-entry message schedule for one block. The accumulator is newest
||| first, so `w[i-3]` is simply the element three places in.
covering
expandSchedule : List Bits32 -> List Bits32
expandSchedule initial = reverse (go (reverse initial) 16)
  where
    covering
    go : List Bits32 -> Nat -> List Bits32
    go acc index =
      if index >= 80
         then acc
         else let mixed = rotl1 (wordAt 2 acc `xor` wordAt 7 acc
                                   `xor` wordAt 13 acc `xor` wordAt 15 acc) in
              go (mixed :: acc) (S index)

roundConstant : Nat -> Bits32
roundConstant index =
  if index < 20 then 0x5A827999
  else if index < 40 then 0x6ED9EBA1
  else if index < 60 then 0x8F1BBCDC
  else 0xCA62C1D6

roundMix : Nat -> Bits32 -> Bits32 -> Bits32 -> Bits32
roundMix index b c d =
  if index < 20 then (b .&. c) .|. ((b `xor` 4294967295) .&. d)
  else if index < 40 then b `xor` c `xor` d
  else if index < 60 then (b .&. c) .|. (b .&. d) .|. (c .&. d)
  else b `xor` c `xor` d

record Sha1State where
  constructor MkSha1State
  h0, h1, h2, h3, h4 : Bits32

covering
runBlock : Sha1State -> List Bits32 -> Sha1State
runBlock state words =
  let schedule = expandSchedule words
      (a, b, c, d, e) = rounds 0 schedule (h0 state, h1 state, h2 state,
                                           h3 state, h4 state) in
  MkSha1State (h0 state + a) (h1 state + b) (h2 state + c) (h3 state + d)
              (h4 state + e)
  where
    covering
    rounds : Nat -> List Bits32 -> (Bits32, Bits32, Bits32, Bits32, Bits32)
          -> (Bits32, Bits32, Bits32, Bits32, Bits32)
    rounds index schedule (a, b, c, d, e) =
      if index >= 80
         then (a, b, c, d, e)
         else let temporary = rotl5 a + roundMix index b c d + e
                                + roundConstant index + wordAt index schedule in
              rounds (S index) schedule (temporary, a, rotl30 b, c, d)

bytesToWord : List Int -> Bits32
bytesToWord bytes =
  case bytes of
       [a, b, c, d] => cast a * 16777216 + cast b * 65536 + cast c * 256 + cast d
       _ => 0

chunksOf4 : List Int -> List Bits32
chunksOf4 [] = []
chunksOf4 (a :: b :: c :: d :: rest) = bytesToWord [a, b, c, d] :: chunksOf4 rest
chunksOf4 _ = []

covering
blocksOf64 : List Int -> List (List Int)
blocksOf64 [] = []
blocksOf64 bytes =
  let block = take 64 bytes
      rest = drop 64 bytes in
  if length block < 64 then [] else block :: blocksOf64 rest

||| Append the SHA-1 padding: a `0x80` byte, zeroes, and the 64-bit big-endian
||| bit length.
padMessage : List Int -> List Int
padMessage message =
  let messageLength = cast {to = Int} (length message)
      zeroes = mod (55 - mod messageLength 64 + 64) 64
      bitLength = messageLength * 8 in
  message ++ [0x80] ++ replicate (cast zeroes) 0 ++ lengthBytes bitLength
  where
    -- `total` is a reserved word in Idris2 (totality annotations), so the
    -- bit length being packed into bytes below is named `bits` instead.
    lengthBytes : Int -> List Int
    lengthBytes bits =
      [ 0, 0, 0, 0
      , mod (div bits 16777216) 256
      , mod (div bits 65536) 256
      , mod (div bits 256) 256
      , mod bits 256
      ]

wordBytes : Bits32 -> List Int
wordBytes value =
  [ cast (mod (div value 16777216) 256)
  , cast (mod (div value 65536) 256)
  , cast (mod (div value 256) 256)
  , cast (mod value 256)
  ]

||| SHA-1 of a byte list. Only the WebSocket handshake uses it, where the input
||| is the 24-character client key concatenated with the protocol GUID.
export covering
sha1 : List Int -> List Int
sha1 message =
  let final = foldl step (MkSha1State 0x67452301 0xEFCDAB89 0x98BADCFE 0x10325476
                                      0xC3D2E1F0)
                    (blocksOf64 (padMessage message)) in
  concatMap wordBytes [h0 final, h1 final, h2 final, h3 final, h4 final]
  where
    covering
    step : Sha1State -> List Int -> Sha1State
    step state block = runBlock state (chunksOf4 block)

--------------------------------------------------------------------------------
-- Convex timestamps
--------------------------------------------------------------------------------

||| Convex encodes a sync timestamp as a little-endian unsigned 64-bit integer
||| in Base64. `Integer` is used rather than a machine word because the top bit
||| is meaningful and must not become a negative comparison.
export
encodeTimestamp : Integer -> Maybe String
encodeTimestamp value =
  if value < 0 || value > 18446744073709551615
     then Nothing
     else Just (base64Encode (bytes 8 value))
  where
    bytes : Nat -> Integer -> List Int
    bytes Z _ = []
    bytes (S remaining) current =
      cast (mod current 256) :: bytes remaining (div current 256)

||| Decode a Convex timestamp and insist that it is canonical. A value that
||| re-encodes differently is treated as profile drift rather than accepted.
export
decodeTimestamp : String -> Maybe Integer
decodeTimestamp text =
  do bytes <- base64Decode text
     if length bytes /= 8
        then Nothing
        else do let value = foldr (\byte, acc => acc * 256 + cast byte) 0 bytes
                encoded <- encodeTimestamp value
                if encoded == text then Just value else Nothing
