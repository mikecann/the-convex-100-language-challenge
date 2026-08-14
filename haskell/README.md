# Haskell

[Haskell](https://www.haskell.org/) is a general-purpose, purely functional language with lazy evaluation and static types. [A committee created it](https://www.haskell.org/onlinereport/preface-jfp.html) to bring the late-1980s world of lazy functional languages around one common language, naming it after logician Haskell B. Curry. It has long been used for teaching and programming-language research, and the official site also highlights present-day commercial users. Unlike JavaScript, Haskell keeps effects such as network calls in the [`IO` type](https://www.haskell.org/onlinereport/io-13.html); this project compiles the client with GHC to a native executable.

This is an educational, unofficial experiment, not a production SDK or a package intended for publication.

## Getting Started

The canonical [`examples/basics/Main.hs`](examples/basics/Main.hs) reads a counter, subscribes before changing it, applies one idempotent mutation, and waits for the reactive update. From the repository root, run the whole example in Docker with:

```sh
./run verify-example haskell
```

The command builds the minimal `linux/amd64` example image and runs that exact source against the approved test deployment.

## Interesting Parts

### The type signature admits it talks to the network

Haskell is *purely* functional: an ordinary function cannot quietly reach the network, so anything effectful wears `IO` in its type. Haskell also lets several names share one signature, which means this client's entire HTTP surface is a single line.

```haskell
query, mutation, action :: Client -> Text -> Value -> IO Result

-- In a do-block, `<-` runs the effect and binds the pure value it produced.
current <- query client "demo:state" (object ["room" .= room])
-- TypeScript: const state = await client.query(api.demo.state, { room });
```

`IO Result` is a promise you can read off the page: this touches the wire, and afterwards you hold the decoded value plus the function's server-side log lines.

### `Just (Bool True)` — one pattern, two layers deep

Aeson, Haskell's ubiquitous JSON library, models any document as one algebraic data type with constructors like `Object`, `Number`, and `Bool`. Checking a mutation's reply is a `case` expression over shapes, not a chain of `typeof` checks.

```haskell
changed <- mutation client "demo:increment"
    (object ["room" .= room, "language" .= ("haskell" :: Text), "runId" .= runId])
applied <- case resultValue changed of
    Object result -> case KM.lookup "applied" result of
        Just (Bool True) -> pure True
        _ -> fail "mutation was not applied"
    _ -> fail "mutation returned a non-object"
```

The pattern `Just (Bool True)` matches through the lookup's `Maybe` and the JSON boolean in a single stroke.

### `bracket` is try/finally as an ordinary function

Haskell has no try/finally statement — `bracket` is a plain function that takes an acquire action, a release action, and the work in between. The canonical example wraps its whole run in one, so the Live worker and HTTP resources are torn down even when an assertion `fail`s halfway through.

```haskell
bracket (newClient deployment) closeClient $ \client -> do
    current <- query client "demo:state" (object ["room" .= room])
    -- ... subscribe, mutate, and check the reactive update ...
    unsubscribe client subscription
```

### A Live update is a blocking read — and `Maybe` makes you check it

React re-renders when Convex pushes new state; a compiled command-line binary has no render loop, so `subscribe` hands you a `Subscription` and `nextUpdate` blocks until the server pushes the next value into its queue. Because Haskell has no `null`, the update's payload is a `Maybe Value` — you cannot touch the value without deciding what happens when it is absent.

```haskell
subscription <- subscribe client "demo:state" (object ["room" .= room])
-- ... the mutation runs; nothing polls — the server pushes the new state ...
updated <- nextUpdate subscription
-- updateValue :: Maybe Value, so skipping the error case will not compile.
updatedValue <- maybe (fail "updated Live update was an error") pure (updateValue updated)
-- TypeScript: useQuery(api.demo.state, { room }) just re-renders with the new count.
```

The example subscribes *before* mutating, so the reactive journey cannot miss the write.

## Status

| Capability | Status |
| --- | --- |
| JSON HTTP queries, mutations, and actions | Verified by shared local and hosted conformance |
| Pinned Live query protocol | Verified by shared local and hosted conformance |
| Production SDK compatibility | Not claimed |

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/Main.hs -->
```haskell
{-# LANGUAGE OverloadedStrings #-}

module Main (main, wholeCount) where

import Control.Exception (bracket)
import Convex
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID.V4 (nextRandom)
import System.Environment (getArgs, lookupEnv)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stderr, stdout)
import System.Timeout (timeout)

-- Convex values are JSON, so decode the demonstrated result into the
-- idiomatic Int this program needs and reject fractional or missing counts.
wholeCount :: Text -> Value -> IO Int
wholeCount operation (Object state) = case KM.lookup "count" state of
    Just (Number count) ->
        let integer = round count :: Integer
         in if fromInteger integer == count
                && integer >= toInteger (minBound :: Int)
                && integer <= toInteger (maxBound :: Int)
                then pure (fromInteger integer)
                else fail (T.unpack operation <> " did not contain an in-range whole count")
    _ -> fail (T.unpack operation <> " did not contain a whole count")
wholeCount operation _ = fail (T.unpack operation <> " was not an object")

main :: IO ()
main = do
    -- Final images write to a pipe during verification, so line buffering keeps
    -- each successfully checked step visible without changing the transcript.
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    -- Point both HTTPS and WSS at the same approved Convex deployment. The
    -- verifier supplies a unique room argument; hand-run examples get a safe default.
    deployment <- maybe (fail "CONVEX_URL is required") pure =<< lookupEnv "CONVEX_URL"
    arguments <- getArgs
    let room = headMay arguments
    -- Create one client for HTTPS and its single-owner Live worker. bracket
    -- always closes subscriptions and transport resources if any step fails.
    bracket (newClient deployment) closeClient $ \client -> do
        -- The verifier supplies a unique room, so concurrent examples do not share state.
        current <- query client "demo:state" (object ["room" .= room])
        currentCount <- wholeCount "current query" (resultValue current)
        putStrLn ("current count: " <> show currentCount)

        -- Start Live before the mutation so the reactive journey cannot miss the write.
        subscription <- subscribe client "demo:state" (object ["room" .= room])
        initial <- awaitLive "initial Live value" subscription
        initialValue <- maybe (fail "initial Live update was an error") pure (updateValue initial)
        initialCount <- wholeCount "initial Live value" initialValue
        if initialCount /= currentCount then fail "Live initial value disagreed with HTTP" else pure ()
        putStrLn ("live initial count: " <> show initialCount)

        -- This random runId is the mutation's idempotency key for this logical write.
        runId <- fmap (show) nextRandom
        changed <- mutation client "demo:increment" (object ["room" .= room, "language" .= ("haskell" :: Text), "runId" .= runId])
        applied <- case resultValue changed of
            Object result -> case KM.lookup "applied" result of
                Just (Bool True) -> pure True
                _ -> fail "mutation was not applied"
            _ -> fail "mutation returned a non-object"
        putStrLn ("mutation applied: " <> map toLower (show applied))
        mutationCount <- case resultValue changed of
            Object result -> maybe (fail "mutation omitted state") (wholeCount "mutation") (KM.lookup "state" result)
            _ -> fail "mutation returned a non-object"
        if mutationCount /= currentCount + 1 then fail "mutation count was unexpected" else pure ()
        putStrLn ("mutation count: " <> show mutationCount)

        -- Receive the resulting reactive value rather than issuing a second query.
        updated <- awaitLive "updated Live value" subscription
        updatedValue <- maybe (fail "updated Live update was an error") pure (updateValue updated)
        updatedCount <- wholeCount "updated Live value" updatedValue
        if updatedCount /= mutationCount then fail "Live update was unexpected" else pure ()
        putStrLn ("live updated count: " <> show updatedCount)
        -- This final line is emitted only when the complete HTTP and Live path agrees.
        putStrLn ("verified count: " <> show currentCount <> " -> " <> show updatedCount)
        unsubscribe client subscription
  where
    headMay [] = "haskell-example"
    headMay (value : _) = value
    toLower 'T' = 't'
    toLower 'F' = 'f'
    toLower character = character
    awaitLive label subscription = do
        received <- timeout (10 * 1000000) (nextUpdate subscription)
        maybe (fail (label <> " timed out")) pure received
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

The public client is native Haskell. It creates Convex's HTTP request and response envelopes itself, and uses `http-client-tls` 0.3.6.4 for HTTPS. For Live queries it owns the pinned `/api/sync` behavior while `wuss` 2.0.2.5 and `websockets` 0.13.0.0 handle the secure WebSocket and frames. It does not delegate Convex work to the JavaScript client, the Convex CLI, or another language runtime.

One worker owns all WebSocket reads, writes, reconnects, and subscription changes. The public `nextUpdate` call reads from a bounded queue: each subscription keeps its newest 16 updates, all subscriptions share a 16 MiB encoded-data budget, and a slow consumer loses the globally oldest intermediate states first. That keeps memory bounded while preserving the newest state.

The Docker build pins GHC 9.10.1, Fourmolu 0.16.2.0, the Cabal dependency resolution, and its Haskell and Debian images. The final non-root images contain the compiled executable, its runtime libraries, CA certificates, and only the small POSIX command set required by the shared verifier. They do not contain GHC, Cabal, package managers, the Convex CLI, or another language runtime.

## Known Issues

1. Values are limited to JSON-safe Convex values. The client returns generic Aeson `Value`s rather than generated Haskell types.
2. Live authentication and optimistic updates are not implemented.
3. Mutations and actions use HTTP only. WebSocket mutations, WebSocket actions, and `TransitionChunk` assembly are deferred.
4. Live support targets the repository's pinned, unversioned sync profile. Unexpected protocol shapes trigger a reconnect rather than being treated as supported behavior.
