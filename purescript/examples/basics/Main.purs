-- | Convex from PureScript: one shared counter, read two different ways.
-- |
-- | The program reads a room's counter over Convex's HTTP API, subscribes to
-- | the same query over the reactive `/api/sync` WebSocket, increments the
-- | counter once, and shows both surfaces agreeing on the journey from 0 to 1.
-- |
-- | Everything it prints on standard output is the shared transcript every
-- | language in this repository has to match exactly. Anything explanatory
-- | goes to standard error instead.
module Main (main, count) where

import Convex.Prelude
import Convex as Convex
import Convex.Error (ConvexError)
import Convex.Json (Json(..))
import Convex.Json as Json
import Convex.Live (LiveEvent(..))
import Convex.Live as Live
import Convex.Sys as Sys

-- | A Live update should arrive in milliseconds. Waiting forever would turn a
-- | broken subscription into a hung example instead of a clear failure.
liveTimeout :: Int
liveTimeout = 10000

main :: Effect Unit
main = do
  -- The verifier passes a unique room so concurrent runs cannot share a
  -- counter. The default only exists for someone running the image by hand.
  arguments <- Sys.plainArguments
  let room = fromMaybe "purescript-basic-example" (listHead arguments)

  -- The verifier also supplies the deployment URL; the default points at the
  -- repository's local self-hosted backend.
  deployment <- Sys.env "CONVEX_URL" "http://127.0.0.1:3210"

  -- One client owns both the documented HTTP calls and the single sync
  -- connection. No socket is opened until something is subscribed.
  client <- required "the client could not be created" (Convex.new deployment)
  let args = JsonObject (listSingleton (Tuple "room" (JsonString room)))

  -- These demo functions are public, so no token is needed. A protected
  -- function would call `Convex.setAuth` before any HTTP call.

  -- Read the durable counter through Convex's documented HTTP API first.
  initial <- required "the initial query failed"
    (Convex.call client Convex.Query "demo:state" args)
  initialCount <- count initial.value
  expect (initialCount == 0) "expected the room to start at 0"
  Sys.println "current count: 0"

  -- Subscribe before changing anything. Starting Live first means no update
  -- can fall into a gap between the initial read and the subscription.
  -- Events arrive in this process's mailbox, so the sink is its own id.
  self <- Sys.selfPid
  subscription <- required "the subscription was refused"
    (Convex.subscribe client "demo:state" args self)

  -- A Live query first hydrates with its current value. Decode it into the
  -- same idiomatic integer the HTTP result produced.
  hydrated <- nextCount subscription
  expect (hydrated == 0) "expected Live to start at 0"
  Sys.println "live initial count: 0"

  -- Convex records this idempotency key, so retrying this exact write cannot
  -- increment the room twice.
  let
    mutationArgs = JsonObject
      ( Cons (Tuple "room" (JsonString room))
          ( Cons (Tuple "language" (JsonString "PureScript"))
              (listSingleton (Tuple "runId" (JsonString (room <> "-once"))))
          )
      )
  mutation <- required "the mutation failed"
    (Convex.call client Convex.Mutation "demo:increment" mutationArgs)
  expect (Json.field mutation.value "applied" == Just (JsonBool true))
    "expected the mutation to be applied"
  state <- expectField mutation.value "state"
  mutatedCount <- count state
  expect (mutatedCount == 1) "expected the mutation to leave the room at 1"
  Sys.println "mutation applied: true"
  Sys.println "mutation count: 1"

  -- The sole Live owner decodes the resulting WebSocket transition and relays
  -- the changed value in protocol order.
  updated <- nextCount subscription
  expect (updated == 1) "expected Live to report the incremented value"
  Sys.println "live updated count: 1"

  -- Remove the server-side query, then release the socket and the owner.
  _ <- required "the unsubscribe failed" (Convex.unsubscribe client subscription)
  _ <- required "the client did not close" (Convex.close client)

  -- Reaching this line proves HTTP and Live agreed on one 0 -> 1 journey.
  Sys.println "verified count: 0 -> 1"

-- | Wait for the next value on one subscription.
-- |
-- | Live also reports query failures and transport failures on the same
-- | channel. Turning those into an immediate stop keeps the example honest: a
-- | failed subscription must never look like a missing update.
nextCount :: String -> Effect Int
nextCount subscription = do
  delivery <- Sys.receiveEvent liveTimeout
  case delivery of
    Nothing -> Sys.fatal "Live delivered no update before the timeout"
    Just received -> do
      expect (received.subscriptionId == subscription)
        "received an event for another subscription"
      -- Tell the bounded relay this value has left our mailbox before it sends
      -- another one. A consumer that stops reading therefore cannot grow an
      -- unbounded BEAM mailbox behind the client's own queue limits.
      Live.acknowledge received
      case received.event of
        LiveValue value _logs -> count value
        LiveFailure problem ->
          Sys.fatal (problem.name <> ": " <> problem.message)

-- | Decode the room's counter.
-- |
-- | Convex may spell a whole number as `0` or `0.0`, so both are accepted, and
-- | a fraction, a quoted number, or an out-of-range value is rejected rather
-- | than rounded into something that looks like agreement.
-- |
-- | This is exported only so the regression test can exercise the exact
-- | function the example uses, rather than a second copy of it.
count :: Json -> Effect Int
count value = case Json.field value "count" of
  Nothing -> Sys.fatal "Convex value has no count field"
  Just raw -> case Json.integralInt raw of
    Just number -> pure number
    Nothing -> Sys.fatal "count is not a whole number in range"

-- | Unwrap a client call, stopping with the client's own message on failure.
-- | The three error names Convex distinguishes are preserved here so a
-- | deployment problem never reads like a network problem.
required :: forall a. String -> Effect (Either ConvexError a) -> Effect a
required context action = do
  outcome <- action
  case outcome of
    Right value -> pure value
    Left problem ->
      Sys.fatal (context <> ": " <> problem.name <> ": " <> problem.message)

expectField :: Json -> String -> Effect Json
expectField value key = case Json.field value key of
  Just inner -> pure inner
  Nothing -> Sys.fatal ("Convex value has no " <> key <> " field")

-- | Stop on an unexpected value. Compilation is not evidence, so every step
-- | the example demonstrates is checked at runtime.
expect :: Boolean -> String -> Effect Unit
expect condition message =
  if condition then pure unit else Sys.fatal message
