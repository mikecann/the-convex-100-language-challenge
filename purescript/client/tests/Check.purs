-- | Minimal assertions shared by the language-local tests.
-- |
-- | The tests run as ordinary compiled programs inside the Docker test stage
-- | rather than through a test framework, so they add no dependency that would
-- | then have to be justified in the runtime images.
module Convex.Test.Check
  ( ok
  , equalInt
  , equalString
  , equalJson
  , done
  ) where

import Convex.Prelude
import Convex.Bytes as Bytes
import Convex.Json (Json)
import Convex.Json as Json
import Convex.Sys as Sys

-- | Fail loudly and stop. A test process that kept going after a failed
-- | assertion would report a misleading final line. `Sys.fatal` writes to
-- | standard error and exits non-zero, which fails the Docker build step.
ok :: String -> Boolean -> Effect Unit
ok name condition =
  if condition then pure unit else Sys.fatal ("FAIL " <> name)

equalInt :: String -> Int -> Int -> Effect Unit
equalInt name actual expected =
  if actual == expected then pure unit
  else Sys.fatal
    ( "FAIL " <> name <> ": expected " <> intToString expected <> " but got "
        <> intToString actual
    )

equalString :: String -> String -> String -> Effect Unit
equalString name actual expected =
  if actual == expected then pure unit
  else Sys.fatal
    ("FAIL " <> name <> ": expected " <> expected <> " but got " <> actual)

-- | Compare decoded values by their canonical encoding, which is also what the
-- | client puts on the wire.
equalJson :: String -> Json -> Json -> Effect Unit
equalJson name actual expected =
  equalString name (Json.toString actual) (Json.toString expected)

-- | Announce a finished suite. Test output is deliberately on stdout here
-- | because these programs are not the adapter and have no protocol surface.
done :: String -> Effect Unit
done suite =
  voidEffect (Sys.stdoutWrite (Bytes.fromString ("PASS " <> suite <> "\n")))
