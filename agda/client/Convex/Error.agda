{-# OPTIONS --without-K #-}

-- Structured Convex failures and the small error-carrying IO monad the rest of
-- the client is written in.
--
-- Agda has no exceptions, which suits this project: a failed Convex call is a
-- value, so no layer can accidentally flatten a function error, a protocol
-- violation, or a dropped socket into a successful result.
module Convex.Error where

open import Convex.Prelude
open import Convex.Prim using (IO; _>>=_; _>>_; return)
open import Convex.Json

data ErrorKind : Set where
  functionError : ErrorKind
  protocolError : ErrorKind
  transportError : ErrorKind
  closedError : ErrorKind

-- The names the shared adapter schema and the conformance controller observe.
kindName : ErrorKind → String
kindName functionError = "FunctionError"
kindName protocolError = "ProtocolError"
kindName transportError = "TransportError"
kindName closedError = "ClosedError"

record ConvexError : Set where
  constructor convexError
  field
    kind : ErrorKind
    message : String
    payload : JSON
    logs : List String

open ConvexError public

errorName : ConvexError → String
errorName e = kindName (kind e)

simpleError : ErrorKind → String → ConvexError
simpleError k m = convexError k m jnull []

transportFailure : String → ConvexError
transportFailure = simpleError transportError

protocolFailure : String → ConvexError
protocolFailure = simpleError protocolError

closedFailure : String → ConvexError
closedFailure = simpleError closedError

record CallResult : Set where
  constructor callResult
  field
    resultValue : JSON
    resultLogs : List String

open CallResult public

--------------------------------------------------------------------------------
-- Error-carrying IO
--------------------------------------------------------------------------------

Task : Set → Set
Task A = IO (Either ConvexError A)

taskOk : {A : Set} → A → Task A
taskOk a = return (right a)

taskFail : {A : Set} → ConvexError → Task A
taskFail e = return (left e)

infixl 1 _>>=T_

private
  bindStep : {A B : Set} → (A → Task B) → Either ConvexError A → Task B
  bindStep _ (left e) = return (left e)
  bindStep f (right a) = f a

_>>=T_ : {A B : Set} → Task A → (A → Task B) → Task B
m >>=T f = m >>= bindStep f

