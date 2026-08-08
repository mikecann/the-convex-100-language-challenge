{-# OPTIONS --without-K #-}

-- Language-local coverage for the conformance executable's own behaviour.
--
-- The shared controller validates every emitted event strictly, so serialised
-- shapes are checked here rather than being discovered as a schema mismatch in
-- shared conformance. The bounded output queue is driven directly with a
-- reader that never drains, which is the only way to observe the count budget,
-- the byte budget, in-flight accounting, and the difference between a
-- droppable subscription value and an acknowledgement that must not be lost.
module AdapterTest where

open import Convex.Prelude
open import Convex.Prim
open import Convex.Bytes
open import Convex.Json
open import Convex.Error
open import Convex.Live using (Update; update)
-- `Adapter` has its own `main` (the conformance executable's entrypoint);
-- this file needs everything else it exports but supplies its own test-
-- runner `main` below, so the clash is hidden rather than renamed.
open import Adapter hiding (main)
open import Check
import Convex.Utf8 as Utf8

private
  render : JSON → String
  render = encode

  sampleError : ConvexError
  sampleError = convexError functionError "boom" (jobj (("code" , jstr "X") ∷ [])) []

  sampleErrorWithLogs : ConvexError
  sampleErrorWithLogs = convexError functionError "boom" jnull ("line" ∷ [])

  command : List (String × JSON) → JSON
  command = jobj

  shapeProblem : Maybe String → Bool
  shapeProblem = isJust

--------------------------------------------------------------------------------
-- Serialised event shapes
--------------------------------------------------------------------------------

eventChecks : MVar Tally → IO ⊤
eventChecks t =
  checkEqString t (render (readyEvent "h1"))
    ("{\"protocolVersion\":1,\"id\":\"h1\",\"type\":\"ready\",\"language\":\"agda\""
      <> ",\"implementation\":\"native-agda-2.7.0.1\",\"runtime\":\"Agda 2.7.0.1 (GHC 9.10.1)\"}")
    "the ready event reports version, language, provenance, and runtime"
    -- An absent optional field is omitted, never serialised as null.
    >> checkEqString t (render (resultEvent "c1" (callResult (jnat 7) [])))
         "{\"id\":\"c1\",\"type\":\"result\",\"value\":7}"
         "a result with no logs omits the logs field"
    >> checkEqString t (render (resultEvent "c1" (callResult (jnat 7) ("a" ∷ []))))
         "{\"id\":\"c1\",\"type\":\"result\",\"value\":7,\"logs\":[\"a\"]}"
         "a result with logs includes them"
    >> checkEqString t (render (ackEvent "c2")) "{\"id\":\"c2\",\"type\":\"ack\"}"
         "an ack carries only its id"
    >> checkEqString t (render (closedEvent "c3")) "{\"id\":\"c3\",\"type\":\"closed\"}"
         "a closed event carries only its id"
    >> checkEqString t (render (errorEvent (just "c4") sampleError))
         "{\"id\":\"c4\",\"type\":\"error\",\"error\":{\"name\":\"FunctionError\",\"message\":\"boom\",\"data\":{\"code\":\"X\"}}}"
         "a structured HTTP error keeps its name, message, and data"
    -- A protocol failure that cannot be attributed to a command omits `id`
    -- entirely rather than sending null.
    >> checkEqString t (render (errorEvent nothing (protocolFailure "bad line")))
         "{\"type\":\"error\",\"error\":{\"name\":\"ProtocolError\",\"message\":\"bad line\",\"data\":null}}"
         "an unattributed error omits the id field"
    >> checkEqString t (render (errorEvent (just "c5") sampleErrorWithLogs))
         "{\"id\":\"c5\",\"type\":\"error\",\"error\":{\"name\":\"FunctionError\",\"message\":\"boom\",\"data\":null},\"logs\":[\"line\"]}"
         "an error with logs includes them"
    >> checkEqString t (render (subscriptionEvent "s1" (update (jnat 1) [] nothing 3)))
         "{\"type\":\"subscription\",\"subscriptionId\":\"s1\",\"value\":1}"
         "a subscription value omits error and logs"
    >> checkEqString t (render (subscriptionEvent "s1" (update jnull [] (just sampleError) 3)))
         "{\"type\":\"subscription\",\"subscriptionId\":\"s1\",\"error\":{\"name\":\"FunctionError\",\"message\":\"boom\",\"data\":{\"code\":\"X\"}}}"
         "a subscription error omits the value field"

--------------------------------------------------------------------------------
-- Strict command validation
--------------------------------------------------------------------------------

shapeChecks : MVar Tally → IO ⊤
shapeChecks t =
  check t (not (shapeProblem (validateShape
      (command (("id" , jstr "1") ∷ ("op" , jstr "query") ∷ ("path" , jstr "demo:state")
                  ∷ ("args" , jobj []) ∷ [])) "query")))
    "a well-formed call is accepted"
    >> check t (shapeProblem (validateShape
         (command (("id" , jstr "1") ∷ ("op" , jstr "query") ∷ ("path" , jstr "demo:state")
                     ∷ ("args" , jobj []) ∷ ("extra" , jnat 1) ∷ [])) "query"))
         "an unknown field is rejected"
    >> check t (shapeProblem (validateShape
         (command (("id" , jstr "1") ∷ ("op" , jstr "query") ∷ ("path" , jstr "demo:state") ∷ []))
         "query"))
         "a missing required field is rejected"
    >> check t (shapeProblem (validateShape
         (command (("id" , jstr "1") ∷ ("id" , jstr "2") ∷ ("op" , jstr "close") ∷ [])) "close"))
         "a duplicate field is rejected"
    >> check t (shapeProblem (validateShape
         (command (("id" , jstr "1") ∷ ("op" , jstr "query") ∷ ("path" , jstr "demo:state")
                     ∷ ("args" , jarr []) ∷ [])) "query"))
         "non-object args are rejected"
    >> check t (shapeProblem (validateShape
         (command (("id" , jstr "1") ∷ ("op" , jstr "query") ∷ ("path" , jstr "ab")
                     ∷ ("args" , jobj []) ∷ [])) "query"))
         "a path shorter than three characters is rejected"
    >> check t (shapeProblem (validateShape
         (command (("id" , jstr "1") ∷ ("op" , jstr "nope") ∷ [])) "nope"))
         "an unknown operation is rejected"
    >> check t (not (shapeProblem (validateShape
         (command (("id" , jstr "1") ∷ ("op" , jstr "subscribe") ∷ ("subscriptionId" , jstr "s")
                     ∷ [])) "subscribe")))
         "subscribe without path and args is accepted"

--------------------------------------------------------------------------------
-- Bounded output with a reader that never drains
--------------------------------------------------------------------------------

private
  -- A value close to the frame ceiling, so the count bound alone would not be
  -- a memory bound.
  bulk : Nat → Bytes
  bulk n = Utf8.encode (repeat n "0123456789abcdef0123456789abcdef")
    where
      repeat : Nat → String → String
      repeat zero _ = ""
      repeat (suc k) unit = unit <> repeat k unit

  droppableItem : OutItem
  droppableItem = outItem (bulk 4096) (size (bulk 4096)) true

  stickyItem : OutItem
  stickyItem = outItem (Utf8.encode "{\"id\":\"a\",\"type\":\"ack\"}\n") 24 false

  admissionKind : Admission → String
  admissionKind admitted = "admitted"
  admissionKind coalesced = "coalesced"
  admissionKind backpressured = "backpressured"
  admissionKind sinkGone = "gone"

  -- Push `n` droppable events into a sink nobody drains.
  flood : Nat → OutItem → Sink → Sink
  flood zero _ s = s
  flood (suc n) item s = flood n item (fst (tryAdmit item s))

  lastAdmission : Nat → OutItem → Sink → Admission
  lastAdmission zero item s = snd (tryAdmit item s)
  lastAdmission (suc n) item s = lastAdmission n item (fst (tryAdmit item s))

outputChecks : MVar Tally → IO ⊤
outputChecks t =
  check t (sinkCount flooded ≤ⁿ outputCountLimit) "the queue never exceeds its count bound"
    >> check t (sinkTotal flooded ≤ⁿ outputByteLimit) "the queue never exceeds its byte bound"
    -- The event budget is well under the shared 128 MiB container limit even
    -- with near-maximum values and a stopped reader.
    >> check t (sinkTotal flooded ≤ⁿ 6291456) "the retained bytes stay inside the declared budget"
    >> checkEqString t (admissionKind (snd (tryAdmit droppableItem flooded))) "admitted"
         "a droppable event is admitted by shedding an older one"
    -- With every queued item non-droppable there is nothing to shed, so an
    -- acknowledgement is refused rather than silently dropped.
    >> checkEqString t (admissionKind (lastAdmission 32 stickyItem initialSink)) "backpressured"
         "an acknowledgement is refused rather than lost when the queue is full"
    -- Handing an item to the writer must not reduce the accounted total: the
    -- charge simply moves from the queue to the in-flight slot.
    >> checkEqNat t (sinkTotal inWriter) (sinkTotal flooded)
         "moving an item into the writer preserves the accounted bytes"
    >> checkEqNat t (sinkCount inWriter) (sinkCount flooded)
         "an in-flight write still occupies a slot"
    >> check t (sinkTotal (fst (clearInFlight inWriter)) <ⁿ sinkTotal flooded)
         "completing the write releases its charge"
  where
    flooded : Sink
    flooded = flood 40 droppableItem initialSink

    inWriter : Sink
    inWriter = fst (takeItem flooded)

main : IO ⊤
main =
  initStandardStreams >> newTally >>= λ t →
  eventChecks t >> shapeChecks t >> outputChecks t >> finish t "adapter-test"
