{-# OPTIONS --without-K #-}

-- JSON for Convex, written in Agda.
--
-- Two decisions matter for Convex specifically.
--
-- First, numbers keep their original lexeme. Convex round-trips arbitrary user
-- values through `demo:echo`, so re-encoding `42.5` must not turn it into a
-- float approximation, while an integral value that arrives as `0.0` must
-- still be readable as a count. `natOfLexeme` performs that integral view with
-- exact arithmetic and rejects fractional, signed, or overflowing input.
--
-- Second, decoding is bounded before it allocates. A lexical pre-pass counts
-- nesting and structural nodes without building a value, so hostile input is
-- refused rather than expanded inside a 128 MiB container.
module Convex.Json where

open import Convex.Prelude
open import Convex.Bytes
import Convex.Utf8 as Utf8

--------------------------------------------------------------------------------
-- Values
--------------------------------------------------------------------------------

data JSON : Set where
  jnull : JSON
  jbool : Bool → JSON
  jnum : String → JSON
  jstr : String → JSON
  jarr : List JSON → JSON
  jobj : List (String × JSON) → JSON

jnat : Nat → JSON
jnat n = jnum (showNat n)

--------------------------------------------------------------------------------
-- Bounds
--------------------------------------------------------------------------------

maxJsonOctets : Nat
maxJsonOctets = 1048576

maxJsonDepth : Nat
maxJsonDepth = 64

maxJsonNodes : Nat
maxJsonNodes = 4096

--------------------------------------------------------------------------------
-- Accessors
--------------------------------------------------------------------------------

objectFields : JSON → Maybe (List (String × JSON))
objectFields (jobj fields) = just fields
objectFields _ = nothing

isObject : JSON → Bool
isObject (jobj _) = true
isObject _ = false

objGet : JSON → String → Maybe JSON
objGet (jobj fields) name = lookupBy (λ k → k ==ˢ name) fields
objGet _ _ = nothing

objHas : JSON → String → Bool
objHas value name = isJust (objGet value name)

objOr : JSON → String → JSON → JSON
objOr value name fallback = fromMaybe fallback (objGet value name)

asString : JSON → Maybe String
asString (jstr s) = just s
asString _ = nothing

asBool : JSON → Maybe Bool
asBool (jbool b) = just b
asBool _ = nothing

asArray : JSON → Maybe (List JSON)
asArray (jarr items) = just items
asArray _ = nothing

-- Convex `logLines` must be an array of strings. Anything else is protocol
-- drift the client reports rather than silently coerces.
asStringList : JSON → Maybe (List String)
asStringList (jarr items) = go items []
  where
    go : List JSON → List String → Maybe (List String)
    go [] acc = just (reverse acc)
    go (jstr s ∷ rest) acc = go rest (s ∷ acc)
    go (_ ∷ _) _ = nothing
asStringList _ = nothing

--------------------------------------------------------------------------------
-- Integral view of a number lexeme
--------------------------------------------------------------------------------

record Decomposed : Set where
  constructor decomposed
  field
    negative : Bool
    intPart : List Char
    fracPart : List Char
    expNegative : Bool
    expPart : List Char

private
  digitsValue : List Char → Maybe Nat
  digitsValue chars = go chars 0
    where
      go : List Char → Nat → Maybe Nat
      go [] acc = just acc
      go (c ∷ rest) acc =
        if isDigit c then go rest ((acc * 10) + (charCode c - 48)) else nothing

  takeDigits : List Char → List Char × List Char
  takeDigits [] = ([] , [])
  takeDigits (c ∷ rest) =
    if isDigit c
      then (let split = takeDigits rest in (c ∷ fst split , snd split))
      else ([] , c ∷ rest)

  exponentOf : Bool → List Char → List Char → List Char → Maybe Decomposed
  exponentOf neg ipart fpart body =
    let signed = signOf body
        split = takeDigits (snd signed)
    in
    if length (fst split) ==ⁿ 0 then nothing
    else if length (snd split) ==ⁿ 0
      then just (decomposed neg ipart fpart (fst signed) (fst split))
      else nothing
    where
      signOf : List Char → Bool × List Char
      signOf ('+' ∷ rest) = (false , rest)
      signOf ('-' ∷ rest) = (true , rest)
      signOf other = (false , other)

  afterFraction : Bool → List Char → List Char → List Char → Maybe Decomposed
  afterFraction neg ipart fpart [] = just (decomposed neg ipart fpart false ('0' ∷ []))
  afterFraction neg ipart fpart ('e' ∷ rest) = exponentOf neg ipart fpart rest
  afterFraction neg ipart fpart ('E' ∷ rest) = exponentOf neg ipart fpart rest
  afterFraction _ _ _ (_ ∷ _) = nothing

  afterInteger : Bool → List Char → List Char → Maybe Decomposed
  afterInteger neg ipart [] = just (decomposed neg ipart [] false ('0' ∷ []))
  afterInteger neg ipart ('.' ∷ rest) =
    let split = takeDigits rest in
    if length (fst split) ==ⁿ 0 then nothing
    else afterFraction neg ipart (fst split) (snd split)
  afterInteger neg ipart ('e' ∷ rest) = exponentOf neg ipart [] rest
  afterInteger neg ipart ('E' ∷ rest) = exponentOf neg ipart [] rest
  afterInteger _ _ (_ ∷ _) = nothing

  -- JSON's integer part is either a lone `0` or a nonzero-led digit run;
  -- `01`, `00`, and `007` are all malformed. `takeDigits` alone accepts any
  -- digit run, so this is the only place that grammar rule is enforced.
  hasLeadingZero : List Char → Bool
  hasLeadingZero ('0' ∷ _ ∷ _) = true
  hasLeadingZero _ = false

  afterSign : Bool → List Char → Maybe Decomposed
  afterSign neg body =
    let split = takeDigits body in
    if length (fst split) ==ⁿ 0 then nothing
    else if hasLeadingZero (fst split) then nothing
    else afterInteger neg (fst split) (snd split)

  pow10 : Nat → Nat
  pow10 zero = 1
  pow10 (suc n) = 10 * pow10 n

-- The JSON number grammar, reused both by the decoder's token check and by the
-- integral view so the two can never drift apart.
decomposeNumber : List Char → Maybe Decomposed
decomposeNumber [] = nothing
decomposeNumber ('-' ∷ rest) = afterSign true rest
decomposeNumber other = afterSign false other

-- Largest integer the shared conformance surface exchanges.
maxSafeInteger : Nat
maxSafeInteger = 9223372036854775807

private
  boundedNat : Bool → Maybe Nat → Maybe Nat
  boundedNat _ nothing = nothing
  boundedNat neg (just v) =
    if neg ∧ not (v ==ⁿ 0) then nothing
    else if v >ⁿ maxSafeInteger then nothing
    else just v

  scaleMantissa : Nat → Nat → Bool → Nat → Maybe Nat
  scaleMantissa mantissa fracDigits expNegative exponent =
    if expNegative then
      (let shift = exponent + fracDigits in
       if mantissa mod pow10 shift ==ⁿ 0 then just (mantissa div pow10 shift) else nothing)
    else if exponent ≥ⁿ fracDigits then just (mantissa * pow10 (exponent - fracDigits))
    else
      (let shift = fracDigits - exponent in
       if mantissa mod pow10 shift ==ⁿ 0 then just (mantissa div pow10 shift) else nothing)

  integralOf : Decomposed → Maybe Nat
  integralOf (decomposed neg ipart fpart eneg epart) =
    combine (digitsValue (ipart ++ fpart)) (digitsValue epart)
    where
      combine : Maybe Nat → Maybe Nat → Maybe Nat
      combine (just mantissa) (just exponent) =
        boundedNat neg (scaleMantissa mantissa (length fpart) eneg exponent)
      combine _ _ = nothing

-- Accept a mathematically integral, in-range, non-negative number, whether it
-- arrived as `1`, `1.0`, or `1e0`. Anything fractional or oversized is
-- rejected instead of rounded.
natOfLexeme : String → Maybe Nat
natOfLexeme lexeme = go (decomposeNumber (stringToList lexeme))
  where
    go : Maybe Decomposed → Maybe Nat
    go nothing = nothing
    go (just parts) = integralOf parts

asNat : JSON → Maybe Nat
asNat (jnum lexeme) = natOfLexeme lexeme
asNat _ = nothing

--------------------------------------------------------------------------------
-- Encoding
--------------------------------------------------------------------------------

private
  escapeChar : Char → List Char
  escapeChar c =
    let n = charCode c in
    if n ==ⁿ 34 then '\\' ∷ '"' ∷ []
    else if n ==ⁿ 92 then '\\' ∷ '\\' ∷ []
    else if n ==ⁿ 8 then '\\' ∷ 'b' ∷ []
    else if n ==ⁿ 9 then '\\' ∷ 't' ∷ []
    else if n ==ⁿ 10 then '\\' ∷ 'n' ∷ []
    else if n ==ⁿ 12 then '\\' ∷ 'f' ∷ []
    else if n ==ⁿ 13 then '\\' ∷ 'r' ∷ []
    else if n <ⁿ 32 then '\\' ∷ 'u' ∷ stringToList (showHex 4 n)
    else c ∷ []

encodeString : String → String
encodeString s =
  stringFromList ('"' ∷ (concat (map escapeChar (stringToList s)) ++ ('"' ∷ [])))

-- Encoding is written as explicit structural recursion over the value, its
-- items, and its members. That keeps Agda's termination checker satisfied
-- without a pragma and keeps the comma placement obvious.
mutual
  encode : JSON → String
  encode jnull = "null"
  encode (jbool true) = "true"
  encode (jbool false) = "false"
  encode (jnum lexeme) = lexeme
  encode (jstr s) = encodeString s
  encode (jarr items) = "[" <> encodeItems items <> "]"
  encode (jobj fields) = "{" <> encodeMembers fields <> "}"

  encodeItems : List JSON → String
  encodeItems [] = ""
  encodeItems (x ∷ []) = encode x
  encodeItems (x ∷ rest) = encode x <> "," <> encodeItems rest

  encodeMembers : List (String × JSON) → String
  encodeMembers [] = ""
  encodeMembers ((k , v) ∷ []) = encodeString k <> ":" <> encode v
  encodeMembers ((k , v) ∷ rest) = encodeString k <> ":" <> encode v <> "," <> encodeMembers rest

-- Exact encoded wire size. Every byte budget in the client and the adapter is
-- charged with this, so a count of events can never stand in for a memory
-- bound.
encodedOctets : JSON → Nat
encodedOctets value = Utf8.octetLength (encode value)

encodeBytes : JSON → Bytes
encodeBytes value = Utf8.encode (encode value)

--------------------------------------------------------------------------------
-- Bounded decoding
--------------------------------------------------------------------------------

private
  data PRes : Set where
    pok : JSON → Nat → PRes
    perr : String → PRes

  data PSRes : Set where
    psok : String → Nat → PSRes
    pserr : String → PSRes

  -- A purely lexical pass over the octets. It understands string literals and
  -- escapes, so brackets and commas inside a string never affect the counts,
  -- and it refuses hostile shapes before any value is constructed. `nothing`
  -- means the shape is acceptable.
  preflight : Nat → Bytes → Nat → Nat → Nat → Nat → Bool → Bool → Maybe String
  preflight zero _ _ _ _ _ _ _ = just "JSON pre-scan did not terminate"
  preflight (suc fuel) buffer index limit depth nodes inString escaped =
    if depth >ⁿ maxJsonDepth then just "JSON exceeds nesting limit"
    else if nodes >ⁿ maxJsonNodes then just "JSON exceeds structural node limit"
    else if index ≥ⁿ limit then nothing
    else
      let c = octet buffer index in
      if inString then
        (if escaped then preflight fuel buffer (suc index) limit depth nodes true false
         else if c ==ⁿ 92 then preflight fuel buffer (suc index) limit depth nodes true true
         else if c ==ⁿ 34 then preflight fuel buffer (suc index) limit depth nodes false false
         else preflight fuel buffer (suc index) limit depth nodes true false)
      else if c ==ⁿ 34 then preflight fuel buffer (suc index) limit depth nodes true false
      else if (c ==ⁿ 123) ∨ (c ==ⁿ 91) then
        preflight fuel buffer (suc index) limit (suc depth) (suc nodes) false false
      else if (c ==ⁿ 125) ∨ (c ==ⁿ 93) then
        preflight fuel buffer (suc index) limit (depth - 1) nodes false false
      -- Each comma introduces at least one more member, so it is a
      -- conservative pre-allocation bound.
      else if c ==ⁿ 44 then preflight fuel buffer (suc index) limit depth (suc nodes) false false
      else preflight fuel buffer (suc index) limit depth nodes false false

  skipSpace : Nat → Bytes → Nat → Nat → Nat
  skipSpace zero _ index _ = index
  skipSpace (suc fuel) buffer index limit =
    if index ≥ⁿ limit then index
    else
      let c = octet buffer index in
      if (c ==ⁿ 32) ∨ (c ==ⁿ 9) ∨ (c ==ⁿ 10) ∨ (c ==ⁿ 13)
        then skipSpace fuel buffer (suc index) limit
        else index

  hexAt : Bytes → Nat → Maybe Nat
  hexAt buffer index = hexDigitValue (charFromCode (octet buffer index))

  hex4 : Bytes → Nat → Nat → Maybe Nat
  hex4 buffer index limit =
    if index + 3 ≥ⁿ limit then nothing
    else combine (hexAt buffer index) (hexAt buffer (index + 1))
                 (hexAt buffer (index + 2)) (hexAt buffer (index + 3))
    where
      combine : Maybe Nat → Maybe Nat → Maybe Nat → Maybe Nat → Maybe Nat
      combine (just a) (just b) (just c) (just d) =
        just ((a * 4096) + (b * 256) + (c * 16) + d)
      combine _ _ _ _ = nothing

  -- String literal scanning. `stringChars`, `stringEscape`, and
  -- `stringUnicode` share one fuel that strictly decreases on every step.
  stringChars : Nat → Bytes → Nat → Nat → List Char → PSRes
  stringEscape : Nat → Bytes → Nat → Nat → List Char → PSRes
  stringUnicode : Nat → Bytes → Nat → Nat → List Char → PSRes

  stringChars zero _ _ _ _ = pserr "JSON string is unterminated"
  stringChars (suc fuel) buffer index limit acc =
    if index ≥ⁿ limit then pserr "JSON string is unterminated"
    else
      let c = octet buffer index in
      if c ==ⁿ 34 then psok (stringFromList (reverse acc)) (suc index)
      else if c ==ⁿ 92 then stringEscape fuel buffer (suc index) limit acc
      else if c <ⁿ 32 then pserr "JSON string contains a raw control character"
      else step (Utf8.decodeAt buffer index limit)
    where
      step : Maybe (Nat × Nat) → PSRes
      step nothing = pserr "JSON string is not valid UTF-8"
      step (just (code , width)) =
        stringChars fuel buffer (index + width) limit (charFromCode code ∷ acc)

  stringEscape zero _ _ _ _ = pserr "JSON escape is unterminated"
  stringEscape (suc fuel) buffer index limit acc =
    if index ≥ⁿ limit then pserr "JSON escape is unterminated"
    else
      let c = octet buffer index in
      if c ==ⁿ 34 then stringChars fuel buffer (suc index) limit ('"' ∷ acc)
      else if c ==ⁿ 92 then stringChars fuel buffer (suc index) limit ('\\' ∷ acc)
      else if c ==ⁿ 47 then stringChars fuel buffer (suc index) limit ('/' ∷ acc)
      else if c ==ⁿ 98 then stringChars fuel buffer (suc index) limit (charFromCode 8 ∷ acc)
      else if c ==ⁿ 102 then stringChars fuel buffer (suc index) limit (charFromCode 12 ∷ acc)
      else if c ==ⁿ 110 then stringChars fuel buffer (suc index) limit (charFromCode 10 ∷ acc)
      else if c ==ⁿ 114 then stringChars fuel buffer (suc index) limit (charFromCode 13 ∷ acc)
      else if c ==ⁿ 116 then stringChars fuel buffer (suc index) limit (charFromCode 9 ∷ acc)
      else if c ==ⁿ 117 then stringUnicode fuel buffer (suc index) limit acc
      else pserr "JSON string has an unsupported escape"

  stringUnicode zero _ _ _ _ = pserr "JSON escape is unterminated"
  stringUnicode (suc fuel) buffer index limit acc = start (hex4 buffer index limit)
    where
      low : Nat → Maybe Nat → PSRes
      low _ nothing = pserr "JSON surrogate pair is malformed"
      low high (just value) =
        if (56320 ≤ⁿ value) ∧ (value ≤ⁿ 57343)
          then stringChars fuel buffer (index + 10) limit
                 (charFromCode (65536 + ((high - 55296) * 1024) + (value - 56320)) ∷ acc)
          else pserr "JSON surrogate pair is malformed"

      start : Maybe Nat → PSRes
      start nothing = pserr "JSON \\u escape is malformed"
      start (just code) =
        if (56320 ≤ⁿ code) ∧ (code ≤ⁿ 57343) then pserr "JSON string has a lone low surrogate"
        else if (55296 ≤ⁿ code) ∧ (code ≤ⁿ 56319) then
          (if (octet buffer (index + 4) ==ⁿ 92) ∧ (octet buffer (index + 5) ==ⁿ 117)
             then low code (hex4 buffer (index + 6) limit)
             else pserr "JSON string has a lone high surrogate")
        else stringChars fuel buffer (index + 4) limit (charFromCode code ∷ acc)

  numberChars : Nat → Bytes → Nat → Nat → List Char → List Char × Nat
  numberChars zero _ index _ acc = (reverse acc , index)
  numberChars (suc fuel) buffer index limit acc =
    if index ≥ⁿ limit then (reverse acc , index)
    else
      let c = octet buffer index in
      if isDigit (charFromCode c) ∨ (c ==ⁿ 45) ∨ (c ==ⁿ 43) ∨ (c ==ⁿ 46)
         ∨ (c ==ⁿ 101) ∨ (c ==ⁿ 69)
        then numberChars fuel buffer (suc index) limit (charFromCode c ∷ acc)
        else (reverse acc , index)

  literalAt : Bytes → Nat → Nat → List Nat → Bool
  literalAt buffer index limit expected = go expected index
    where
      go : List Nat → Nat → Bool
      go [] _ = true
      go (c ∷ rest) i =
        if i ≥ⁿ limit then false
        else if octet buffer i ==ⁿ c then go rest (suc i) else false

  -- The value grammar. Every mutual call strictly decreases the shared fuel,
  -- which is seeded with the buffer length, so nesting terminates without a
  -- termination pragma.
  parseValue : Nat → Bytes → Nat → Nat → Nat → PRes
  parseNumberToken : Nat → Bytes → Nat → Nat → PRes
  parseArray : Nat → Bytes → Nat → Nat → Nat → List JSON → PRes
  parseArrayMember : Nat → Bytes → Nat → Nat → Nat → List JSON → PRes
  parseArrayTail : Nat → Bytes → Nat → Nat → Nat → List JSON → PRes → PRes
  parseObject : Nat → Bytes → Nat → Nat → Nat → List (String × JSON) → PRes
  parseObjectMember : Nat → Bytes → Nat → Nat → Nat → List (String × JSON) → PRes
  parseObjectValue : Nat → Bytes → Nat → Nat → Nat → List (String × JSON) → PSRes → PRes
  parseObjectTail : Nat → Bytes → Nat → Nat → Nat → List (String × JSON) → String → PRes → PRes

  parseValue zero _ _ _ _ = perr "JSON exceeds size or nesting limit"
  parseValue (suc fuel) buffer index limit depth =
    if depth >ⁿ maxJsonDepth then perr "JSON exceeds nesting limit"
    else
      let i = skipSpace (suc fuel) buffer index limit in
      if i ≥ⁿ limit then perr "JSON input ended unexpectedly"
      else
        let c = octet buffer i in
        if c ==ⁿ 34 then asValue (stringChars (suc fuel) buffer (suc i) limit [])
        else if c ==ⁿ 123 then parseObject fuel buffer (suc i) limit depth []
        else if c ==ⁿ 91 then parseArray fuel buffer (suc i) limit depth []
        else if literalAt buffer i limit (asciiOctets "true") then pok (jbool true) (i + 4)
        else if literalAt buffer i limit (asciiOctets "false") then pok (jbool false) (i + 5)
        else if literalAt buffer i limit (asciiOctets "null") then pok jnull (i + 4)
        else parseNumberToken fuel buffer i limit
    where
      asValue : PSRes → PRes
      asValue (pserr message) = perr message
      asValue (psok text next) = pok (jstr text) next

  parseNumberToken fuel buffer index limit =
    check (numberChars (suc fuel) buffer index limit [])
    where
      check : List Char × Nat → PRes
      check (chars , next) =
        if length chars ==ⁿ 0 then perr "JSON has an unexpected token"
        else if isJust (decomposeNumber chars) then pok (jnum (stringFromList chars)) next
        else perr "JSON number is malformed"

  parseArray zero _ _ _ _ _ = perr "JSON array exceeds size limit"
  parseArray (suc fuel) buffer index limit depth acc =
    let i = skipSpace (suc fuel) buffer index limit in
    if i ≥ⁿ limit then perr "JSON array is unterminated"
    else if octet buffer i ==ⁿ 93 then pok (jarr (reverse acc)) (suc i)
    else parseArrayTail fuel buffer i limit depth acc (parseValue fuel buffer i limit (suc depth))

  -- Entered only right after a comma, so (unlike `parseArray`) a `]` here is
  -- not an empty array: it is a trailing comma, and `parseValue` rejects it
  -- as an unexpected token because `]` starts no JSON value.
  parseArrayMember zero _ _ _ _ _ = perr "JSON array exceeds size limit"
  parseArrayMember (suc fuel) buffer index limit depth acc =
    let i = skipSpace (suc fuel) buffer index limit in
    if i ≥ⁿ limit then perr "JSON array is unterminated"
    else parseArrayTail fuel buffer i limit depth acc (parseValue fuel buffer i limit (suc depth))

  parseArrayTail zero _ _ _ _ _ _ = perr "JSON array exceeds size limit"
  parseArrayTail (suc fuel) buffer _ limit depth acc (pok value next) =
    let j = skipSpace (suc fuel) buffer next limit in
    if j ≥ⁿ limit then perr "JSON array is unterminated"
    else if octet buffer j ==ⁿ 44 then parseArrayMember fuel buffer (suc j) limit depth (value ∷ acc)
    else if octet buffer j ==ⁿ 93 then pok (jarr (reverse (value ∷ acc))) (suc j)
    else perr "JSON array is missing a separator"
  parseArrayTail (suc _) _ _ _ _ _ (perr message) = perr message

  parseObject zero _ _ _ _ _ = perr "JSON object exceeds size limit"
  parseObject (suc fuel) buffer index limit depth acc =
    let i = skipSpace (suc fuel) buffer index limit in
    if i ≥ⁿ limit then perr "JSON object is unterminated"
    else if octet buffer i ==ⁿ 125 then pok (jobj (reverse acc)) (suc i)
    else parseObjectMember fuel buffer i limit depth acc

  -- Entered only right after a comma, so (unlike `parseObject`) a `}` here
  -- is a trailing comma, not an empty object, and must be rejected rather
  -- than accepted as the end of the member list.
  parseObjectMember zero _ _ _ _ _ = perr "JSON object exceeds size limit"
  parseObjectMember (suc fuel) buffer index limit depth acc =
    let i = skipSpace (suc fuel) buffer index limit in
    if i ≥ⁿ limit then perr "JSON object is unterminated"
    else if not (octet buffer i ==ⁿ 34) then perr "JSON object key must be a string"
    else parseObjectValue fuel buffer i limit depth acc
           (stringChars (suc fuel) buffer (suc i) limit [])

  parseObjectValue zero _ _ _ _ _ _ = perr "JSON object exceeds size limit"
  parseObjectValue (suc fuel) buffer _ limit depth acc (psok name afterKey) =
    let j = skipSpace (suc fuel) buffer afterKey limit in
    if j ≥ⁿ limit then perr "JSON object is unterminated"
    else if not (octet buffer j ==ⁿ 58) then perr "JSON object member is missing a colon"
    else parseObjectTail fuel buffer j limit depth acc name
           (parseValue fuel buffer (suc j) limit (suc depth))
  parseObjectValue (suc _) _ _ _ _ _ (pserr message) = perr message

  parseObjectTail zero _ _ _ _ _ _ _ = perr "JSON object exceeds size limit"
  parseObjectTail (suc fuel) buffer _ limit depth acc name (pok value next) =
    let k = skipSpace (suc fuel) buffer next limit in
    if k ≥ⁿ limit then perr "JSON object is unterminated"
    else if octet buffer k ==ⁿ 44 then
      parseObjectMember fuel buffer (suc k) limit depth ((name , value) ∷ acc)
    else if octet buffer k ==ⁿ 125 then pok (jobj (reverse ((name , value) ∷ acc))) (suc k)
    else perr "JSON object is missing a separator"
  parseObjectTail (suc _) _ _ _ _ _ _ (perr message) = perr message

  finishDecode : Bytes → Nat → PRes → Either String JSON
  finishDecode _ _ (perr message) = left message
  finishDecode buffer limit (pok value next) =
    if skipSpace (suc limit) buffer next limit ≥ⁿ limit
      then right value
      else left "JSON has trailing data"

decodeBytes : Bytes → Either String JSON
decodeBytes buffer =
  if size buffer >ⁿ maxJsonOctets then left "JSON exceeds byte limit"
  else if size buffer ==ⁿ 0 then left "JSON input is empty"
  else guarded (preflight (suc (size buffer)) buffer 0 (size buffer) 0 1 false false)
  where
    guarded : Maybe String → Either String JSON
    guarded (just message) = left message
    guarded nothing =
      finishDecode buffer (size buffer)
        (parseValue (suc (size buffer)) buffer 0 (size buffer) 0)

decodeText : String → Either String JSON
decodeText text = decodeBytes (Utf8.encode text)
