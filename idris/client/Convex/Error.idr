||| The one failure type the client raises.
|||
||| Keeping the three kinds distinct is a conformance requirement, not a
||| stylistic choice. A Convex function that throws must never be reported as a
||| broken socket, and a broken socket must never be reported as a function
||| result. The adapter forwards the kind straight through as the error name.
module Convex.Error

import Convex.Json

public export
data ErrorKind
  = ||| The Convex function itself failed, including a structured `ConvexError`.
    FunctionFailure
  | ||| The peer spoke something outside the pinned protocol profile.
    ProtocolFailure
  | ||| The transport failed, timed out, or closed.
    TransportFailure

public export
Eq ErrorKind where
  FunctionFailure == FunctionFailure = True
  ProtocolFailure == ProtocolFailure = True
  TransportFailure == TransportFailure = True
  _ == _ = False

export
errorKindName : ErrorKind -> String
errorKindName FunctionFailure = "FunctionError"
errorKindName ProtocolFailure = "ProtocolError"
errorKindName TransportFailure = "TransportError"

public export
record ConvexError where
  constructor MkConvexError
  kind : ErrorKind
  message : String
  ||| Application data from a structured `ConvexError`, or `JNull`.
  errorData : Json
  ||| Log lines produced before the failure, which stay separate from the data.
  errorLogs : List String
  ||| Which client operation raised this, for diagnostics.
  operation : String

export
simpleError : ErrorKind -> String -> String -> ConvexError
simpleError kind' operation' message' =
  MkConvexError kind' message' JNull [] operation'

export
transportError : String -> String -> ConvexError
transportError = simpleError TransportFailure

export
protocolError : String -> String -> ConvexError
protocolError = simpleError ProtocolFailure

||| The adapter's wire shape for a failure. `data` is always present so the
||| controller can read `error.data.code` without a special case, and it is JSON
||| null rather than an omitted field when the function supplied nothing.
export
errorJson : ConvexError -> Json
errorJson failure =
  JObject
    [ ("name", JString (errorKindName (kind failure)))
    , ("message", JString (message failure))
    , ("data", errorData failure)
    ]
