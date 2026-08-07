{-# OPTIONS --without-K #-}

-- A real TLS exchange against a locally issued certificate.
--
-- The fixture peer is an `openssl s_server` started by the Docker test stage
-- and trusted through `SSL_CERT_FILE`. The point of this test is that the
-- client verifies the name it was asked to connect to, not merely the chain:
-- the same certificate must be accepted for `localhost` and refused for
-- `127.0.0.1`.
module TlsTest where

open import Convex.Prelude
open import Convex.Prim
open import Convex.Bytes
open import Convex.Reader
open import Check
import Convex.Utf8 as Utf8

private
  request : Bytes
  request = Utf8.encode "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n"

  -- Return the first response line, or the transport diagnostic.
  exchange : String → Nat → IO (Either String String)
  exchange hostName tlsPort = socketConnect hostName tlsPort true 4000 >>= opened
    where
      -- Named `closeAndReport`, not `finish`: this file also uses
      -- `Check.finish` (the suite's final report-and-exit, called below in
      -- `main`) unqualified via `open import Check`, and a local `where`
      -- binding cannot reuse that name.
      closeAndReport : Socket → Either String Bytes → IO (Either String String)
      closeAndReport s outcome = socketClose s >> return (firstLine outcome)
        where
          firstLine : Either String Bytes → Either String String
          firstLine (left m) = left m
          firstLine (right buffer) = onCRLF (findCRLF buffer 0)
            where
              onCRLF : Maybe Nat → Either String String
              onCRLF nothing = left "no status line"
              onCRLF (just at) = right (fromMaybe "" (Utf8.decodeRegion buffer 0 at))

      sent : Socket → Nat → Either String ⊤ → IO (Either String String)
      sent s _ (left m) = socketClose s >> return (left m)
      sent s deadline (right _) =
        readUntil 65536 s emptyBytes (λ current → findCRLF current 0) deadline 65536
          >>= λ outcome → closeAndReport s (strip outcome)
        where
          strip : Either String (Nat × Bytes) → Either String Bytes
          strip (left m) = left m
          strip (right (_ , buffer)) = right buffer

      opened : IOResult Socket → IO (Either String String)
      opened (ioErr m) = return (left m)
      opened (ioOk s) =
        deadlineFrom 6000 >>= λ deadline → writeAll s request 3000 >>= sent s deadline

  succeeded : Either String String → Bool
  succeeded (right _) = true
  succeeded (left _) = false

  statusOf : Either String String → String
  statusOf (right line) = line
  statusOf (left m) = "error: " <> m

  portOf : Maybe String → Nat
  portOf nothing = 8443
  portOf (just text) = fromMaybe 8443 (digits (stringToList text))
    where
      digits : List Char → Maybe Nat
      digits [] = nothing
      digits chars = go chars 0
        where
          go : List Char → Nat → Maybe Nat
          go [] acc = just acc
          go (c ∷ rest) acc = if isDigit c then go rest ((acc * 10) + (charCode c - 48)) else nothing

main : IO ⊤
main =
  initStandardStreams
    >> newTally >>= λ t →
    getEnvironment "TLS_FIXTURE_PORT" >>= λ configured →
    run t (portOf configured)
  where
    run : MVar Tally → Nat → IO ⊤
    run t tlsPort =
      exchange "localhost" tlsPort >>= λ trusted →
      check t (succeeded trusted)
        ("a certificate for the requested hostname is accepted: " <> statusOf trusted)
        >> exchange "127.0.0.1" tlsPort >>= λ mismatched →
        check t (not (succeeded mismatched))
          "a certificate that does not cover the requested address is rejected"
        >> finish t "tls-test"
