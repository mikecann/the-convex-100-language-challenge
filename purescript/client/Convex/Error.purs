-- | The three failures a Convex caller has to tell apart.
-- |
-- | Flattening these into one string would make an application error look like
-- | a network blip, so the client keeps the distinction all the way out to the
-- | caller and to the conformance adapter.
module Convex.Error
  ( ConvexError
  , functionError
  , protocolError
  , transportError
  , toJson
  ) where

import Convex.Prelude
import Convex.Json (Json(..))

-- | `name` is `FunctionError`, `ProtocolError`, or `TransportError`.
-- |
-- | `errorData` is the `errorData` a Convex function threw. Convex
-- | distinguishes an absent field from an explicit JSON null, so this is
-- | `Just JsonNull` for the latter and `Nothing` for the former.
type ConvexError =
  { name :: String
  , message :: String
  , errorData :: Maybe Json
  , logs :: List String
  }

-- | A Convex function raised an application error. The function ran; the
-- | deployment and the transport are healthy.
functionError :: String -> Maybe Json -> List String -> ConvexError
functionError message errorData logs =
  { name: "FunctionError"
  , message: message
  , errorData: errorData
  , logs: logs
  }

-- | The peer said something this client cannot reconcile with the pinned sync
-- | profile. Treated as drift rather than as an application failure.
protocolError :: String -> ConvexError
protocolError message =
  { name: "ProtocolError"
  , message: message
  , errorData: Nothing
  , logs: Nil
  }

-- | The connection failed. The request may or may not have been applied, which
-- | is why Convex mutations in the example carry an idempotency key.
transportError :: String -> ConvexError
transportError message =
  { name: "TransportError"
  , message: message
  , errorData: Nothing
  , logs: Nil
  }

-- | Render for the NDJSON adapter. Optional members are omitted rather than
-- | serialised as null, because the shared schema validates event shapes
-- | strictly and an explicit null would fail it.
toJson :: ConvexError -> Json
toJson error =
  let
    base = listPair (Tuple "name" (JsonString error.name))
      (Tuple "message" (JsonString error.message))
    withData = case error.errorData of
      Nothing -> base
      Just value -> listSnoc base (Tuple "data" value)
    withLogs =
      if listNull error.logs then withData
      else
        listSnoc withData
          (Tuple "logs" (JsonArray (listMap JsonString error.logs)))
  in
    JsonObject withLogs
