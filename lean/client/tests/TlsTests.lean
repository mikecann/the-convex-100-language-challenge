/-
TLS verification.

A handshake that merely completes proves nothing, so all three cases here run
against a real OpenSSL server presenting a real chain: one that should be
trusted, one signed by a CA the client was not given, and one whose identity
does not match the host that was asked for.

The certificates are generated in the Docker build stage and passed in through
the environment; nothing here reaches the network.
-/

import Tests.Support
import Tests.Fixture

namespace Tests.TlsTests

open Convex

def requiredPath (name : String) : IO String := do
  match ← IO.getEnv name with
  | some value => pure value
  | none => failure s!"{name} is required to run the TLS tests"

def probe (endpoint : Endpoint) (tls : TlsOptions) : ConvexM HttpResponse := do
  let deadline := (← Live.nowMs) + 10000
  Http.request endpoint tls "POST" #[("Content-Type", "application/json")] "{}".toUTF8 deadline {}

def runTls (runner : Runner) : IO Unit := do
  let authority ← requiredPath "CONVEX_TEST_CA"
  let certificate ← requiredPath "CONVEX_TEST_CERT"
  let key ← requiredPath "CONVEX_TEST_KEY"
  let otherCertificate ← requiredPath "CONVEX_TEST_OTHER_CERT"
  let otherKey ← requiredPath "CONVEX_TEST_OTHER_KEY"

  runner.test "tls/trusted-chain-and-matching-name" do
    let fixture ← startFixture "tls-echo" #[certificate, key]
    let endpoint : Endpoint :=
      { secure := true, host := "localhost", port := fixture.port, path := "/api/query" }
    let response ← expectOk "request" (probe endpoint { caFile := authority })
    expectEq "status" response.status 200
    expectEq "fixture exit" (← fixture.finish) (0 : UInt32)

  runner.test "tls/untrusted-authority-is-refused" do
    let fixture ← startFixture "tls-echo" #[certificate, key]
    let endpoint : Endpoint :=
      { secure := true, host := "localhost", port := fixture.port, path := "/api/query" }
    -- No CA file, so the container's trust store is used and the fixture's
    -- private authority is not in it.
    let problem ← expectFailure "request" "TLS" (probe endpoint {})
    expect "reported as transport" (problem.name == "TransportError")
    fixture.stop

  runner.test "tls/name-mismatch-is-refused" do
    let fixture ← startFixture "tls-echo" #[otherCertificate, otherKey]
    let endpoint : Endpoint :=
      { secure := true, host := "localhost", port := fixture.port, path := "/api/query" }
    -- The chain validates, but the certificate is for a different name, so
    -- verification still has to fail.
    let problem ← expectFailure "request" "TLS" (probe endpoint { caFile := authority })
    expect "reported as transport" (problem.name == "TransportError")
    fixture.stop

def tlsMain : IO UInt32 := do
  let runner ← Runner.new "tls"
  runTls runner
  runner.finish

end Tests.TlsTests

def main : IO UInt32 := Tests.TlsTests.tlsMain
