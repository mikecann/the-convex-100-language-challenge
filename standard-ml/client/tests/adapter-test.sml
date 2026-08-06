(* Adapter protocol tests: strict command schemas, malformed envelopes, and the
   bounded output budget.

   These drive the real adapter loop rather than a copy of it, so a shape
   mismatch or an unbounded queue is caught here instead of in shared black-box
   conformance. *)

use "client/sources.sml";
use "client/tests/check.sml";
use "client/tests/fixture.sml";
use "client/tests/conformance/adapter.sml";

structure AdapterTest =
struct
  val tcpPort = 19300

  fun events text =
    List.map Json.decode
      (List.filter (fn line => line <> "")
         (String.tokens (fn character => character = #"\n") text))

  (* Feed a whole NDJSON script through the real loop and collect what it
     emitted. *)
  fun runMemory input =
    let
      val position = ref 0
      fun readByte () =
        if !position >= String.size input then NONE
        else (position := !position + 1; SOME (String.sub (input, !position - 1)))
      val output = Buffer.new ()
    in
      Adapter.runLoop (readByte, fn text => Buffer.add (output, text));
      events (Buffer.contents output)
    end

  fun typeOf event = Json.asString (Json.getOr (event, "type", Json.Null))

  fun idOf event = Json.asString (Json.getOr (event, "id", Json.Null))

  val script =
    String.concat
      ["\n",
       "{\n",
       "\255\n",
       "{\"id\":\"early\",\"op\":\"query\",\"path\":\"demo:get\",\"args\":{}}\n",
       "{\"id\":\"trailing\",\"op\":\"hello\",\"protocolVersion\":1} trailing\n",
       "{\"id\":\"hello\",\"op\":\"hello\",\"protocolVersion\":1}\n",
       "{\"id\":\"missing-args\",\"op\":\"query\",\"path\":\"demo:get\"}\n",
       "{\"id\":\"missing-token\",\"op\":\"setAuth\"}\n",
       "{\"id\":\"extra\",\"op\":\"setAuth\",\"token\":\"\",\"extra\":true}\n",
       "{\"id\":\"unknown\",\"op\":\"wat\"}\n",
       "{\"id\":\"close\",\"op\":\"close\"}\n"]

  fun envelopes () =
    let
      val emitted = runMemory script
      fun at index = List.nth (emitted, index)
    in
      Check.that ("every NDJSON record produced one event", List.length emitted = 11);
      Check.that ("every event is an object", List.all Json.isObject emitted);
      Check.that
        ("every event carries a type",
         List.all (fn item => Option.isSome (typeOf item)) emitted);
      Check.that
        ("empty, malformed, non-UTF-8, pre-hello, and trailing input all recover",
         List.all (fn index => typeOf (at index) = SOME "error") [0, 1, 2, 3, 4]);
      Check.that ("hello answers with ready", typeOf (at 5) = SOME "ready");
      Check.that
        ("missing, duplicate-shaped, and unknown commands are rejected",
         List.all (fn index => typeOf (at index) = SOME "error") [6, 7, 8, 9]);
      Check.that ("a well-formed command keeps its id", idOf (at 6) = SOME "missing-args");
      Check.that ("close answers with closed", typeOf (at 10) = SOME "closed");
      Check.that ("malformed input never invents an id", idOf (at 0) = NONE);

      (* Keep the serialized ready, error, and closed shapes close to the shared
         schema so drift is caught locally, not by the black-box controller. *)
      Check.that
        ("ready reports the protocol version",
         Json.asInt (Json.getOr (at 5, "protocolVersion", Json.Null)) = SOME 1);
      Check.that
        ("ready reports language, provenance, and runtime",
         List.all
           (fn key => Option.isSome (Json.asString (Json.getOr (at 5, key, Json.Null))))
           ["language", "implementation", "runtime"]);
      Check.that
        ("ready names this language",
         Json.asString (Json.getOr (at 5, "language", Json.Null)) = SOME "standard-ml");
      Check.that
        ("ready reports a native Poly/ML provenance",
         case Json.asString (Json.getOr (at 5, "implementation", Json.Null)) of
             SOME text => Text.startsWith ("native-poly-ml-", text)
           | NONE => false);
      Check.that
        ("ready names the Poly/ML runtime",
         case Json.asString (Json.getOr (at 5, "runtime", Json.Null)) of
             SOME text => Text.startsWith ("Poly/ML ", text)
           | NONE => false);
      Check.that
        ("a structured error carries a name and a message",
         let
           val failure = Json.getOr (at 6, "error", Json.Null)
         in
           Json.isObject failure
           andalso Option.isSome (Json.asString (Json.getOr (failure, "name", Json.Null)))
           andalso Option.isSome (Json.asString (Json.getOr (failure, "message", Json.Null)))
         end);
      (* Optional fields are omitted, never serialized as null. *)
      Check.that ("an HTTP error omits subscriptionId", not (Json.has (at 6, "subscriptionId")));
      Check.that ("closed omits error", not (Json.has (at 10, "error")));
      Check.that ("closed keeps its id", idOf (at 10) = SOME "close")
    end

  (* This exact shape has exhausted a 128 MiB runtime in another client. *)
  fun hostileInput () =
    let
      val deep =
        CharVector.tabulate (200000, fn _ => #"[") ^ CharVector.tabulate (200000, fn _ => #"]")
      val emitted =
        runMemory
          (String.concat
             [deep, "\n",
              "{\"id\":\"hello\",\"op\":\"hello\",\"protocolVersion\":1}\n",
              "{\"id\":\"close\",\"op\":\"close\"}\n"])
      val overlong = CharVector.tabulate (Adapter.lineLimit + 8, fn _ => #"x")
      val drained =
        runMemory
          (String.concat
             [overlong, "\n",
              "{\"id\":\"hello\",\"op\":\"hello\",\"protocolVersion\":1}\n",
              "{\"id\":\"close\",\"op\":\"close\"}\n"])
    in
      Check.that ("hostile nesting does not kill the adapter", List.length emitted = 3);
      Check.that
        ("hostile nesting emits a structured error", typeOf (List.nth (emitted, 0)) = SOME "error");
      Check.that
        ("the adapter recovers after hostile nesting",
         typeOf (List.nth (emitted, 1)) = SOME "ready");
      Check.that ("an overlong line drains exactly once", List.length drained = 3);
      Check.that
        ("an overlong line emits a structured error",
         typeOf (List.nth (drained, 0)) = SOME "error");
      Check.that
        ("a valid command after an overlong line is recovered",
         typeOf (List.nth (drained, 1)) = SOME "ready")
    end

  (* Hold the real queue with nothing draining it. This makes coalescing fully
     deterministic and proves the budget includes an output already in flight. *)
  fun boundedOutput () =
    let
      val sink = Adapter.newStoppedSink ()
      val Adapter.Sink {inFlight, ...} = sink
      val large = CharVector.tabulate (350000, fn _ => #"x")
      fun value index =
        Json.Object
          [("type", Json.String "subscription"),
           ("subscriptionId", Json.String "budget"),
           ("value",
            Json.Object
              [("index", Json.Int (IntInf.fromInt index)), ("text", Json.String large)])]
      fun fill index =
        if index >= 40 then ()
        else (ignore (Adapter.publish (sink, value index, true, 5.0)); fill (index + 1))
    in
      fill 0;
      Check.that
        ("the adapter retains at most the newest sixteen events",
         Adapter.sinkCount sink <= Adapter.outputCountLimit);
      Check.that
        ("the adapter respects its encoded byte budget",
         Adapter.sinkBytes sink <= Adapter.outputByteLimit);
      inFlight := 5900 * 1024;
      Check.that
        ("an in-flight write participates in the global byte bound",
         not (Adapter.publish (sink, value 41, true, 5.0)));
      Check.that ("backpressure drops queued values first", Adapter.sinkCount sink = 1)
    end

  (* Real kernel sockets, not string ports, for the transport the shared
     controller actually uses. *)
  fun tcpMode () =
    let
      val listener = Fixture.listenOn tcpPort
      val server =
        Fixture.spawn
          (fn () =>
             let
               val {channel, reader} = Fixture.acceptPeer listener
             in
               Socket.close listener;
               Adapter.runLoop
                 (fn () => Reader.byte (reader, Clock.deadlineIn 10.0),
                  fn text => Transport.writeAll (channel, text, Clock.deadlineIn 2.0));
               Transport.close channel
             end)
      val channel =
        Transport.connect
          {host = "127.0.0.1", port = tcpPort, secure = false,
           deadline = Clock.deadlineIn 3.0}
      val reader = Reader.new channel
      fun line () =
        case Reader.line (reader, Clock.deadlineIn 5.0) of
            SOME text => Json.decode text
          | NONE => raise Fail "the TCP adapter closed early"
    in
      Transport.writeAll
        (channel,
         "{\"protocolVersion\":1,\"id\":\"tcp-hello\",\"op\":\"hello\"}\n"
         ^ "{\"id\":\"tcp-close\",\"op\":\"close\"}\n",
         Clock.deadlineIn 2.0);
      Check.that ("the TCP adapter answers hello", idOf (line ()) = SOME "tcp-hello");
      Check.that ("the TCP adapter answers close", typeOf (line ()) = SOME "closed");
      Transport.close channel;
      Fixture.join (server, 5.0, "the TCP adapter")
    end

  (* The shared harness selects the TCP transport with ADAPTER_LISTEN, so a
     malformed address must be rejected rather than silently ignored. *)
  fun listenAddress () =
    (Check.that
       ("ADAPTER_LISTEN is parsed into a host and a port",
        Adapter.parseListen "127.0.0.1:19301" = ("127.0.0.1", 19301));
     Check.raises
       ("ADAPTER_LISTEN without a port is rejected",
        fn () => Adapter.parseListen "127.0.0.1");
     Check.raises
       ("ADAPTER_LISTEN with an out-of-range port is rejected",
        fn () => Adapter.parseListen "127.0.0.1:70000"))

  fun run () =
    (envelopes (); hostileInput (); boundedOutput (); listenAddress (); tcpMode ())
end

fun main () = Check.run ("adapter-test", AdapterTest.run)
