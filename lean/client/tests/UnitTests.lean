/-
Pure tests for the pieces that decide whether hostile input is refused: the
byte codecs, the JSON admission bounds, and the sync-profile parser.

These need no socket, so every case here is exact rather than timing dependent.
-/

import Tests.Support
import Tests.Fixture

namespace Tests.UnitTests

open Convex
open Lean (Json)

def zeroTimestampBytes : ByteArray := ByteArray.mk (List.replicate 8 (0 : UInt8)).toArray

def runBytes (runner : Runner) : IO Unit := do
  runner.test "base64/round-trip" do
    let bytes := ByteArray.mk #[(0 : UInt8), 1, 2, 250, 251, 252, 253]
    match Bytes.base64Decode (Bytes.base64Encode bytes) with
    | .error problem => failure s!"decode failed: {problem}"
    | .ok decoded => expect "round-trip" (Bytes.bytesEqual decoded bytes)

  runner.test "base64/zero-timestamp" do
    expectEq "eight zero bytes" (Bytes.base64Encode zeroTimestampBytes) Sync.initialTimestamp

  runner.test "base64/rejects-malformed" do
    expect "misplaced padding" (isErr (Bytes.base64Decode "A=AA"))
    expect "bad length" (isErr (Bytes.base64Decode "AAA"))
    expect "invalid character" (isErr (Bytes.base64Decode "AA*A"))
    expect "empty input" (isErr (Bytes.base64Decode ""))

  runner.test "utf8/decodes-multibyte" do
    match Bytes.utf8Decode "aé世🌍".toUTF8 with
    | .error problem => failure s!"decode failed: {problem}"
    | .ok text => expectEq "text" text "aé世🌍"

  runner.test "utf8/suspends-mid-character" do
    -- 世 is three bytes. Feeding a prefix must not produce a character early
    -- and must not lose the partial state.
    let bytes := "世".toUTF8
    match Bytes.utf8Feed Bytes.Utf8State.empty (bytes.extract 0 1) with
    | .error problem => failure s!"first byte rejected: {problem}"
    | .ok (text, state) => do
        expectEq "nothing decoded yet" text ""
        expect "state is suspended" (!state.isComplete)
        match Bytes.utf8Feed state (bytes.extract 1 3) with
        | .error problem => failure s!"remainder rejected: {problem}"
        | .ok (rest, final) => do
            expectEq "decoded" rest "世"
            expect "state is complete" final.isComplete

  runner.test "utf8/rejects-overlong-and-surrogates" do
    expect "overlong" (isErr (Bytes.utf8Decode (ByteArray.mk #[(0xC0 : UInt8), 0x80])))
    expect "surrogate" (isErr (Bytes.utf8Decode (ByteArray.mk #[(0xED : UInt8), 0xA0, 0x80])))
    expect "stray continuation" (isErr (Bytes.utf8Decode (ByteArray.mk #[(0x80 : UInt8)])))
    expect "truncated" (isErr (Bytes.utf8Decode (ByteArray.mk #[(0xE4 : UInt8), 0xB8])))

def runJson (runner : Runner) : IO Unit := do
  runner.test "json/accepts-integral-decimals" do
    match parseJsonString "{\"count\":1.0}" with
    | .error problem => failure s!"parse failed: {problem}"
    | .ok value =>
        match jsonObjVal? value "count" >>= jsonIntegral? with
        | some number => expectEq "count" number (1 : Int)
        | none => failure "1.0 was not treated as whole"

  runner.test "json/rejects-fractional" do
    match parseJsonString "{\"count\":1.5}" with
    | .error problem => failure s!"parse failed: {problem}"
    | .ok value =>
        expect "fractional rejected" (jsonObjVal? value "count" >>= jsonIntegral?).isNone

  runner.test "json/rejects-quoted-count" do
    match parseJsonString "{\"count\":\"1\"}" with
    | .error problem => failure s!"parse failed: {problem}"
    | .ok value =>
        expect "quoted rejected" (jsonObjVal? value "count" >>= jsonIntegral?).isNone

  runner.test "json/bounds-depth" do
    let deep := String.mk (List.replicate 200 '[') ++ String.mk (List.replicate 200 ']')
    expect "deep nesting rejected" (isErr (parseJsonString deep { maxDepth := 128 }))

  runner.test "json/bounds-size" do
    expect "oversize rejected" (isErr (parseJsonString "{\"a\":1}" { maxBytes := 3 }))

  runner.test "json/bounds-nodes" do
    let dense := "[" ++ String.intercalate "," (List.replicate 100 "1") ++ "]"
    expect "dense input rejected" (isErr (parseJsonString dense { maxNodes := 10 }))

  runner.test "json/log-lines-must-be-strings" do
    match parseJsonString "{\"logLines\":[1]}" with
    | .error problem => failure s!"parse failed: {problem}"
    | .ok value => expect "non-string log rejected" (isErr (jsonStringArray value "logLines"))

def runEndpoints (runner : Runner) : IO Unit := do
  runner.test "endpoint/https-default-port" do
    match parseEndpoint "https://example.convex.cloud" "/api/sync" with
    | .error problem => failure s!"parse failed: {problem}"
    | .ok endpoint => do
        expect "secure" endpoint.secure
        expectEq "host" endpoint.host "example.convex.cloud"
        expectEq "port" endpoint.port (443 : UInt32)
        expectEq "path" endpoint.path "/api/sync"

  runner.test "endpoint/explicit-port-and-prefix" do
    match parseEndpoint "http://backend:3210/base/" "/api/query" with
    | .error problem => failure s!"parse failed: {problem}"
    | .ok endpoint => do
        expect "not secure" (!endpoint.secure)
        expectEq "port" endpoint.port (3210 : UInt32)
        expectEq "path" endpoint.path "/base/api/query"

  runner.test "endpoint/rejects-other-schemes" do
    expect "ws rejected" (isErr (parseEndpoint "ws://example" "/api/sync"))
    expect "empty host rejected" (isErr (parseEndpoint "https://" "/api/sync"))

private def parsedTransition (text : String) : IO Sync.Transition := do
  match parseJsonString text with
  | .error problem => failure s!"parse failed: {problem}"
  | .ok value =>
      match Sync.parseTransition value with
      | .error problem => failure s!"transition parse failed: {problem}"
      | .ok transition => pure transition

def runSync (runner : Runner) : IO Unit := do
  runner.test "sync/timestamp-is-little-endian" do
    match Sync.decodeTimestamp (Tests.Fixture.timestampFor 258) with
    | .error problem => failure s!"decode failed: {problem}"
    | .ok value => expectEq "value" value 258

  runner.test "sync/timestamp-rejects-wrong-width" do
    expect "short timestamp rejected" (isErr (Sync.decodeTimestamp "AAAA"))

  runner.test "sync/state-version-requires-counters" do
    match parseJsonString "{\"querySet\":0,\"identity\":0}" with
    | .error problem => failure s!"parse failed: {problem}"
    | .ok value =>
        expect "missing ts rejected" (isErr (Sync.parseStateVersion "startVersion" value))

  runner.test "sync/transition-must-start-where-we-are" do
    let transition ← parsedTransition
      (Tests.Fixture.transitionMessage 1 5 1 6 (Tests.Fixture.queryUpdated 0 1))
    expect "mismatch rejected"
      (isErr (Sync.validateTransition transition Sync.zeroVersion 1 #[0]))

  runner.test "sync/transition-cannot-exceed-written-query-set" do
    let transition ← parsedTransition
      (Tests.Fixture.transitionMessage 0 0 4 1 (Tests.Fixture.queryUpdated 0 1))
    expect "unwritten query-set version rejected"
      (isErr (Sync.validateTransition transition Sync.zeroVersion 1 #[0]))

  runner.test "sync/transition-rejects-inactive-query" do
    let transition ← parsedTransition
      (Tests.Fixture.transitionMessage 0 0 1 1 (Tests.Fixture.queryUpdated 7 1))
    expect "inactive queryId rejected"
      (isErr (Sync.validateTransition transition Sync.zeroVersion 1 #[0]))

  runner.test "sync/accepts-a-well-formed-transition" do
    let transition ← parsedTransition
      (Tests.Fixture.transitionMessage 0 0 1 1 (Tests.Fixture.queryUpdated 0 3))
    expect "accepted" (isOkay (Sync.validateTransition transition Sync.zeroVersion 1 #[0]))
    expectEq "one change" transition.changes.size 1

  runner.test "sync/coalesces-repeated-query" do
    let changes : Array Sync.Change :=
      #[.updated 0 (jsonOfNat 1) #[], .updated 0 (jsonOfNat 2) #[], .updated 1 (jsonOfNat 3) #[]]
    let coalesced := Sync.coalesce changes
    expectEq "one entry per query" coalesced.size 2
    match coalesced[0]! with
    | .updated _ value _ => expectEq "final value wins" (renderJson value) "2"
    | _ => failure "expected an update"

  runner.test "sync/connect-message-omits-absent-timestamp" do
    let without := renderJson (Sync.connectMessage "abc" 0 "InitialConnect" none)
    expect "no maxObservedTimestamp"
      (Bytes.findSub? without.toUTF8 "maxObservedTimestamp".toUTF8).isNone
    let carried := renderJson (Sync.connectMessage "abc" 2 "DebugDisconnect" (some "AAAAAAAAAAA="))
    expect "carries maxObservedTimestamp"
      (Bytes.findSub? carried.toUTF8 "maxObservedTimestamp".toUTF8).isSome
    expect "carries connectionCount"
      (Bytes.findSub? carried.toUTF8 "\"connectionCount\":2".toUTF8).isSome

  runner.test "sync/add-modification-wraps-args-in-an-array" do
    let arguments := jsonObject [("room", Json.str "r")]
    let rendered := renderJson (Sync.addModification 4 "demo:state" arguments)
    expect "queryId" (Bytes.findSub? rendered.toUTF8 "\"queryId\":4".toUTF8).isSome
    expect "udfPath" (Bytes.findSub? rendered.toUTF8 "\"udfPath\":\"demo:state\"".toUTF8).isSome
    expect "args array" (Bytes.findSub? rendered.toUTF8 "\"args\":[{".toUTF8).isSome

def unitMain : IO UInt32 := do
  let runner ← Runner.new "unit"
  runBytes runner
  runJson runner
  runEndpoints runner
  runSync runner
  runner.finish

end Tests.UnitTests

def main : IO UInt32 := Tests.UnitTests.unitMain
