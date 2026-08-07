-- | The exact bytes the conformance adapter puts on stdout.
-- |
-- | The shared controller validates every line against
-- | `_shared/schemas/adapter.schema.json`, and the schema is strict about
-- | optional members: an absent `id`, `subscriptionId`, value, or error must be
-- | omitted rather than serialised as null. These assertions run against the
-- | production event builders, so a shape mismatch fails here rather than in a
-- | shared conformance run.
module Convex.Test.Adapter (main) where

import Convex.Prelude
import Adapter as Adapter
import Convex.Error as Error
import Convex.Json (Json(..))
import Convex.Json as Json
import Convex.Live (LiveEvent(..))
import Convex.Test.Check as Check

main :: Effect Unit
main = do
  Check.equalString "an ack carries only its id and type"
    (Json.toString (Adapter.ackEvent "cmd-1"))
    "{\"id\":\"cmd-1\",\"type\":\"ack\"}"

  Check.equalString "a closed event carries only its id and type"
    (Json.toString (Adapter.closedEvent "cmd-2"))
    "{\"id\":\"cmd-2\",\"type\":\"closed\"}"

  Check.equalString "a result always carries a logs array"
    ( Json.toString
        ( Adapter.resultEvent "cmd-3"
            (JsonObject (listSingleton (Tuple "count" (JsonInt 1))))
            Nil
        )
    )
    ( "{\"id\":\"cmd-3\",\"type\":\"result\","
        <> "\"value\":{\"count\":1},\"logs\":[]}"
    )

  Check.equalString "a result keeps the function's log lines"
    ( Json.toString
        (Adapter.resultEvent "cmd-4" JsonNull (listSingleton "hello"))
    )
    "{\"id\":\"cmd-4\",\"type\":\"result\",\"value\":null,\"logs\":[\"hello\"]}"

  -- A structured Convex failure keeps its data, and the adapter reports it as
  -- an error event rather than as a successful value.
  Check.equalString "a structured function error keeps its data"
    ( Json.toString
        ( Adapter.callErrorEvent "cmd-5"
            ( Error.functionError "boom"
                ( Just
                    ( JsonObject
                        (listSingleton (Tuple "code" (JsonString "X")))
                    )
                )
                Nil
            )
        )
    )
    ( "{\"id\":\"cmd-5\",\"type\":\"error\",\"error\":"
        <> "{\"name\":\"FunctionError\",\"message\":\"boom\","
        <> "\"data\":{\"code\":\"X\"}}}"
    )

  Check.equalString "a transport error omits absent members"
    ( Json.toString
        (Adapter.callErrorEvent "cmd-6" (Error.transportError "gone"))
    )
    ( "{\"id\":\"cmd-6\",\"type\":\"error\",\"error\":"
        <> "{\"name\":\"TransportError\",\"message\":\"gone\"}}"
    )

  Check.equalString "a subscription value names its subscription"
    ( Json.toString
        ( Adapter.subscriptionEvent "sub-1"
            ( LiveValue
                (JsonObject (listSingleton (Tuple "count" (JsonInt 0))))
                Nil
            )
        )
    )
    ( "{\"type\":\"subscription\",\"subscriptionId\":\"sub-1\","
        <> "\"value\":{\"count\":0},\"logs\":[]}"
    )

  -- A subscription failure carries an `error` and deliberately no `value`, so
  -- a consumer cannot mistake a failed query for a null result.
  Check.equalString "a subscription failure carries no value"
    ( Json.toString
        ( Adapter.subscriptionEvent "sub-2"
            (LiveFailure (Error.protocolError "drift"))
        )
    )
    ( "{\"type\":\"subscription\",\"subscriptionId\":\"sub-2\",\"error\":"
        <> "{\"name\":\"ProtocolError\",\"message\":\"drift\"}}"
    )

  Check.equalString "the adapter reports this language"
    Adapter.languageId
    "purescript"
  Check.ok "the provenance string names the transpilation path"
    (stringContains Adapter.implementation "purerl")

  runtime <- Adapter.runtimeDescription
  Check.ok "the runtime names the PureScript compiler"
    (stringContains runtime "PureScript 0.15.14")
  Check.ok "the runtime names the Erlang release"
    (stringContains runtime "Erlang/OTP")

  -- The output budget has to stay comfortably below the 128 MiB the shared
  -- conformance run gives the container, including the payload the sender is
  -- physically writing.
  Check.ok "the queued output budget is a small fraction of the memory limit"
    (Adapter.maxOutputBytes * 4 < 134217728)
  Check.ok "one command cannot exceed the output budget"
    (Adapter.maxCommandBytes < Adapter.maxOutputBytes)
  Check.ok "the output queue is bounded by count as well as bytes"
    (Adapter.maxOutputCount == 16)

  Check.done "convex_test_adapter"
