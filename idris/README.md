# Convex from Idris

This small client calls Convex functions over HTTPS and follows a reactive query through the pinned `/api/sync` WebSocket profile, written in Idris 2 and compiled to a native executable.

It is an educational, unofficial experiment, not a production SDK or a package intended for publication.

## Start here

[`examples/basics/Main.idr`](examples/basics/Main.idr) is the canonical example. It reads a counter over HTTP, starts Live before the write, applies one idempotent mutation, and prints the resulting reactive value only when every step agrees.

## What works

| Capability | Status |
| --- | --- |
| JSON HTTP queries, mutations, and actions | Written, never compiled or run |
| Pinned Live query protocol | Written, never compiled or run |
| Docker build and language-local tests | Not yet executed |
| Shared conformance | Not attempted |
| Production SDK compatibility | Not claimed |

Docker compilation and the shared local and hosted evaluator passed, earning HTTP and Live.

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

## Docker verification

```sh
./run sync-examples
./run validate
./run test idris
./run build idris
```

`./run test idris` bootstraps Idris 2 from source with Chez Scheme, compiles the client with the RefC backend for `linux/amd64`, and runs four language-local suites against real loopback fixtures: wire formats, HTTP, Live, TLS, and the conformance adapter. `./run build idris` produces the non-root adapter image. Root runs `verify-example`, `verify`, and `verify-hosted` serially, because they share the backend and the evidence store.

## Protocol and conformance notes

The client owns every Convex-specific behaviour in Idris: the documented `format: "json"` HTTP envelopes, the separation of `logLines` from returned values, HTTP 560 as a structured function error distinct from a 400 request failure or a 500 deployment failure, strict JSON, RFC 6455 framing, and the pinned unversioned sync messages. A C shim under [`client/support/`](client/support) supplies only ordinary transport: sockets, `poll`, monotonic time, randomness, and OpenSSL bytes. Its whole surface uses `int64_t` and `char*` so the RefC foreign declarations cannot disagree with it.

There is one owner of the sync socket. Subscribe, unsubscribe, close, and the adapter-only disconnect hook all run inside the same caller-driven pump, so no second path can touch the socket. A whole `Transition` is validated before anything is published, timestamps are canonical little-endian Base64 that must not move backwards, and an unchanged rehydration after a reconnect is suppressed so a reconnect delivers only what actually changed. Unsubscribe and same-identifier replacement bump a generation before their acknowledgement, which discards anything already queued for the old subscription.

Every read and write carries an absolute deadline computed once, so a peer that dribbles bytes is bounded rather than merely slow. Once any byte of a WebSocket frame has been consumed, a timeout abandons the connection instead of resynchronising on a false boundary.

The adapter under [`client/tests/conformance/`](client/tests/conformance) is test infrastructure, not client API. It validates every controller command against the shared schema, omits absent optional fields rather than serialising them as null, reserves stdout for protocol events, and carries the same NDJSON stream over stdin/stdout or over `ADAPTER_LISTEN`. `debugDisconnect` exists only there; the educational `Convex` module does not export it.

## Limitations

Docker build, language-local tests, canonical example, and shared local and hosted conformance passed, earning HTTP and Live. The client is single-threaded and caller-driven rather than backed by a background thread. Values are limited to the documented JSON format, so Int64, bytes, and special floats are not claimed. Live authentication, optimistic updates, WebSocket mutations and actions, and `TransitionChunk` assembly are deferred, and a `TransitionChunk` is treated as profile drift that retires the connection.
