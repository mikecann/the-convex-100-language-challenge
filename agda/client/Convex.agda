{-# OPTIONS --without-K #-}

-- The educational Convex surface.
--
-- This is what the canonical example and the README present. It re-exports the
-- JSON model, structured errors, and the client operations, and deliberately
-- omits the adapter-only fault-injection hook that lives in `Convex.Client`.
module Convex where

open import Convex.Prelude public
open import Convex.Prim public
  using (IO; _>>=_; _>>_; return
        ; getEnvironment; getArguments; exitProcess; initStandardStreams; randomBytes)
-- Raw stream access stays internal; the surface below exposes line output only.
open import Convex.Prim using (stdoutWrite; stderrLine)
open import Convex.Bytes public using (hexString)
open import Convex.Json public
open import Convex.Error public
open import Convex.Live public using (Update; updValue; updLogs; updError; updGeneration)
open import Convex.Client public
  using ( Client; newClient; setAuth
        ; clientQuery; clientMutation; clientAction
        ; clientSubscribe; clientNext; clientUnsubscribe; clientClose )

import Convex.Utf8 as Utf8

-- Program output. Stdout carries the transcript the shared verifier compares
-- byte for byte, so every diagnostic goes to stderr instead.
putLine : String → IO ⊤
putLine text = stdoutWrite (Utf8.encode (text <> "\n")) >> return tt

errLine : String → IO ⊤
errLine = stderrLine

-- A fresh 128-bit hexadecimal identifier drawn from the runtime's entropy
-- source. Convex uses it as a mutation idempotency key.
randomHex : IO String
randomHex = randomBytes 16 >>= λ entropy → return (hexString entropy)
