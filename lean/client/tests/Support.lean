/-
Shared plumbing for the language-local tests.

Fixtures run as a separate process so a scripted peer can misbehave while the
real client sits in its ordinary blocking call. The fixture prints the port it
bound and a line for every protocol fact it observed, and it advances only when
the test writes `step`, so no test depends on a sleep to be deterministic.
-/

import Convex

namespace Tests

open Convex

def failure {α : Type} (message : String) : IO α := throw (IO.userError message)

/-- Spelled out rather than assumed, so these tests do not depend on which
`Except` helpers a given toolchain happens to ship. -/
def isErr {ε α : Type} : Except ε α → Bool
  | .error _ => true
  | .ok _ => false

def isOkay {ε α : Type} (result : Except ε α) : Bool := !isErr result

def expect (label : String) (condition : Bool) : IO Unit := do
  if !condition then
    failure s!"{label}"

def expectEq [BEq α] [ToString α] (label : String) (actual expected : α) : IO Unit := do
  if actual != expected then
    failure s!"{label}: expected {expected}, got {actual}"

def expectContains (label : String) (haystack needle : String) : IO Unit := do
  if !(Bytes.findSub? haystack.toUTF8 needle.toUTF8).isSome then
    failure s!"{label}: {haystack} did not contain {needle}"

/-- Run a Convex action and require it to fail with a message that mentions
`needle`. A test that merely proves "something went wrong" would pass even when
the client reported the wrong kind of failure. -/
def expectFailure {α : Type} (label : String) (needle : String) (action : ConvexM α) :
    IO ConvexError := do
  match ← action.run with
  | .ok _ => failure s!"{label}: expected a failure mentioning {needle}"
  | .error problem =>
      expectContains s!"{label} message" (toString problem) needle
      pure problem

def expectOk {α : Type} (label : String) (action : ConvexM α) : IO α := do
  match ← action.run with
  | .ok value => pure value
  | .error problem => failure s!"{label}: {problem}"

structure Runner where
  failures : IO.Ref Nat
  name : String

def Runner.new (name : String) : IO Runner := do
  pure { failures := ← IO.mkRef 0, name }

def Runner.test (runner : Runner) (label : String) (action : IO Unit) : IO Unit := do
  let stdout ← IO.getStdout
  try
    action
    stdout.putStr s!"PASS {runner.name}/{label}\n"
  catch problem =>
    runner.failures.modify (· + 1)
    stdout.putStr s!"FAIL {runner.name}/{label}: {problem}\n"
  stdout.flush

def Runner.finish (runner : Runner) : IO UInt32 := do
  let failed ← runner.failures.get
  let stdout ← IO.getStdout
  if failed == 0 then
    stdout.putStr s!"PASS {runner.name}\n"
    stdout.flush
    pure 0
  else
    stdout.putStr s!"FAIL {runner.name}: {failed} failing test(s)\n"
    stdout.flush
    pure 1

/-! ### Fixture processes -/

structure Fixture where
  child : IO.Process.Child { stdin := .piped, stdout := .piped, stderr := .inherit }
  port : UInt32

def fixtureBinary : IO String := do
  match ← IO.getEnv "CONVEX_FIXTURE_BIN" with
  | some path => pure path
  | none => failure "CONVEX_FIXTURE_BIN is required to run the fixture tests"

/-- Start a scenario and wait for the port it bound. The fixture chooses the
port so parallel test executables never collide. -/
def startFixture (scenario : String) (extra : Array String := #[]) : IO Fixture := do
  let binary ← fixtureBinary
  let child ← IO.Process.spawn {
    cmd := binary
    args := #[scenario] ++ extra
    stdin := .piped
    stdout := .piped
    stderr := .inherit }
  let line ← child.stdout.getLine
  let trimmed := line.trim
  if !trimmed.startsWith "port " then
    failure s!"fixture {scenario} did not announce a port, got: {trimmed}"
  match (trimmed.drop 5).toNat? with
  | none => failure s!"fixture {scenario} announced an unusable port: {trimmed}"
  | some port => pure { child, port := UInt32.ofNat port }

/-- Let the scenario take its next scripted action. -/
def Fixture.step (fixture : Fixture) : IO Unit := do
  fixture.child.stdin.putStr "step\n"
  fixture.child.stdin.flush

def Fixture.note (fixture : Fixture) : IO String := do
  pure (← fixture.child.stdout.getLine).trim

/-- Require the fixture's next observation to be exactly this line. The
scenarios report what they actually saw on the wire, so this is how a test
proves the client sent the right thing. -/
def Fixture.expectNote (fixture : Fixture) (label : String) (expected : String) : IO Unit := do
  let note ← fixture.note
  if note != expected then
    failure s!"{label}: expected fixture note {expected}, got {note}"

/-- Like `expectNote`, but only pins the stable part of a line. Used where the
tail carries a message the client composed. -/
def Fixture.expectNotePrefix (fixture : Fixture) (label : String) (expected : String) :
    IO Unit := do
  let note ← fixture.note
  if !note.startsWith expected then
    failure s!"{label}: expected a fixture note starting with {expected}, got {note}"

def Fixture.finish (fixture : Fixture) : IO UInt32 := do
  fixture.child.stdin.flush
  fixture.child.wait

def Fixture.stop (fixture : Fixture) : IO Unit := do
  try
    fixture.child.kill
  catch _ =>
    pure ()
  let _ ← fixture.child.wait

def Fixture.endpoint (fixture : Fixture) (path : String) (secure : Bool := false) : Endpoint :=
  { secure, host := "127.0.0.1", port := fixture.port, path }

def Fixture.url (fixture : Fixture) : String := s!"http://127.0.0.1:{fixture.port}"

def nowMs : IO UInt64 := Ffi.nowMs

/-- Build a large filler string by doubling. Repeated appends or a character
list of the same length would dominate a test's runtime and allocation for no
extra coverage. -/
def filler (atLeast : Nat) (unit : Char := 'x') : String := Id.run do
  let mut text := String.mk (List.replicate 64 unit)
  while text.length < atLeast do
    text := text ++ text
  return text

/-- Assert that an operation finished inside its own deadline rather than
merely finishing. This is what makes the dribble and stall tests meaningful. -/
def expectWithin {α : Type} (label : String) (budgetMs : UInt64) (action : IO α) : IO α := do
  let started ← nowMs
  let value ← action
  let elapsed := (← nowMs) - started
  if elapsed > budgetMs then
    failure s!"{label}: took {elapsed}ms, beyond the {budgetMs}ms budget"
  pure value

end Tests
