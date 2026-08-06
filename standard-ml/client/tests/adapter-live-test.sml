(* The adapter driving real Live traffic.

   Two things are proved here that neither the client tests nor the adapter
   protocol tests can prove alone:

   * five genuine reconnect and hydration cycles requested through the
     adapter-only debugDisconnect command, each one resending the active Add;
   * stale relay rejection - a relay that dequeued a value just before an
     unsubscribe barrier must drop it rather than deliver it after the
     acknowledgement.

   The Docker test stage points CONVEX_URL at the fixture below, because the
   Standard ML Basis Library can read the environment but not modify it. *)

use "client/sources.sml";
use "client/tests/check.sml";
use "client/tests/fixture.sml";
use "client/tests/conformance/adapter.sml";

structure AdapterLiveTest =
struct
  val livePort = 19400
  val controlPort = 19401

  (* Lets the fixture and the controller step through the stale-relay window in
     a fixed order instead of racing. *)
  val armed = Latch.new ()
  val paused = Latch.new ()
  val resume = Latch.new ()

  (* The connection index doubles as the timestamp and the counter value, so
     the timestamp conversion happens here rather than at every call site. *)
  fun version ts =
    Json.Object
      [("querySet", Json.Int 1), ("identity", Json.Int 0),
       ("ts", Json.String (Timestamp.encode (IntInf.fromInt ts)))]

  val zeroVersion =
    Json.Object
      [("querySet", Json.Int 0), ("identity", Json.Int 0),
       ("ts", Json.String Timestamp.initial)]

  fun updated (queryId, count) =
    Json.Object
      [("type", Json.String "QueryUpdated"),
       ("queryId", Json.Int queryId),
       ("value", Json.Object [("count", Json.Int (IntInf.fromInt count))]),
       ("logLines", Json.Array [])]

  fun sendTransition (peer, startTs, endTs, change) =
    Fixture.sendServerText
      (peer,
       Json.encode
         (Json.Object
            [("type", Json.String "Transition"),
             ("startVersion", if startTs = 0 then zeroVersion else version startTs),
             ("endVersion", version endTs),
             ("modifications", Json.Array [change])]))

  fun acceptLive (listener, expectedCount) =
    let
      val peer = Fixture.acceptPeer listener
      val request = Fixture.handshake peer
      val _ =
        Check.that
          ("the adapter uses the pinned sync endpoint",
           String.isSubstring "/api/sync" (#line request))
      val connect = Fixture.readClientJson (peer, "Connect")
      val _ =
        Check.that
          ("the adapter carries connectionCount across reconnects",
           Json.asInt (Json.getOr (connect, "connectionCount", Json.Null))
           = SOME (IntInf.fromInt expectedCount))
      val modify = Fixture.readClientJson (peer, "ModifyQuerySet")
      val add =
        case Json.asList (Json.getOr (modify, "modifications", Json.Null)) of
            SOME (first :: _) => first
          | _ => raise Fail "reconnect sent no modifications"
      val _ =
        Check.that
          ("each adapter reconnect resends its Add",
           Json.asString (Json.getOr (add, "type", Json.Null)) = SOME "Add")
    in
      case Json.asInt (Json.getOr (add, "queryId", Json.Null)) of
          SOME queryId => (peer, queryId)
        | NONE => raise Fail "Add carried no query identifier"
    end

  fun liveScript listener =
    let
      (* Connections 0 to 5: the initial hydration and the five reconnects. *)
      fun cycle index =
        if index > 5 then ()
        else
          let
            val (peer, queryId) = acceptLive (listener, index)
          in
            sendTransition (peer, 0, index + 1, updated (queryId, index));
            if index < 5 then
              (ignore (Fixture.waitForDisconnect peer);
               Fixture.closePeer peer;
               cycle (index + 1))
            else
              (* The last connection stays up for the stale-relay window. *)
              (Check.that ("the stale-relay window is armed", Latch.awaitSeconds (armed, 10.0));
               sendTransition (peer, index + 1, index + 2, updated (queryId, 99));
               (let
                  val modify = Fixture.readClientJson (peer, "ModifyQuerySet")
                  val change =
                    case Json.asList (Json.getOr (modify, "modifications", Json.Null)) of
                        SOME (first :: _) => first
                      | _ => raise Fail "unsubscribe sent no modifications"
                in
                  Check.that
                    ("the adapter unsubscribe sends a real Remove",
                     Json.asString (Json.getOr (change, "type", Json.Null)) = SOME "Remove")
                end);
               ignore (Fixture.waitForDisconnect peer);
               Fixture.closePeer peer)
          end
    in
      cycle 0;
      Socket.close listener
    end

  (* ---- controller ------------------------------------------------------- *)

  fun command (channel, text) = Transport.writeAll (channel, text ^ "\n", Clock.deadlineIn 3.0)

  fun nextEvent reader =
    case Reader.line (reader, Clock.deadlineIn 10.0) of
        SOME text => Json.decode text
      | NONE => raise Fail "the adapter closed before answering"

  fun typeOf event = Json.asString (Json.getOr (event, "type", Json.Null))

  fun countOf event =
    Json.asInt (Json.getOr (Json.getOr (event, "value", Json.Null), "count", Json.Null))

  fun expectAck (reader, id, label) =
    let
      val event = nextEvent reader
    in
      Check.that
        (label,
         typeOf event = SOME "ack"
         andalso Json.asString (Json.getOr (event, "id", Json.Null)) = SOME id)
    end

  fun expectValue (reader, expected, label) =
    Check.that (label, countOf (nextEvent reader) = SOME (IntInf.fromInt expected))

  fun controller (channel, reader) =
    (command (channel, "{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}");
     Check.that ("the adapter is ready", typeOf (nextEvent reader) = SOME "ready");
     command
       (channel,
        "{\"id\":\"sub\",\"op\":\"subscribe\",\"subscriptionId\":\"s1\","
        ^ "\"path\":\"demo:state\",\"args\":{\"room\":\"standard-ml-adapter\"}}");
     expectAck (reader, "sub", "subscribe is acknowledged");
     expectValue (reader, 0, "the adapter delivers the initial Live value");

     (* Five genuine reconnect and hydration cycles. *)
     (let
        fun cycle index =
          if index > 5 then ()
          else
            (command
               (channel,
                "{\"id\":\"drop" ^ Int.toString index ^ "\",\"op\":\"debugDisconnect\"}");
             expectAck (reader, "drop" ^ Int.toString index, "debugDisconnect is acknowledged");
             expectValue (reader, index, "the reconnected subscription rehydrates");
             cycle (index + 1))
      in
        cycle 1
      end);

     (* Stale relay rejection: the relay dequeues 99 and is held there while the
        unsubscribe barrier passes. That value must never be published. *)
     Adapter.afterDequeueHook :=
       (fn _ =>
          if Latch.awaitSeconds (paused, 0.0) then ()
          else (Latch.release paused; ignore (Latch.awaitSeconds (resume, 5.0))));
     Latch.release armed;
     Check.that ("the relay reached the stale window", Latch.awaitSeconds (paused, 10.0));
     command (channel, "{\"id\":\"unsub\",\"op\":\"unsubscribe\",\"subscriptionId\":\"s1\"}");
     expectAck (reader, "unsub", "unsubscribe is acknowledged");
     Latch.release resume;
     Clock.sleep 0.5;
     command (channel, "{\"id\":\"bye\",\"op\":\"close\"}");
     Check.that
       ("no stale value crosses the unsubscribe acknowledgement",
        typeOf (nextEvent reader) = SOME "closed"))

  fun run () =
    let
      val liveListener = Fixture.listenOn livePort
      val liveServer = Fixture.spawn (fn () => liveScript liveListener)
      val controlListener = Fixture.listenOn controlPort
      val adapter =
        Fixture.spawn
          (fn () =>
             let
               val {channel, reader} = Fixture.acceptPeer controlListener
             in
               Socket.close controlListener;
               Check.that
                 ("the adapter ends the Live session cleanly",
                  Adapter.runLoop
                    (fn () => Reader.byte (reader, Clock.deadlineIn 60.0),
                     fn text => Transport.writeAll (channel, text, Clock.deadlineIn 3.0))
                  = Adapter.Ended);
               Transport.close channel
             end)
      val channel =
        Transport.connect
          {host = "127.0.0.1", port = controlPort, secure = false,
           deadline = Clock.deadlineIn 3.0}
      val reader = Reader.new channel
    in
      controller (channel, reader);
      Transport.close channel;
      Fixture.join (adapter, 10.0, "the adapter");
      Fixture.join (liveServer, 20.0, "the Live fixture")
    end
end

fun main () = Check.run ("adapter-live-test", AdapterLiveTest.run)
