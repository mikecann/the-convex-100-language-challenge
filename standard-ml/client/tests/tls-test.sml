(* Real TLS, end to end, against a locally generated certificate.

   The Docker test stage generates a private certificate authority, issues a
   certificate for `localhost` only, starts `openssl s_server` on TLS_TEST_PORT,
   and points SSL_CERT_FILE at that authority. This test then proves the three
   things the transport must get right: a trusted certificate for the requested
   name works, a trusted certificate for a different name does not, and an
   attempt that is abandoned part-way through releases everything it built. *)

use "client/sources.sml";
use "client/tests/check.sml";
use "client/tests/fixture.sml";

structure TlsTest =
struct
  val abortPort = 19601

  (* Enough abandoned handshakes that a context, session, or memory buffer left
     behind by one of them would be plainly visible. Those objects live in the C
     heap, where Poly/ML's collector cannot reach them, so the only thing that
     frees them is the transport's own cleanup path. The warm-up pays for the
     one-time library load and lets the allocator settle, so the measured run
     starts from a steady process; the ceiling then allows well under 100 kB of
     drift per attempt, which a retained context would exceed several times
     over. *)
  val warmupAttempts = 20
  val abortAttempts = 300
  val residentCeiling = 24 * 1024 * 1024

  fun port () =
    case Option.mapPartial Int.fromString (OS.Process.getEnv "TLS_TEST_PORT") of
        SOME value => value
      | NONE => 19600

  (* Resident pages straight from the kernel. This is a gross-leak guard, not an
     allocation counter: it catches a failure path that forgot to free an
     OpenSSL object, not a few stray bytes. *)
  fun residentBytes () =
    let
      val stream = TextIO.openIn "/proc/self/statm"
      val text = TextIO.inputAll stream handle exn => (TextIO.closeIn stream; raise exn)
      val _ = TextIO.closeIn stream
    in
      case String.tokens Char.isSpace text of
          _ :: resident :: _ =>
            (case Int.fromString resident of
                 SOME pages => pages * 4096
               | NONE => raise Fail "could not read the resident page count")
        | _ => raise Fail "could not read /proc/self/statm"
    end

  fun exchange host =
    let
      val channel =
        Transport.connect
          {host = host, port = port (), secure = true, deadline = Clock.deadlineIn 5.0}
      val reader = Reader.new channel
      val status =
        (Transport.writeAll
           (channel, "GET / HTTP/1.0\r\nHost: " ^ host ^ "\r\n\r\n", Clock.deadlineIn 5.0);
         Reader.line (reader, Clock.deadlineIn 5.0))
        handle exn => (Transport.close channel; raise exn)
    in
      Transport.close channel;
      Option.getOpt (status, "")
    end

  (* A peer that accepts the connection, reads the ClientHello, and then goes
     away leaves the client holding a context, a session, and two memory
     buffers with nothing left to complete. Repeating that many times is the
     regression: every one of those attempts has to release everything it
     created, and the process must not grow. *)
  fun abandonedHandshakes () =
    let
      val listener = Fixture.listenOn abortPort
      val server =
        Fixture.spawn
          (fn () =>
             let
               fun serve remaining =
                 if remaining <= 0 then ()
                 else
                   let
                     val peer = Fixture.acceptPeer listener
                   in
                     (* Draining first makes the close a clean end of stream
                        rather than a reset, so every attempt fails the same
                        way. *)
                     (ignore (Transport.readSome (#channel peer, 16384, Clock.deadlineIn 5.0))
                      handle _ => ());
                     Fixture.closePeer peer;
                     serve (remaining - 1)
                   end
             in
               serve (warmupAttempts + abortAttempts);
               Socket.close listener
             end)
      fun attempt () =
        (ignore
           (Transport.connect
              {host = "127.0.0.1", port = abortPort, secure = true,
               deadline = Clock.deadlineIn 5.0});
         false)
        handle ConvexError.Error {name, ...} => name = "TransportError"
      fun loop (remaining, structured) =
        if remaining <= 0 then structured
        else loop (remaining - 1, attempt () andalso structured)
      val warmed = loop (warmupAttempts, true)
      val baseline = residentBytes ()
      (* The measured run is always performed, whatever the warm-up reported, so
         the fixture is never left waiting for connections that never come. *)
      val structured = loop (abortAttempts, true) andalso warmed
    in
      Check.that
        ("every abandoned TLS handshake is a structured transport failure", structured);
      Check.that
        ("abandoned TLS handshakes release everything they allocated",
         residentBytes () - baseline < residentCeiling);
      Fixture.join (server, 60.0, "the abandoned handshake fixture")
    end

  fun run () =
    (Check.that
       ("a trusted certificate for the requested name completes a TLS exchange",
        Text.startsWith ("HTTP/1.0 200", exchange "localhost"));
     (* The certificate carries only DNS:localhost, so asking for the address
        must fail the name check rather than fall back to the chain alone. *)
     Check.failureNamed
       ("a trusted certificate for a different name is rejected", "TransportError",
        fn () => exchange "127.0.0.1");
     abandonedHandshakes ())
end

fun main () = Check.run ("tls-test", TlsTest.run)
