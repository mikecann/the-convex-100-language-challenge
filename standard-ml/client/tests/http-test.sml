(* Real HTTP over real kernel sockets.

   The fixture is a deliberately dumb server: it records exactly what the client
   put on the wire and replies with a fixed script, including one reply that is
   not Convex JSON at all. That makes the request shape, the bearer-token
   lifecycle, and the malformed-envelope path all observable. *)

use "client/sources.sml";
use "client/tests/check.sml";
use "client/tests/fixture.sml";

structure HttpTest =
struct
  val servicePort = 19100
  val stallPort = 19101
  val framingPort = 19102

  (* U+96EA, three UTF-8 bytes, as escapes: a Standard ML string literal may
     only contain printable ASCII. *)
  val snowflake = "\233\155\170"

  val script =
    ["{\"status\":\"success\",\"value\":{\"count\":7,\"text\":\"" ^ snowflake
     ^ "\"},\"logLines\":[\"query-log\"]}",
     "{\"status\":\"error\",\"errorMessage\":\"counter rejected\","
     ^ "\"errorData\":{\"code\":\"DENIED\"},\"logLines\":[\"mutation-log\"]}",
     "{\"status\":\"success\",\"value\":[true,null,2.5],\"logLines\":[]}",
     "{\"status\":\"success\",\"value\":1,\"logLines\":[]}",
     "{\"status\":\"success\",\"value\":2,\"logLines\":[]}",
     "{\"status\":\"success\",\"value\":3,\"logLines\":[]}",
     "not-json"]

  val captured : Fixture.request list ref = ref []
  val captureMutex = Thread.Mutex.mutex ()

  fun record request =
    Guard.critical (captureMutex, fn () => captured := !captured @ [request])

  fun serve listener =
    (List.app
       (fn body =>
          let
            val peer = Fixture.acceptPeer listener
          in
            record (Fixture.readRequest peer);
            Fixture.respond (peer, body);
            Fixture.closePeer peer
          end)
       script;
     Socket.close listener)

  fun nth index = List.nth (!captured, index)

  fun headerAt (index, name) = Fixture.headerOf (nth index, name)

  fun successPath () =
    let
      val client = Convex.client (Fixture.urlFor servicePort)
      val {value, logs} =
        Convex.query
          (client, "demo:state",
           Json.Object
             [("room", Json.String "nested"),
              ("input", Json.Object [("array", Json.Array [Json.Int 1, Json.Bool true])])])
    in
      Check.that
        ("the query value decodes",
         Json.asInt (Json.getOr (value, "count", Json.Null)) = SOME 7);
      Check.that
        ("multibyte values survive the round trip",
         Json.asString (Json.getOr (value, "text", Json.Null)) = SOME snowflake);
      Check.that ("query log lines are carried", logs = ["query-log"]);

      (* A failing Convex function is a structured FunctionError, not a value. *)
      Check.that
        ("a function failure keeps its structure",
         (ignore (Convex.mutation (client, "demo:increment", Json.Object [])); false)
         handle ConvexError.Error {name, message, data, logs, ...} =>
                  name = "FunctionError" andalso message = "counter rejected"
                  andalso Json.asString (Json.getOr (data, "code", Json.Null)) = SOME "DENIED"
                  andalso logs = ["mutation-log"]
              | _ => false);

      Check.that
        ("actions return arbitrary JSON",
         Json.encode (#value (Convex.action (client, "demo:echo", Json.Object [])))
         = "[true,null,2.5]");

      (* The bearer token is opaque: set, replaced, and cleared. *)
      Convex.setAuth (client, "opaque token:one");
      ignore (Convex.query (client, "demo:state", Json.Object []));
      Convex.setAuth (client, "replacement-token");
      ignore (Convex.query (client, "demo:state", Json.Object []));
      Convex.setAuth (client, "");
      ignore (Convex.query (client, "demo:state", Json.Object []));

      Check.failureNamed
        ("a non-Convex body is a transport failure", "TransportError",
         fn () => Convex.query (client, "demo:state", Json.Object []));
      Convex.close client
    end

  fun wireChecks () =
    (Check.that ("every request reached the fixture", List.length (!captured) = List.length script);
     Check.that
       ("queries use the query endpoint",
        Text.startsWith ("POST /api/query ", #line (nth 0)));
     Check.that
       ("mutations use the mutation endpoint",
        Text.startsWith ("POST /api/mutation ", #line (nth 1)));
     Check.that
       ("actions use the action endpoint",
        Text.startsWith ("POST /api/action ", #line (nth 2)));
     Check.that
       ("the client identifies itself",
        headerAt (0, "convex-client") = SOME "standard-ml-0.1.0");
     Check.that ("no token means no Authorization header", headerAt (0, "authorization") = NONE);
     Check.that
       ("an opaque token is sent verbatim",
        headerAt (3, "authorization") = SOME "Bearer opaque token:one");
     Check.that
       ("a replacement token takes effect",
        headerAt (4, "authorization") = SOME "Bearer replacement-token");
     Check.that ("clearing the token removes the header", headerAt (5, "authorization") = NONE);
     let
       val body = Json.decode (#body (nth 0))
     in
       Check.that
         ("the request names the function",
          Json.asString (Json.getOr (body, "path", Json.Null)) = SOME "demo:state");
       Check.that
         ("the documented JSON format is requested",
          Json.asString (Json.getOr (body, "format", Json.Null)) = SOME "json");
       Check.that
         ("arguments are a named object",
          Json.isObject (Json.getOr (body, "args", Json.Null)))
     end)

  fun injectionChecks () =
    (Check.raises
       ("a token containing CRLF is rejected",
        fn () => Convex.setAuth (Convex.client "http://127.0.0.1:1", "bad\r\ntoken"));
     Check.raises
       ("a client version containing CRLF is rejected",
        fn () =>
          Convex.make
            {url = "http://127.0.0.1:1", authToken = "", version = "bad\r\nversion"}))

  (* Response framing a client may not resolve in the server's favour. Each
     entry is a complete raw response; the client must refuse it as protocol
     drift, and the final entry proves the connection after a refusal is still
     usable, so one bad response never strands the client. *)
  val framingScript =
    [("a status line without a version",
      "200 OK\r\nContent-Length: 2\r\n\r\n{}"),
     ("a status line with a non-numeric code",
      "HTTP/1.1 2O0 OK\r\nContent-Length: 2\r\n\r\n{}"),
     ("a status line with a code outside the assigned range",
      "HTTP/1.1 099 Nope\r\nContent-Length: 2\r\n\r\n{}"),
     ("a status line that runs the code into the reason phrase",
      "HTTP/1.1 200OK\r\nContent-Length: 2\r\n\r\n{}"),
     ("a repeated Content-Length",
      "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}"),
     ("a conflicting Content-Length",
      "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 40\r\n\r\n{}"),
     ("a Content-Length that is not a plain decimal",
      "HTTP/1.1 200 OK\r\nContent-Length: +2\r\n\r\n{}"),
     ("a Content-Length with trailing rubbish",
      "HTTP/1.1 200 OK\r\nContent-Length: 2junk\r\n\r\n{}"),
     ("a chunked transfer coding",
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n"),
     ("a repeated Transfer-Encoding",
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: identity\r\nTransfer-Encoding: chunked\r\n\r\n{}"),
     ("both framing headers at once",
      "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n{}"),
     ("a header name with a space before its colon",
      "HTTP/1.1 200 OK\r\nContent-Length : 2\r\n\r\n{}"),
     ("an obsolete folded header line",
      "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\tjunk\r\n\r\n{}")]

  fun framingServer listener =
    (List.app
       (fn (_, response) =>
          let
            val peer = Fixture.acceptPeer listener
          in
            ignore (Fixture.readRequest peer);
            Fixture.send (peer, response);
            Fixture.closePeer peer
          end)
       framingScript;
     (let
        val peer = Fixture.acceptPeer listener
      in
        ignore (Fixture.readRequest peer);
        Fixture.respond (peer, "{\"status\":\"success\",\"value\":7,\"logLines\":[]}");
        Fixture.closePeer peer
      end);
     Socket.close listener)

  fun framingChecks () =
    let
      val listener = Fixture.listenOn framingPort
      val server = Fixture.spawn (fn () => framingServer listener)
      val client = Convex.client (Fixture.urlFor framingPort)
    in
      List.app
        (fn (label, _) =>
           Check.failureNamed
             (label ^ " is refused as protocol drift", "ProtocolError",
              fn () => Convex.query (client, "demo:state", Json.Object [])))
        framingScript;
      (* Recovery: a refused response closes only its own connection. *)
      Check.that
        ("a well-framed response after a refused one still works",
         Json.asInt (#value (Convex.query (client, "demo:state", Json.Object []))) = SOME 7);
      Convex.close client;
      Fixture.join (server, 20.0, "the HTTP framing fixture")
    end

  (* Name resolution is the one blocking call the Basis Library gives no
     deadline, so these prove the three properties the Live owner depends on:
     a literal address never reaches the resolver, a caller is released at its
     own deadline however long the resolver takes, and an answer is reused. *)
  fun resolverChecks () =
    let
      fun elapsed body =
        let
          val started = Clock.now ()
          val outcome = (body (); true) handle _ => false
        in
          (outcome, Time.toReal (Time.- (Clock.now (), started)))
        end
      (* An expired deadline is the strongest form of the question: a literal
         address must still convert, because no lookup is involved at all. *)
      val (literal, literalSeconds) =
        elapsed (fn () => ignore (Resolver.address ("127.0.0.1", Clock.deadlineIn 0.0)))
      (* The same expired deadline against a name must come straight back
         instead of waiting for the resolver thread it just started. *)
      val (named, namedSeconds) =
        elapsed
          (fn () => ignore (Resolver.address ("standard-ml-unresolvable.invalid",
                                              Clock.deadlineIn 0.0)))
      val _ = ignore (Resolver.address ("localhost", Clock.deadlineIn 5.0))
      (* Cached, so a reconnecting owner never re-enters the resolver. *)
      val (repeated, repeatedSeconds) =
        elapsed (fn () => ignore (Resolver.address ("localhost", Clock.deadlineIn 0.0)))
    in
      Check.that ("a literal address resolves without a lookup", literal);
      Check.that ("a literal address never waits", literalSeconds < 0.5);
      Check.that ("an unanswered lookup releases its caller", not named);
      Check.that ("an unanswered lookup releases it at the deadline", namedSeconds < 0.5);
      Check.that ("a resolved name is reused", repeated);
      Check.that ("a reused name never waits again", repeatedSeconds < 0.5);
      Check.failureNamed
        ("an unresolvable name is a structured transport failure", "TransportError",
         fn () =>
           ignore
             (Resolver.address ("standard-ml-unresolvable.invalid", Clock.deadlineIn 5.0)))
    end

  (* A peer that completes TCP and then says nothing must not hold a caller for
     OpenSSL's own default handshake timeout. *)
  fun stallChecks () =
    let
      val listener = Fixture.listenOn stallPort
      val server =
        Fixture.spawn
          (fn () =>
             let
               val peer = Fixture.acceptPeer listener
             in
               Socket.close listener;
               Clock.sleep 4.0;
               Fixture.closePeer peer
             end)
      val client = Convex.client ("https://127.0.0.1:" ^ Int.toString stallPort)
      val started = Clock.now ()
    in
      Check.failureNamed
        ("a stalled TLS handshake is a structured transport failure", "TransportError",
         fn () => Convex.query (client, "demo:state", Json.Object []));
      Check.that
        ("the TLS handshake deadline is bounded",
         Time.toReal (Time.- (Clock.now (), started)) < 3.5);
      Convex.close client;
      Fixture.join (server, 8.0, "TLS stall fixture")
    end

  fun run () =
    let
      val listener = Fixture.listenOn servicePort
      val server = Fixture.spawn (fn () => serve listener)
    in
      successPath ();
      Fixture.join (server, 10.0, "HTTP fixture");
      wireChecks ();
      injectionChecks ();
      framingChecks ();
      resolverChecks ();
      stallChecks ()
    end
end

fun main () = Check.run ("http-test", HttpTest.run)
