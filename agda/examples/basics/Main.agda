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
