{-# OPTIONS --without-K #-}

-- Deterministic Live coverage against a raw WebSocket fixture.
--
-- The fixture is a real TCP peer speaking RFC6455 by hand, so the client's own
-- handshake, framing, envelope validation, and worker are exercised end to end
-- without a Convex deployment. It drives the failure modes a happy-path test
-- cannot reach:
--
--   * an initial `QueryUpdated`, then an external update delivered as two
--     fragments that split a multi-byte character;
--   * a ping the client must answer with a pong on the same connection;
--   * a `QueryFailed` followed by a later valid value on the same
--     subscription;
--   * five real reconnects driven by `debugDisconnect`, each of which must
--     resend the active `Add`, suppress an unchanged rehydration, and then
--     deliver the changed value.
--
-- Rejecting a frame header that declares an absurd payload is a pure property
-- of `scanFrame` and is covered in `ProtocolTest`, so it is not repeated here.
module LiveFixtureTest where

open import Convex.Prelude
open import Convex.Prim
open import Convex.Bytes
open import Convex.Reader
open import Convex.Json
open import Convex.Error
open import Convex.Digest using (xor8)
open import Convex.WebSocket
  using (opText; opPing; opPong; opClose; opContinuation; expectedAccept)
open import Convex.Http using (Deployment; deployment; findBlankLine)
open import Convex.Live
open import Check
import Convex.Base64 as B64
import Convex.Utf8 as Utf8

--------------------------------------------------------------------------------
-- Fixture framing (the mirror image of the client's)
--------------------------------------------------------------------------------

private
  -- Server frames are never masked.
  serverFrame : Bool → Nat → Bytes → Bytes
  serverFrame isFinal code body =
    fromOctets (((if isFinal then 128 else 0) + code) ∷ header) +++ body
    where
      n : Nat
      n = size body

      header : List Nat
      header =
        if n <ⁿ 126 then n ∷ []
        else 126 ∷ (n div 256) ∷ (n mod 256) ∷ []

  textFrame : String → Bytes
  textFrame text = serverFrame true opText (Utf8.encode text)

  unmask : List Nat → Nat → List Nat → List Nat
  unmask _ _ [] = []
  unmask key index (b ∷ rest) = xor8 b (nth key (index mod 4)) ∷ unmask key (suc index) rest
    where
      nth : List Nat → Nat → Nat
      nth [] _ = 0
      nth (x ∷ _) zero = x
      nth (_ ∷ more) (suc k) = nth more k

  record ClientFrame : Set where
    constructor clientFrame
    field
      cfOpcode : Nat
      cfPayload : Bytes
      cfRest : Bytes

  open ClientFrame

  -- Client frames are always masked, and the fixture only ever receives short
  -- control frames and Live envelopes, so the two length forms below cover the
  -- whole surface.
  scanClientFrame : Bytes → Maybe ClientFrame
  scanClientFrame buffer =
    if size buffer <ⁿ 2 then nothing
    else if not ((octet buffer 1 div 128) ==ⁿ 1) then nothing
    else sized (octet buffer 1 mod 128)
    where
      build : Nat → Nat → Maybe ClientFrame
      build headerOctets declared =
        if size buffer <ⁿ (headerOctets + 4 + declared) then nothing
        else
          just (clientFrame (octet buffer 0 mod 16)
                  (fromOctets (unmask (toOctets (slice buffer headerOctets 4)) 0
                                 (toOctets (slice buffer (headerOctets + 4) declared))))
                  (dropBytes (headerOctets + 4 + declared) buffer))

      sized : Nat → Maybe ClientFrame
      sized marker =
        if marker <ⁿ 126 then build 2 marker
        else if marker ==ⁿ 126 then
          (if size buffer <ⁿ 4 then nothing
           else build 4 ((octet buffer 2 * 256) + octet buffer 3))
        else nothing

--------------------------------------------------------------------------------
-- Fixture transport helpers
--------------------------------------------------------------------------------

private
  fixtureSlice : Nat
  fixtureSlice = 100

  -- Read until `ready` succeeds or the absolute deadline passes. The fixture
  -- has its own tiny reader so a failure here is never confused with the
  -- client's.
  pull : Nat → Socket → Bytes → (Bytes → Maybe Nat) → Nat → IO (Maybe (Nat × Bytes))
  pull zero _ _ _ _ = return nothing
  pull (suc fuel) s buffer ready deadline = onReady (ready buffer)
    where
      onFill : Fill → IO (Maybe (Nat × Bytes))
      onFill (filled grown) = pull fuel s grown ready deadline
      onFill fillTimeout = pull fuel s buffer ready deadline
      onFill fillEof = return nothing
      onFill (fillFailed _) = return nothing

      onReady : Maybe Nat → IO (Maybe (Nat × Bytes))
      onReady (just at) = return (just (at , buffer))
      onReady nothing =
        remainingMillis deadline >>= λ remaining →
        if remaining ==ⁿ 0 then return nothing
        else readChunk s buffer 4096 (min remaining fixtureSlice) >>= onFill

  frameReady : Bytes → Maybe Nat
  frameReady buffer = if isJust (scanClientFrame buffer) then just 0 else nothing

  nextClientFrame : Socket → Bytes → Nat → IO (Maybe ClientFrame)
  nextClientFrame s buffer deadline =
    pull 4096 s buffer frameReady deadline >>= λ found → return (unwrap found)
    where
      unwrap : Maybe (Nat × Bytes) → Maybe ClientFrame
      unwrap nothing = nothing
      unwrap (just (_ , grown)) = scanClientFrame grown

  keyFrom : Bytes → Nat → Maybe String
  keyFrom buffer headerEnd = go 64 (fromMaybe 0 (findCRLF buffer 0) + 2)
    where
      go : Nat → Nat → Maybe String
      go zero _ = nothing
      go (suc fuel) at =
        if at + 1 ≥ⁿ headerEnd then nothing
        else onLine (findCRLF buffer at)
        where
          onLine : Maybe Nat → Maybe String
          onLine nothing = nothing
          onLine (just crlf) = onColon (findOctet buffer 58 at crlf)
            where
              onColon : Maybe Nat → Maybe String
              onColon nothing = go fuel (crlf + 2)
              onColon (just colon) =
                if regionEqualsAsciiLower buffer at colon (asciiOctets "sec-websocket-key")
                  then Utf8.decodeRegion buffer (trimSpacesFrom buffer (suc colon) crlf)
                         (trimSpacesTo buffer (trimSpacesFrom buffer (suc colon) crlf) crlf
                           - trimSpacesFrom buffer (suc colon) crlf)
                  else go fuel (crlf + 2)

  handshake : Socket → Nat → IO (Maybe Bytes)
  handshake s deadline =
    pull 4096 s emptyBytes (λ current → findBlankLine current 0) deadline >>= onHead
    where
      reply : Bytes → Nat → String → IO (Maybe Bytes)
      reply buffer headerEnd clientKey =
        writeAll s (Utf8.encode ("HTTP/1.1 101 Switching Protocols\r\n"
                                   <> "Upgrade: websocket\r\nConnection: Upgrade\r\n"
                                   <> "Sec-WebSocket-Accept: " <> expectedAccept clientKey
                                   <> "\r\n\r\n")) 2000
          >> return (just (dropBytes headerEnd buffer))

      onHead : Maybe (Nat × Bytes) → IO (Maybe Bytes)
      onHead nothing = return nothing
      onHead (just (headerEnd , buffer)) = onKey (keyFrom buffer headerEnd)
        where
          onKey : Maybe String → IO (Maybe Bytes)
          onKey nothing = return nothing
          onKey (just clientKey) = reply buffer headerEnd clientKey

--------------------------------------------------------------------------------
-- Scripted Live envelopes
--------------------------------------------------------------------------------

private
  versionText : Nat → Nat → String
  versionText querySet ts =
    "{\"querySet\":" <> showNat querySet <> ",\"identity\":0,\"ts\":\""
      <> B64.timestampEncode ts <> "\"}"

  transitionText : Nat → Nat → Nat → Nat → String → String
  transitionText startSet startTs endSet endTs modifications =
    "{\"type\":\"Transition\",\"startVersion\":" <> versionText startSet startTs
      <> ",\"endVersion\":" <> versionText endSet endTs
      <> ",\"modifications\":[" <> modifications <> "]}"

  updatedText : Nat → String
  updatedText count =
    "{\"type\":\"QueryUpdated\",\"queryId\":0,\"value\":{\"count\":" <> showNat count
      <> ",\"note\":\"世界\"},\"logLines\":[]}"

  failedText : String
  failedText =
    "{\"type\":\"QueryFailed\",\"queryId\":0,\"errorMessage\":\"room empty\""
      <> ",\"errorData\":{\"code\":\"ROOM_EMPTY\"},\"logLines\":[]}"

  -- Split one text message so a multi-byte character straddles the boundary,
  -- which is the case a naive per-fragment UTF-8 check gets wrong.
  fragmentedFrames : String → Nat → List Bytes
  fragmentedFrames text at =
    serverFrame false opText (slice body 0 at)
      ∷ serverFrame true opContinuation (dropBytes at body) ∷ []
    where
      body : Bytes
      body = Utf8.encode text

--------------------------------------------------------------------------------
-- The fixture session
--------------------------------------------------------------------------------

private
  sendAll : Socket → List Bytes → IO ⊤
  sendAll _ [] = return tt
  sendAll s (b ∷ rest) = writeAll s b 2000 >> sendAll s rest

  -- Wait for the client's Connect and its ModifyQuerySet, and report whether
  -- the query-set message carried an `Add`. Every reconnect must resend it.
  expectOpening : Socket → Bytes → Nat → IO (Bool × Bytes)
  expectOpening s buffer deadline = step 8 buffer false false
    where
      contains : String → String → Bool
      contains haystack needle = search (stringToList haystack)
        where
          needleChars : List Char
          needleChars = stringToList needle

          startsWith : List Char → List Char → Bool
          startsWith [] _ = true
          startsWith (_ ∷ _) [] = false
          startsWith (a ∷ as) (b ∷ bs) = if a ==ᶜ b then startsWith as bs else false

          search : List Char → Bool
          search [] = startsWith needleChars []
          search (c ∷ rest) = if startsWith needleChars (c ∷ rest) then true else search rest

      step : Nat → Bytes → Bool → Bool → IO (Bool × Bytes)
      step zero current _ sawAdd = return (sawAdd , current)
      step (suc fuel) current sawConnect sawAdd =
        nextClientFrame s current deadline >>= onFrame
        where
          -- `onText` has to be defined before `onFrame` below: Agda's
          -- `where` clauses check declarations in order and do not scan
          -- every sibling's signature up front the way a `mutual` block
          -- does, so `onFrame` could not otherwise call it.
          onText : Maybe String → Bytes → IO (Bool × Bytes)
          onText nothing rest = step fuel rest sawConnect sawAdd
          onText (just body) rest =
            if contains body "\"Connect\"" then step fuel rest true sawAdd
            else if contains body "\"Add\"" then
              (if sawConnect then return (true , rest) else step fuel rest sawConnect true)
            else step fuel rest sawConnect sawAdd

          onFrame : Maybe ClientFrame → IO (Bool × Bytes)
          onFrame nothing = return (sawAdd , current)
          onFrame (just f) = onText (Utf8.decode (cfPayload f)) (cfRest f)

  -- Answer pings and swallow anything else until the peer goes away. Running
  -- this after the script keeps the connection alive for the client's own
  -- deadlines.
  drainSession : Nat → Socket → Bytes → Nat → MVar Tally → IO ⊤
  drainSession zero _ _ _ _ = return tt
  drainSession (suc fuel) s buffer deadline t = nextClientFrame s buffer deadline >>= onFrame
    where
      onFrame : Maybe ClientFrame → IO ⊤
      onFrame nothing = return tt
      onFrame (just f) =
        if cfOpcode f ==ⁿ opPing then
          writeAll s (serverFrame true opPong (cfPayload f)) 2000
            >> drainSession fuel s (cfRest f) deadline t
        else if cfOpcode f ==ⁿ opClose then return tt
        else drainSession fuel s (cfRest f) deadline t

  -- Connection 0 carries the whole first-connection script; every later
  -- connection is a reconnect that must resend the Add before it is fed a
  -- suppressed rehydration and then a changed value.
  session : MVar Tally → Nat → Socket → IO ⊤
  session t index s = deadlineFrom 15000 >>= started
    where
      firstScript : Bytes → IO ⊤
      firstScript rest =
        sendAll s (textFrame (transitionText 0 0 1 10 (updatedText 0)) ∷ [])
          >> sleepMillis 150
          >> sendAll s (fragmentedFrames (transitionText 1 10 1 20 (updatedText 1)) 40)
          >> sleepMillis 150
          >> sendAll s (serverFrame true opPing (Utf8.encode "hb") ∷ [])
          >> sleepMillis 150
          >> sendAll s (textFrame (transitionText 1 20 1 30 failedText) ∷ [])
          >> sleepMillis 150
          >> sendAll s (textFrame (transitionText 1 30 1 40 (updatedText 2)) ∷ [])
          >> return tt

      reconnectScript : Bytes → IO ⊤
      reconnectScript _ =
        -- The same value the client last published: it must be suppressed.
        sendAll s (textFrame (transitionText 0 0 1 (10 * (index + 4)) (updatedText (index + 1))) ∷ [])
          >> sleepMillis 150
          >> sendAll s (textFrame (transitionText 1 (10 * (index + 4)) 1 (10 * (index + 5))
                                     (updatedText (index + 2))) ∷ [])
          >> return tt

      script : Bool × Bytes → Nat → IO ⊤
      script (sawAdd , rest) deadline =
        check t sawAdd ("connection " <> showNat index <> " resent its active Add")
          >> (if index ==ⁿ 0 then firstScript rest else reconnectScript rest)
          >> drainSession 256 s rest deadline t

      started : Nat → IO ⊤
      started deadline = handshake s deadline >>= onHandshake
        where
          onHandshake : Maybe Bytes → IO ⊤
          onHandshake nothing =
            check t false ("connection " <> showNat index <> " completed its handshake")
          onHandshake (just rest) = expectOpening s rest deadline >>= λ opened → script opened deadline

  serveLoop : Nat → MVar Tally → Listener → MVar Nat → IO ⊤
  serveLoop zero _ _ _ = return tt
  serveLoop (suc fuel) t listener counter = listenerAccept listener >>= onAccept
    where
      onAccept : IOResult Socket → IO ⊤
      onAccept (ioErr _) = return tt
      onAccept (ioOk s) =
        takeMVar counter >>= λ index →
        putMVar counter (suc index)
          >> session t index s
          >> socketClose s
          >> serveLoop fuel t listener counter

--------------------------------------------------------------------------------
-- Assertions
--------------------------------------------------------------------------------

private
  countOf : Maybe Update → Maybe Nat
  countOf nothing = nothing
  countOf (just u) = onError (updError u)
    where
      onError : Maybe ConvexError → Maybe Nat
      onError (just _) = nothing
      onError nothing = asNat (objOr (updValue u) "count" jnull)

  errorCodeOf : Maybe Update → String
  errorCodeOf nothing = "<none>"
  errorCodeOf (just u) = onError (updError u)
    where
      onError : Maybe ConvexError → String
      onError nothing = "<value>"
      onError (just e) = fromMaybe "<no code>" (asString (objOr (payload e) "code" jnull))

  expectCount : MVar Tally → Live → Nat → Nat → String → IO ⊤
  expectCount t manager qid expected label =
    nextUpdate manager qid 8000 >>= λ observed →
    check t (fromMaybe 9999 (countOf observed) ==ⁿ expected)
      (label <> ": expected " <> showNat expected <> " but got "
         <> showNat (fromMaybe 9999 (countOf observed)))

  reconnectRound : MVar Tally → Live → Nat → Nat → IO ⊤
  reconnectRound t manager qid round =
    debugDisconnect manager >>= onAck
    where
      onAck : Either ConvexError Nat → IO ⊤
      onAck (left e) =
        check t false ("reconnect " <> showNat round <> " acknowledged: " <> message e)
      onAck (right _) =
        -- The exact sequence must be the disconnect acknowledgement followed
        -- by the changed value: the unchanged rehydration is suppressed.
        expectCount t manager qid (round + 2)
          ("reconnect " <> showNat round <> " delivered the changed value after rehydration")

  reconnectRounds : Nat → Nat → MVar Tally → Live → Nat → IO ⊤
  reconnectRounds zero _ _ _ _ = return tt
  reconnectRounds (suc remaining) round t manager qid =
    reconnectRound t manager qid round >> reconnectRounds remaining (suc round) t manager qid

  runClient : MVar Tally → Nat → IO ⊤
  runClient t fixturePort =
    startLive (deployment false "127.0.0.1" fixturePort
                 ("127.0.0.1:" <> showNat fixturePort)) "agda-0.1.0"
      >>= subscribed
    where
      onSubscribed : Live → Either ConvexError Nat → IO ⊤
      onSubscribed _ (left e) = check t false ("subscribe succeeded: " <> message e)
      onSubscribed manager (right qid) =
        expectCount t manager qid 0 "the initial Live value hydrates the query"
          -- The external update arrives as two fragments splitting a
          -- multi-byte character.
          >> expectCount t manager qid 1 "a fragmented external update is reassembled"
          >> nextUpdate manager qid 8000 >>= λ failure →
            checkEqString t (errorCodeOf failure) "ROOM_EMPTY"
              "a QueryFailed is published as a structured function error"
          >> expectCount t manager qid 2 "the same subscription recovers after QueryFailed"
          >> reconnectRounds 5 1 t manager qid
          >> unsubscribe manager qid >>= λ _ →
            nextUpdate manager qid 400 >>= λ afterRemove →
            check t (not (isJust afterRemove)) "no value crosses the unsubscribe barrier"
          >> closeLive manager >> return tt

      subscribed : Live → IO ⊤
      subscribed manager =
        subscribe manager "demo:state" (jobj (("room" , jstr "fixture") ∷ []))
          >>= onSubscribed manager

main : IO ⊤
main =
  initStandardStreams >> newTally >>= λ t →
  listenerOpen "127.0.0.1" 0 >>= onListener t
  where
    onListener : MVar Tally → IOResult Listener → IO ⊤
    onListener t (ioErr m) = stderrLine ("fixture listen failed: " <> m) >> exitProcess 1
    onListener t (ioOk listener) =
      listenerPort listener >>= λ fixturePort →
      newMVar 0 >>= λ counter →
      forkThread (serveLoop 16 t listener counter)
        >> sleepMillis 50
        >> runClient t fixturePort
        >> listenerClose listener
        >> finish t "live-fixture-test"
