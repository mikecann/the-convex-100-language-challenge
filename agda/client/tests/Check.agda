{-# OPTIONS --without-K #-}

-- Minimal assertion support shared by the language-local test executables.
--
-- Failures are counted rather than thrown, so one run reports every broken
-- expectation instead of stopping at the first, and the process exit status is
-- what the Docker `test` stage checks.
module Check where

open import Convex.Prelude
open import Convex.Prim

record Tally : Set where
  constructor tally
  field
    ran : Nat
    failed : Nat

open Tally public

newTally : IO (MVar Tally)
newTally = newMVar (tally 0 0)

check : MVar Tally → Bool → String → IO ⊤
check cell holds label =
  takeMVar cell >>= λ current →
  putMVar cell (tally (suc (ran current)) (if holds then failed current else suc (failed current)))
    >> (if holds then return tt else stderrLine ("FAIL " <> label))

checkEqNat : MVar Tally → Nat → Nat → String → IO ⊤
checkEqNat cell actual expected label =
  check cell (actual ==ⁿ expected)
    (label <> ": expected " <> showNat expected <> " but got " <> showNat actual)

checkEqString : MVar Tally → String → String → String → IO ⊤
checkEqString cell actual expected label =
  check cell (actual ==ˢ expected) (label <> ": expected " <> expected <> " but got " <> actual)

-- Report and exit. A non-zero exit is what fails the Docker build.
finish : MVar Tally → String → IO ⊤
finish cell suite = readMVar cell >>= report
  where
    report : Tally → IO ⊤
    report current =
      stderrLine (suite <> ": " <> showNat (ran current) <> " checks, "
                    <> showNat (failed current) <> " failed")
        >> (if failed current ==ⁿ 0 then exitProcess 0 else exitProcess 1)
