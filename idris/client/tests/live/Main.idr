||| Live tests against real forked raw-WebSocket fixtures.
|||
||| Each phase forks a child that speaks RFC 6455 and the pinned Convex sync
||| profile by hand, so the client exercises its own handshake, framing,
||| transition application, reconnect, and delivery bounds rather than a mock.
module Main

import Data.IORef
import Data.List
import Data.Maybe
import Data.String
import System
import System.File

import Convex.Codec
import Convex.Error
import Convex.Json
import Convex.Live
import Convex.Net
import Convex.Prim
import Convex.Update
import Convex.Ws

check : IORef Int -> String -> Bool -> IO ()
check failures label ok =
  if ok
     then putStrLn ("ok   " ++ label)
     else do modifyIORef failures (+ 1)
             ignore $ fPutStrLn stderr ("FAIL " ++ label)
             putStrLn ("FAIL " ++ label)

--------------------------------------------------------------------------------
-- Server-side framing for the fixture
--------------------------------------------------------------------------------

||| Write one unmasked server frame. Servers must not mask, which is also what
||| the client asserts when it reads.
covering
serverFrame : Connection -> (final : Bool) -> (opcode : Int) -> String -> IO ()
serverFrame link final' opcode text =
  do size <- textSize text
     scratch <- bufNew (size + 16)
     if scratch < 0
        then pure ()
        else do ignore $ bufSet scratch 0 ((if final' then 128 else 0) + opcode)
                start <- if size < 126
                            then do ignore $ bufSet scratch 1 size
                                    pure 2
                            else do ignore $ bufSet scratch 1 126
                                    ignore $ bufSet scratch 2 (div size 256)
                                    ignore $ bufSet scratch 3 (mod size 256)
                                    pure 4
                ignore $ bufPutText scratch start text
                deadline <- deadlineIn 5000
                ignore $ writeAll link scratch 0 (start + size) deadline
                bufFree scratch

||| Split a text message across continuation frames so the client has to
||| reassemble it before it can parse anything.
covering
serverFragments : Connection -> List String -> IO ()
serverFragments link [] = pure ()
serverFragments link [only] = serverFrame link True 1 only
serverFragments link (first :: rest) =
  do serverFrame link False 1 first
     continue rest
  where
    covering
    continue : List String -> IO ()
    continue [] = pure ()
    continue [final'] = serverFrame link True 0 final'
    continue (piece :: more) =
      do serverFrame link False 0 piece
         continue more

||| Read one client frame and unmask it. Only the shapes the client sends are
||| supported: small text frames and control frames.
covering
serverRead : Connection -> Int -> IO (Maybe (Int, String))
serverRead link deadline =
  do scratch <- bufNew 65536
     if scratch < 0
        then pure Nothing
        else do header <- readExact link scratch 0 2 deadline
                case header of
                     Left _ => do bufFree scratch
                                  pure Nothing
                     Right () => sized scratch
  where
    -- xorBytes, unmask, and payload are all defined before sized, which
    -- (transitively) calls all three, per the where-block ordering rule
    -- (see the Convex.Ws await/upgrade note).
    xorBytes : Int -> Int -> Int
    xorBytes left right = go 1 0
      where
        covering
        go : Int -> Int -> Int
        go weight acc =
          if weight > 128
             then acc
             else let a = mod (div left weight) 2
                      b = mod (div right weight) 2 in
                  go (weight * 2) (acc + (if a == b then 0 else weight) * 1)

    covering
    unmask : Int -> Int -> Int -> IO ()
    unmask scratch size index =
      if index >= size
         then pure ()
         else do keyByte <- bufGet scratch (mod index 4)
                 value <- bufGet scratch (8 + index)
                 ignore $ bufSet scratch (8 + index) (xorBytes value keyByte)
                 unmask scratch size (index + 1)

    covering
    payload : Int -> Int -> Int -> IO (Maybe (Int, String))
    payload scratch opcode size =
      do maskRead <- readExact link scratch 0 4 deadline
         case maskRead of
              Left _ => do bufFree scratch
                           pure Nothing
              Right () =>
                do body <- readExact link scratch 8 size deadline
                   case body of
                        Left _ => do bufFree scratch
                                     pure Nothing
                        Right () =>
                          do unmask scratch size 0
                             text <- bufTakeText scratch 8 size
                             bufFree scratch
                             pure (map (\value => (opcode, value)) text)

    covering
    sized : Int -> IO (Maybe (Int, String))
    sized scratch =
      do byte0 <- bufGet scratch 0
         byte1 <- bufGet scratch 1
         let opcode = mod byte0 16
         let marker = mod byte1 128
         extended <- if marker == 126
                        then do more <- readExact link scratch 2 2 deadline
                                case more of
                                     Left _ => pure (-1)
                                     Right () =>
                                       do high <- bufGet scratch 2
                                          low <- bufGet scratch 3
                                          pure (high * 256 + low)
                        else pure marker
         if extended < 0 || extended > 60000 || byte1 < 128
            then do bufFree scratch
                    pure Nothing
            else payload scratch opcode extended

||| Complete the RFC 6455 upgrade the client asked for.
covering
serverUpgrade : Connection -> Int -> IO Bool
serverUpgrade link deadline = collect Nothing 0
  where
    -- update, isRight, and finish are all defined before collect, which
    -- calls update and finish (and finish itself calls isRight), per the
    -- where-block ordering rule (see the Convex.Ws await/upgrade note).
    update : Maybe String -> String -> Maybe String
    update key text =
      let name = toLower (fst (span (/= ':') text))
          rest = snd (span (/= ':') text) in
      if name == "sec-websocket-key" && rest /= ""
         then Just (trim (substr 1 (length rest) rest))
         else key

    isRight : Either a b -> Bool
    isRight (Right _) = True
    isRight (Left _) = False

    covering
    finish : Maybe String -> IO Bool
    finish Nothing = pure False
    finish (Just key) =
      do let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                          ++ "Connection: Upgrade\r\nSec-WebSocket-Accept: "
                          ++ expectedAccept key ++ "\r\n\r\n"
         sent <- writeText link response deadline
         pure (isRight sent)

    covering
    collect : Maybe String -> Int -> IO Bool
    collect key seen =
      if seen > 64
         then pure False
         else do line <- readLine link 8192 deadline
                 case line of
                      Left _ => pure False
                      Right "" => finish key
                      Right text => collect (update key text) (seen + 1)

--------------------------------------------------------------------------------
-- Sync-profile messages
--------------------------------------------------------------------------------

stamp : Integer -> String
stamp value = fromMaybe "AAAAAAAAAAA=" (encodeTimestamp value)

version : Int -> Integer -> String
version querySet' at =
  "{\"querySet\":" ++ show querySet' ++ ",\"identity\":0,\"ts\":\"" ++ stamp at ++ "\"}"

transition : Int -> Integer -> Int -> Integer -> String -> String
transition fromSet fromAt toSet toAt modifications =
  "{\"type\":\"Transition\",\"startVersion\":" ++ version fromSet fromAt
    ++ ",\"endVersion\":" ++ version toSet toAt
    ++ ",\"modifications\":[" ++ modifications ++ "]}"

queryUpdated : Int -> String -> String
queryUpdated queryId value =
  "{\"type\":\"QueryUpdated\",\"queryId\":" ++ show queryId ++ ",\"value\":" ++ value
    ++ ",\"logLines\":[]}"

queryFailed : Int -> String -> String
queryFailed queryId code =
  "{\"type\":\"QueryFailed\",\"queryId\":" ++ show queryId
    ++ ",\"errorMessage\":\"room is empty\",\"errorData\":{\"code\":\"" ++ code
    ++ "\"},\"logLines\":[]}"

||| Pull the query identifiers out of a `ModifyQuerySet` the client sent. A
||| reconnect must resend every active `Add`, and this is how the fixture sees
||| that it did.
covering
addedQueryIds : String -> IO (List Int)
addedQueryIds text =
  do parsed <- parseJsonText text
     pure (case parsed of
                Left _ => []
                Right value =>
                  case field "modifications" value >>= asArray of
                       Nothing => []
                       Just items =>
                         mapMaybe (\item =>
                                     case map asString (field "type" item) of
                                          Just (Just "Add") =>
                                            field "queryId" item >>= wholeNumber
                                          _ => Nothing)
                                  items)

||| Read the client's opening `Connect` and its first `ModifyQuerySet`.
covering
readOpening : Connection -> Int -> IO (List Int)
readOpening link deadline =
  do hello <- serverRead link deadline
     case hello of
          Nothing => pure []
          Just _ =>
            do modification <- serverRead link deadline
               case modification of
                    Nothing => pure []
                    Just (_, text) => addedQueryIds text

--------------------------------------------------------------------------------
-- Client construction
--------------------------------------------------------------------------------

settingsFor : Int -> Int -> Int -> Int -> LiveConfig
settingsFor portNumber frameBudget deliveries deliveryBytes =
  MkLiveConfig (MkEndpoint False "127.0.0.1" portNumber "/api/sync") "" "idris-tests"
               5000 frameBudget deliveries deliveryBytes 50 400

covering
startLive : Int -> Int -> Int -> Int -> IO (Maybe Live)
startLive portNumber frameBudget deliveries deliveryBytes =
  do created <- newLive (settingsFor portNumber frameBudget deliveries deliveryBytes)
     pure (either (const Nothing) Just created)

covering
listenLocal : IO (Maybe (Int, Int))
listenLocal =
  do listener <- tcpListen "127.0.0.1" 0
     if listener < 0
        then pure Nothing
        else do portNumber <- tcpPort listener
                pure (Just (listener, portNumber))

--------------------------------------------------------------------------------
-- Phase one: the happy path, failures, fragments, and control frames
--------------------------------------------------------------------------------

covering
phaseOneFixture : Int -> IO ()
phaseOneFixture listener =
  do deadline <- deadlineIn 30000
     accepted <- acceptConnection listener "" "" deadline 65536
     case accepted of
          Left _ => pure ()
          Right link =>
            do upgraded <- serverUpgrade link deadline
               when upgraded (converse link)
               closeConnection link
  where
    -- splitThree and script are defined before converse, which (transitively,
    -- via script) calls both, per the where-block ordering rule (see the
    -- Convex.Ws await/upgrade note).
    splitThree : String -> List String
    splitThree text =
      -- substr takes Nat positions, and String's `length` returns a Nat, but
      -- Nat has no `Integral` instance for `div`. Do the division in Int and
      -- cast the (non-negative) result back to Nat for substr's arguments.
      let size = length text
          chunk = the Nat (cast (div (the Int (cast size)) 3))
          first = substr 0 chunk text
          second = substr chunk chunk text
          third = substr (2 * chunk) size text in
      [first, second, third]

    covering
    script : Connection -> Int -> IO ()
    script link queryId =
      do -- The initial value, split across three continuation frames so the
         -- client has to reassemble it before it can parse anything.
         let initial = transition 0 0 1 10 (queryUpdated queryId "{\"count\":0}")
         serverFragments link (splitThree initial)
         -- A protocol-level ping while the subscription is live: the client
         -- must answer with a pong without disturbing the message stream.
         serverFrame link True 9 "keepalive"
         -- Consume the client's pong so the stream stays in step.
         ignore $ do deadline <- deadlineIn 10000
                     serverRead link deadline
         -- An unsolicited pong is legal and must simply be ignored.
         serverFrame link True 10 ""
         -- An external mutation lands.
         serverFrame link True 1
           (transition 1 10 1 20 (queryUpdated queryId "{\"count\":1}"))
         -- The reactive query then fails, and is later repaired.
         serverFrame link True 1 (transition 1 20 1 30 (queryFailed queryId "ROOM_EMPTY"))
         serverFrame link True 1
           (transition 1 30 1 40 (queryUpdated queryId "{\"count\":2}"))
         -- Finally a burst the delivery bound has to trim.
         serverFrame link True 1
           (transition 1 40 1 50 (queryUpdated queryId "{\"count\":3}"))
         serverFrame link True 1
           (transition 1 50 1 60 (queryUpdated queryId "{\"count\":4}"))
         serverFrame link True 1
           (transition 1 60 1 70 (queryUpdated queryId "{\"count\":5}"))
         sleepMs 3000

    covering
    converse : Connection -> IO ()
    converse link =
      do deadline <- deadlineIn 30000
         added <- readOpening link deadline
         case added of
              [] => pure ()
              (queryId :: _) => script link queryId

covering
phaseOne : IORef Int -> Int -> IO ()
phaseOne failures portNumber =
  do started <- startLive portNumber 5000 2 (1024 * 1024)
     case started of
          Nothing => check failures "phase one built a Live client" False
          Just manager => exercise manager
  where
    -- drain, valueIs, and steps are all defined before exercise, which
    -- (transitively, via steps) calls all three, per the where-block
    -- ordering rule (see the Convex.Ws await/upgrade note).
    --
    -- Takes what is already queued without pumping again, so the assertion
    -- sees the retained set rather than whatever arrives next.
    covering
    drain : Live -> Int -> List Json -> IO (List Json)
    drain manager queryId acc =
      do taken <- takeDelivery manager
         case taken of
              Nothing => pure acc
              Just (owner, update) =>
                if owner /= queryId
                   then drain manager queryId acc
                   else case updateValue update of
                             Nothing => drain manager queryId acc
                             Just value => drain manager queryId (acc ++ [value])

    valueIs : Maybe LiveUpdate -> Json -> Bool
    valueIs update expected = (update >>= updateValue) == Just expected

    covering
    steps : Live -> Int -> IO ()
    steps manager queryId =
      do initial <- awaitUpdate manager queryId 10000
         check failures "a fragmented initial transition is reassembled"
           (valueIs initial (JObject [("count", jsonInt 0)]))

         external <- awaitUpdate manager queryId 10000
         check failures "an external update arrives without polling"
           (valueIs external (JObject [("count", jsonInt 1)]))

         failed <- awaitUpdate manager queryId 10000
         check failures "a reactive failure stays a typed subscription error"
           -- The Applicative/Monad used by `>>=` is only pinned down by how
           -- the case alternatives use the result, and Idris2 does not push
           -- that expected type back into the scrutinee (see the identical
           -- note on Convex.Live's `traverse parseModification` scrutinee).
           (case the (Maybe ConvexError) (failed >>= updateError) of
                 Just failure => kind failure == FunctionFailure
                                   && errorData failure
                                        == JObject [("code", JString "ROOM_EMPTY")]
                 Nothing => False)

         repaired <- awaitUpdate manager queryId 10000
         check failures "the same subscription recovers after its error"
           (valueIs repaired (JObject [("count", jsonInt 2)]))

         -- Three more states arrive while nothing is reading. `pumpReady`
         -- applies all of them without stopping at the first, so the bound is
         -- exercised: the queue keeps two, dropping the oldest intermediate
         -- state rather than the newest.
         sleepMs 500
         pumpReady manager
         sleepMs 200
         pumpReady manager
         retained <- drain manager queryId []
         check failures "a slow consumer keeps the newest bounded states"
           (cast (length retained) <= the Int 2
              && last' retained == Just (JObject [("count", jsonInt 5)]))

         maximumStamp <- liveMaxObservedTimestamp manager
         check failures "the maximum observed timestamp advances" (maximumStamp >= 50)

         closeLive manager

    covering
    exercise : Live -> IO ()
    exercise manager =
      do subscribed <- subscribeLive manager "demo:state" (JObject [("room", JString "a")])
         case subscribed of
              Left failure =>
                check failures ("phase one subscribed: " ++ message failure) False
              Right queryId => steps manager queryId

--------------------------------------------------------------------------------
-- Phase two: five genuine reconnect and hydration cycles
--------------------------------------------------------------------------------

covering
reconnectFixture : Int -> Int -> IO ()
reconnectFixture listener remaining =
  if remaining < 0
     then pure ()
     else do deadline <- deadlineIn 30000
             accepted <- acceptConnection listener "" "" deadline 65536
             case accepted of
                  Left _ => pure ()
                  Right link =>
                    do upgraded <- serverUpgrade link deadline
                       when upgraded (cycle' link deadline)
                       closeConnection link
                       reconnectFixture listener (remaining - 1)
  where
    covering
    cycle' : Connection -> Int -> IO ()
    cycle' link deadline =
      do added <- readOpening link deadline
         case added of
              [] => pure ()
              (queryId :: _) =>
                do -- Every new connection rehydrates with the value the client
                   -- already has. It must suppress that, so the only update the
                   -- caller sees is the change that follows. The client's
                   -- suppression is a digest match against the value it last
                   -- actually received, not "rehydration frames are always
                   -- ignored" -- so this has to resend that same value, not a
                   -- hardcoded "count:0" that was only ever right for the very
                   -- first reconnect. A stale rehydration value fails the
                   -- client's digest match, gets (wrongly) delivered as a
                   -- real update ahead of the genuine change, and the test's
                   -- single `awaitUpdate` call then reads that leaked stale
                   -- value instead of the one it is asserting on.
                   let known = if remaining >= 4 then 0 else 4 - remaining
                   serverFrame link True 1
                     (transition 0 0 1 10
                        (queryUpdated queryId ("{\"count\":" ++ show known ++ "}")))
                   when (remaining < 5)
                     (serverFrame link True 1
                        (transition 1 10 1 (20 + cast (5 - remaining))
                           (queryUpdated queryId
                              ("{\"count\":" ++ show (5 - remaining) ++ "}"))))
                   sleepMs 4000

covering
phaseTwo : IORef Int -> Int -> IO ()
phaseTwo failures portNumber =
  do started <- startLive portNumber 5000 16 (1024 * 1024)
     case started of
          Nothing => check failures "phase two built a Live client" False
          Just manager => exercise manager
  where
    -- isRightUnit and cycles are defined before exercise, which
    -- (transitively, via cycles) calls both, per the where-block ordering
    -- rule (see the Convex.Ws await/upgrade note).
    isRightUnit : Either ConvexError () -> Bool
    isRightUnit (Right ()) = True
    isRightUnit (Left _) = False

    covering
    cycles : Live -> Int -> Int -> IO ()
    cycles manager queryId attempt =
      if attempt > 5
         then do count <- liveConnectionCount manager
                 check failures "five reconnects were genuinely made" (count >= 5)
         else do dropped <- debugDisconnectLive manager
                 reason <- liveLastCloseReason manager
                 check failures ("cycle " ++ show attempt ++ " retired the connection")
                   (isRightUnit dropped && reason == "DebugDisconnect")
                 update <- awaitUpdate manager queryId 20000
                 check failures ("cycle " ++ show attempt
                                   ++ " rehydrated and delivered only the change")
                   ((update >>= updateValue)
                      == Just (JObject [("count", jsonInt attempt)]))
                 backoff <- liveBackoff manager
                 check failures ("cycle " ++ show attempt ++ " reset the backoff")
                   (backoff <= 100)
                 cycles manager queryId (attempt + 1)

    covering
    exercise : Live -> IO ()
    exercise manager =
      do subscribed <- subscribeLive manager "demo:state" (JObject [("room", JString "b")])
         case subscribed of
              Left failure =>
                check failures ("phase two subscribed: " ++ message failure) False
              Right queryId =>
                do initial <- awaitUpdate manager queryId 10000
                   check failures "the reconnect phase starts from zero"
                     ((initial >>= updateValue) == Just (JObject [("count", jsonInt 0)]))
                   cycles manager queryId 1
                   closeLive manager

--------------------------------------------------------------------------------
-- Phase three: a frame that stops half way, and a bounded close
--------------------------------------------------------------------------------

covering
dribbleFixture : Int -> IO ()
dribbleFixture listener =
  do deadline <- deadlineIn 30000
     accepted <- acceptConnection listener "" "" deadline 65536
     case accepted of
          Left _ => pure ()
          Right link =>
            do upgraded <- serverUpgrade link deadline
               when upgraded (stall link deadline)
               sleepMs 4000
               closeConnection link
  where
    covering
    stall : Connection -> Int -> IO ()
    stall link deadline =
      do ignore $ readOpening link deadline
         -- Announce a frame, send part of it, then go quiet for longer than the
         -- client's frame budget. The client must abandon the connection rather
         -- than resynchronise on a false boundary.
         scratch <- bufNew 16
         if scratch < 0
            then pure ()
            else do ignore $ bufSet scratch 0 129
                    ignore $ bufSet scratch 1 60
                    ignore $ bufPutText scratch 2 "{\"type\":\"Tra"
                    at <- deadlineIn 2000
                    ignore $ writeAll link scratch 0 14 at
                    bufFree scratch

covering
phaseThree : IORef Int -> Int -> IO ()
phaseThree failures portNumber =
  do started <- startLive portNumber 700 16 (1024 * 1024)
     case started of
          Nothing => check failures "phase three built a Live client" False
          Just manager => exercise manager
  where
    covering
    exercise : Live -> IO ()
    exercise manager =
      do subscribed <- subscribeLive manager "demo:state" (JObject [("room", JString "c")])
         case subscribed of
              Left _ => check failures "phase three subscribed" False
              Right queryId =>
                do update <- awaitUpdate manager queryId 4000
                   check failures "a half-delivered frame is reported, not resynchronised"
                     -- See the case-scrutinee annotation note in phaseOne.
                     (case the (Maybe ConvexError) (update >>= updateError) of
                           Just failure => kind failure == TransportFailure
                           Nothing => False)
                   -- Close must stay bounded even though the peer is silent.
                   before <- nowMs
                   closeLive manager
                   after <- nowMs
                   check failures "close is bounded against a silent peer"
                     (after - before < 3000)

--------------------------------------------------------------------------------
-- Phase four: unsubscribe invalidates anything already queued
--------------------------------------------------------------------------------

covering
staleFixture : Int -> IO ()
staleFixture listener =
  do deadline <- deadlineIn 30000
     accepted <- acceptConnection listener "" "" deadline 65536
     case accepted of
          Left _ => pure ()
          Right link =>
            do upgraded <- serverUpgrade link deadline
               when upgraded (converse link deadline)
               closeConnection link
  where
    -- publish is defined before converse, which calls it, per the
    -- where-block ordering rule (see the Convex.Ws await/upgrade note).
    covering
    publish : Connection -> Int -> Int -> IO ()
    publish link a b =
      do serverFrame link True 1
           (transition 0 0 2 10 (queryUpdated a "{\"count\":1}" ++ ","
                                   ++ queryUpdated b "{\"count\":2}"))
         sleepMs 4000

    covering
    converse : Connection -> Int -> IO ()
    converse link deadline =
      do first <- readOpening link deadline
         second <- serverRead link deadline
         -- Without the annotation, `pure []` below leaves `extra`'s element
         -- type an unresolved metavariable until something forces it, and
         -- Idris2 does not resolve that from the tuple pattern match two
         -- lines down (compare the case-scrutinee notes elsewhere in this
         -- file); it must be pinned right where it is bound instead.
         extra <- the (IO (List Int)) (case second of
                       Just (_, text) => addedQueryIds text
                       Nothing => pure [])
         case (first, extra) of
              ((a :: _), (b :: _)) => publish link a b
              _ => pure ()

covering
phaseFour : IORef Int -> Int -> IO ()
phaseFour failures portNumber =
  do started <- startLive portNumber 5000 16 (1024 * 1024)
     case started of
          Nothing => check failures "phase four built a Live client" False
          Just manager => exercise manager
  where
    -- drain is defined before race, and race before exercise, because each
    -- calls the one above it (where-block callees must precede their call
    -- sites; see the Convex.Ws await/upgrade note for the general rule).
    covering
    drain : Live -> List (Int, LiveUpdate) -> IO (List (Int, LiveUpdate))
    drain manager acc =
      do taken <- takeDelivery manager
         case taken of
              Nothing => pure acc
              Just entry => drain manager (acc ++ [entry])

    covering
    race : Live -> Int -> Int -> IO ()
    race manager a b =
      do -- Let the transition arrive and queue updates for both queries.
         pumpLive manager 3000
         -- Drop the second subscription. The acknowledgement is only produced
         -- after its generation is bumped, so its queued update can never be
         -- published afterwards.
         ignore $ unsubscribeLive manager b
         collected <- drain manager []
         check failures "an unsubscribed query publishes nothing that was queued"
           (all (\entry => fst entry == a) collected)
         check failures "the surviving subscription still delivers"
           (any (\entry => fst entry == a) collected)
         closeLive manager

    covering
    exercise : Live -> IO ()
    exercise manager =
      do first <- subscribeLive manager "demo:state" (JObject [("room", JString "d")])
         second <- subscribeLive manager "demo:state" (JObject [("room", JString "e")])
         case (first, second) of
              (Right a, Right b) => race manager a b
              _ => check failures "phase four subscribed twice" False

--------------------------------------------------------------------------------
-- Driver
--------------------------------------------------------------------------------

covering
runPhase : IORef Int -> String -> (Int -> IO ()) -> (IORef Int -> Int -> IO ()) -> IO ()
runPhase failures label fixture body =
  do bound <- listenLocal
     case bound of
          Nothing => check failures (label ++ " bound a fixture port") False
          Just (listener, portNumber) =>
            do child <- forkProcess
               if child == 0
                  then do fixture listener
                          exitNow 0
                  else do closeFd listener
                          body failures portNumber
                          killProcess child
                          deadline <- deadlineIn 3000
                          ignore $ waitProcess child deadline

covering
main : IO ()
main =
  do initialise
     failures <- newIORef 0
     runPhase failures "phase one" phaseOneFixture phaseOne
     runPhase failures "phase two" (\listener => reconnectFixture listener 5) phaseTwo
     runPhase failures "phase three" dribbleFixture phaseThree
     runPhase failures "phase four" staleFixture phaseFour
     failureCount <- readIORef failures
     if failureCount == 0
        then putStrLn "live tests passed"
        else do ignore $ fPutStrLn stderr ("live tests failed: " ++ show failureCount)
                exitFailure
