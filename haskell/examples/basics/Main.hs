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
