(* Encoding-level tests: strict JSON, the digest and base64 helpers the
   WebSocket handshake depends on, Convex's sync timestamp spelling, and
   deployment URL parsing. These are the layers every later test assumes. *)

use "client/sources.sml";
use "client/tests/check.sml";

structure JsonTest =
struct
  fun decodes (label, text) =
    Check.that (label, (ignore (Json.decode text); true) handle _ => false)

  fun rejects (label, text) =
    Check.that (label, (ignore (Json.decode text); false) handle _ => true)

  fun numbers () =
    (Check.that
       ("integers stay exact",
        Json.asInt (Json.decode "9007199254740993") = SOME 9007199254740993);
     (* Convex may spell an integral counter as 0.0; the example decodes both. *)
     Check.that ("integral decimals are accepted", Json.asInt (Json.decode "1.0") = SOME 1);
     Check.that ("integral exponents are accepted", Json.asInt (Json.decode "1e2") = SOME 100);
     Check.that
       ("negative integral decimals are accepted", Json.asInt (Json.decode "-0.0") = SOME 0);
     Check.that ("fractional numbers are not integers", Json.asInt (Json.decode "1.5") = NONE);
     Check.that ("quoted numbers are not integers", Json.asInt (Json.decode "\"1\"") = NONE);
     rejects ("a bare minus is malformed", "-");
     rejects ("a trailing dot is malformed", "1.");
     rejects ("an empty exponent is malformed", "1e");
     rejects ("an empty signed exponent is malformed", "1e+");
     rejects ("a leading zero is malformed", "01");
     rejects ("a bare decimal point is malformed", ".5");
     decodes ("a lone zero is fine", "0");
     decodes ("a zero fraction is fine", "0.5");
     Check.that
       ("non-finite numbers cannot be encoded",
        (ignore (Json.encode (Json.Real (0.0 / 0.0))); false) handle _ => true))

  fun strings () =
    (* Json.value carries reals, so it is not an equality type; the tests
       compare canonical encodings instead. *)
    (Check.that
       ("surrogate pairs become one code point",
        Json.encode (Json.decode "\"\\uD834\\uDD1E\"")
        = Json.encode (Json.String "\240\157\132\158"));
     rejects ("an unpaired high surrogate is rejected", "\"\\uD834\"");
     rejects ("an unpaired low surrogate is rejected", "\"\\uDD1E\"");
     rejects ("raw control characters are rejected", "\"\001\"");
     rejects ("invalid UTF-8 is rejected", "\"\255\"");
     Check.that
       ("multibyte text round-trips",
        Json.encode (Json.decode (Json.encode (Json.String "\233\155\170"))) = "\"\233\155\170\""))

  fun envelopes () =
    (decodes ("a well-formed object decodes", "{\"a\":[1,true,null]}");
     rejects ("trailing data is rejected", "{} trailing");
     rejects ("an unterminated object is rejected", "{");
     rejects ("an empty document is rejected", "");
     (* This exact shape previously exhausted a 128 MiB runtime in another
        client, so the depth limit is enforced before any value is built. *)
     rejects
       ("hostile nesting is rejected before allocation",
        CharVector.tabulate (200000, fn _ => #"[")
        ^ CharVector.tabulate (200000, fn _ => #"]"));
     rejects
       ("a dense but shallow payload hits the node limit",
        "[" ^ String.concatWith "," (List.tabulate (Json.maxNodes + 10, fn _ => "1")) ^ "]");
     Check.that
       ("duplicate keys are preserved for strict command checking",
        case Json.asEntries (Json.decode "{\"a\":1,\"a\":2}") of
            SOME entries => List.length entries = 2
          | NONE => false))

  fun digests () =
    (Check.that
       ("SHA-1 matches its published vector",
        Bytes.toHex (Sha1.hash "abc") = "a9993e364706816aba3e25717850c26c9cd0d89d");
     Check.that
       ("SHA-1 matches the empty vector",
        Bytes.toHex (Sha1.hash "") = "da39a3ee5e6b4b0d3255bfef95601890afd80709");
     Check.that
       ("SHA-1 matches the pangram vector",
        Bytes.toHex (Sha1.hash "The quick brown fox jumps over the lazy dog")
        = "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12");
     Check.that ("base64 pads one byte", Base64.encode "a" = "YQ==");
     Check.that ("base64 pads two bytes", Base64.encode "ab" = "YWI=");
     Check.that
       ("base64 round-trips", Base64.decode (Base64.encode "\000\255\128") = "\000\255\128");
     Check.raises ("base64 rejects a ragged length", fn () => Base64.decode "YQ=");
     (* The RFC 6455 example: this is the handshake the Live client performs. *)
     Check.that
       ("the WebSocket accept key matches RFC 6455",
        WebSocket.acceptFor "dGhlIHNhbXBsZSBub25jZQ==" = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))

  fun timestamps () =
    (Check.that ("the zero timestamp is canonical", Timestamp.encode 0 = Timestamp.initial);
     Check.that ("255 encodes little-endian", Timestamp.encode 255 = "/wAAAAAAAAA=");
     Check.that ("256 carries into the next byte", Timestamp.encode 256 = "AAEAAAAAAAA=");
     Check.that
       ("timestamps round-trip", Timestamp.decode (Timestamp.encode 1234567890) = 1234567890);
     Check.failureNamed
       ("a non-canonical timestamp is protocol drift", "ProtocolError",
        fn () => Timestamp.decode "AAAAAAAAAAF=");
     Check.failureNamed
       ("a short timestamp is protocol drift", "ProtocolError",
        fn () => Timestamp.decode "AAAA"))

  fun urls () =
    (Check.that ("an https origin parses", #secure (Url.parse "https://example.convex.cloud"));
     Check.that
       ("the default port is inferred", #port (Url.parse "https://example.convex.cloud") = 443);
     Check.that ("an explicit port is kept", #port (Url.parse "http://127.0.0.1:3210") = 3210);
     Check.that
       ("a non-default port appears in the Host header",
        Url.hostHeader (Url.parse "http://127.0.0.1:3210") = "127.0.0.1:3210");
     Check.raises ("credentials are rejected", fn () => Url.parse "https://user:pass@host");
     Check.raises ("a query string is rejected", fn () => Url.parse "https://host/?a=1");
     Check.raises ("a header injection is rejected", fn () => Url.parse "https://host\r\nX: 1"))

  fun run () =
    (numbers (); strings (); envelopes (); digests (); timestamps (); urls ())
end

fun main () = Check.run ("json-test", JsonTest.run)
