(* Real TLS, end to end, against a locally generated certificate.

   The Docker test stage generates a private certificate authority, issues a
   certificate for `localhost` only, starts `openssl s_server` on TLS_TEST_PORT,
   and points SSL_CERT_FILE at that authority. This test then proves the two
   things the transport must get right: a trusted certificate for the requested
   name works, and a trusted certificate for a different name does not. *)

use "client/sources.sml";
use "client/tests/check.sml";

structure TlsTest =
struct
  fun port () =
    case Option.mapPartial Int.fromString (OS.Process.getEnv "TLS_TEST_PORT") of
        SOME value => value
      | NONE => 19600

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

  fun run () =
    (Check.that
       ("a trusted certificate for the requested name completes a TLS exchange",
        Text.startsWith ("HTTP/1.0 200", exchange "localhost"));
     (* The certificate carries only DNS:localhost, so asking for the address
        must fail the name check rather than fall back to the chain alone. *)
     Check.failureNamed
       ("a trusted certificate for a different name is rejected", "TransportError",
        fn () => exchange "127.0.0.1"))
end

fun main () = Check.run ("tls-test", TlsTest.run)
