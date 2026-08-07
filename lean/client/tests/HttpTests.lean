/-
HTTP behaviour against deterministic raw peers.

Each case is something a happy-path test cannot reach: a structured failure
arriving with a non-2xx status, a body that is not an envelope at all, chunked
framing, a declared length beyond the budget, an endless stream, and a peer
that dribbles bytes forever.
-/

import Tests.Support
import Tests.Fixture

namespace Tests.HttpTests

open Convex
open Lean (Json)

def roomArgs : Json := jsonObject [("room", Json.str "fixture")]

def runHttp (runner : Runner) : IO Unit := do
  runner.test "http/structured-error-envelope-on-non-2xx" do
    let fixture ← startFixture "http-error-envelope"
    let client ← expectOk "client" (Client.new fixture.url)
    let problem ← expectFailure "query" "FunctionError" (client.query "demo:state" roomArgs)
    match problem with
    | .function message data logs => do
        expectContains "message" message "ConvexError"
        match data >>= (jsonObjVal? · "code") >>= jsonStr? with
        | some code => expectEq "error code" code "FIXTURE_FAIL"
        | none => failure "structured errorData was lost"
        expect "log lines survived" (logs.size == 1)
    | other => failure s!"expected a function error, got {other.name}"
    expectOk "close" client.close
    expectEq "fixture exit" (← fixture.finish) (0 : UInt32)

  runner.test "http/non-envelope-body-is-protocol-drift" do
    let fixture ← startFixture "http-plain-error"
    let client ← expectOk "client" (Client.new fixture.url)
    let problem ← expectFailure "query" "ProtocolError" (client.query "demo:state" roomArgs)
    -- The status has to survive into the report, otherwise a 503 and a 400
    -- would be indistinguishable to whoever reads the failure.
    expectContains "status in message" problem.message "503"
    expectOk "close" client.close
    expectEq "fixture exit" (← fixture.finish) (0 : UInt32)

  runner.test "http/chunked-response-is-reassembled" do
    let fixture ← startFixture "http-chunked"
    let client ← expectOk "client" (Client.new fixture.url)
    let result ← expectOk "query" (client.query "demo:state" roomArgs)
    match jsonObjVal? result.value "count" >>= jsonIntegral? with
    | some count => expectEq "count" count (7 : Int)
    | none => failure "chunked body did not decode"
    expect "logs survived" (result.logs.size == 1)
    expectOk "close" client.close
    expectEq "fixture exit" (← fixture.finish) (0 : UInt32)

  runner.test "http/declared-length-beyond-budget-is-refused" do
    let fixture ← startFixture "http-oversize"
    let endpoint := fixture.endpoint "/api/query"
    let deadline := (← nowMs) + 5000
    -- The rejection must come from the declared length, so it has to happen
    -- long before a 999 MB body could have been transferred.
    let _ ← expectWithin "oversize rejection" 3000 do
      expectFailure "request" "999999999"
        (Http.request endpoint {} "POST" #[] "{}".toUTF8 deadline { maxBodyBytes := 65536 })
    fixture.step
    expectEq "fixture exit" (← fixture.finish) (0 : UInt32)

  runner.test "http/endless-chunked-body-hits-the-byte-budget" do
    let fixture ← startFixture "http-endless-chunks"
    let endpoint := fixture.endpoint "/api/query"
    let deadline := (← nowMs) + 20000
    let problem ← expectWithin "endless body rejection" 15000 do
      expectFailure "request" "body budget"
        (Http.request endpoint {} "POST" #[] "{}".toUTF8 deadline { maxBodyBytes := 262144 })
    expect "reported as protocol drift" (problem.name == "ProtocolError")
    fixture.stop

  runner.test "http/dribbling-peer-hits-the-absolute-deadline" do
    let fixture ← startFixture "http-dribble"
    let endpoint := fixture.endpoint "/api/query"
    let deadline := (← nowMs) + 1500
    -- The peer keeps making progress, one byte at a time. Only a deadline that
    -- was fixed before the first read can stop this, and it must stop close to
    -- that deadline rather than after the peer gives up.
    let problem ← expectWithin "dribble deadline" 4000 do
      expectFailure "request" "deadline"
        (Http.request endpoint {} "POST" #[] "{}".toUTF8 deadline {})
    expect "reported as transport" (problem.name == "TransportError")
    fixture.stop

def httpMain : IO UInt32 := do
  let runner ← Runner.new "http"
  runHttp runner
  runner.finish

end Tests.HttpTests

def main : IO UInt32 := Tests.HttpTests.httpMain
