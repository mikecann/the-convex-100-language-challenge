/-
Convex failures are kept apart from Lean's `IO.Error` because the adapter has
to report which kind occurred. Flattening a function error into a transport
error, or either one into a successful value, would hide exactly the drift the
conformance suite is looking for.
-/

import Convex.Json

namespace Convex

open Lean (Json)

inductive ConvexError where
  /-- The Convex function itself threw. `data` carries a `ConvexError` payload
  such as `{ code, message }` when the deployment supplied one. -/
  | function (message : String) (data : Option Json) (logs : Array String)
  /-- The peer spoke HTTP, JSON, or the sync profile incorrectly. -/
  | protocol (message : String)
  /-- The socket, TLS session, or a deadline failed. -/
  | transport (message : String)
  /-- The client or subscription was already closed. -/
  | closed (message : String)
  deriving Inhabited

namespace ConvexError

def name : ConvexError → String
  | .function .. => "FunctionError"
  | .protocol _ => "ProtocolError"
  | .transport _ => "TransportError"
  | .closed _ => "ClosedError"

def message : ConvexError → String
  | .function message _ _ => message
  | .protocol message => message
  | .transport message => message
  | .closed message => message

def data : ConvexError → Option Json
  | .function _ data _ => data
  | _ => none

def logs : ConvexError → Array String
  | .function _ _ logs => logs
  | _ => #[]

end ConvexError

instance : ToString ConvexError where
  toString error := s!"{error.name}: {error.message}"

/-- The client's working monad. Lifting plain `IO` into it is automatic, so
foreign calls stay readable; `ConvexM.attempt` is what turns an unexpected
`IO.Error` into a structured transport failure. -/
abbrev ConvexM := ExceptT ConvexError IO

namespace ConvexM

private def ioAttempt {α : Type} (action : IO α) : IO (Except IO.Error α) := do
  try
    let value ← action
    pure (Except.ok value)
  catch problem =>
    pure (Except.error problem)

/-- Run an `IO` action, converting a raw runtime failure into a Convex
transport error tagged with what the client was attempting. -/
def attempt {α : Type} (context : String) (action : IO α) : ConvexM α := do
  match ← ioAttempt action with
  | .ok value => pure value
  | .error problem => throw (ConvexError.transport s!"{context}: {problem}")

/-- Recover from a Convex failure without unwinding the caller. -/
def catchError {α : Type} (action : ConvexM α) (handler : ConvexError → ConvexM α) :
    ConvexM α := do
  try
    action
  catch problem =>
    handler problem

/-- Best-effort cleanup: a close that itself fails must not replace the
original failure a caller is already reporting. -/
def ignoreFailure (action : ConvexM Unit) : ConvexM Unit :=
  catchError action fun _ => pure ()

def orThrowIO {α : Type} (action : ConvexM α) : IO α := do
  match ← action.run with
  | .ok value => pure value
  | .error problem => throw (IO.userError (toString problem))

end ConvexM

def liftExcept {α : Type} (context : String) : Except String α → ConvexM α
  | .ok value => pure value
  | .error problem => throw (.protocol s!"{context}: {problem}")

end Convex
