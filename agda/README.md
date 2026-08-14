# Agda

[Agda](https://agda.readthedocs.io/en/latest/getting-started/what-is-agda.html) is a dependently typed functional programming language and interactive theorem prover. It grew out of the programming-logic work at Chalmers, following languages including Alf, Alfa, Agda 1, and Cayenne. Its type system can express facts about values, so the same source can be both an executable program and a constructive proof. That makes Agda a specialist tool today, mostly seen in formal methods, programming-language research, and teaching, with close conceptual neighbours such as Lean, Idris, and Rocq.

This repository uses that unusual tool to build a real Convex client. It is an educational, unofficial demonstration, not a production SDK and not a package intended for publication.

## Getting Started

Start with [`examples/basics/Main.agda`](examples/basics/Main.agda). It reads a fresh counter over HTTP, subscribes to the same state, applies an idempotent mutation, then checks that the mutation result and the next Live value both show `0 -> 1`.

From the repository root, Docker builds the pinned toolchain and runs that exact example against an approved test deployment:

```sh
./run verify-example agda
```

You do not need Agda, GHC, or Cabal installed on your machine.

## Interesting Parts

### `∷` and `==ⁿ` are library code, not syntax

Agda source is written in real Unicode — the editor input method turns `\::` into `∷` and `\to` into `→` — and almost every operator is an ordinary definition whose underscores mark argument slots, a scheme called mixfix. Even list cons, `_∷_`, comes from a library. Building the arguments for a Convex query is just pairs consed onto `[]`:

```agda
roomArgs : JSON
roomArgs = jobj (("room" , jstr "agda-readme") ∷ [])
-- TypeScript: const state = useQuery(api.demo.state, { room: "agda-readme" })

showState : Client → IO ⊤
showState client = clientQuery client "demo:state" roomArgs >>= onResult
```

This client's `_==ⁿ_` for comparing counts is defined the same way — two lines in `client/Convex/Prelude.agda`, no compiler magic.

### The next count is literally `suc current`

Agda's `Nat` is the Peano inductive type from a proofs course: a number is `zero` or `suc` of another number. So when the example predicts what `demo:increment` will return, it takes the successor by constructor:

```agda
expected : Nat
expected = suc current
-- TypeScript: const expected = current + 1

if not (counted ==ⁿ expected)
  then stop client "mutation returned an unexpected count"
```

The GHC backend compiles `Nat` to arbitrary-precision `Integer`, so the proof-friendly definition costs nothing at runtime.

### A Live update cannot be left half-handled

Agda is a total language: every pattern match must cover every constructor, or the file does not compile. After `clientSubscribe` registers the reactive query, `clientNext` hands back a `Maybe Update`, and an `Update` carries either a Convex value or a structured error — so timeout, failure, and fresh data each get their own checked equation:

```agda
-- TypeScript: useQuery returns undefined while loading; here each case is an equation.
liveValue : String → Maybe Update → Either String JSON
liveValue label nothing = left (label <> " timed out")
liveValue label (just u) = onError (updError u)
  where
    onError : Maybe ConvexError → Either String JSON
    onError (just e) = left (label <> " failed: " <> message e)
    onError nothing = right (updValue u)
```

Forget the `nothing` case and the coverage checker rejects the program — a missed Live edge case is a compile error, not a 2 a.m. crash.

### Exactly one module touches the real world

Agda's runtime has no sockets, threads, or clock. The client declares them as `postulate`s — names assumed rather than defined — and a `COMPILE GHC` pragma binds each one to Haskell, all inside the single reviewed module [`client/Convex/Prim.agda`](client/Convex/Prim.agda):

```agda
postulate
  Socket : Set
  socketSend : Socket → Bytes → Nat → IO (IOResult ⊤)
  socketRecv : Socket → Nat → Nat → IO RecvResult

{-# COMPILE GHC socketSend = convexSend #-}
{-# COMPILE GHC socketRecv = convexRecv #-}
```

Everything above that boundary — HTTP framing, the JSON codec, WebSocket frames, the Live state machine — is plain type-checked Agda moving opaque octets.

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions | Verified locally and hosted |
| Bearer authentication and structured function errors | Verified locally and hosted |
| Live initial values, updates, and query-error recovery | Verified locally and hosted |
| Unsubscribe barriers, five reconnects, and bounded delivery | Verified locally and hosted |

The Docker `test` target builds the toolchain, type-checks and compiles the client, and runs its unit, conformance, and TLS tests on native `linux/amd64`. Shared local and hosted conformance also passed, earning HTTP and Live.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/Main.agda -->
```agda
{-# OPTIONS --without-K #-}

module Main where

open import Convex

-- Convex may send an integral number in a decimal form such as `0.0`. This
-- narrows a Convex value to the non-negative integer the example's output
-- contract needs, and rejects a fractional, non-finite, or out-of-range value
-- rather than rounding it into agreement.
exampleCount : String → JSON → Either String Nat
exampleCount label value = onField (objGet value "count")
  where
    onNat : Maybe Nat → Either String Nat
    onNat nothing = left (label <> " returned a non-integral or out-of-range count")
    onNat (just n) = right n

    onField : Maybe JSON → Either String Nat
    onField nothing = left (label <> " returned no count")
    onField (just counted) = onNat (asNat counted)

-- A Live update carries either a value or a structured error. The example
-- treats a failed query as a failure of the demonstration rather than
-- continuing with a placeholder.
liveValue : String → Maybe Update → Either String JSON
liveValue label nothing = left (label <> " timed out")
liveValue label (just u) = onError (updError u)
  where
    onError : Maybe ConvexError → Either String JSON
    onError (just e) = left (label <> " failed: " <> message e)
    onError nothing = right (updValue u)

-- Cleanup uses the same acknowledged, bounded operations as the rest of the
-- example, so the program cannot exit while the Live worker still owns a
-- socket.
shutdown : Client → Nat → IO ⊤
shutdown client subscriptionId =
  clientUnsubscribe client subscriptionId >> clientClose client >> return tt

stop : Client → String → IO ⊤
stop client text =
  errLine ("Agda example failed: " <> text) >> clientClose client >> exitProcess 1

-- The final Live value after the mutation. Everything the example claims has
-- now been observed on all three surfaces, so the proof line is printed last.
finish : Client → Nat → Nat → Nat → Maybe Update → IO ⊤
finish client subscriptionId current expected latest = onValue (liveValue "updated Live value" latest)
  where
    onCount : Either String Nat → IO ⊤
    onCount (left text) = stop client text
    onCount (right updated) =
      if not (updated ==ⁿ expected) then stop client "updated Live count disagreed with the mutation"
      else
        putLine ("live updated count: " <> showNat updated)
          >> putLine ("verified count: " <> showNat current <> " -> " <> showNat updated)
          >> shutdown client subscriptionId
          >> exitProcess 0

    onValue : Either String JSON → IO ⊤
    onValue (left text) = stop client text
    onValue (right value) = onCount (exampleCount "updated Live value" value)

-- The mutation result. `applied` proves the increment ran for this runId, and
-- `state.count` is the value Live must converge on.
afterMutation : Client → Nat → Nat → Either ConvexError CallResult → IO ⊤
afterMutation client subscriptionId current outcome = onOutcome outcome
  where
    expected : Nat
    expected = suc current

    onCount : JSON → Either String Nat → IO ⊤
    onCount _ (left text) = stop client text
    onCount value (right counted) =
      if not (counted ==ⁿ expected) then stop client "mutation returned an unexpected count"
      else if not (fromMaybe false (asBool (objOr value "applied" jnull))) then
        stop client "mutation was not applied"
      else
        putLine "mutation applied: true"
          >> putLine ("mutation count: " <> showNat counted)
          -- The increment reaches this program through Live rather than
          -- through another HTTP poll.
          >> clientNext client subscriptionId 10000
          >>= finish client subscriptionId current expected

    onOutcome : Either ConvexError CallResult → IO ⊤
    onOutcome (left e) = stop client ("mutation failed: " <> message e)
    onOutcome (right result) =
      onCount (resultValue result)
              (exampleCount "mutation" (objOr (resultValue result) "state" jnull))

-- The first Live value hydrates the query the HTTP call already answered, so
-- the two must agree before the example changes anything.
afterInitial : Client → String → Nat → Nat → Maybe Update → IO ⊤
afterInitial client room subscriptionId current initial = onValue (liveValue "initial Live value" initial)
  where
    increment : String → IO ⊤
    increment runId =
      clientMutation client "demo:increment"
        (jobj (("room" , jstr room) ∷ ("language" , jstr "agda") ∷ ("runId" , jstr runId) ∷ []))
        >>= afterMutation client subscriptionId current

    onCount : Either String Nat → IO ⊤
    onCount (left text) = stop client text
    onCount (right initialCount) =
      if not (initialCount ==ⁿ current) then stop client "initial Live count disagreed with HTTP"
      else
        putLine ("live initial count: " <> showNat initialCount)
          -- runId is the mutation's idempotency key. Reusing it returns the
          -- previous result instead of incrementing twice.
          >> randomHex >>= increment

    onValue : Either String JSON → IO ⊤
    onValue (left text) = stop client text
    onValue (right value) = onCount (exampleCount "initial Live value" value)

-- Live is started before the mutation so no reactive update can be missed
-- between the read and the write.
afterQuery : Client → String → Either ConvexError CallResult → IO ⊤
afterQuery client room outcome = onOutcome outcome
  where
    onSubscribed : Nat → Either ConvexError Nat → IO ⊤
    onSubscribed _ (left e) = stop client ("subscribe failed: " <> message e)
    onSubscribed current (right subscriptionId) =
      clientNext client subscriptionId 10000 >>= afterInitial client room subscriptionId current

    onCount : Either String Nat → IO ⊤
    onCount (left text) = stop client text
    onCount (right current) =
      putLine ("current count: " <> showNat current)
        >> clientSubscribe client "demo:state" (jobj (("room" , jstr room) ∷ []))
        >>= onSubscribed current

    onOutcome : Either ConvexError CallResult → IO ⊤
    onOutcome (left e) = stop client ("current query failed: " <> message e)
    onOutcome (right result) = onCount (exampleCount "current query" (resultValue result))

-- Configure one native Agda client for the deployment the runtime container
-- supplies, then read the shared counter over Convex's documented HTTP
-- endpoint.
run : String → String → IO ⊤
run url room = newClient url "agda-0.1.0" >>= onClient
  where
    onClient : Either ConvexError Client → IO ⊤
    onClient (left e) = errLine ("Agda example failed: " <> message e) >> exitProcess 1
    onClient (right client) =
      clientQuery client "demo:state" (jobj (("room" , jstr room) ∷ []))
        >>= afterQuery client room

-- The verifier passes the unique room as the first argument; the environment
-- variable and the literal are friendly defaults for running the image by
-- hand.
roomFrom : List String → Maybe String → String
roomFrom (first ∷ _) _ = first
roomFrom [] (just configured) = configured
roomFrom [] nothing = "agda-example"

main : IO ⊤
main =
  initStandardStreams
    >> getEnvironment "CONVEX_URL"
    >>= λ url → getArguments
    >>= λ arguments → getEnvironment "EXAMPLE_ROOM"
    >>= λ configured → start url (roomFrom arguments configured)
  where
    start : Maybe String → String → IO ⊤
    start nothing _ = errLine "Agda example failed: CONVEX_URL is required" >> exitProcess 1
    start (just url) room =
      if stringLength url ==ⁿ 0
        then errLine "Agda example failed: CONVEX_URL is required" >> exitProcess 1
        else run url room
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

This is a native Agda implementation of Convex's documented JSON HTTP endpoints and the repository's pinned `/api/sync` profile. JSON, UTF-8, HTTP framing, the WebSocket handshake and frames, and the Live state machine are written in Agda. It does not delegate Convex behaviour to another SDK, the Convex CLI, `curl`, Node.js, or Python.

The pinned toolchain is Agda 2.7.0.1 with GHC 9.10.1. Agda's [GHC backend](https://agda.readthedocs.io/en/v2.7.0.1/tools/compilers.html) turns the checked source into native executables. This project deliberately uses only Agda's builtin modules, not `agda-stdlib`, so [`client/Convex/Prelude.agda`](client/Convex/Prelude.agda) supplies its small collection of list, string, and arithmetic helpers.

Agda itself does not provide the socket and operating-system primitives this client needs. The reviewed boundary in [`client/Convex/Prim.agda`](client/Convex/Prim.agda) maps a small set of opaque Agda types and operations to Haskell, using the language's documented [GHC foreign-function interface](https://agda.readthedocs.io/en/v2.7.0.1/language/foreign-function-interface.html). It moves bytes over TCP and TLS, manages threads and an `MVar`, reads time and entropy, and handles process I/O. It does not understand Convex, HTTP, JSON, or WebSockets.

One worker owns the Live socket and receives commands from the public client. This avoids concurrent reads or writes during reconnects. Deliveries are bounded by both count and estimated memory: the client retains at most 16 updates within 20 MiB, while active subscriptions have their own 64-entry and 8 MiB limits. Unsubscribe waits for a barrier acknowledgement, so an update from the retired subscription cannot appear afterwards.

`./run test agda` builds and runs the language-local protocol, adapter, TLS, and Live fixture tests in Docker. `./run verify-example agda` exercises the exact example above. The root-owned local and hosted conformance runs are separate evidence layers, and those recorded runs earned the HTTP and Live capabilities shown in the status table.

## Known Issues

1. Live authentication, optimistic updates, WebSocket mutations and actions, journals, and `TransitionChunk` assembly are not implemented. A `TransitionChunk` causes a recoverable reconnect instead of exposing partial state.
2. Values cover Convex's JSON-safe subset. Tagged Convex values are not decoded into richer Agda types.
3. JSON, HTTP responses, and Live messages are limited to 1 MiB. JSON also stops at 64 nesting levels and 4096 structural nodes.
4. Waiting uses bounded polling rather than condition variables. It adds a few milliseconds of latency, but keeps each component's shared state behind one `MVar`.
5. The byte-at-a-time parsers favour auditability over speed. Agda naturals compile to arbitrary-precision `Integer`, so these paths are not designed for high-throughput workloads.
