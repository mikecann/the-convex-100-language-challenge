/-
Byte-level helpers shared by the HTTP and WebSocket layers.

The UTF-8 decoder here is incremental on purpose. A WebSocket text message may
be split across continuation frames, and each frame may be split across TCP
reads, so validation has to survive being suspended between any two bytes.
-/

namespace Convex.Bytes

/-- Naive substring search. Only used on bounded header buffers. -/
def findSub? (haystack needle : ByteArray) (start : Nat := 0) : Option Nat := Id.run do
  if needle.size == 0 || haystack.size < needle.size then
    return none
  let last := haystack.size - needle.size
  let mut position := start
  while position ≤ last do
    let mut matched := true
    let mut offset := 0
    while offset < needle.size do
      if haystack.get! (position + offset) != needle.get! offset then
        matched := false
        offset := needle.size
      else
        offset := offset + 1
    if matched then
      return some position
    position := position + 1
  return none

/-- `ByteArray` equality is spelled out here rather than assumed, so protocol
comparisons such as a chunk terminator do not depend on an instance that may
not exist in every toolchain. -/
def bytesEqual (left right : ByteArray) : Bool := Id.run do
  if left.size != right.size then
    return false
  let mut index := 0
  while index < left.size do
    if left.get! index != right.get! index then
      return false
    index := index + 1
  return true

def indexOfByte? (haystack : ByteArray) (needle : UInt8) (start : Nat := 0) :
    Option Nat := Id.run do
  let mut index := start
  while index < haystack.size do
    if haystack.get! index == needle then
      return some index
    index := index + 1
  return none

/-- Header and protocol text is ASCII by specification. Anything else is
rejected rather than silently reinterpreted. -/
def asciiToString (bytes : ByteArray) : Except String String := Id.run do
  let mut text := ""
  let mut index := 0
  while index < bytes.size do
    let byte := bytes.get! index
    if byte ≥ (0x80 : UInt8) then
      return .error "expected ASCII text"
    text := text.push (Char.ofNat byte.toNat)
    index := index + 1
  return .ok text

def asciiLower (text : String) : String := Id.run do
  let mut lowered := ""
  for character in text.toList do
    if character ≥ 'A' && character ≤ 'Z' then
      lowered := lowered.push (Char.ofNat (character.toNat + 32))
    else
      lowered := lowered.push character
  return lowered

/-- The state of a UTF-8 decode that may be suspended mid-sequence. -/
structure Utf8State where
  /-- Continuation bytes still required to finish the current code point. -/
  needed : Nat := 0
  /-- Code point accumulated so far. -/
  value : Nat := 0
  /-- Smallest code point this sequence length may legally encode. -/
  lowerBound : Nat := 0
  deriving Inhabited

def Utf8State.empty : Utf8State := {}

def Utf8State.isComplete (state : Utf8State) : Bool := state.needed == 0

/-- Feed bytes into a suspended decode. Returns the decoded text plus the state
to resume from, or the first structural problem found. -/
def utf8Feed (state : Utf8State) (bytes : ByteArray) :
    Except String (String × Utf8State) := Id.run do
  let mut current := state
  let mut text := ""
  let mut index := 0
  while index < bytes.size do
    let value := (bytes.get! index).toNat
    index := index + 1
    if current.needed == 0 then
      if value < 0x80 then
        text := text.push (Char.ofNat value)
      else if value < 0xC2 then
        -- 0x80..0xBF is a stray continuation byte; 0xC0 and 0xC1 are overlong.
        return .error "invalid UTF-8 lead byte"
      else if value < 0xE0 then
        current := { needed := 1, value := value - 0xC0, lowerBound := 0x80 }
      else if value < 0xF0 then
        current := { needed := 2, value := value - 0xE0, lowerBound := 0x800 }
      else if value < 0xF5 then
        current := { needed := 3, value := value - 0xF0, lowerBound := 0x10000 }
      else
        return .error "invalid UTF-8 lead byte"
    else
      if value < 0x80 || value ≥ 0xC0 then
        return .error "invalid UTF-8 continuation byte"
      let combined := current.value * 64 + (value - 0x80)
      let remaining := current.needed - 1
      if remaining == 0 then
        if combined < current.lowerBound then
          return .error "overlong UTF-8 sequence"
        if combined ≥ 0xD800 && combined ≤ 0xDFFF then
          return .error "UTF-8 encoded a surrogate code point"
        if combined > 0x10FFFF then
          return .error "UTF-8 code point is out of range"
        text := text.push (Char.ofNat combined)
        current := Utf8State.empty
      else
        current := { current with needed := remaining, value := combined }
  return .ok (text, current)

