||| The shape of one reactive result.
|||
||| It lives in its own module so the educational `Convex` API can re-export it
||| without also re-exporting `Convex.Live`, which carries the adapter-only
||| disconnect hook that must stay out of the client API.
module Convex.Update

import Convex.Error
import Convex.Json

||| Exactly one of the value and the error is present. A reactive query that
||| fails stays a typed subscription event rather than collapsing into a value.
public export
record LiveUpdate where
  constructor MkLiveUpdate
  updateValue : Maybe Json
  updateLogs : List String
  updateError : Maybe ConvexError

export
liveValueUpdate : Json -> List String -> LiveUpdate
liveValueUpdate value logs = MkLiveUpdate (Just value) logs Nothing

export
liveErrorUpdate : ConvexError -> List String -> LiveUpdate
liveErrorUpdate failure logs = MkLiveUpdate Nothing logs (Just failure)
