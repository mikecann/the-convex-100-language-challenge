<img src="logo.png" alt="Idris logo" width="128">
<!-- Logo source: https://github.com/idris-lang/Idris2/blob/main/icons/idris-256x256.png -->

# Idris

[Idris](https://www.idris-lang.org/) is a purely functional, general-purpose language built around type-driven development. Its signature feature is dependent types, where types can refer to values and express facts such as "these two lists have the same length." Idris 2 continues that research with a new core based on quantitative type theory. Its syntax will feel most familiar to Haskell or OCaml developers, but it occupies a smaller present-day niche in programming-language research, education, and software where proving invariants in the type system is the point.

This repository uses Idris 2 to call Convex over HTTPS and follow a reactive query over WebSocket. It is an educational, unofficial experiment, not a production SDK or a package intended for publication.

## Getting Started

The canonical [`examples/basics/Main.idr`](examples/basics/Main.idr) reads a counter, subscribes before changing it, applies one idempotent mutation, and checks the resulting reactive update. From the repository root, Docker builds the exact example and runs it against a fresh room:

```sh
./run verify-example idris
```

## Interesting Parts

### The compiler asks whether your network calls halt

Idris grew out of a research programme where programs double as proofs, so the compiler classifies every function's totality: a `total` function provably terminates and covers every case, while a `covering` one handles every input but might loop. A client that blocks on a WebSocket cannot honestly promise termination, so this repo's transport functions say so right in their declarations.

```idris
-- `total` would demand a termination proof the network cannot give,
-- so every socket-touching function declares itself `covering`.
export covering
query : Client -> String -> Json -> IO (Either ConvexError CallResult)

export covering
nextUpdate : Client -> Subscription -> (budgetMs : Int) -> IO (Maybe LiveUpdate)
```

And `(budgetMs : Int)` is more than documentation flair: in a dependently typed language, argument names in a signature are real binders that later parts of the type may refer to.

### Reading `count` is a `>>=` chain the compiler audits

This demonstration client has no generated bindings, so a query result arrives as a plain `Json` sum type. Accessors such as `field` and `wholeNumber` each return a `Maybe` — Idris's "might be absent" type — and `>>=` threads the possible failure through the chain, with the compiler insisting the `Nothing` case is handled.

```idris
wholeCount : String -> Json -> IO Int
wholeCount step state =
  -- TypeScript: const count = state.count  (generated types vouch for it)
  case field "count" state >>= wholeNumber of
       Just value => pure value
       Nothing => abort (step ++ " did not contain a whole count")
```

`wholeNumber` also knows Convex numbers travel as Float64: it accepts `1.0` as a count of one but rejects `1.5` outright instead of rounding it.

### The reactive update is the next value, not a rerender

`useQuery` hides Convex's WebSocket sync protocol behind React's lifecycle. Here the same protocol is caller-driven: `subscribe` returns a watch handle, and `nextUpdate` runs the socket loop until an update arrives or the millisecond budget expires. The example subscribes *before* writing, so the reactive update provably cannot be missed.

```idris
started <- subscribe client "demo:state" (JObject [("room", JString room)])
watch <- either (abort . message) pure started
initial <- nextUpdate client watch 10000  -- the first value arrives here

runId <- newRunId
changed <- mutation client "demo:increment"
             (JObject [ ("room", JString room)
                      , ("language", JString "idris")
                      , ("runId", JString runId) ])

-- TypeScript: useQuery(api.demo.state, { room }) rerenders on its own.
updated <- nextUpdate client watch 10000  -- pushed by Convex, not re-queried
```

Each update is a `LiveUpdate` carrying either a value or a typed error, never both, so a failed reactive query stays a subscription event instead of masquerading as state.

### A termination checker reviews the `Eq` instance

Comparing two JSON values sounds routine until Idris's size-change termination analysis reviews the recursion. A recursive `==` written inside the `Eq Json` implementation desugars into a call through the interface dictionary, which the checker cannot follow — so equality lives in plainly named mutually recursive functions, and the interface is a one-line alias.

```idris
mutual
  jsonEq : Json -> Json -> Bool
  jsonEq (JArray left) (JArray right) = jsonArrayEq left right
  jsonEq (JObject left) (JObject right) =
    length left == length right && jsonObjectSubset left right
  -- ...

Eq Json where
  (==) = jsonEq  -- a non-recursive alias keeps the checker satisfied
```

The Live client leans on this equality to suppress an unchanged value when the socket reconnects, so the proof-friendly shape is doing real reactive work.

## Status

| Capability | Status |
| --- | --- |
| JSON HTTP queries, mutations, and actions | Verified by shared local and hosted conformance |
| Pinned Live query protocol | Verified by shared local and hosted conformance |
| Docker build and language-local tests | Passed |
| Shared conformance | Passed locally and hosted; HTTP and Live earned |
| Production SDK compatibility | Not claimed |

Docker compilation and the shared local and hosted evaluator passed, earning HTTP and Live.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/Main.idr -->
```idris
module Main

import Convex
import Data.List
import Data.Maybe
import System
import System.File

-- Anything that is not the verified transcript belongs on stderr. Stdout is
-- compared byte for byte against the shared expected output, so a stray line
-- there would fail the run even if Convex behaved perfectly.
abort : String -> IO a
abort reason =
  do ignore $ fPutStrLn stderr ("convex example: " ++ reason)
     exitFailure

-- Convex sends Float64, so a count can legitimately arrive as `0.0` rather
-- than `0`. This accepts any value that is mathematically whole and in range
-- and rejects a fractional, quoted, or overflowing one instead of rounding it.
wholeCount : String -> Json -> IO Int
wholeCount step state =
  case field "count" state >>= wholeNumber of
       Just value => pure value
       Nothing => abort (step ++ " did not contain a whole count")

-- A reactive update carries either a value or a typed error, never both. The
-- example insists on a value so a `QueryFailed` cannot be mistaken for state.
liveValue : String -> Maybe LiveUpdate -> IO Json
liveValue step Nothing = abort (step ++ " did not arrive within its budget")
liveValue step (Just update) =
  case updateValue update of
       Just value => pure value
       Nothing => abort (step ++ " reported a subscription error")

main : IO ()
main =
  do -- One URL configures both transports. The client derives the sync socket
     -- from it, so queries and subscriptions cannot drift apart.
     deployment <- getEnv "CONVEX_URL"
     url <- maybe (abort "CONVEX_URL is required") pure deployment
     -- The verifier passes a unique room so parallel runs never share a
     -- counter; a hand-run image gets a friendly default instead.
     arguments <- getArgs
     let room = fromMaybe "idris-example" (head' (drop 1 arguments))
     created <- newClient url
     client <- either abort pure created

     -- Read the counter over the documented JSON HTTP API first.
     current <- query client "demo:state" (JObject [("room", JString room)])
     currentResult <- either (abort . message) pure current
     currentCount <- wholeCount "current query" (resultValue currentResult)
     putStrLn ("current count: " ++ show currentCount)

     -- Subscribe before the write. Starting Live first is what makes the
     -- reactive journey provable: the update cannot have been missed.
     started <- subscribe client "demo:state" (JObject [("room", JString room)])
     watch <- either (abort . message) pure started
     initial <- nextUpdate client watch 10000
     initialValue <- liveValue "initial Live value" initial
     initialCount <- wholeCount "initial Live value" initialValue
     when (initialCount /= currentCount)
          (abort "Live initial value disagreed with HTTP")
     putStrLn ("live initial count: " ++ show initialCount)

     -- The runId is this write's idempotency key. Repeating it would return
     -- the room unchanged with `applied: false` rather than counting twice.
     runId <- newRunId
     changed <- mutation client "demo:increment"
                  (JObject [ ("room", JString room)
                           , ("language", JString "idris")
                           , ("runId", JString runId)
                           ])
     changedResult <- either (abort . message) pure changed
     applied <- case field "applied" (resultValue changedResult) >>= asBool of
                     Just value => pure value
                     Nothing => abort "mutation did not report whether it applied"
     when (not applied) (abort "mutation was not applied")
     putStrLn "mutation applied: true"
     mutationState <- case field "state" (resultValue changedResult) of
                           Just value => pure value
                           Nothing => abort "mutation omitted the room state"
     mutationCount <- wholeCount "mutation" mutationState
     when (mutationCount /= currentCount + 1)
          (abort "mutation count was unexpected")
     putStrLn ("mutation count: " ++ show mutationCount)

     -- Take the resulting value from the subscription rather than issuing a
     -- second query, which is the whole point of the reactive path.
     updated <- nextUpdate client watch 10000
     updatedValue <- liveValue "updated Live value" updated
     updatedCount <- wholeCount "updated Live value" updatedValue
     when (updatedCount /= mutationCount)
          (abort "Live update was unexpected")
     putStrLn ("live updated count: " ++ show updatedCount)

     -- Only now, with every step agreeing, is the journey verified.
     putStrLn ("verified count: " ++ show currentCount ++ " -> " ++ show updatedCount)

     -- Release the subscription and the socket before exiting, so the image
     -- never leaves a half-open connection behind.
     ignore $ unsubscribe client watch
     closeClient client
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

The public [`Convex` module](client/Convex.idr) gives one client both transports. `query`, `mutation`, and `action` use Convex's documented JSON HTTP endpoint, while `subscribe` and `nextUpdate` use the pinned sync profile. HTTP failures remain distinct as function, protocol, or transport errors, and log lines stay separate from returned values.

Idris 2's RefC backend compiles the program through C to a native `linux/amd64` executable. The Convex-specific HTTP envelopes, strict JSON, WebSocket framing, and Live state machine are written in Idris. A small [`client/support`](client/support) shim supplies ordinary sockets, polling, monotonic time, randomness, and OpenSSL byte transport. It does not delegate to another Convex client.

The JSON implementation reads and writes byte buffers directly because RefC character handling is not a safe place to round-trip arbitrary UTF-8. Parsed numbers retain their original token, while `wholeNumber` accepts values such as `1.0` only when they are mathematically integral and in range. The Live client also owns a bounded queue, validates a complete transition before publishing it, and suppresses an unchanged value when reconnecting.

The Docker build pins Idris 2 0.7.0 and bootstraps it with Chez Scheme, then ships only the native executables and their runtime library closure. The conformance adapter in [`client/tests/conformance`](client/tests/conformance) is test infrastructure, not part of the educational client API.

## Known Issues

1. The API accepts and returns the client's general `Json` type. It has no generated function bindings, so argument and result shapes are checked manually.
2. Live is single-threaded and caller-driven. `nextUpdate` runs the socket owner loop, and a slow consumer may lose the oldest intermediate update after the shared 64-event or 4 MiB delivery limit is reached.
3. Live targets the pinned `convex-rs-0.10.4-unversioned-sync` profile, not a documented stable third-party protocol. `TransitionChunk` is treated as protocol drift and closes that connection.
4. Live authentication, optimistic updates, WebSocket mutations and actions, and non-JSON Convex values such as Int64, bytes, and special floats are not implemented.
