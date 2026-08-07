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
