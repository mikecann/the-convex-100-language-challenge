{-# OPTIONS --without-K #-}

-- Convex over HTTP.
--
-- The request line, the header block, response framing, and the Convex
-- envelope are all built and parsed here in Agda. The foreign boundary only
-- moves octets, so this module is where a reviewer can see exactly what the
-- client sends to `/api/query`, `/api/mutation`, and `/api/action`, and how a
-- non-2xx or non-Convex reply becomes a structured error instead of a value.
module Convex.Http where

open import Convex.Prelude
open import Convex.Prim
open import Convex.Bytes
open import Convex.Reader
open import Convex.Error
open import Convex.Json
import Convex.Utf8 as Utf8

--------------------------------------------------------------------------------
-- Bounds
--------------------------------------------------------------------------------

-- A response is refused rather than buffered beyond this. It matches the JSON
-- decoder's ceiling, so nothing that survives framing can still be rejected
-- for size afterwards.
maxResponseOctets : Nat
maxResponseOctets = 1048576

connectMillis : Nat
connectMillis = 5000

exchangeMillis : Nat
exchangeMillis = 15000

writeMillis : Nat
writeMillis = 5000

--------------------------------------------------------------------------------
-- Small character helpers
--------------------------------------------------------------------------------

private
  prefixOf : List Char → List Char → Bool
  prefixOf [] _ = true
  prefixOf (_ ∷ _) [] = false
  prefixOf (a ∷ as) (b ∷ bs) = if a ==ᶜ b then prefixOf as bs else false

  countChar : Char → List Char → Nat
  countChar c = foldl (λ acc x → if x ==ᶜ c then suc acc else acc) 0

  breakOn : Char → List Char → Maybe (List Char × List Char)
  breakOn _ [] = nothing
  breakOn c (x ∷ xs) =
    if x ==ᶜ c then just ([] , xs) else extend (breakOn c xs)
    where
      extend : Maybe (List Char × List Char) → Maybe (List Char × List Char)
      extend nothing = nothing
      extend (just (before , after)) = just (x ∷ before , after)

  natOfDigits : List Char → Maybe Nat
  natOfDigits [] = nothing
  natOfDigits chars = go chars 0
    where
      go : List Char → Nat → Maybe Nat
      go [] acc = just acc
      go (c ∷ rest) acc = if isDigit c then go rest ((acc * 10) + (charCode c - 48)) else nothing

  trimTrailingSlash : List Char → List Char
  trimTrailingSlash chars = reverse (dropSlashes (reverse chars))
    where
      dropSlashes : List Char → List Char
      dropSlashes [] = []
      dropSlashes (c ∷ rest) = if c ==ᶜ '/' then dropSlashes rest else c ∷ rest

containsChar : Char → List Char → Bool
containsChar c = any (λ x → x ==ᶜ c)

-- Reject anything that could smuggle a second request line into a header.
-- The client applies this to the deployment URL, the client version, the
-- function path, and the bearer token.
safeHeaderValue : String → Bool
safeHeaderValue text =
  let chars = stringToList text in
  not (containsChar '\r' chars) ∧ not (containsChar '\n' chars)

--------------------------------------------------------------------------------
-- Deployment URLs
--------------------------------------------------------------------------------

record Deployment : Set where
  constructor deployment
  field
    secure : Bool
    host : String
    port : Nat
    authority : String

open Deployment public

private
  defaultPortFor : Bool → Nat
  defaultPortFor isSecure = if isSecure then 443 else 80

  buildDeployment : Bool → String → List Char → Maybe Nat → Either String Deployment
  buildDeployment _ _ _ nothing = left "deployment URL port is invalid"
  buildDeployment isSecure auth hostChars (just p) =
    if (p ==ⁿ 0) ∨ (p >ⁿ 65535) then left "deployment URL port is invalid"
    else if length hostChars ==ⁿ 0 then left "deployment URL host must not be empty"
    else right (deployment isSecure (stringFromList hostChars) p auth)

  splitHostPort : Bool → String → List Char → Either String Deployment
  splitHostPort isSecure auth chars =
    if countChar ':' chars ==ⁿ 0 then
      buildDeployment isSecure auth chars (just (defaultPortFor isSecure))
    else if countChar ':' chars ==ⁿ 1 then fromSplit (breakOn ':' chars)
    else left "deployment URL host is ambiguous; bracket an IPv6 literal"
    where
      fromSplit : Maybe (List Char × List Char) → Either String Deployment
      fromSplit nothing = left "deployment URL port is invalid"
      fromSplit (just (h , p)) = buildDeployment isSecure auth h (natOfDigits p)

  bracketedHost : Bool → String → List Char → Either String Deployment
  bracketedHost isSecure auth rest = closing (breakOn ']' rest)
    where
      closing : Maybe (List Char × List Char) → Either String Deployment
      closing nothing = left "deployment URL is missing a closing bracket"
      closing (just (h , [])) = buildDeployment isSecure auth h (just (defaultPortFor isSecure))
      closing (just (h , (':' ∷ p))) = buildDeployment isSecure auth h (natOfDigits p)
      closing (just (_ , (_ ∷ _))) = left "deployment URL port is invalid"

  authorityParts : Bool → List Char → Either String Deployment
  authorityParts _ [] = left "deployment URL host must not be empty"
  authorityParts isSecure ('[' ∷ rest) =
    if containsChar '@' rest then left "deployment URL must not contain credentials"
    else bracketedHost isSecure (stringFromList ('[' ∷ rest)) rest
  authorityParts isSecure chars =
    if containsChar '@' chars then left "deployment URL must not contain credentials"
    else splitHostPort isSecure (stringFromList chars) chars

  authorityOf : Nat → List Char → List Char
  authorityOf skip chars = beforeSlash (drop skip chars)
    where
      beforeSlash : List Char → List Char
      beforeSlash [] = []
      beforeSlash (c ∷ rest) = if c ==ᶜ '/' then [] else c ∷ beforeSlash rest

parseDeployment : String → Either String Deployment
parseDeployment text =
  if not (safeHeaderValue text) then left "deployment URL must not contain newlines"
  else if containsChar '?' chars ∨ containsChar '#' chars then
    left "deployment URL must not contain a query or fragment"
  else if prefixOf (stringToList "https://") chars then
    authorityParts true (authorityOf 8 chars)
  else if prefixOf (stringToList "http://") chars then
    authorityParts false (authorityOf 7 chars)
  else left "deployment URL must be an absolute HTTP(S) URL"
  where
    chars : List Char
    chars = trimTrailingSlash (stringToList text)

--------------------------------------------------------------------------------
-- Requests
--------------------------------------------------------------------------------

validFunctionPath : String → Bool
validFunctionPath path =
  let chars = stringToList path in
  (stringLength path ≥ⁿ 3) ∧ containsChar ':' chars
    ∧ not (containsChar '\r' chars) ∧ not (containsChar '\n' chars)

requestText : Deployment → String → String → String → String → String
requestText dep version token operation body =
  "POST /api/" <> operation <> " HTTP/1.1\r\n"
    <> "Host: " <> authority dep <> "\r\n"
    <> "Content-Type: application/json\r\n"
    <> "Accept: application/json\r\n"
    <> "Connection: close\r\n"
    <> "Convex-Client: " <> version <> "\r\n"
    <> "Content-Length: " <> showNat (Utf8.octetLength body) <> "\r\n"
    <> (if token ==ˢ "" then "" else "Authorization: Bearer " <> token <> "\r\n")
    <> "\r\n"
    <> body

callBody : String → JSON → String
callBody path args =
  encode (jobj (("path" , jstr path) ∷ ("args" , args) ∷ ("format" , jstr "json") ∷ []))

--------------------------------------------------------------------------------
-- Response framing
--------------------------------------------------------------------------------

record ResponseHead : Set where
  constructor responseHead
  field
    statusCode : Nat
    contentLength : Maybe Nat
    chunked : Bool
    bodyStart : Nat

open ResponseHead public

findBlankLine : Bytes → Nat → Maybe Nat
findBlankLine buffer from = go (size buffer) from
  where
    go : Nat → Nat → Maybe Nat
    go zero _ = nothing
    go (suc fuel) index =
      if index + 3 ≥ⁿ size buffer then nothing
      else if (octet buffer index ==ⁿ 13) ∧ (octet buffer (index + 1) ==ⁿ 10)
            ∧ (octet buffer (index + 2) ==ⁿ 13) ∧ (octet buffer (index + 3) ==ⁿ 10)
        then just (index + 4)
        else go fuel (suc index)

private
  -- Walk the header block once, keeping only the two fields that decide how
  -- the body is framed. Header names are matched case-insensitively.
  scanHeaders : Nat → Bytes → Nat → Nat → Maybe Nat → Bool → Either String (Maybe Nat × Bool)
  scanHeaders zero _ _ _ _ _ = left "HTTP header block is malformed"
  scanHeaders (suc fuel) buffer at headerEnd declared isChunked =
    if at + 1 ≥ⁿ headerEnd then right (declared , isChunked)
    else if (octet buffer at ==ⁿ 13) ∧ (octet buffer (suc at) ==ⁿ 10) then
      right (declared , isChunked)
    else onLine (findCRLF buffer at)
    where
      onLength : Nat → Maybe Nat → Either String (Maybe Nat × Bool)
      onLength _ nothing = left "HTTP Content-Length is not a number"
      onLength crlf (just n) = scanHeaders fuel buffer (crlf + 2) headerEnd (just n) isChunked

      onNamed : Nat → Maybe Nat → Either String (Maybe Nat × Bool)
      onNamed _ nothing = left "HTTP header line has no colon"
      onNamed crlf (just colon) =
        let valueFrom = trimSpacesFrom buffer (suc colon) crlf
            valueTo = trimSpacesTo buffer valueFrom crlf
        in
        if regionEqualsAsciiLower buffer at colon (asciiOctets "content-length") then
          onLength crlf (decimalIn buffer valueFrom valueTo)
        else if regionEqualsAsciiLower buffer at colon (asciiOctets "transfer-encoding") then
          scanHeaders fuel buffer (crlf + 2) headerEnd declared
            (regionEqualsAsciiLower buffer valueFrom valueTo (asciiOctets "chunked"))
        else scanHeaders fuel buffer (crlf + 2) headerEnd declared isChunked

      onLine : Maybe Nat → Either String (Maybe Nat × Bool)
      onLine nothing = left "HTTP header line is unterminated"
      onLine (just crlf) = onNamed crlf (findOctet buffer 58 at crlf)

parseHead : Bytes → Either String ResponseHead
parseHead buffer = located (findBlankLine buffer 0)
  where
    statusLineEnd : Nat
    statusLineEnd = fromMaybe 0 (findCRLF buffer 0)

    onCode : Maybe Nat → Either String Nat
    onCode nothing = left "HTTP status code is not a number"
    onCode (just n) =
      if (n <ⁿ 100) ∨ (n >ⁿ 599) then left "HTTP status code is out of range" else right n

    statusOf : Either String Nat
    statusOf =
      if not (regionEqualsAsciiLower buffer 0 7 (asciiOctets "http/1.")) then
        left "HTTP status line is invalid"
      else if not (octet buffer 8 ==ⁿ 32) then left "HTTP status line is invalid"
      else onCode (decimalIn buffer 9 12)

    assemble : Nat → Nat → Either String (Maybe Nat × Bool) → Either String ResponseHead
    assemble _ _ (left message) = left message
    assemble status headerEnd (right (declared , isChunked)) =
      right (responseHead status declared isChunked headerEnd)

    withStatus : Nat → Either String Nat → Either String ResponseHead
    withStatus _ (left message) = left message
    withStatus headerEnd (right status) =
      assemble status headerEnd
        (scanHeaders (size buffer) buffer (statusLineEnd + 2) headerEnd nothing false)

    located : Maybe Nat → Either String ResponseHead
    located nothing = left "HTTP response has no header block"
    located (just headerEnd) = withStatus headerEnd statusOf

--------------------------------------------------------------------------------
-- Body framing
--------------------------------------------------------------------------------

private
  -- Chunked transfer decoding. Each step re-checks the accumulated size
  -- against the cap, so a peer cannot stream past the budget one chunk at a
  -- time, and a declared chunk size is rejected before it is ever buffered.
  chunkedBody : Nat → Socket → Bytes → Nat → Nat → Nat → Bytes → IO (Either String Bytes)
  chunkedBody zero _ _ _ _ _ _ = return (left "chunked body did not terminate")
  chunkedBody (suc fuel) sock buffer cursor deadline cap acc =
    readLine sock buffer cursor deadline cap >>= onHeader
    where
      onData : Nat → Nat → Either String Bytes → IO (Either String Bytes)
      onData _ _ (left message) = return (left message)
      onData dataFrom chunkSize (right grown) =
        if not ((octet grown (dataFrom + chunkSize) ==ⁿ 13)
                  ∧ (octet grown (dataFrom + chunkSize + 1) ==ⁿ 10)) then
          return (left "chunked body is missing a chunk terminator")
        else
          chunkedBody fuel sock grown (dataFrom + chunkSize + 2) deadline cap
            (acc +++ slice grown dataFrom chunkSize)

      onSize : Nat → Bytes → Maybe Nat → IO (Either String Bytes)
      onSize _ _ nothing = return (left "chunked body has a malformed chunk size")
      onSize crlf grown (just chunkSize) =
        if chunkSize ==ⁿ 0 then return (right acc)
        else if size acc + chunkSize >ⁿ cap then
          return (left "peer exceeded the response byte budget")
        else
          readAtLeast sock grown (crlf + 2 + chunkSize + 2) deadline cap
            >>= onData (crlf + 2) chunkSize

      onHeader : Either String (Nat × Bytes) → IO (Either String Bytes)
      onHeader (left message) = return (left message)
      onHeader (right (crlf , grown)) =
        onSize crlf grown
          (hexIn grown cursor (fromMaybe crlf (findOctet grown 59 cursor crlf)))

readBody : Socket → Bytes → ResponseHead → Nat → IO (Either String Bytes)
readBody sock buffer head deadline =
  if chunked head then
    chunkedBody (maxResponseOctets + 64) sock buffer (bodyStart head) deadline
      maxResponseOctets emptyBytes
  else declared (contentLength head)
  where
    exact : Nat → Either String Bytes → Either String Bytes
    exact _ (left message) = left message
    exact n (right grown) = right (slice grown (bodyStart head) n)

    toEnd : Either String Bytes → Either String Bytes
    toEnd (left message) = left message
    toEnd (right grown) = right (slice grown (bodyStart head) (size grown - bodyStart head))

    declared : Maybe Nat → IO (Either String Bytes)
    declared nothing =
      readToEnd (maxResponseOctets + 64) sock buffer deadline maxResponseOctets
        >>= λ outcome → return (toEnd outcome)
    declared (just n) =
      if n >ⁿ maxResponseOctets then return (left "peer exceeded the response byte budget")
      else readAtLeast sock buffer (bodyStart head + n) deadline maxResponseOctets
             >>= λ outcome → return (exact n outcome)

--------------------------------------------------------------------------------
-- The Convex envelope
--------------------------------------------------------------------------------

-- Convex answers every documented HTTP endpoint with the same envelope. A
-- reply that does not carry a recognised `status` is protocol drift, and a
-- `status: "error"` reply is a real function failure carrying its own data and
-- log lines, never a successful value.
interpret : Nat → JSON → Either ConvexError CallResult
interpret status payload = withLogs (asStringList (objOr payload "logLines" (jarr [])))
  where
    functionFailure : List String → ConvexError
    functionFailure entries =
      convexError functionError
        (fromMaybe "Convex function failed" (asString (objOr payload "errorMessage" jnull)))
        (objOr payload "errorData" jnull)
        entries

    unknown : ConvexError
    unknown =
      protocolFailure ("HTTP " <> showNat status <> " response has an unknown Convex status")

    byStatus : List String → Maybe String → Either ConvexError CallResult
    byStatus entries (just "success") =
      if objHas payload "value"
        then right (callResult (objOr payload "value" jnull) entries)
        else left (protocolFailure "Convex success response has no value")
    byStatus entries (just "error") = left (functionFailure entries)
    byStatus _ _ = left unknown

    withLogs : Maybe (List String) → Either ConvexError CallResult
    withLogs nothing = left (protocolFailure "Convex logLines must be an array of strings")
    withLogs (just entries) = byStatus entries (asString (objOr payload "status" jnull))

--------------------------------------------------------------------------------
-- One call
--------------------------------------------------------------------------------

private
  decodeEnvelope : Nat → Bytes → Either ConvexError CallResult
  decodeEnvelope status body = fromJson (decodeBytes body)
    where
      fromJson : Either String JSON → Either ConvexError CallResult
      fromJson (left _) =
        left (transportFailure ("HTTP " <> showNat status <> " returned non-Convex JSON"))
      fromJson (right payload) = interpret status payload

  runExchange : Socket → Deployment → String → String → String → String →
                IO (Either ConvexError CallResult)
  runExchange sock dep version token operation body =
    deadlineFrom exchangeMillis >>= start
    where
      onBody : Nat → Either String Bytes → IO (Either ConvexError CallResult)
      onBody _ (left message) = return (left (transportFailure message))
      onBody status (right payload) = return (decodeEnvelope status payload)

      onHead : Nat → Bytes → Either String ResponseHead → IO (Either ConvexError CallResult)
      onHead _ _ (left message) = return (left (protocolFailure message))
      onHead deadline buffer (right head) =
        readBody sock buffer head deadline >>= onBody (statusCode head)

      onHeaderBlock : Nat → Either String (Nat × Bytes) → IO (Either ConvexError CallResult)
      onHeaderBlock _ (left message) = return (left (transportFailure message))
      onHeaderBlock deadline (right (_ , buffer)) = onHead deadline buffer (parseHead buffer)

      onSent : Nat → Either String ⊤ → IO (Either ConvexError CallResult)
      onSent _ (left message) = return (left (transportFailure message))
      onSent deadline (right _) =
        readUntil (maxResponseOctets + 64) sock emptyBytes
          (λ current → findBlankLine current 0) deadline maxResponseOctets
          >>= onHeaderBlock deadline

      start : Nat → IO (Either ConvexError CallResult)
      start deadline =
        writeAll sock (Utf8.encode (requestText dep version token operation body)) writeMillis
          >>= onSent deadline

-- `token` may be empty, in which case no Authorization header is sent at all.
httpCall : Deployment → String → String → String → String → JSON → Task CallResult
httpCall dep version token operation path args =
  if not (validFunctionPath path) then
    taskFail (protocolFailure "function path must be module:function")
  else if not (isObject args) then
    taskFail (protocolFailure "arguments must be a named JSON object")
  else if not (safeHeaderValue token) then
    taskFail (protocolFailure "auth token must not contain newlines")
  else
    socketConnect (host dep) (port dep) (secure dep) connectMillis >>= connected
  where
    release : Socket → Either ConvexError CallResult → IO (Either ConvexError CallResult)
    release sock outcome = socketClose sock >> return outcome

    connected : IOResult Socket → Task CallResult
    connected (ioErr diagnostic) =
      taskFail (transportFailure (operation <> " transport failed: " <> diagnostic))
    connected (ioOk sock) =
      runExchange sock dep version token operation (callBody path args) >>= release sock
