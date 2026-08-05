# Convex from Haskell

This small client calls Convex functions over HTTPS and follows a reactive query through the pinned `/api/sync` WebSocket profile.

It is an educational, unofficial experiment, not a production SDK or a package intended for publication.

## Start here

[`examples/basics/Main.hs`](examples/basics/Main.hs) is the canonical example. It reads a counter over HTTP, starts Live before the write, applies one idempotent mutation, and verifies the Live update.

## What works

| Capability | Status |
| --- | --- |
| JSON HTTP queries, mutations, and actions | Implemented locally, unearned pending shared evidence |
| Pinned Live query protocol | Implemented locally, unearned pending shared evidence |
| Production SDK compatibility | Not claimed |

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

## Docker verification

```sh
./run sync-examples
./run validate
./run test haskell
./run build haskell
```

The test target checks Fourmolu formatting, compiles the exact example and adapter for `linux/amd64`, and runs real loopback HTTP, WebSocket, stdin, and TCP fixtures. The build target creates the non-root conformance image. Root runs `verify-example`, `verify`, and `verify-hosted` serially because they share the backend and evidence store.

## Protocol notes

The client owns Convex-specific HTTP envelopes and the pinned unversioned sync messages. `http-client-tls` 0.3.6.4 supplies ordinary HTTPS/TLS transport; `wuss` 2.0.2.5 and `websockets` 0.13.0.0 supply ordinary WSS and frame handling. One socket actor performs every WebSocket read, write, and close while the Live state owner serializes reconnects and `Add`/`Remove` query-set changes. It validates canonical little-endian Convex timestamps, keeps their numeric maximum across reconnects, and publishes the final modification for each query in query-ID order. Each subscription retains at most the newest 16 updates. All subscriptions share a 16 MiB encoded-byte budget, and the client drops the globally oldest intermediate state first when a consumer is slow.

The build uses GHC 9.10.1, Fourmolu 0.16.2.0, a Cabal index state of 2025-08-01, the fully resolved dependency and flag closure in `client/cabal.project.freeze`, and digest-pinned Haskell 9.10.1 and Debian Bookworm images. The final images contain the compiled Haskell executable and runtime library closure, CA certificates, `/bin/sh`, and an explicit small allowlist of POSIX text tools required by the shared verifier. They do not contain apt, dpkg, network helper commands, GHC, Cabal, Fourmolu, another language runtime, or the Convex CLI.

## Limitations

The implementation deliberately limits values to JSON, does not offer Live authentication or optimistic updates, and reconnects on protocol shapes outside the pinned profile. WebSocket mutations, WebSocket actions, and `TransitionChunk` assembly are deferred. The shared evaluator, not this README, awards HTTP or Live badges.
