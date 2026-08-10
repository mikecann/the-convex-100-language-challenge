<img src="logo.png" alt="Lean logo" width="180">
<!-- Logo source: https://github.com/leanprover/lean4/blob/master/images/lean.png -->

# Lean

[Lean](https://lean-lang.org/) is both an interactive theorem prover and a
[strict, pure functional programming language](https://lean-lang.org/functional_programming_in_lean/Introduction/)
with dependent types. Its functional style has family resemblances to Haskell, OCaml, and F#,
while dependent types let types contain values and computations. Leonardo de Moura
[started the project at Microsoft Research in 2013](https://lean-lang.org/fro/about/), and it is
now developed by the Lean Focused Research Organization. Lean's main niche is formalising
mathematics and verifying software, hardware, and protocols, though Lean 4 can also compile
ordinary programs like this client to native code.

This is an educational, unofficial Convex client. It is not a production SDK and is not intended
for package publication.

## Getting Started

Start with [`examples/basics/Main.lean`](examples/basics/Main.lean). It reads a fresh counter,
subscribes before changing it, makes one idempotent mutation, and receives the new value through
the subscription. From the repository root, run the exact example in Docker with:

```sh
./run verify-example lean
```

Docker supplies the pinned Lean toolchain and the approved test deployment, so you do not need to
install Lean or point the example at your own Convex project.

## Interesting Parts

### React owns the subscription; this client asks you to own it

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function Counter() {
  const room = "lean-readme";
  const state = useQuery(api.demo.state, { room });

  if (state === undefined) return <span>Loading...</span>;
  return <output>{state.count}</output>; // React rerenders when the query changes.
}
```

**Lean**

```lean
def receiveOneState : ConvexM Unit := do
  -- Use the same deployment setting as the canonical Docker example.
  let deployment ← match ← IO.getEnv "CONVEX_URL" with
    | some url =>
        if url.isEmpty then
          throw (ConvexError.protocol "CONVEX_URL must not be empty")
        else
          pure url
    | none => throw (ConvexError.protocol "CONVEX_URL is required")
  let room := "lean-readme"
  let client ← Client.new deployment

  -- subscribe returns a handle. This command-line program owns its lifetime.
  let subscription ←
    client.subscribe "demo:state" (jsonObject [("room", Json.str room)])

  -- nextUpdate drives the Live connection while it waits for one value.
  match ← client.nextUpdate subscription 10000 with
  | none => throw (ConvexError.transport "Live update timed out")
  | some update =>
      match update.error, update.value with
      | some problem, _ => throw problem
      | none, some value => IO.println (renderJson value)
      | none, none => throw (ConvexError.protocol "Live update had no value")

  -- There is no component unmount here, so cleanup is explicit.
  client.unsubscribe subscription
  client.close
```

`useQuery` hides subscription setup and cleanup behind the React component lifecycle. Lean supports
higher-order functions and callbacks, but this particular client deliberately exposes a blocking
`nextUpdate` operation for a command-line program. The [complete example](examples/basics/Main.lean)
also guarantees cleanup when an earlier operation fails.

### Generated TypeScript types become explicit JSON checks

**TypeScript with React**

```tsx
import { useMutation } from "convex/react";
import { api } from "../convex/_generated/api";

export function IncrementButton() {
  const increment = useMutation(api.demo.increment);
  const room = "lean-readme";

  async function handleClick() {
    const runId = crypto.randomUUID();
    const result = await increment({ room, language: "typescript", runId });
    console.log(result.state.count); // The generated API makes state.count a number.
  }

  return <button onClick={handleClick}>Increment</button>;
}
```

**Lean**

```lean
def freshRunId : ConvexM String := do
  -- Generate the same 128-bit idempotency key used by the canonical example.
  let bytes ← ConvexM.attempt "generating a run id" (Ffi.randomBytes 16)
  pure (Bytes.toHex bytes)

def incrementCounter : ConvexM Unit := do
  -- Read the deployment supplied by the Docker verifier.
  let deployment ← match ← IO.getEnv "CONVEX_URL" with
    | some url =>
        if url.isEmpty then
          throw (ConvexError.protocol "CONVEX_URL must not be empty")
        else
          pure url
    | none => throw (ConvexError.protocol "CONVEX_URL is required")
  let room := "lean-readme"
  let runId ← freshRunId
  let client ← Client.new deployment

  -- This client constructs the Convex argument object as Lean.Json.
  let changed ← client.mutation "demo:increment"
    (jsonObject
      [ ("room", Json.str room)
      , ("language", Json.str "lean")
      , ("runId", Json.str runId) ])

  -- There is no generated schema binding, so narrow the returned JSON explicitly.
  let state ← match jsonObjVal? changed.value "state" with
    | some value => pure value
    | none => throw (ConvexError.protocol "mutation omitted state")
  let count ← match jsonObjVal? state "count" >>= jsonIntegral? with
    | some value => pure value
    | none => throw (ConvexError.protocol "state.count was not a whole number")
  IO.println s!"new count: {count}"
  client.close
```

Lean can express much stronger types than this snippet uses. The dynamic `Json` boundary is a
choice in this small handwritten client, not a limitation of Lean. In a normal Convex React app,
generated bindings connect `api.demo.increment` to its argument and return types automatically.

## Status

Clean parent commit `305e9a4` passed all 31 local and all 31 hosted checks from
the same built image, earning both HTTP and Live. This prose-only reconciliation
does not change those verified build inputs.

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions | Verified locally and hosted |
| Bearer authentication and structured function errors | Verified locally and hosted |
| Live initial values, external updates, and query-error recovery | Verified locally and hosted |
| Five reconnects with hydration, stale-update barriers, and bounded delivery | Verified locally and hosted |
| Convex value types beyond the JSON-safe subset | Not implemented |
| Live authentication, WebSocket mutations, and optimistic updates | Not implemented |

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/Main.lean -->
```lean
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
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

This is a native Lean 4.23.0 implementation. The public API in
[`client/Convex/Client.lean`](client/Convex/Client.lean) implements Convex queries, mutations,
actions, authentication, and Live subscriptions without delegating to another Convex client.
`Lean.Data.Json` supplies JSON support, so the build has no third-party Lean packages.

Lean's standard library does not provide the socket and TLS surface this client needs. The small C
shim in [`client/shim/convex_shim.c`](client/shim/convex_shim.c) supplies BSD sockets, OpenSSL,
`poll(2)`, a monotonic clock, SHA-1, and secure random bytes. HTTP framing, WebSocket framing, and
all Convex-specific behaviour stay in Lean.

One poll-driven owner manages the Live socket and query set. `nextUpdate` drives that owner while a
caller waits, which keeps the API understandable for a command-line demonstration but means a
blocking HTTP request pauses Live progress. Delivery is deliberately bounded: each subscription
keeps at most 16 recent updates, all subscriptions share a 16 MiB charged-byte budget, and the test
adapter has a separate 16-event, 6 MiB output budget.

The language-local Docker tests cover JSON and integer bounds, TLS identity checks, HTTP and
WebSocket framing, fragmented UTF-8, reconnects, query failure recovery, stale-update barriers,
bounded slow-consumer behaviour, adapter event shapes, and the exact canonical example. The final
images contain the native executable, Lean runtime libraries, OpenSSL, certificate roots, and only
the small POSIX command set required by the shared verifier.

## Known Issues

1. Live authentication, optimistic updates, mutations and actions over WebSocket, journals, and
   `TransitionChunk` assembly are not implemented.
2. Values use Convex's JSON-safe subset. Tagged Convex encodings are not converted to richer Lean
   types.
3. HTTP opens a new connection for every request. Persistent and pipelined connections are deferred.
4. The single-threaded design does not advance Live while a blocking HTTP call is running, and
   oversized or backpressured inputs are rejected or coalesced to preserve the documented bounds.
