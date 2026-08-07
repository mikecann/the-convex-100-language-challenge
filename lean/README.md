# Convex from Lean

This is a small native Lean 4 client that calls Convex functions over HTTPS and keeps a query current over a Live WebSocket. Lean is best known as a proof assistant, so the interesting question here is what an ordinary networked client looks like when the language ships no networking at all: the answer is one small C shim for sockets and OpenSSL, and everything Convex-specific written in Lean on top of it.

It is educational and unofficial. It is not a production SDK and is not intended for package publication.

## Start here

Read [`examples/basics/Main.lean`](examples/basics/Main.lean). It queries a fresh counter over HTTP, starts Live *before* changing anything, applies one idempotent mutation, and then lets the reactive subscription — not a second query — report the new value. It prints its final line only once HTTP, the mutation result, and Live all agree on `0 -> 1`.

## What works

Nothing in this checkpoint has been compiled or run: the source is complete, but no Docker build, no language-local test, and no shared conformance run has been executed against it. The table below is therefore a statement of intent and of what the code implements, not of earned evidence.

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions | Implemented in source, execution unverified |
| Bearer authentication and structured function errors | Implemented in source, execution unverified |
| Live initial values, external updates, and query-error recovery | Implemented in source, execution unverified |
| Five reconnects with hydration, generation barriers, and bounded delivery | Implemented in source, execution unverified |
| Convex value types beyond the JSON-safe subset | Not implemented |
| Live authentication, WebSocket mutations, optimistic updates | Not implemented |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/Main.lean -->
```text
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

## Docker verification

```sh
./run sync-examples
./run validate
./run test lean
./run verify-example lean
./run verify lean
./run verify-hosted lean
./run verify-all lean
```

`test` compiles the C shim and the whole Lean tree inside Docker, enforces the checked-in source style, and then runs the language-local suites: the pure codecs and bounds, real TLS chain and hostname verification, raw HTTP framing, raw WebSocket framing, the Live engine against a scripted Convex sync peer, the adapter's own event shapes and output admission, and the exact canonical example binary. `verify-example` runs that same example from its minimal image against a unique room. The remaining commands add shared black-box conformance, locally and against the hosted drift target. Only the shared result evaluator awards HTTP or Live badges, so this directory claims none.

## Conformance and protocol notes

The client is native. `client/shim/convex_shim.c` is the only foreign surface: BSD sockets, OpenSSL, `poll(2)`, a monotonic clock, SHA-1, and the CSPRNG. It contains nothing Convex-specific and no fault injection. HTTP/1.1 framing, RFC 6455 framing, the documented Convex JSON endpoints, and the pinned `/api/sync` profile are all implemented in Lean. JSON comes from `Lean.Data.Json`, which the toolchain already ships, so the Docker build fetches no packages beyond the pinned toolchain itself. No request invokes another Convex client, the Convex CLI, `curl`, Node.js, or Python.

The whole client runs on one `poll(2)`-driven thread. The "single owner" rule that concurrent clients enforce with locks is structural here: exactly one place opens, reads, writes, retires, and reconnects the socket, and exactly one place changes the query set. Subscribers only ever pop from a bounded queue that the same loop filled. The cost of that choice is stated plainly in the limitations below.

Every wait is an absolute monotonic deadline rather than a per-read timeout, so a peer that dribbles one byte at a time cannot extend a bound. The WebSocket reader never consumes a byte until the whole frame is buffered and rejects an oversized *declared* length the moment the header is readable, so a frame that announces a terabyte is an error rather than an allocation; a deadline that fires mid-frame leaves the parser suspended exactly where it was instead of resynchronising on a byte that merely looks like a boundary. UTF-8 validation is incremental and survives a character split across two continuation frames.

Transitions are validated against the locally written query-set version, coalesced per query, and committed before anything is published. Unchanged rehydration after a reconnect is suppressed with a fixed-width FNV-1a signature rather than a retained copy of the value. Every delivered update carries the connection generation that produced it, which is what lets the adapter reject an update that a replacement, unsubscribe, or `debugDisconnect` barrier has already invalidated. Reconnect backoff starts at 100 ms, caps at 15 s, and resets after a valid server message so a healthy connection does not inherit an old maximum.

Each subscription retains at most the newest 16 updates, and all subscriptions share a 16 MiB budget charged at four times the encoded length plus a fixed record allowance; the globally oldest intermediate state is dropped first. The adapter keeps a separate queue of at most 16 encoded events within 6 MiB, counting the write currently in flight, and admits a non-droppable event only within a 5 s admission deadline. JSON is refused before parsing if it exceeds 2 MiB, 128 levels, or 65,536 structural nodes.

The adapter speaks bounded UTF-8 NDJSON protocol v1 over stdin and stdout, or over one `ADAPTER_LISTEN` connection. Commands are validated strictly against the v1 shapes, including duplicate top-level members, which the JSON object model alone cannot see. Optional event members are omitted rather than serialised as null. `debugDisconnect` is adapter-only and is not part of the client API the example teaches.

The final images contain the two native executables, the Lean runtime libraries, OpenSSL 3, certificate roots, `/bin/sh`, and the individual POSIX tools the shared verifier requires. They contain no Lean or Lake command, no C compiler, no package or network tooling, and no delegated runtime. Both run as `65532:65532` under the repository's read-only, capability-drop, no-new-privileges, 128 MiB policy.

## Limitations

Execution is unverified: this is a source checkpoint. Live authentication, optimistic updates, mutations and actions over the WebSocket, journals, and `TransitionChunk` assembly are deferred; a `TransitionChunk` is treated as recoverable protocol drift that retires the connection rather than publishing partial state. HTTP opens one connection per request and closes it, so persistent and pipelined connections are deferred. Values cover Convex's JSON-safe subset; tagged Convex value encodings are not converted into richer Lean types. Because the client is single-threaded by design, a blocking HTTP call does not advance the Live loop while it is in flight — acceptable for a demonstration, and stated rather than hidden. Input beyond the documented line, JSON, subscription, delivery, or output bounds is rejected or coalesced instead of risking unbounded memory. The manifest deliberately leaves capability badges empty until root-owned shared evidence passes from a clean reviewed commit.
