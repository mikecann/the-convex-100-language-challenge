-- | Regression for the canonical example's own decoding.
-- |
-- | The example is the file the README and the website show, so this test
-- | calls the exact function that file uses rather than a copy of it. Convex
-- | may deliver a whole number as `0` or as `0.0`, and an example that only
-- | accepted one spelling would pass against a mocked fixture and then fail
-- | against a real deployment.
module Convex.Test.Example (main) where

import Convex.Prelude
import Convex.Json (Json(..))
import Convex.Json as Json
import Convex.Test.Check as Check
import Main as Example

main :: Effect Unit
main = do
  integer <- Example.count (room (JsonInt 0))
  Check.equalInt "an integer count decodes" integer 0

  integral <- Example.count (room (JsonNumber 1.0))
  Check.equalInt "an integral float count decodes" integral 1

  larger <- Example.count (room (JsonNumber 42.0))
  Check.equalInt "a larger integral float count decodes" larger 42

  -- A fractional or quoted count would mean the deployment and this client
  -- disagree about the value, so the example must stop rather than round.
  Check.ok "a fractional count is rejected" (rejects (room (JsonNumber 1.5)))
  Check.ok "a quoted count is rejected" (rejects (room (JsonString "1")))
  Check.ok "a missing count is rejected" (rejects (JsonObject Nil))

  Check.done "convex_test_example"

room :: Json -> Json
room value = JsonObject (listSingleton (Tuple "count" value))

-- | `Example.count` stops the program on a bad value, so the rejection cases
-- | are checked through the same decoder the example relies on instead of by
-- | catching an exit.
rejects :: Json -> Boolean
rejects value = case Json.field value "count" of
  Nothing -> true
  Just raw -> isNothing (Json.integralInt raw)