/-- Decode a complete buffer, rejecting a truncated final sequence. -/
def utf8Decode (bytes : ByteArray) : Except String String := do
  let (text, state) ← utf8Feed Utf8State.empty bytes
  if state.isComplete then
    .ok text
  else
    .error "truncated UTF-8 sequence"

private def base64Alphabet : Array Char :=
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".toList.toArray

def base64Encode (bytes : ByteArray) : String := Id.run do
  let alphabet := base64Alphabet
  let mut text := ""
  let mut index := 0
  while index + 2 < bytes.size do
    let a := (bytes.get! index).toNat
    let b := (bytes.get! (index + 1)).toNat
    let c := (bytes.get! (index + 2)).toNat
    let triple := a * 65536 + b * 256 + c
    text := text.push alphabet[triple / 262144]!
    text := text.push alphabet[(triple / 4096) % 64]!
    text := text.push alphabet[(triple / 64) % 64]!
    text := text.push alphabet[triple % 64]!
    index := index + 3
  let remaining := bytes.size - index
  if remaining == 1 then
    let a := (bytes.get! index).toNat
    text := text.push alphabet[a / 4]!
    text := text.push alphabet[(a % 4) * 16]!
    text := text ++ "=="
  else if remaining == 2 then
    let a := (bytes.get! index).toNat
    let b := (bytes.get! (index + 1)).toNat
    text := text.push alphabet[a / 4]!
    text := text.push alphabet[((a % 4) * 16) + (b / 16)]!
    text := text.push alphabet[(b % 16) * 4]!
    text := text.push '='
  return text

private def base64Value (character : Char) : Option Nat :=
  if character ≥ 'A' && character ≤ 'Z' then some (character.toNat - 65)
  else if character ≥ 'a' && character ≤ 'z' then some (character.toNat - 97 + 26)
  else if character ≥ '0' && character ≤ '9' then some (character.toNat - 48 + 52)
  else if character == '+' then some 62
  else if character == '/' then some 63
  else none

/-- Strict base64: exact padding, no whitespace, and no alternative alphabet.
The Convex sync timestamp is compared by re-encoding it, so a lenient decoder
would let a non-canonical timestamp through. -/
def base64Decode (text : String) : Except String ByteArray := Id.run do
  let characters := text.toList.toArray
  if characters.size == 0 || characters.size % 4 != 0 then
    return .error "base64 length must be a positive multiple of four"
  let mut bytes := ByteArray.empty
  let mut index := 0
  while index < characters.size do
    let isLastGroup := index + 4 == characters.size
    let mut values : Array Nat := #[]
    let mut padding := 0
    let mut offset := 0
    while offset < 4 do
      let character := characters[index + offset]!
      if character == '=' then
        if !isLastGroup || offset < 2 then
          return .error "base64 padding is misplaced"
        padding := padding + 1
        values := values.push 0
      else if padding > 0 then
        return .error "base64 padding is misplaced"
      else
        match base64Value character with
        | none => return .error "base64 contains an invalid character"
        | some value => values := values.push value
      offset := offset + 1
    let triple := values[0]! * 262144 + values[1]! * 4096 + values[2]! * 64 + values[3]!
    bytes := bytes.push (UInt8.ofNat (triple / 65536))
    if padding < 2 then
      bytes := bytes.push (UInt8.ofNat ((triple / 256) % 256))
    if padding < 1 then
      bytes := bytes.push (UInt8.ofNat (triple % 256))
    index := index + 4
  return .ok bytes

private def hexDigits : Array Char := "0123456789abcdef".toList.toArray

def toHex (bytes : ByteArray) : String := Id.run do
  let digits := hexDigits
  let mut text := ""
  let mut index := 0
  while index < bytes.size do
    let byte := (bytes.get! index).toNat
    text := text.push digits[byte / 16]!
    text := text.push digits[byte % 16]!
    index := index + 1
  return text

def ofString (text : String) : ByteArray := text.toUTF8

end Convex.Bytes
