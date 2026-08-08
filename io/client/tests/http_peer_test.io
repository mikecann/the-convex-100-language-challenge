//
// HTTP behaviour against a deliberately awkward loopback peer.
//
// These run over real sockets through the transport boundary, so the request
// bytes, the response framings and every deadline are exercised exactly as
// they would be against a deployment.
//

ConvexHttpPeerTest := Object clone do(
    // Each scenario gets its own peer and client so nothing leaks between
    // them, and the peer is attached to the client's loop so it can answer
    // while a blocking call is in flight.
    withPeer := method(handler,
        peer := ConvexTestPeer clone start
        client := Convex clientForUrl(peer url)
        peer attachTo(client)
        outcome := try(handler call(peer, client))
        client close
        peer shutdown
        if(outcome, outcome pass)
        nil
    )

    run := method(
        ConvexTest begin("http/request-shape")
        ConvexHttpPeerTest withPeer(block(peer, client,
            seenHead := nil
            seenBody := nil
            peer onRequest = block(p,
                seenHead = p requestHead
                seenBody = p requestBody
                p forget
                p respond("200 OK", "{\"status\":\"success\",\"value\":{\"count\":0},\"logLines\":[]}")
            )
            answer := client query("demo:state", Convex object(list("room", Convex string("r"))))
            ConvexTest equals(answer value, "{\"count\":0}", "the raw value is returned unchanged")
            ConvexTest ok(
                seenHead beginsWithSeq("POST /api/query HTTP/1.1"),
                "a query posts to /api/query"
            )
            ConvexTest ok(
                seenHead containsSeq("Convex-Client: io-"),
                "the client identifies itself"
            )
            ConvexTest ok(
                seenHead asLowercase containsSeq("authorization:") not,
                "no Authorization header is sent without a token"
            )
            ConvexTest equals(
                seenBody,
                "{\"path\":\"demo:state\",\"args\":{\"room\":\"r\"},\"format\":\"json\"}",
                "the envelope carries the caller's exact argument bytes"
            )
        ))

        ConvexTest begin("http/host-header")
        ConvexHttpPeerTest withPeer(block(peer, client,
            seenHead := nil
            peer onRequest = block(p,
                seenHead = p requestHead
                p forget
                p respond("200 OK", "{\"status\":\"success\",\"value\":null,\"logLines\":[]}")
            )
            client query("demo:state", "{}")
            // The peer listens on an ephemeral port, so this is the same shape
            // as the approved local backend on 3210: dropping the port would
            // address a different virtual host than the one dialled.
            ConvexTest ok(
                seenHead containsSeq("Host: 127.0.0.1:" .. peer port asString .. "\r\n"),
                "a non-default port stays in the Host header"
            )
        ))

        ConvexTest begin("http/single-owner")
        ConvexHttpPeerTest withPeer(block(peer, client,
            previous := Convex httpTimeoutMs
            Convex httpTimeoutMs = 600
            reentrant := nil
            // The peer answers from inside the client's own event loop, which
            // is exactly where a subscription callback runs. A second request
            // issued from there must be refused, because taking over the single
            // httpStream slot would drop the in-flight request out of the poll
            // set and strand it until its deadline.
            peer onRequest = block(p,
                p forget
                if(reentrant isNil, reentrant = try(client query("demo:state", "{}")))
            )
            outer := try(client query("demo:state", "{}"))
            Convex httpTimeoutMs = previous
            ConvexTest equals(
                Convex errorName(reentrant),
                "TransportError",
                "a reentrant HTTP call is refused rather than taking the socket"
            )
            ConvexTest ok(
                Convex errorMessage(reentrant) containsSeq("already in flight"),
                "the refusal says why"
            )
            ConvexTest equals(
                Convex errorName(outer),
                "TransportError",
                "the refused caller never answered, so the outer request times out"
            )
        ))

        ConvexTest begin("http/bearer-token")
        ConvexHttpPeerTest withPeer(block(peer, client,
            seenHead := nil
            peer onRequest = block(p,
                seenHead = p requestHead
                p forget
                p respond("200 OK", "{\"status\":\"success\",\"value\":null,\"logLines\":[]}")
            )
            client setAuth("token-one")
            client query("demo:state", "{}")
            ConvexTest ok(
                seenHead containsSeq("Authorization: Bearer token-one"),
                "a bearer token is sent once set"
            )
            // Clearing the token must actually remove the header, not send an
            // empty one, which is what the conformance lifecycle checks.
            peer onRequest = block(p,
                seenHead = p requestHead
                p forget
                p respond("200 OK", "{\"status\":\"success\",\"value\":null,\"logLines\":[]}")
            )
            client setAuth("")
            client query("demo:state", "{}")
            ConvexTest ok(
                seenHead asLowercase containsSeq("authorization:") not,
                "clearing the token removes the header"
            )
        ))

        ConvexTest begin("http/utf8-length")
        ConvexHttpPeerTest withPeer(block(peer, client,
            seenHead := nil
            seenBody := nil
            peer onRequest = block(p,
                seenHead = p requestHead
                seenBody = p requestBody
                p forget
                p respond("200 OK", "{\"status\":\"success\",\"value\":null,\"logLines\":[]}")
            )
            // Content-Length must count bytes, not characters, or a multi-byte
            // argument truncates the request on the wire.
            client query("demo:echo", Convex object(list("value", Convex string("Καλημέρα 👋"))))
            declared := nil
            seenHead split("\r\n") foreach(line,
                if(line asLowercase beginsWithSeq("content-length:"),
                    declared = line exSlice(15) asMutable strip asNumber
                )
            )
            ConvexTest equals(declared, seenBody size, "Content-Length matches the byte count")
            ConvexTest ok(seenBody containsSeq("👋"), "the multi-byte argument arrives intact")
        ))

        ConvexTest begin("http/structured-error")
        ConvexHttpPeerTest withPeer(block(peer, client,
            peer onRequest = block(p,
                p forget
                p respond("200 OK",
                    "{\"status\":\"error\",\"errorMessage\":\"Intentional\"," .. \
                        "\"errorData\":{\"code\":\"ROOM_EMPTY\"},\"logLines\":[\"note\"]}"
                )
            )
            failure := try(client query("demo:fail", "{}"))
            ConvexTest equals(
                Convex errorName(failure), "FunctionError", "an error envelope is a FunctionError"
            )
            ConvexTest equals(Convex errorMessage(failure), "Intentional", "the message survives")
            ConvexTest equals(
                Convex errorData(failure),
                "{\"code\":\"ROOM_EMPTY\"}",
                "errorData reaches the caller as raw JSON"
            )
            ConvexTest equals(Convex errorLogs(failure), "[\"note\"]", "log lines accompany the failure")
        ))

        ConvexTest begin("http/chunked")
        ConvexHttpPeerTest withPeer(block(peer, client,
            peer onRequest = block(p,
                p forget
                // A proxy may split the envelope anywhere, including inside a
                // JSON token, so reassembly cannot assume chunk boundaries.
                p respondChunked("200 OK", list(
                    "{\"status\":\"suc",
                    "cess\",\"value\":{\"count\":",
                    "7},\"logLines\":[]}"
                ))
            )
            answer := client query("demo:state", "{}")
            ConvexTest equals(answer value, "{\"count\":7}", "a chunked response reassembles")
        ))

        ConvexTest begin("http/status-and-envelope")
        ConvexHttpPeerTest withPeer(block(peer, client,
            // This is the shape a rejected bearer token produces. Nothing in
            // it is a Convex envelope, and the status says the network path
            // answered, so it must not be reported as Convex protocol drift.
            peer onRequest = block(p,
                p forget
                p respond("401 Unauthorized", "Unauthorized")
            )
            rejected := try(client query("demo:state", "{}"))
            ConvexTest equals(
                Convex errorName(rejected),
                "TransportError",
                "a non-2xx status with no Convex envelope is a transport failure"
            )

            // A 200 that is not an envelope is a different claim: Convex
            // answered, but not in its own protocol.
            peer onRequest = block(p,
                p forget
                p respond("200 OK", "<html>not convex</html>")
            )
            garbled := try(client query("demo:state", "{}"))
            ConvexTest equals(
                Convex errorName(garbled),
                "ProtocolError",
                "a 2xx body that is not an envelope is a protocol error"
            )

            // A real Convex error envelope is authoritative whatever status
            // carried it, so the application error must survive intact.
            peer onRequest = block(p,
                p forget
                p respond("400 Bad Request",
                    "{\"status\":\"error\",\"errorMessage\":\"Nope\"," .. \
                        "\"errorData\":{\"code\":\"BAD\"},\"logLines\":[]}"
                )
            )
            envelope := try(client query("demo:state", "{}"))
            ConvexTest equals(
                Convex errorName(envelope),
                "FunctionError",
                "a Convex error envelope survives a non-2xx status"
            )
            ConvexTest equals(
                Convex errorData(envelope),
                "{\"code\":\"BAD\"}",
                "the envelope's structured data is still preserved"
            )
        ))

        ConvexTest begin("http/peer-closes-early")
        ConvexHttpPeerTest withPeer(block(peer, client,
            peer onRequest = block(p, p forget; p hangUp)
            failure := try(client query("demo:state", "{}"))
            ConvexTest equals(
                Convex errorName(failure),
                "TransportError",
                "a peer that hangs up before responding is a transport error"
            )
        ))

        ConvexTest begin("http/response-budget")
        ConvexHttpPeerTest withPeer(block(peer, client,
            // Shrink the budget rather than moving megabytes, so the bound is
            // proved deterministically and quickly.
            previous := Convex maximumResponseBytes
            Convex maximumResponseBytes = 256
            peer onRequest = block(p,
                p forget
                padding := Sequence clone
                while(padding size < 4096, padding appendSeq("0123456789"))
                p respond("200 OK", "{\"status\":\"success\",\"value\":\"" .. padding .. "\"}")
            )
            failure := try(client query("demo:state", "{}"))
            Convex maximumResponseBytes = previous
            ConvexTest equals(
                Convex errorName(failure),
                "TransportError",
                "an oversized response is refused rather than buffered"
            )
        ))

        ConvexTest begin("http/deadline")
        ConvexHttpPeerTest withPeer(block(peer, client,
            previous := Convex httpTimeoutMs
            Convex httpTimeoutMs = 400
            // The peer accepts the connection and then never moves a byte,
            // which is the stall an unbounded reader would hang on forever.
            peer freeze
            started := Lobby ConvexIO monotonicMs
            failure := try(client query("demo:state", "{}"))
            elapsed := Lobby ConvexIO monotonicMs - started
            Convex httpTimeoutMs = previous
            peer thaw
            ConvexTest equals(
                Convex errorName(failure),
                "TransportError",
                "a stalled peer produces a transport error"
            )
            ConvexTest ok(elapsed < 5000, "the deadline is enforced rather than merely hoped for")
        ))

        ConvexTest begin("http/refused")
        // Nothing is listening on this port, so connect or handshake must fail
        // without waiting for a deadline that never arrives.
        idle := ConvexTestPeer clone start
        port := idle port
        idle shutdown
        refusedClient := Convex clientForUrl("http://127.0.0.1:" .. port asString)
        previousTimeout := Convex httpTimeoutMs
        Convex httpTimeoutMs = 2000
        refusal := try(refusedClient query("demo:state", "{}"))
        Convex httpTimeoutMs = previousTimeout
        refusedClient close
        ConvexTest equals(
            Convex errorName(refusal),
            "TransportError",
            "a refused connection is a transport error"
        )

        ConvexTest
    )
)
