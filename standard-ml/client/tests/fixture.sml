(* Deterministic language-local fixtures.

   These are real kernel sockets speaking raw HTTP and raw RFC 6455 bytes, not
   mocks of the client's own transport. That is what lets the tests below drive
   fragmentation, malformed envelopes, stalled half-frames, and genuine
   reconnects without a Convex deployment. *)

structure Fixture =
struct
  type peer = {channel: Transport.t, reader: Reader.t}

  (* Fixtures are generous: a deadline that fires here should mean the client
     stopped talking, not that the fixture was impatient. *)
  val patience = 10.0

  fun deadline () = Clock.deadlineIn patience

  fun loopback () = Transport.resolve "127.0.0.1"

  fun listenOn port =
    let
      val listener = INetSock.TCP.socket ()
    in
      Socket.Ctl.setREUSEADDR (listener, true);
      Socket.bind (listener, INetSock.toAddr (loopback (), port));
      Socket.listen (listener, 8);
      listener
    end

  fun acceptPeer listener : peer =
    let
      val (accepted, _) = Socket.accept listener
      val channel = Transport.ofSocket accepted
    in
      {channel = channel, reader = Reader.new channel}
    end

  fun closePeer ({channel, ...} : peer) = Transport.close channel

  fun send ({channel, ...} : peer, text) = Transport.writeAll (channel, text, deadline ())

  fun urlFor port = "http://127.0.0.1:" ^ Int.toString port

  (* ---- HTTP ---------------------------------------------------------- *)

  type request = {line: string, headers: (string * string) list, body: string}

  fun readRequest (peer as {reader, ...} : peer) : request =
    let
      val requestLine =
        case Reader.line (reader, deadline ()) of
            SOME text => text
          | NONE => raise Fail "fixture saw no request line"
      fun headers acc =
        case Reader.line (reader, deadline ()) of
            NONE => raise Fail "fixture request ended in its headers"
          | SOME "" => List.rev acc
          | SOME line =>
              (case Text.indexFrom (line, #":", 0) of
                   NONE => raise Fail "fixture request header is malformed"
                 | SOME index =>
                     headers
                       ((Text.lower (String.substring (line, 0, index)),
                         Text.trim (String.extract (line, index + 1, NONE))) :: acc))
      val collected = headers []
      val length =
        case List.find (fn (key, _) => key = "content-length") collected of
            SOME (_, value) => Option.getOpt (Int.fromString value, 0)
          | NONE => 0
    in
      {line = requestLine, headers = collected,
       body = Reader.exact (reader, length, deadline ())}
    end

  fun headerOf ({headers, ...} : request, name) =
    Option.map #2 (List.find (fn (key, _) => key = name) headers)

  fun respond (peer, body) =
    send
      (peer,
       String.concat
         ["HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n",
          "Content-Length: ", Int.toString (String.size body), "\r\n\r\n", body])

  (* ---- WebSocket ------------------------------------------------------ *)

  fun handshake (peer as {reader, ...} : peer) =
    let
      val request = readRequest peer
      val key =
        case headerOf (request, "sec-websocket-key") of
            SOME value => value
          | NONE => raise Fail "fixture handshake had no key"
    in
      send
        (peer,
         String.concat
           ["HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n",
            "Connection: Upgrade\r\nSec-WebSocket-Accept: ",
            Base64.encode (Sha1.hash (key ^ WebSocket.guid)), "\r\n\r\n"]);
      request
    end

  type serverFrame = {fin: bool, opcode: int, payload: string}

  (* Client frames must be masked; the fixture asserts that rather than quietly
     accepting an unmasked frame. *)
  fun readClientFrame ({reader, ...} : peer) : serverFrame option =
    case Reader.byte (reader, deadline ()) of
        NONE => NONE
      | SOME first =>
          let
            val header = Char.ord first
            val second =
              case Reader.byte (reader, deadline ()) of
                  SOME character => Char.ord character
                | NONE => raise Fail "fixture saw a truncated frame"
            val masked = second >= 128
            val marker = second mod 128
            val length =
              if marker < 126 then marker
              else if marker = 126 then
                Bytes.readU16 (Reader.exact (reader, 2, deadline ()), 0)
              else IntInf.toInt (Bytes.readU64 (Reader.exact (reader, 8, deadline ()), 0))
            val _ = if masked then () else raise Fail "client frame was not masked"
            val mask = Reader.exact (reader, 4, deadline ())
            val payload = Reader.exact (reader, length, deadline ())
          in
            SOME
              {fin = header >= 128, opcode = header mod 16,
               payload = Bytes.xorMask (payload, mask)}
          end

  fun sendServerFrame (peer, fin, opcode, payload) =
    let
      val size = String.size payload
      val length =
        if size < 126 then Bytes.ofByte size
        else if size < 65536 then Bytes.ofByte 126 ^ Bytes.u16 size
        else raise Fail "fixture frame is unexpectedly large"
    in
      send (peer, String.concat [Bytes.ofByte ((if fin then 128 else 0) + opcode), length, payload])
    end

  fun sendServerText (peer, text) = sendServerFrame (peer, true, 1, text)

  (* Skip control frames until the named message arrives. *)
  fun readClientJson (peer, expected) =
    let
      fun loop () =
        case readClientFrame peer of
            NONE => raise Fail ("fixture never saw a " ^ expected)
          | SOME {opcode = 1, payload, ...} =>
              let
                val message = Json.decode payload
              in
                if Json.asString (Json.getOr (message, "type", Json.Null)) = SOME expected then
                  message
                else loop ()
              end
          | SOME {opcode = 8, ...} =>
              raise Fail ("client closed before sending a " ^ expected)
          | SOME _ => loop ()
    in
      loop ()
    end

  (* Drain until the client goes away, reporting whether it answered a ping.
     A frame error or a half-read frame ends the wait but must not be reported
     as a pong, or the ping assertions above would pass for the wrong reason. *)
  fun waitForDisconnect peer =
    let
      val sawPong = ref false
      fun loop () =
        case readClientFrame peer of
            NONE => ()
          | SOME {opcode = 10, ...} => (sawPong := true; loop ())
          | SOME _ => loop ()
    in
      (loop () handle _ => ());
      !sawPong
    end

  (* ---- background fixtures -------------------------------------------- *)

  type background = {done: Latch.t, failure: exn option ref}

  fun spawn body : background =
    let
      val done = Latch.new ()
      val failure = ref NONE
      fun run () =
        ((body ()
          handle exn =>
            (failure := SOME exn;
             TextIO.output (TextIO.stdErr, "fixture failed: " ^ ConvexError.describe exn ^ "\n");
             TextIO.flushOut TextIO.stdErr));
         Latch.release done)
    in
      ignore (Thread.Thread.fork (run, []));
      {done = done, failure = failure}
    end

  fun join ({done, failure} : background, seconds, label) =
    (Check.that (label ^ " finished", Latch.awaitSeconds (done, seconds));
     Check.that (label ^ " reported no failure", not (Option.isSome (!failure))))
end
