/-
The canonical example, exercised as the exact binary the runtime image ships.

There is deliberately no second, test-only copy of the example: this runs
`examples/basics/Main.lean` as compiled, against a scripted backend, and
compares its stdout with the shared transcript character for character.

The second case is the integral-number regression. Convex may send a whole
count as `0.0`, which must be accepted, while `0.5` must be refused rather
than rounded.
-/

import Tests.Support
import Tests.Fixture

namespace Tests.ExampleTests

open Convex

def exampleBinary : IO String := do
  match ← IO.getEnv "CONVEX_EXAMPLE_BIN" with
  | some path => pure path
  | none => failure "CONVEX_EXAMPLE_BIN is required to run the example tests"

def expectedTranscript : String :=
  "current count: 0\n" ++
  "live initial count: 0\n" ++
  "mutation applied: true\n" ++
  "mutation count: 1\n" ++
  "live updated count: 1\n" ++
  "verified count: 0 -> 1\n"

structure ExampleRun where
  exitCode : UInt32
  stdout : String
  stderr : String

def runExample (fixture : Fixture) : IO ExampleRun := do
  let binary ← exampleBinary
  let child ← IO.Process.spawn {
    cmd := binary
    args := #["fixture"]
    env := #[("CONVEX_URL", some fixture.url)]
    stdin := .null
    stdout := .piped
    stderr := .piped }
  let stdout ← child.stdout.readToEnd
  let stderr ← child.stderr.readToEnd
  let exitCode ← child.wait
  pure { exitCode, stdout, stderr }

def runExamples (runner : Runner) : IO Unit := do
  runner.test "example/prints-the-shared-transcript-exactly" do
    let fixture ← startFixture "example-backend"
    -- The scripted backend serves the query, the Live hydration, the mutation,
    -- and the resulting reactive update, in the order the example makes them.
    let outcome ← runExample fixture
    if outcome.exitCode != 0 then
      failure s!"example exited {outcome.exitCode}: {outcome.stderr}"
    -- Character for character, because the shared verifier compares stdout
    -- against one universal transcript for every language.
    expectEq "stdout" outcome.stdout expectedTranscript
    fixture.expectNote "connect" "note Connect connectionCount=0 lastCloseReason=InitialConnect"
    fixture.expectNote "add" "note ModifyQuerySet Add:0:demo:state"
    fixture.expectNote "journey" "note example journey served"
    fixture.step
    expectEq "fixture exit" (← fixture.finish) (0 : UInt32)

  runner.test "example/accepts-integral-decimals-and-refuses-fractions" do
    -- The backend serves `count: 0.5`. A client that rounded, truncated, or
    -- reinterpreted it would print a transcript line and continue.
    let fixture ← startFixture "example-fractional"
    let outcome ← runExample fixture
    expect "example failed" (outcome.exitCode != 0)
    expectEq "nothing was printed" outcome.stdout ""
    expectContains "reported on stderr" outcome.stderr "whole count"
    fixture.expectNote "fractional" "note fractional count served"
    expectEq "fixture exit" (← fixture.finish) (0 : UInt32)

  runner.test "example/requires-a-deployment-url" do
    let binary ← exampleBinary
    let child ← IO.Process.spawn {
      cmd := binary
      args := #["fixture"]
      env := #[("CONVEX_URL", none)]
      stdin := .null
      stdout := .piped
      stderr := .piped }
    let stdout ← child.stdout.readToEnd
    let stderr ← child.stderr.readToEnd
    let exitCode ← child.wait
    expect "example failed" (exitCode != 0)
    expectEq "nothing was printed" stdout ""
    expectContains "reported on stderr" stderr "CONVEX_URL is required"

def exampleMain : IO UInt32 := do
  let runner ← Runner.new "example"
  runExamples runner
  runner.finish

end Tests.ExampleTests

def main : IO UInt32 := Tests.ExampleTests.exampleMain
