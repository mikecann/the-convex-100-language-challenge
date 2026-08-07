/-
The pinned Convex sync profile, expressed as plain Lean values.

This is the wire contract the Live client speaks: what it sends after a
handshake, and what a `Transition` has to look like before any of it becomes
visible to a subscriber. Nothing here touches a socket, so the whole protocol
is testable without one.
-/

import Convex.Json
import Convex.Error

namespace Convex

open Lean (Json)

namespace Sync

/-- Every connection starts from this version, and a server transition must
begin exactly where the client believes it is. -/
def initialTimestamp : String := "AAAAAAAAAAA="

structure StateVersion where
  querySet : Nat
  identity : Nat
  ts : String
  /-- The decoded little-endian value, because ordering the base64 text would
  get rollover wrong. -/
  tsValue : Nat
  deriving Inhabited, Repr, BEq

def zeroVersion : StateVersion :=
  { querySet := 0, identity := 0, ts := initialTimestamp, tsValue := 0 }

/-- Timestamps are eight little-endian bytes in canonical base64. Re-encoding
the decoded bytes rejects a padded or otherwise non-canonical spelling that
would still decode. -/
def decodeTimestamp (text : String) : Except String Nat := do
  if text.length != 12 then
    .error "Live timestamp must encode exactly eight bytes"
  let bytes ← Bytes.base64Decode text
  if bytes.size != 8 then
    .error "Live timestamp must decode to exactly eight bytes"
  if Bytes.base64Encode bytes != text then
    .error "Live timestamp was not canonical base64"
  let mut value := 0
  let mut index := 8
  while index > 0 do
    index := index - 1
    value := value * 256 + (bytes.get! index).toNat
  .ok value

private def counterField (label field : String) (container : Json) : Except String Nat :=
  match jsonObjVal? container field with
  | none => .error s!"{label} omitted integer {field}"
  | some value =>
      match jsonNat? value with
      | some number =>
          if number ≤ 4294967295 then .ok number
          else .error s!"{label} had an out-of-range {field}"
      | none => .error s!"{label} omitted integer {field}"

def parseStateVersion (label : String) (value : Json) : Except String StateVersion := do
  if !jsonIsObj value then
    .error s!"{label} was not an object"
  let querySet ← counterField label "querySet" value
  let identity ← counterField label "identity" value
  match jsonObjVal? value "ts" >>= jsonStr? with
  | none => .error s!"{label} omitted string ts"
  | some ts => do
      let tsValue ← decodeTimestamp ts
      .ok { querySet, identity, ts, tsValue }

inductive Change where
  | updated (queryId : Nat) (value : Json) (logs : Array String)
  | failed (queryId : Nat) (message : String) (data : Option Json) (logs : Array String)
  | removed (queryId : Nat)
  deriving Inhabited

def Change.queryId : Change → Nat
  | .updated id _ _ => id
  | .failed id _ _ _ => id
  | .removed id => id

private def parseChange (value : Json) : Except String Change := do
  if !jsonIsObj value then
    .error "Transition modification was not an object"
  let queryId ←
    match jsonObjVal? value "queryId" >>= jsonNat? with
    | none => .error "Transition modification omitted a whole queryId"
    | some id => .ok id
  match jsonObjVal? value "type" >>= jsonStr? with
  | some "QueryUpdated" => do
      let logs ← jsonStringArray value "logLines"
      match jsonObjVal? value "value" with
      | none => .error "QueryUpdated omitted value"
      | some payload => .ok (.updated queryId payload logs)
  | some "QueryFailed" => do
      let logs ← jsonStringArray value "logLines"
      match jsonObjVal? value "errorMessage" >>= jsonStr? with
      | none => .error "QueryFailed omitted string errorMessage"
      | some message => .ok (.failed queryId message (jsonObjVal? value "errorData") logs)
  | some "QueryRemoved" => .ok (.removed queryId)
  | some other => .error s!"unknown Transition modification: {other}"
  | none => .error "Transition modification omitted type"

structure Transition where
  startVersion : StateVersion
  endVersion : StateVersion
  changes : Array Change
  deriving Inhabited

def parseTransition (message : Json) : Except String Transition := do
  let startValue ← match jsonObjVal? message "startVersion" with
    | none => .error "Transition omitted startVersion"
    | some value => .ok value
  let endValue ← match jsonObjVal? message "endVersion" with
    | none => .error "Transition omitted endVersion"
    | some value => .ok value
  let startVersion ← parseStateVersion "startVersion" startValue
  let endVersion ← parseStateVersion "endVersion" endValue
  match jsonObjVal? message "modifications" >>= jsonArr? with
  | none => .error "Transition omitted modifications"
  | some items => do
      let mut changes : Array Change := #[]
      for item in items do
        changes := changes.push (← parseChange item)
      .ok { startVersion, endVersion, changes }

/-- The transition must move forward on every counter and must not claim a
query-set version this client never wrote. -/
def validateTransition (transition : Transition) (localVersion : StateVersion)
    (querySetVersion : Nat) (activeIds : Array Nat) : Except String Unit := do
  if transition.startVersion != localVersion then
    .error "Transition startVersion did not match local state"
  if transition.endVersion.querySet < transition.startVersion.querySet
      || transition.endVersion.identity < transition.startVersion.identity
      || transition.endVersion.tsValue < transition.startVersion.tsValue then
    .error "Transition endVersion moved backwards"
  if transition.endVersion.querySet > querySetVersion then
    .error "Transition exceeded the locally written query-set version"
  for change in transition.changes do
    match change with
    | .removed _ => pure ()
    | _ =>
        if !activeIds.contains change.queryId then
          .error "Transition updated an inactive queryId"
  .ok ()

/-- A transition describes the resulting query set, so a query that appears
twice keeps only its final modification. -/
def coalesce (changes : Array Change) : Array Change := Id.run do
  let mut result : Array Change := #[]
  for change in changes do
    match result.findIdx? (fun existing => existing.queryId == change.queryId) with
    | some index => result := result.set! index change
    | none => result := result.push change
  return result

def connectMessage (sessionId : String) (connectionCount : Nat) (lastCloseReason : String)
    (maxObservedTimestamp : Option String) : Json :=
  let base : List (String × Json) :=
    [ ("type", Json.str "Connect")
    , ("sessionId", Json.str sessionId)
    , ("connectionCount", jsonOfNat connectionCount)
    , ("lastCloseReason", Json.str lastCloseReason)
    , ("clientTs", jsonOfNat 0) ]
  jsonObject (match maxObservedTimestamp with
    | none => base
    | some ts => base ++ [("maxObservedTimestamp", Json.str ts)])

def addModification (queryId : Nat) (path : String) (args : Json) : Json :=
  jsonObject
    [ ("type", Json.str "Add")
    , ("queryId", jsonOfNat queryId)
    , ("udfPath", Json.str path)
    , ("args", Json.arr #[args]) ]

def removeModification (queryId : Nat) : Json :=
  jsonObject [("type", Json.str "Remove"), ("queryId", jsonOfNat queryId)]

def modifyQuerySetMessage (baseVersion : Nat) (modifications : Array Json) : Json :=
  jsonObject
    [ ("type", Json.str "ModifyQuerySet")
    , ("baseVersion", jsonOfNat baseVersion)
    , ("newVersion", jsonOfNat (baseVersion + 1))
    , ("modifications", Json.arr modifications) ]

end Sync

end Convex
