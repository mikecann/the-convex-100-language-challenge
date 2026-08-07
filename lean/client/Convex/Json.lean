/-
JSON is the one place this client leans on Lean's own library: `Lean.Data.Json`
ships with the toolchain, so no package needs to be fetched to parse a Convex
value. What it does not provide is a way to refuse hostile input before the
parser walks it, which is what the bounds below add.
-/

import Lean.Data.Json
import Convex.Bytes

namespace Convex

open Lean (Json JsonNumber)

/-- Limits applied before `Lean.Json.parse` sees the text. A Convex response,
a Live message, and an adapter command all arrive from a socket, so each one
is checked against an explicit budget rather than trusted to be small. -/
structure JsonLimits where
  maxBytes : Nat := 2 * 1024 * 1024
  maxDepth : Nat := 128
  maxNodes : Nat := 65536
  deriving Inhabited

/-- Walk the raw bytes once, tracking nesting depth and structural node count
while skipping string contents. Deeply nested or extremely dense input is
rejected here instead of being handed to the parser. -/
def scanJsonBounds (bytes : ByteArray) (limits : JsonLimits) : Except String Unit := Id.run do
  if bytes.size > limits.maxBytes then
    return .error s!"JSON input exceeded {limits.maxBytes} bytes"
  let mut index := 0
  let mut depth := 0
  let mut nodes := 0
  let mut inString := false
  let mut escaped := false
  while index < bytes.size do
    let byte := bytes.get! index
    index := index + 1
    if inString then
      if escaped then
        escaped := false
      else if byte == 0x5C then
        escaped := true
      else if byte == 0x22 then
        inString := false
    else if byte == 0x22 then
      inString := true
      nodes := nodes + 1
    else if byte == 0x7B || byte == 0x5B then
      depth := depth + 1
      nodes := nodes + 1
      if depth > limits.maxDepth then
        return .error s!"JSON nesting exceeded {limits.maxDepth} levels"
    else if byte == 0x7D || byte == 0x5D then
      if depth == 0 then
        return .error "JSON closed a container that was never opened"
      depth := depth - 1
    else if byte == 0x2C || byte == 0x3A then
      nodes := nodes + 1
    if nodes > limits.maxNodes then
      return .error s!"JSON exceeded {limits.maxNodes} structural nodes"
  if inString then
    return .error "JSON ended inside a string"
  if depth != 0 then
    return .error "JSON ended with unclosed containers"
  return .ok ()

def parseJsonString (text : String) (limits : JsonLimits := {}) : Except String Json := do
  scanJsonBounds text.toUTF8 limits
  Json.parse text

def parseJsonBytes (bytes : ByteArray) (limits : JsonLimits := {}) : Except String Json := do
  scanJsonBounds bytes limits
  let text ← Convex.Bytes.utf8Decode bytes
  Json.parse text

def renderJson (value : Json) : String := value.compress

def renderJsonBytes (value : Json) : ByteArray := value.compress.toUTF8

def jsonObjVal? (value : Json) (key : String) : Option Json :=
  match value.getObjVal? key with
  | .ok found => some found
  | .error _ => none

def jsonHasKey (value : Json) (key : String) : Bool := (jsonObjVal? value key).isSome

def jsonStr? : Json → Option String
  | .str text => some text
  | _ => none

def jsonBool? : Json → Option Bool
  | .bool value => some value
  | _ => none

def jsonArr? : Json → Option (Array Json)
  | .arr items => some items
  | _ => none

def jsonIsObj : Json → Bool
  | .obj _ => true
  | _ => false

def jsonIsNull : Json → Bool
  | .null => true
  | _ => false

private def powTen : Nat → Nat
  | 0 => 1
  | n + 1 => 10 * powTen n

/-- Convex sends JSON numbers, and an integral value may legitimately arrive as
`1.0`. This accepts anything mathematically integral and rejects a fractional
value rather than silently truncating it. -/
def jsonIntegral? : Json → Option Int
  | .num number =>
      if number.exponent == 0 then
        some number.mantissa
      else
        let scale : Int := Int.ofNat (powTen number.exponent)
        if number.mantissa % scale == 0 then some (number.mantissa / scale) else none
  | _ => none

def jsonNat? (value : Json) : Option Nat :=
  match jsonIntegral? value with
  | some integer => if integer ≥ 0 then some integer.toNat else none
  | none => none

def jsonOfNat (value : Nat) : Json := Json.num { mantissa := Int.ofNat value, exponent := 0 }

def jsonOfInt (value : Int) : Json := Json.num { mantissa := value, exponent := 0 }

/-- `logLines` is optional but, when present, must be an array of strings.
A malformed one is protocol drift, not an empty log. -/
def jsonStringArray (container : Json) (key : String) : Except String (Array String) :=
  match jsonObjVal? container key with
  | none => .ok #[]
  | some (.arr items) => Id.run do
      let mut lines : Array String := #[]
      for item in items do
        match jsonStr? item with
        | some line => lines := lines.push line
        | none => return .error s!"{key} must contain only strings"
      return .ok lines
  | some _ => .error s!"{key} must be an array of strings"

def jsonObject (fields : List (String × Json)) : Json := Json.mkObj fields

def jsonOfStrings (values : Array String) : Json := Json.arr (values.map Json.str)

end Convex
