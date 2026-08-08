//
// Unit coverage for the pieces of the client that have no socket in them:
// the JSON scanner, SHA-1, base64, RFC 6455 framing, URL parsing and the
// protocol's scalar validators.
//

ConvexUnitTest := Object clone do(
    hex := method(bytes,
        out := Sequence clone
        for(index, 0, bytes size - 1, out appendSeq(ConvexJson twoHexDigits(bytes at(index))))
        out asSymbol
    )

    run := method(
        ConvexTest begin("json/encode")
        ConvexTest equals(Convex string("plain"), "\"plain\"", "plain strings are quoted")
        ConvexTest equals(
            Convex string("say \"hi\"\n"),
            "\"say \\\"hi\\\"\\n\"",
            "quotes and newlines are escaped"
        )
        ConvexTest equals(
            Convex string(Sequence clone append(1) asSymbol),
            "\"\\u0001\"",
            "control bytes become \\u escapes"
        )
        // A multi-byte UTF-8 sequence must survive untouched rather than being
        // re-encoded into escapes.
        ConvexTest equals(
            Convex string("héllo") size,
            8,
            "UTF-8 bytes pass through unchanged"
        )
        ConvexTest equals(
            Convex object(list("a", "1", "b", Convex string("x"))),
            "{\"a\":1,\"b\":\"x\"}",
            "objects join encoded members"
        )
        ConvexTest equals(Convex array(list("1", "2")), "[1,2]", "arrays join encoded members")

        ConvexTest begin("json/scan")
        document := "{\"a\":{\"b\":[1,2,{\"c\":\"}\"}]},\"d\":\"e\",\"n\":null}"
        ConvexTest equals(
            Convex field(document, "a"),
            "{\"b\":[1,2,{\"c\":\"}\"}]}",
            "a nested subtree is returned byte for byte"
        )
        ConvexTest equals(Convex field(document, "d"), "\"e\"", "a later member is still found")
        ConvexTest equals(Convex field(document, "n"), "null", "null is returned as its literal")
        ConvexTest ok(
            ConvexJson field(document, "missing") isNil,
            "an absent member reads as nil"
        )
        ConvexTest equals(
            ConvexJson elements("[1,\"two\",[3],{\"four\":4}]") size,
            4,
            "array elements are split without decoding"
        )
        ConvexTest equals(
            ConvexJson elements("[1,\"two\",[3],{\"four\":4}]") at(3),
            "{\"four\":4}",
            "an object element keeps its bytes"
        )
        ConvexTest equals(ConvexJson elements("[]") size, 0, "an empty array has no elements")
        ConvexTest raisesNamed("ProtocolError", "trailing bytes are rejected",
            ConvexJson validate("{\"a\":1} junk")
        )
        ConvexTest raisesNamed("ProtocolError", "an unterminated container is rejected",
            ConvexJson validate("{\"a\":[1,2")
        )
        ConvexTest raisesNamed("ProtocolError", "an unterminated string is rejected",
            ConvexJson validate("{\"a\":\"oops}")
        )

        ConvexTest begin("json/decode")
        ConvexTest equals(Convex text("\"a\\/b\""), "a/b", "an escaped solidus decodes")
        ConvexTest equals(Convex text("\"\\u0041\""), "A", "a BMP escape decodes")
        // U+1F600 arrives as a surrogate pair and must become four UTF-8 bytes.
        ConvexTest equals(
            Convex text("\"\\ud83d\\ude00\"") size,
            4,
            "a surrogate pair becomes one four-byte scalar"
        )
        ConvexTest equals(
            ConvexUnitTest hex(Convex text("\"\\ud83d\\ude00\"")),
            "f09f9880",
            "the surrogate pair decodes to the right bytes"
        )
        ConvexTest raisesNamed("ProtocolError", "an unknown escape is rejected",
            Convex text("\"\\q\"")
        )

        ConvexTest begin("json/protocol-scalars")
        ConvexTest equals(ConvexJson decodeUint32("0", "n"), 0, "zero is a valid counter")
        ConvexTest equals(
            ConvexJson decodeUint32(" 4294967295 ", "n"),
            4294967295,
            "the maximum uint32 is accepted"
        )
        ConvexTest raisesNamed("ProtocolError", "a quoted counter is rejected",
            ConvexJson decodeUint32("\"1\"", "n")
        )
        ConvexTest raisesNamed("ProtocolError", "a fractional counter is rejected",
            ConvexJson decodeUint32("1.0", "n")
        )
        ConvexTest raisesNamed("ProtocolError", "a leading zero is rejected",
            ConvexJson decodeUint32("01", "n")
        )
        ConvexTest raisesNamed("ProtocolError", "an out of range counter is rejected",
            ConvexJson decodeUint32("4294967296", "n")
        )
        ConvexTest raisesNamed("ProtocolError", "a boolean is not a string",
            ConvexJson decodeRequiredString("true", "s")
        )

        ConvexTest begin("sha1")
        ConvexTest equals(
            ConvexUnitTest hex(ConvexSha1 digest("")),
            "da39a3ee5e6b4b0d3255bfef95601890afd80709",
            "the empty digest matches the published vector"
        )
        ConvexTest equals(
            ConvexUnitTest hex(ConvexSha1 digest("abc")),
            "a9993e364706816aba3e25717850c26c9cd0d89d",
            "the abc digest matches the published vector"
        )
        ConvexTest equals(
            ConvexUnitTest hex(ConvexSha1 digest("The quick brown fox jumps over the lazy dog")),
            "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12",
            "a multi-word digest matches the published vector"
        )
        // A message that crosses a 64-byte block boundary exercises the second
        // chunk and the length padding together.
        ConvexTest equals(
            ConvexUnitTest hex(ConvexSha1 digest(
                "0123456789012345678901234567890123456789012345678901234567890123456789"
            )),
            "194522b2bdb1f1838a2d2d24a248202001ac6838",
            "a seventy byte message spans two blocks and still digests correctly"
        )

        ConvexTest begin("websocket/handshake-digest")
        // The example key and expected accept value are taken from RFC 6455.
        ConvexTest equals(
            Convex base64(ConvexSha1 digest(
                "dGhlIHNhbXBsZSBub25jZQ==258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
            )),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
            "the RFC 6455 example accept value is reproduced"
        )
        ConvexTest ok(
            Convex base64(Sequence clone appendSeq("abc")) containsSeq("\n") not,
            "base64 output carries no trailing newline"
        )
        // Nine bytes encode to exactly twelve base64 characters with no
        // padding, which is what makes the example's runId a tidy suffix.
        ConvexTest equals(Convex randomToken(9) size, 12, "a nine byte token is twelve characters")
        ConvexTest ok(
            Convex randomToken(9) != Convex randomToken(9),
            "tokens come from the CSPRNG rather than a counter"
        )

        ConvexTest begin("websocket/framing")
        transport := Convex loadTransport
        small := ConvexFrame encode(transport, 1, "hello")
        ConvexTest equals(small at(0), 129, "a final text frame sets FIN and opcode 1")
        ConvexTest ok(small at(1) >= 128, "client frames set the mask bit")
        ConvexTest equals(small size, 2 + 4 + 5, "a short frame has a two byte header")

        medium := ConvexFrame encode(transport, 1, Sequence clone setSize(200))
        ConvexTest equals(medium at(1), 128 + 126, "a 200 byte payload uses the 16 bit length")
        ConvexTest equals(medium size, 4 + 4 + 200, "the 16 bit header is four bytes")

        large := ConvexFrame encode(transport, 1, Sequence clone setSize(70000))
        ConvexTest equals(large at(1), 128 + 127, "a 70000 byte payload uses the 64 bit length")
        ConvexTest equals(large size, 10 + 4 + 70000, "the 64 bit header is ten bytes")

        // Decoding uses server framing, which is never masked.
        server := ConvexTestPeer frameBytes(1, "pong", true)
        decoded := ConvexFrame decode(server)
        ConvexTest equals(decoded opcode, 1, "a server text frame decodes")
        ConvexTest equals(decoded payload asString, "pong", "the payload survives decoding")
        ConvexTest equals(decoded consumed, server size, "the whole frame is consumed")
        ConvexTest ok(
            ConvexFrame decode(server exSlice(0, server size - 1)) isNil,
            "a truncated frame decodes to nil rather than a guess"
        )
        ConvexTest raisesNamed("ProtocolError", "a masked server frame is rejected",
            ConvexFrame decode(
                Sequence clone append(129) append(129) append(0) append(0) append(0) append(0) append(65)
            )
        )
        ConvexTest raisesNamed("ProtocolError", "reserved frame bits are rejected",
            ConvexFrame decode(Sequence clone append(129 + 64) append(1) append(65))
        )
        ConvexTest raisesNamed("ProtocolError", "a fragmented control frame is rejected",
            ConvexFrame decode(Sequence clone append(9) append(1) append(65))
        )

        ConvexTest begin("url")
        plain := ConvexUrl parse("http://backend:3210")
        ConvexTest equals(plain host, "backend", "the host is parsed")
        ConvexTest equals(plain port, 3210, "an explicit port is parsed")
        ConvexTest equals(plain secure, false, "http is not secure")
        ConvexTest equals(plain basePath, "", "no path yields an empty base path")

        secure := ConvexUrl parse("https://example.convex.cloud/")
        ConvexTest equals(secure port, 443, "https defaults to 443")
        ConvexTest equals(secure secure, true, "https is secure")
        ConvexTest equals(secure basePath, "", "a trailing slash is trimmed")

        nested := ConvexUrl parse("https://proxy.example/deployments/alpha")
        ConvexTest equals(nested basePath, "/deployments/alpha", "a base path is preserved")

        // RFC 7230 wants the port in Host whenever it is not the scheme's
        // default. The approved local backend answers on 3210, so omitting it
        // would address a different virtual host than the one dialled.
        ConvexTest equals(
            plain authority,
            "backend:3210",
            "a non-default port stays in the authority"
        )
        ConvexTest equals(
            secure authority,
            "example.convex.cloud",
            "the default https port is left out of the authority"
        )
        ConvexTest equals(
            ConvexUrl parse("http://backend") authority,
            "backend",
            "the default http port is left out of the authority"
        )
        ConvexTest equals(
            ConvexUrl parse("https://example.convex.cloud:8443") authority,
            "example.convex.cloud:8443",
            "a non-default https port stays in the authority"
        )

        ConvexTest begin("stream/buffered-input")
        // TLS can hold decrypted bytes that poll cannot see, so those count as
        // readability - but only while the stream can still hand them out.
        pending := Object clone
        pending bufferedBytes := method(handle, 4096)
        buffered := ConvexStream clone
        buffered io = pending
        buffered handle = 7
        buffered stage = "open"
        ConvexTest ok(buffered hasBufferedInput, "decrypted bytes poll cannot see are readable")
        // After end of stream those bytes can never be consumed. Reporting them
        // anyway would drive the event loop's timeout to zero on every pass and
        // spin the process for as long as the stream is held.
        buffered atEnd = true
        ConvexTest ok(
            buffered hasBufferedInput not,
            "buffered bytes after end of stream are not readability"
        )

        ConvexTest ok(
            try(ConvexUrl parse("ftp://example")) isNil not,
            "a non-HTTP scheme is rejected"
        )
        ConvexTest ok(
            try(ConvexUrl parse("https://example?a=1")) isNil not,
            "a query string is rejected"
        )
        // asNumber would read "3210junk" as 3210, which would silently connect
        // somewhere the caller never asked for.
        ConvexTest ok(
            try(ConvexUrl parse("http://backend:3210junk")) isNil not,
            "a port with trailing junk is rejected"
        )
        ConvexTest ok(
            try(ConvexUrl parse("http://backend:")) isNil not,
            "an empty port is rejected"
        )
        ConvexTest ok(
            try(ConvexUrl parse("http://backend:70000")) isNil not,
            "an out of range port is rejected"
        )

        ConvexTest begin("timestamps")
        client := ConvexClient clone openWith("http://127.0.0.1:1")
        ConvexTest equals(
            client timestampKey(Convex initialTimestamp),
            "0000000000000000",
            "the initial timestamp is all zeroes"
        )
        // Ordering the reversed hex form must agree with ordering the integers.
        ConvexTest ok(
            client timestampKey(ConvexTest timestamp(2)) > client timestampKey(ConvexTest timestamp(1)),
            "a later timestamp sorts higher"
        )
        ConvexTest ok(
            client timestampKey(ConvexTest timestamp(4294967296)) > \
                client timestampKey(ConvexTest timestamp(4294967295)),
            "ordering survives the 32 bit boundary"
        )
        ConvexTest raisesNamed("ProtocolError", "a short timestamp is rejected",
            client timestampKey("AAAA")
        )

        ConvexTest begin("errors")
        functionFailure := try(Convex raiseError("FunctionError", "boom", "{\"code\":\"X\"}", "[\"log\"]"))
        ConvexTest equals(Convex errorName(functionFailure), "FunctionError", "the name survives")
        ConvexTest equals(Convex errorMessage(functionFailure), "boom", "the message survives")
        ConvexTest equals(Convex errorData(functionFailure), "{\"code\":\"X\"}", "errorData stays raw JSON")
        ConvexTest equals(Convex errorLogs(functionFailure), "[\"log\"]", "log lines travel with the error")
        plainFailure := try(Exception raise("ordinary"))
        ConvexTest equals(
            Convex errorName(plainFailure),
            "Error",
            "an ordinary Io exception is not promoted to a Convex error"
        )

        ConvexTest begin("client/argument-validation")
        ConvexTest raisesNamed("ProtocolError", "non-object arguments are rejected",
            client httpBody("demo:state", "[1]")
        )
        ConvexTest raisesNamed("ProtocolError", "malformed arguments are rejected",
            client httpBody("demo:state", "{\"a\":}")
        )
        ConvexTest equals(
            client httpBody("demo:state", "{\"room\":\"r\"}"),
            "{\"path\":\"demo:state\",\"args\":{\"room\":\"r\"},\"format\":\"json\"}",
            "the request envelope wraps the caller's exact argument bytes"
        )

        ConvexTest begin("client/response-classification")
        success := client classify("{\"status\":\"success\",\"value\":{\"count\":1},\"logLines\":[\"a\"]}")
        ConvexTest equals(success value, "{\"count\":1}", "a success value stays raw")
        ConvexTest equals(success logs, "[\"a\"]", "log lines are forwarded")
        ConvexTest raisesNamed("FunctionError", "an error envelope becomes a FunctionError",
            client classify("{\"status\":\"error\",\"errorMessage\":\"nope\",\"errorData\":{\"code\":\"E\"}}")
        )
        ConvexTest raisesNamed("ProtocolError", "a missing status is a protocol error",
            client classify("{\"value\":1}")
        )
        ConvexTest raisesNamed("ProtocolError", "an unknown status is a protocol error",
            client classify("{\"status\":\"weird\"}")
        )

        ConvexTest begin("client/http-status")
        ConvexTest equals(client statusCodeOf("HTTP/1.1 200 OK"), 200, "a status code is read")
        ConvexTest equals(
            client statusCodeOf("HTTP/1.0 503 Service Unavailable"),
            503,
            "HTTP/1.0 status lines are read too"
        )
        ConvexTest raisesNamed("ProtocolError", "a non-HTTP status line is refused",
            client statusCodeOf("ICY 200 OK")
        )
        ConvexTest raisesNamed("ProtocolError", "a non-numeric status is refused",
            client statusCodeOf("HTTP/1.1 OK")
        )
        // A Convex envelope is authoritative on any status, while a body that
        // is not an envelope splits by status: a gateway failure is transport,
        // and a 2xx that does not speak the protocol is protocol drift.
        ConvexTest equals(
            client classifyResponse(200, "{\"status\":\"success\",\"value\":7}") value,
            "7",
            "a 200 envelope classifies normally"
        )
        ConvexTest raisesNamed("FunctionError", "an envelope wins over a 500 status",
            client classifyResponse(500, "{\"status\":\"error\",\"errorMessage\":\"boom\"}")
        )
        ConvexTest raisesNamed("TransportError", "a 502 with no envelope is a transport failure",
            client classifyResponse(502, "<html>bad gateway</html>")
        )
        ConvexTest raisesNamed("ProtocolError", "a 200 with no envelope is protocol drift",
            client classifyResponse(200, "<html>not convex</html>")
        )
        client close
        ConvexTest
    )
)
