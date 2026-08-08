/-
The canonical Convex-from-Lean example.

It follows one shared counter from `0` to `1`: read it over HTTP, start Live
before changing anything, apply one idempotent mutation, and then let the
reactive subscription -- not a second query -- report the new value.
-/

import Convex

open Convex
open Lean (Json)

/-- Final images write to a pipe during verification, so each checked step is
flushed as it is proven rather than appearing all at once at exit. -/
def emit (line : String) : IO Unit := do
  let stdout ← IO.getStdout
  stdout.putStr (line ++ "\n")
  stdout.flush

/-- Convex values are JSON, so the demonstrated result has to be narrowed to
the whole number this program's output contract needs. Convex may legitimately
send an integral value as `0.0`, which is accepted; a fractional, quoted, or
out-of-range count is rejected rather than rounded. -/
def wholeCount (operation : String) (value : Json) : ConvexM Int := do
  match jsonObjVal? value "count" with
  | none => throw (ConvexError.protocol s!"{operation} did not contain a count")
  | some count =>
      match jsonIntegral? count with
      | none => throw (ConvexError.protocol s!"{operation} did not contain a whole count")
      | some number =>
          if number < -9223372036854775808 || number > 9223372036854775807 then
            throw (ConvexError.protocol s!"{operation} returned an out-of-range count")
          else
            pure number

/-- A fresh random identifier. This is the mutation's idempotency key, so
generating it in the client -- rather than delegating to another runtime -- is
part of what the example demonstrates. -/
def freshRunId : ConvexM String := do
  let bytes ← ConvexM.attempt "generating a run id" (Ffi.randomBytes 16)
  pure (Bytes.toHex bytes)

/-- Live delivers either a value or a structured failure. The example insists
on a value, and treats the absence of one within the deadline as a failure of
the demonstration rather than something to retry quietly. -/
def awaitValue (client : Client) (subscription : Subscription) (label : String) :
    ConvexM Json := do
  match ← client.nextUpdate subscription 10000 with
  | none => throw (ConvexError.transport s!"{label} timed out")
  | some update =>
      match update.error with
      | some problem => throw problem
      | none =>
          match update.value with
          | none => throw (ConvexError.protocol s!"{label} carried neither a value nor an error")
          | some value => pure value

def run (arguments : List String) : ConvexM Unit := do
  -- Point both HTTPS and WSS at the same approved Convex deployment. The
  -- verifier supplies a unique room argument so concurrent runs never share
  -- state; someone running the image by hand gets a safe default.
  let deployment ← match ← IO.getEnv "CONVEX_URL" with
    | some url => pure url
    | none => throw (ConvexError.protocol "CONVEX_URL is required")
  let room := arguments.headD "lean-example"

  -- One client owns the HTTP endpoint and the single-owner Live loop.
  let client ← Client.new deployment { clientVersion := "lean-0.1.0" }
  let body : ConvexM Unit := do
    -- Read the current state through Convex's documented JSON HTTP endpoint.
    let current ← client.query "demo:state" (jsonObject [("room", Json.str room)])
    let currentCount ← wholeCount "current query" current.value
    emit s!"current count: {currentCount}"

    -- Start Live before the mutation, so the reactive journey cannot miss the
    -- write it is supposed to observe.
    let subscription ← client.subscribe "demo:state" (jsonObject [("room", Json.str room)])
    let initialValue ← awaitValue client subscription "initial Live value"
    let initialCount ← wholeCount "initial Live value" initialValue
    if initialCount != currentCount then
      throw (ConvexError.protocol "initial Live value disagreed with HTTP")
    emit s!"live initial count: {initialCount}"

    -- runId is the idempotency key for this logical write: replaying it
    -- returns the previous result instead of incrementing a second time.
    let runId ← freshRunId
    let changed ← client.mutation "demo:increment"
      (jsonObject
        [ ("room", Json.str room)
        , ("language", Json.str "lean")
        , ("runId", Json.str runId) ])
    match jsonObjVal? changed.value "applied" >>= jsonBool? with
    | some true => pure ()
    | _ => throw (ConvexError.protocol "mutation was not applied")
    emit "mutation applied: true"
    let mutationState ← match jsonObjVal? changed.value "state" with
      | some state => pure state
      | none => throw (ConvexError.protocol "mutation omitted the resulting state")
    let mutationCount ← wholeCount "mutation" mutationState
    if mutationCount != currentCount + 1 then
      throw (ConvexError.protocol "mutation returned an unexpected count")
    emit s!"mutation count: {mutationCount}"

    -- Receive the write reactively rather than issuing a second query.
    let updatedValue ← awaitValue client subscription "updated Live value"
    let updatedCount ← wholeCount "updated Live value" updatedValue
    if updatedCount != mutationCount then
      throw (ConvexError.protocol "Live update disagreed with the mutation")
    emit s!"live updated count: {updatedCount}"

    -- Only printed once HTTP, the mutation result, and Live all agree.
    emit s!"verified count: {currentCount} -> {updatedCount}"

    -- Unsubscribing is an acknowledged, bounded operation on the Live loop.
    client.unsubscribe subscription
  -- Closing always runs (both branches below), so a failure part way through
  -- still retires the socket instead of leaving it to process exit.
  try
    body
    ConvexM.ignoreFailure client.close
  catch problem =>
    ConvexM.ignoreFailure client.close
    throw problem

def main (arguments : List String) : IO UInt32 := do
  match ← (run arguments).run with
  | .ok () => pure 0
  | .error problem =>
      let stderr ← IO.getStderr
      stderr.putStr s!"Lean example failed: {problem}\n"
      stderr.flush
      pure 1
