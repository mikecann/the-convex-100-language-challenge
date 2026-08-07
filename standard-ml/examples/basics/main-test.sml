(* Runs the built canonical example, exactly as shipped, against a fixture.

   There is deliberately no second copy of the example: this test executes the
   same /usr/local/bin/convex-example binary the runtime image publishes, so
   the transcript it checks is the transcript the shared verifier compares.

   The fixture answers every numeric field in Convex's integral decimal
   spelling (0.0, 1.0). That is the regression: the example must accept a
   mathematically integral value and still print an integer. *)

use "client/sources.sml";
use "client/tests/check.sml";
use "client/tests/fixture.sml";

structure MainTest =
struct
  val happyPort = 19500
  val fractionalPort = 19501

  val expected =
    String.concat
      ["current count: 0\n",
       "live initial count: 0\n",
       "mutation applied: true\n",
       "mutation count: 1\n",
       "live updated count: 1\n",
       "verified count: 0 -> 1\n"]

  fun binary () =
    case OS.Process.getEnv "EXAMPLE_BINARY" of
        SOME path => path
      | NONE => "/out/convex-example"

  (* The example reads its deployment from the environment, so the fixture URL
     is handed over the same way the runtime container does it. *)
  fun runExample (port, room) =
    let
      val child =
        Unix.executeInEnv
          (binary (), [room],
           ["CONVEX_URL=http://127.0.0.1:" ^ Int.toString port,
            "PATH=/usr/bin:/bin"])
      val output = TextIO.inputAll (Unix.textInstreamOf child)
      val status = Unix.reap child
    in
      {output = output, ok = OS.Process.isSuccess status}
    end

  (* ---- fixture --------------------------------------------------------- *)

  val zeroVersion =
    Json.Object
      [("querySet", Json.Int 0), ("identity", Json.Int 0),
       ("ts", Json.String Timestamp.initial)]

  fun version ts =
    Json.Object
      [("querySet", Json.Int 1), ("identity", Json.Int 0),
       ("ts", Json.String (Timestamp.encode ts))]

  fun transition (start, finish, queryId, count) =
    Json.encode
      (Json.Object
         [("type", Json.String "Transition"),
          ("startVersion", start), ("endVersion", finish),
          ("modifications",
           Json.Array
             [Json.Object
                [("type", Json.String "QueryUpdated"),
                 ("queryId", Json.Int queryId),
                 (* Integral, spelled as a decimal. *)
                 ("value", Json.Object [("count", Json.Real (Real.fromInt count))]),
                 ("logLines", Json.Array [])]])])

  val queryReply = "{\"status\":\"success\",\"value\":{\"count\":0.0},\"logLines\":[]}"

  val mutationReply =
    "{\"status\":\"success\",\"value\":{\"applied\":true,"
    ^ "\"state\":{\"count\":1.0}},\"logLines\":[]}"

  (* Dispatches by request line: the example opens one HTTP connection per call
     and one long-lived WebSocket connection in between. *)
  fun happyScript listener =
    let
      val mutationApplied = Latch.new ()
      fun serve remaining =
        if remaining <= 0 then ()
        else
          let
            val peer = Fixture.acceptPeer listener
            val request = Fixture.readRequest peer
            val line = #line request
          in
            if Text.startsWith ("POST /api/query", line) then
              (Fixture.respond (peer, queryReply);
               Fixture.closePeer peer;
               serve (remaining - 1))
            else if Text.startsWith ("POST /api/mutation", line) then
              (Fixture.respond (peer, mutationReply);
               Fixture.closePeer peer;
               Latch.release mutationApplied;
               serve (remaining - 1))
            else if Text.startsWith ("GET /api/sync", line) then
              let
                (* The WebSocket stays open, so it is handled beside the
                   remaining HTTP calls rather than in front of them. *)
                val key =
                  case Fixture.headerOf (request, "sec-websocket-key") of
                      SOME value => value
                    | NONE => raise Fail "the example sent no WebSocket key"
                val _ =
                  Fixture.send
                    (peer,
                     String.concat
                       ["HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n",
                        "Connection: Upgrade\r\nSec-WebSocket-Accept: ",
                        Base64.encode (Sha1.hash (key ^ WebSocket.guid)), "\r\n\r\n"])
                val handler =
                  Fixture.spawn (fn () => afterHandshake (peer, mutationApplied))
              in
                serve (remaining - 1);
                Fixture.join (handler, 20.0, "the example sync connection")
              end
            else raise Fail ("the example made an unexpected request: " ^ line)
          end
    in
      serve 3;
      Socket.close listener
    end

  (* The handshake response is already sent by the dispatcher above, so this
     picks up at the first Convex message. *)
  and afterHandshake (peer, mutationApplied) =
    let
      val _ = Fixture.readClientJson (peer, "Connect")
      val modify = Fixture.readClientJson (peer, "ModifyQuerySet")
      val add =
        case Json.asList (Json.getOr (modify, "modifications", Json.Null)) of
            SOME (first :: _) => first
          | _ => raise Fail "the example sent no Add"
      val queryId =
        case Json.asInt (Json.getOr (add, "queryId", Json.Null)) of
            SOME value => value
          | NONE => raise Fail "the example Add carried no query identifier"
    in
      Fixture.sendServerText (peer, transition (zeroVersion, version 1, queryId, 0));
      Check.that ("the mutation reached the fixture", Latch.awaitSeconds (mutationApplied, 20.0));
      Fixture.sendServerText (peer, transition (version 1, version 2, queryId, 1));
      ignore (Fixture.waitForDisconnect peer);
      Fixture.closePeer peer
    end

  (* A fractional count is not a counter. The example must refuse it and print
     nothing at all on stdout. *)
  fun fractionalScript listener =
    let
      val peer = Fixture.acceptPeer listener
    in
      ignore (Fixture.readRequest peer);
      Fixture.respond (peer, "{\"status\":\"success\",\"value\":{\"count\":1.5},\"logLines\":[]}");
      Fixture.closePeer peer;
      Socket.close listener
    end

  fun run () =
    let
      val happyListener = Fixture.listenOn happyPort
      val happyServer = Fixture.spawn (fn () => happyScript happyListener)
      val {output, ok} = runExample (happyPort, "standard-ml-main-test")
      val _ = Fixture.join (happyServer, 25.0, "the example fixture")
      val fractionalListener = Fixture.listenOn fractionalPort
      val fractionalServer = Fixture.spawn (fn () => fractionalScript fractionalListener)
      val fractional = runExample (fractionalPort, "standard-ml-main-test-fractional")
    in
      Check.that ("the example exits successfully", ok);
      Check.that ("the example prints the universal transcript exactly", output = expected);
      Fixture.join (fractionalServer, 15.0, "the fractional fixture");
      Check.that ("a fractional count fails the example", not (#ok fractional));
      Check.that ("a failing example prints nothing on stdout", #output fractional = "")
    end
end

fun main () = Check.run ("main-test", MainTest.run)
