(* Live acceptance against a raw WebSocket fixture.

   The fixture is a scripted sequence of connections. Between them it injects
   every failure ordinary happy-path testing misses: a transition whose second
   member is malformed, a message fragmented inside a multi-byte character with
   a ping interleaved, invalid UTF-8, a reserved opcode, a frame that stalls
   half-way through, and finally five genuine reconnect and hydration cycles.

   Each connection also proves the reconnect contract: the client resends its
   active Add operations, carries connectionCount and maxObservedTimestamp
   forward, and suppresses an unchanged rehydration. *)

use "client/sources.sml";
use "client/tests/check.sml";
use "client/tests/fixture.sml";

structure LiveTest =
struct
  val servicePort = 19200
  val stallPort = 19201
  val slowPort = 19202
  val orphanPort = 19203

  (* U+96EA, three UTF-8 bytes. Written as escapes because a Standard ML string
     literal may only contain printable ASCII. *)
  val snowflake = "\233\155\170"

  (* ---- message builders ---------------------------------------------- *)

  fun version (querySet, ts) =
    Json.Object
      [("querySet", Json.Int querySet), ("identity", Json.Int 0),
       ("ts", Json.String (Timestamp.encode ts))]

  (* Convex may spell an integral counter as 1.0. The client must normalise the
     state version before comparing it, so one transition uses that spelling. *)
  fun decimalVersion ts =
    Json.Object
      [("querySet", Json.Real 1.0), ("identity", Json.Real 0.0),
       ("ts", Json.String (Timestamp.encode ts))]

  val zeroVersion = version (0, 0)

  fun updated (queryId, count, extra) =
    Json.Object
      ([("type", Json.String "QueryUpdated"),
        ("queryId", Json.Int queryId),
        ("value",
         Json.Object
           ([("count", Json.Int (IntInf.fromInt count))]
            @ (case extra of SOME text => [("snow", Json.String text)] | NONE => [])))]
       @ [("logLines", Json.Array [Json.String ("count=" ^ Int.toString count)])])

  fun failed queryId =
    Json.Object
      [("type", Json.String "QueryFailed"),
       ("queryId", Json.Int queryId),
       ("errorMessage", Json.String "reactive failure"),
       ("errorData", Json.Object [("code", Json.String "BROKEN")]),
       ("logLines", Json.Array [Json.String "query-failed"])]

  fun transition (start, finish, changes) =
    Json.encode
      (Json.Object
         [("type", Json.String "Transition"),
          ("startVersion", start), ("endVersion", finish),
          ("modifications", Json.Array changes)])

  fun sendTransition (peer, startTs, endTs, change) =
    Fixture.sendServerText
      (peer,
       transition
         (if startTs = 0 then zeroVersion else version (1, startTs), version (1, endTs), [change]))

  (* ---- connection script ---------------------------------------------- *)

  fun acceptLive (listener, expectedCount, expectedMax) =
    let
      val peer = Fixture.acceptPeer listener
      val request = Fixture.handshake peer
      val _ =
        Check.that
          ("Live uses the pinned sync endpoint", String.isSubstring "/api/sync" (#line request))
      val connect = Fixture.readClientJson (peer, "Connect")
      val _ =
        Check.that
          ("connectionCount carries across reconnects",
           Json.asInt (Json.getOr (connect, "connectionCount", Json.Null))
           = SOME (IntInf.fromInt expectedCount))
      val _ =
        case expectedMax of
            SOME ts =>
              Check.that
                ("maxObservedTimestamp carries across reconnects",
                 Json.asString (Json.getOr (connect, "maxObservedTimestamp", Json.Null))
                 = SOME (Timestamp.encode ts))
          | NONE =>
              Check.that
                ("the first Connect omits maxObservedTimestamp",
                 not (Json.has (connect, "maxObservedTimestamp")))
      val modify = Fixture.readClientJson (peer, "ModifyQuerySet")
      val add =
        case Json.asList (Json.getOr (modify, "modifications", Json.Null)) of
            SOME (first :: _) => first
          | _ => raise Fail "reconnect sent no modifications"
      val _ =
        Check.that
          ("every connection resends its Add",
           Json.asString (Json.getOr (add, "type", Json.Null)) = SOME "Add")
    in
      case Json.asInt (Json.getOr (add, "queryId", Json.Null)) of
          SOME queryId => (peer, queryId)
        | NONE => raise Fail "Add carried no query identifier"
    end

  fun finish (peer, expectPong, label) =
    (Check.that (label, Fixture.waitForDisconnect peer orelse not expectPong);
     Fixture.closePeer peer)

  fun firstConnection listener =
    let
      val (peer, queryId) = acceptLive (listener, 0, NONE)
    in
      sendTransition (peer, 0, 1, updated (queryId, 0, NONE));
      (* Two changes for one query inside one transaction publish only the
         final coalesced value; 100 must never be observed. *)
      Fixture.sendServerText
        (peer,
         transition
           (decimalVersion 1, decimalVersion 2,
            [updated (queryId, 100, NONE), updated (queryId, 1, NONE)]));
      sendTransition (peer, 2, 3, failed queryId);
      sendTransition (peer, 3, 4, updated (queryId, 2, NONE));
      Fixture.sendServerFrame (peer, true, 9, "transaction-ping");
      (* A valid change followed by a malformed member rejects the whole
         transaction. 777 must never escape before recovery. *)
      Fixture.sendServerText
        (peer,
         transition
           (version (1, 4), version (1, 5),
            [updated (queryId, 777, NONE), Json.Object [("queryId", Json.Int queryId)]]));
      finish (peer, true, "a malformed transition retires its socket")
    end

  fun fragmentedConnection listener =
    let
      val (peer, queryId) = acceptLive (listener, 1, SOME 4)
      (* The value carries a three-byte character; Standard ML string literals
         are ASCII only, so it is written as escapes. *)
      val text =
        transition
          (zeroVersion, version (1, 5), [updated (queryId, 3, SOME snowflake)])
      (* Split inside the multi-byte character so a naive decoder fails. *)
      fun splitPoint index =
        if Bytes.byteAt (text, index) >= 128 then index + 1 else splitPoint (index + 1)
      val cut = splitPoint 0
    in
      Fixture.sendServerFrame (peer, false, 1, String.substring (text, 0, cut));
      Fixture.sendServerFrame (peer, true, 9, "ping");
      Fixture.sendServerFrame (peer, true, 0, String.extract (text, cut, NONE));
      finish (peer, true, "a ping between fragments is answered with a pong")
    end

  fun rehydrationConnection listener =
    let
      val (peer, queryId) = acceptLive (listener, 2, SOME 5)
    in
      (* The same value again: the client must suppress the rehydration. *)
      sendTransition (peer, 0, 6, updated (queryId, 3, SOME snowflake));
      sendTransition (peer, 6, 7, updated (queryId, 4, NONE));
      (* Invalid UTF-8 retires the connection; it is not a query failure. *)
      Fixture.sendServerFrame (peer, true, 1, "\255");
      finish (peer, false, "invalid UTF-8 retires its socket")
    end

  fun reservedOpcodeConnection listener =
    let
      val (peer, queryId) = acceptLive (listener, 3, SOME 7)
    in
      sendTransition (peer, 0, 8, updated (queryId, 5, NONE));
      Fixture.sendServerFrame (peer, true, 3, "");
      finish (peer, false, "a reserved opcode retires its socket")
    end

  fun stalledFrameConnection listener =
    let
      val (peer, queryId) = acceptLive (listener, 4, SOME 8)
    in
      sendTransition (peer, 0, 255, updated (queryId, 6, NONE));
      (* Announce a ten-byte text frame and then send only two of its bytes.
         The owner must abandon this connection rather than resume the parser
         at a byte that is not a frame header. *)
      Fixture.send (peer, Bytes.ofByte 129 ^ Bytes.ofByte 10 ^ "{\"");
      Clock.sleep 1.3;
      finish (peer, false, "a stalled half-frame retires its socket")
    end

  fun recoveredConnection listener =
    let
      val (peer, queryId) = acceptLive (listener, 5, SOME 255)
    in
      (* Crossing the 255 -> 256 boundary exercises the timestamp carry. *)
      sendTransition (peer, 0, 256, updated (queryId, 7, NONE));
      finish (peer, false, "the recovered connection ends on request")
    end

  (* The remaining four explicit fault-injection cycles, then the real Remove
     the client sends before it acknowledges unsubscribe. *)
  fun reconnectCycles listener =
    let
      fun cycle (connectionCount, ts, count) =
        let
          val (peer, queryId) = acceptLive (listener, connectionCount, SOME (ts - 1))
        in
          sendTransition (peer, 0, ts, updated (queryId, count, NONE));
          if connectionCount < 9 then
            (finish (peer, false, "a reconnect cycle ends on request");
             cycle (connectionCount + 1, ts + 1, count + 1))
          else
            let
              val modify = Fixture.readClientJson (peer, "ModifyQuerySet")
              val change =
                case Json.asList (Json.getOr (modify, "modifications", Json.Null)) of
                    SOME (first :: _) => first
                  | _ => raise Fail "unsubscribe sent no modifications"
            in
              Check.that
                ("unsubscribe sends a real Remove",
                 Json.asString (Json.getOr (change, "type", Json.Null)) = SOME "Remove");
              sendTransition (peer, ts, ts + 1, updated (queryId, 999, NONE));
              (* Keep the peer continuously readable. Close still has to be
                 bounded rather than starved by control frames. *)
              (let
                 fun flood remaining =
                   if remaining <= 0 then ()
                   else (Fixture.sendServerFrame (peer, true, 9, ""); flood (remaining - 1))
               in
                 flood 200
               end
               handle _ => ());
              Fixture.closePeer peer
            end
        end
    in
      cycle (6, 257, 8)
    end

  fun script listener =
    (firstConnection listener;
     fragmentedConnection listener;
     rehydrationConnection listener;
     reservedOpcodeConnection listener;
     stalledFrameConnection listener;
     recoveredConnection listener;
     reconnectCycles listener;
     Socket.close listener)

  (* ---- client expectations --------------------------------------------- *)

  fun nextUpdate (subscription, label) =
    case Convex.next (subscription, 5.0) of
        SOME update => update
      | NONE => raise Fail ("timed out waiting for " ^ label)

  fun countOf update =
    Json.asInt (Json.getOr (Convex.updateValue update, "count", Json.Null))

  fun expectCount (subscription, expected, label) =
    Check.that (label, countOf (nextUpdate (subscription, label)) = SOME (IntInf.fromInt expected))

  fun expectFailure (subscription, expected, label) =
    case Convex.updateError (nextUpdate (subscription, label)) of
        SOME {name, ...} => Check.that (label, name = expected)
      | NONE => Check.that (label, false)

  fun observe client =
    let
      val subscription =
        Convex.subscribe
          (client, "demo:state", Json.Object [("room", Json.String "standard-ml-live")])
    in
      expectCount (subscription, 0, "the initial Live value");
      expectCount (subscription, 1, "a separate Live update");
      (let
         val update = nextUpdate (subscription, "QueryFailed")
       in
         case Convex.updateError update of
             SOME {name, data, ...} =>
               (Check.that ("QueryFailed is a typed function error", name = "FunctionError");
                Check.that
                  ("QueryFailed carries its error data",
                   Json.asString (Json.getOr (data, "code", Json.Null)) = SOME "BROKEN"))
           | NONE => Check.that ("QueryFailed is a typed function error", false)
       end);
      expectCount (subscription, 2, "recovery on the same subscription after QueryFailed");
      expectFailure (subscription, "ProtocolError", "a malformed transaction");
      (let
         val update = nextUpdate (subscription, "the fragmented value")
       in
         Check.that ("the fragmented update decodes", countOf update = SOME 3);
         Check.that
           ("the fragmented multi-byte character survives",
            Json.asString (Json.getOr (Convex.updateValue update, "snow", Json.Null))
            = SOME snowflake)
       end);

      (* Five explicit fault-injection reconnects. The malformed-message
         recoveries happen independently and never masquerade as query
         failures. *)
      ignore (Convex.Internal.debugDisconnect (client, 5.0));
      expectCount (subscription, 4, "an unchanged rehydration is suppressed");
      expectFailure (subscription, "ProtocolError", "invalid UTF-8");
      expectCount (subscription, 5, "recovery after invalid UTF-8");
      expectFailure (subscription, "ProtocolError", "a reserved opcode");
      expectCount (subscription, 6, "recovery after a reserved opcode");
      expectFailure (subscription, "TransportError", "a stalled half-frame");
      expectCount (subscription, 7, "recovery after a stalled half-frame");

      (let
         fun cycle (expected, remaining) =
           if remaining <= 0 then ()
           else
             (ignore (Convex.Internal.debugDisconnect (client, 5.0));
              expectCount (subscription, expected, "a genuine reconnect and hydration cycle");
              cycle (expected + 1, remaining - 1))
       in
         cycle (8, 4)
       end);

      Convex.unsubscribe subscription;
      Clock.sleep 0.2;
      Check.that
        ("no event crosses the unsubscribe acknowledgement",
         not (Option.isSome (Convex.next (subscription, 0.1))))
    end

  (* A deployment that is slow to come up, not one that is down. The first two
     attempts are answered with a closed socket and only the third completes the
     handshake, so a subscribe that gave up after one attempt would fail here.
     The whole retry sequence has to fit inside the single budget the caller
     granted, and the connection that finally succeeds must be the client's
     first: attempts that never produced a socket are not connections. *)
  fun slowConnectChecks () =
    let
      val listener = Fixture.listenOn slowPort
      val refusals = 2
      val server =
        Fixture.spawn
          (fn () =>
             let
               fun refuse remaining =
                 if remaining <= 0 then ()
                 else
                   let
                     val peer = Fixture.acceptPeer listener
                   in
                     (* Read the upgrade request, then go away without
                        answering it. *)
                     ignore (Fixture.readRequest peer);
                     Fixture.closePeer peer;
                     refuse (remaining - 1)
                   end
               val _ = refuse refusals
               val (peer, queryId) = acceptLive (listener, 0, NONE)
             in
               Socket.close listener;
               sendTransition (peer, 0, 1, updated (queryId, 42, NONE));
               ignore (Fixture.waitForDisconnect peer);
               Fixture.closePeer peer
             end)
      val client = Convex.client (Fixture.urlFor slowPort)
      val started = Clock.now ()
      val subscription =
        Convex.subscribe
          (client, "demo:state", Json.Object [("room", Json.String "standard-ml-slow")])
      val elapsed = Time.toReal (Time.- (Clock.now (), started))
    in
      Check.that ("a slow deployment is retried until it answers", elapsed < 4.0);
      expectCount (subscription, 42, "the retried connection delivers its first value");
      Convex.close client;
      Fixture.join (server, 20.0, "the slow connect fixture")
    end

  (* A caller that stops waiting must not leave a subscription behind. The
     acknowledgement is cancelled here in exactly the way awaitReply cancels it
     when a caller's own wait expires; the owner then has to withdraw the query
     it had just added rather than publish an acknowledgement nobody holds. *)
  fun orphanChecks () =
    let
      val listener = Fixture.listenOn orphanPort
      val proceed = Latch.new ()
      val sawRemove = Latch.new ()
      val server =
        Fixture.spawn
          (fn () =>
             let
               (* Nothing is accepted until the acknowledgement has been
                  cancelled, so the owner is still inside its handshake when the
                  caller gives up. *)
               val _ = Check.that ("the orphan window opened", Latch.awaitSeconds (proceed, 10.0))
               val peer = Fixture.acceptPeer listener
               val _ = Fixture.handshake peer
               val _ = Socket.close listener
               val _ = Fixture.readClientJson (peer, "Connect")
               fun modification message =
                 case Json.asList (Json.getOr (message, "modifications", Json.Null)) of
                     SOME (first :: _) => first
                   | _ => raise Fail "the owner sent no modifications"
               val add = modification (Fixture.readClientJson (peer, "ModifyQuerySet"))
               val remove = modification (Fixture.readClientJson (peer, "ModifyQuerySet"))
             in
               Check.that
                 ("the cancelled subscribe still added its query",
                  Json.asString (Json.getOr (add, "type", Json.Null)) = SOME "Add");
               Check.that
                 ("the cancelled subscribe is withdrawn with a real Remove",
                  Json.asString (Json.getOr (remove, "type", Json.Null)) = SOME "Remove");
               Check.that
                 ("the withdrawal names the query that was added",
                  Json.asInt (Json.getOr (remove, "queryId", Json.Null))
                  = Json.asInt (Json.getOr (add, "queryId", Json.Null)));
               Latch.release sawRemove;
               ignore (Fixture.waitForDisconnect peer);
               Fixture.closePeer peer
             end)
      val manager = Live.newManager (Url.parse (Fixture.urlFor orphanPort), "standard-ml-0.1.0")
      val reply =
        Live.enqueueCommand
          (manager, Live.SubscribeKind, NONE,
           SOME ("demo:state", Json.Object [("room", Json.String "standard-ml-orphan")]), 4.0)
      val Live.Reply {cancelled, ...} = reply
    in
      (* The owner is blocked in its handshake by now, so the cancellation lands
         before the acknowledgement can. *)
      Clock.sleep 0.3;
      cancelled := true;
      Latch.release proceed;
      Check.that ("the withdrawal reached the fixture", Latch.awaitSeconds (sawRemove, 10.0));
      Clock.sleep 0.5;
      Check.that
        ("no subscription survives a cancelled acknowledgement",
         List.null (Live.sortedSubscriptions manager));
      Live.close (manager, 5.0);
      Fixture.join (server, 20.0, "the orphan fixture")
    end

  (* A peer that accepts TCP and never speaks TLS must not monopolise the one
     Live owner. Close is queued behind the handshake, so this also proves the
     public lifecycle stays bounded while connecting. *)
  fun stallChecks () =
    let
      val listener = Fixture.listenOn stallPort
      val accepted = Latch.new ()
      val server =
        Fixture.spawn
          (fn () =>
             let
               val peer = Fixture.acceptPeer listener
             in
               Socket.close listener;
               Latch.release accepted;
               Clock.sleep 4.0;
               Fixture.closePeer peer
             end)
      val client = Convex.client ("https://127.0.0.1:" ^ Int.toString stallPort)
      val outcome = ref NONE
      val subscriber =
        Fixture.spawn
          (fn () =>
             (ignore (Convex.subscribe (client, "demo:state", Json.Object []))
              handle exn => outcome := SOME exn))
      val _ = Check.that ("the stalled fixture accepted", Latch.awaitSeconds (accepted, 3.0))
      val started = Clock.now ()
    in
      Convex.close client;
      Check.that
        ("a stalled Live handshake and a queued close stay bounded",
         Time.toReal (Time.- (Clock.now (), started)) < 3.5);
      Fixture.join (subscriber, 3.0, "the stalled subscriber");
      Check.that
        ("the stalled subscribe is a structured transport failure",
         case !outcome of
             SOME (ConvexError.Error {name, ...}) => name = "TransportError"
           | _ => false);
      Fixture.join (server, 8.0, "the Live TLS stall fixture")
    end

  fun run () =
    let
      val listener = Fixture.listenOn servicePort
      val server = Fixture.spawn (fn () => script listener)
      val client = Convex.client (Fixture.urlFor servicePort)
    in
      observe client;
      (let
         val started = Clock.now ()
       in
         Convex.close client;
         Check.that
           ("close stays bounded under continuous control frames",
            Time.toReal (Time.- (Clock.now (), started)) < 2.5)
       end);
      Fixture.join (server, 15.0, "the Live fixture");
      slowConnectChecks ();
      orphanChecks ();
      stallChecks ()
    end
end

fun main () = Check.run ("live-test", LiveTest.run)
