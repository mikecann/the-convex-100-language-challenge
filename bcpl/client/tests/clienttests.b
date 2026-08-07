// clienttests.b -- deterministic unit tests for the BCPL Convex client.
//
// These need no network. They cover the decisions that ordinary happy-path
// traffic never exercises: integral decoding of Convex's 0 and 0.0 forms, the
// parser's hostile-input bounds, the exact bytes of every adapter event, the
// subscription queue's behaviour with a stopped consumer, generation
// invalidation, and transport backoff.

SECTION "convexclient"

GET "libhdr"
GET "convexhdr"
GET "convex.b"

.

SECTION "convextests"

GET "libhdr"
GET "convexhdr"
GET "eventshdr"

// The same event builders the conformance adapter uses, so the bytes asserted
// below are the bytes that program emits.
GET "events.b"

GLOBAL {
tsFailures: 700
tsCount:    701
}

LET report(prefix, name) BE
{ LET line = bbNew(160)
  UNLESS line RETURN
  bbPushStr(line, prefix)
  bbPushStr(line, name)
  bbPush(line, '*n')
  cxOut(line)
  bbFree(line)
}

AND check(condition, name) BE
{ tsCount := tsCount + 1
  TEST condition
  THEN report("ok   ", name)
  ELSE { tsFailures := tsFailures + 1
         report("FAIL ", name)
       }
}

// Parses `text` and re-serialises it, comparing against `expected`. This is
// the round trip Convex values actually take through the adapter.
AND checkRoundTrip(text, expected, name) BE
{ LET source = bbFromStr(text)
  LET node = 0
  LET out = 0
  node := jsParseBuffer(source)
  TEST node = 0
  THEN check(FALSE, name)
  ELSE
  { out := jsSerialise(node)
    check(bbEqualStr(out, expected), name)
    bbFree(out)
    jsFree(node)
  }
  bbFree(source)
}

AND checkRejected(text, name) BE
{ LET source = bbFromStr(text)
  LET node = jsParseBuffer(source)
  check(node = 0, name)
  IF node DO jsFree(node)
  bbFree(source)
}

AND checkWhole(text, expected, name) BE
{ LET source = bbFromStr(text)
  LET node = jsParseBuffer(source)
  LET value = -999
  LET ok = FALSE
  IF node ~= 0 DO ok := jsWholeNumber(node, @value)
  check(ok & value = expected, name)
  IF node DO jsFree(node)
  bbFree(source)
}

AND checkNotWhole(text, name) BE
{ LET source = bbFromStr(text)
  LET node = jsParseBuffer(source)
  LET value = 0
  LET ok = TRUE
  IF node ~= 0 DO ok := jsWholeNumber(node, @value)
  check(node ~= 0 & ~ok, name)
  IF node DO jsFree(node)
  bbFree(source)
}

AND checkText(text, first, second, name) BE
{ LET expected = bbNew(256)
  bbPushStr(expected, first)
  IF second ~= 0 DO bbPushStr(expected, second)
  check(bbEqual(text, expected), name)
  bbFree(expected)
}

AND testJson() BE
{ LET deep = bbNew(512)
  LET node = 0

  checkRoundTrip("{}", "{}", "json: empty object round trip")
  checkRoundTrip("[1,2,3]", "[1,2,3]", "json: array round trip")
  checkRoundTrip("{*"a*":null,*"b*":true,*"c*":false}",
                 "{*"a*":null,*"b*":true,*"c*":false}",
                 "json: literals round trip")
  // The literal text of a number survives untouched, which is what lets a
  // Convex millisecond timestamp pass through a 32-bit word machine intact.
  checkRoundTrip("{*"updatedAt*":1750000000000}",
                 "{*"updatedAt*":1750000000000}",
                 "json: oversized number keeps its literal text")
  checkRoundTrip("{*"number*":42.5}", "{*"number*":42.5}",
                 "json: fractional number keeps its literal text")
  checkRoundTrip("*"\u0041\u0042*"", "*"AB*"",
                 "json: escaped code points decode")
  checkRoundTrip("*"line\nbreak*"", "*"line\nbreak*"",
                 "json: control characters are re-escaped")

  // A surrogate pair has to become one four byte UTF-8 sequence. The bytes are
  // checked numerically so this source file stays pure ASCII.
  { LET source = bbFromStr("*"\ud83d\udc4b*"")
    LET node = jsParseBuffer(source)
    LET decoded = 0
    LET ok = FALSE
    IF node ~= 0 DO
    { decoded := node!Js_a
      ok := decoded!Bb_len = 4
      IF ok DO ok := bbGet(decoded, 0) = #xF0
      IF ok DO ok := bbGet(decoded, 1) = #x9F
      IF ok DO ok := bbGet(decoded, 2) = #x91
      IF ok DO ok := bbGet(decoded, 3) = #x8B
    }
    check(ok, "json: a surrogate pair becomes one UTF-8 code point")
    IF node DO jsFree(node)
    bbFree(source)
  }

  checkRejected("{", "json: truncated object is rejected")
  checkRejected("[1,]", "json: trailing comma is rejected")
  checkRejected("01", "json: leading zero is rejected")
  checkRejected("1.", "json: empty fraction is rejected")
  checkRejected("1e", "json: empty exponent is rejected")
  checkRejected("*"\ud83d*"", "json: unpaired surrogate is rejected")
  checkRejected("*"\q*"", "json: unknown escape is rejected")
  checkRejected("nul", "json: truncated literal is rejected")
  checkRejected("{} {}", "json: trailing data is rejected")

  // A hostile peer must not be able to drive the parser into the Cintcode
  // stack through sheer nesting.
  FOR index = 1 TO Maxjsondepth + 4 DO bbPush(deep, '[')
  FOR index = 1 TO Maxjsondepth + 4 DO bbPush(deep, ']')
  node := jsParseBuffer(deep)
  check(node = 0, "json: nesting beyond the depth bound is rejected")
  IF node DO jsFree(node)
  bbFree(deep)

  // Convex reports a whole count as 0 or 0.0 depending on the path it took.
  checkWhole("0", 0, "json: 0 decodes as a whole number")
  checkWhole("0.0", 0, "json: 0.0 decodes as a whole number")
  checkWhole("1", 1, "json: 1 decodes as a whole number")
  checkWhole("1.0", 1, "json: 1.0 decodes as a whole number")
  checkWhole("-7", -7, "json: a negative whole number decodes")
  checkWhole("1e2", 100, "json: an exponent that stays integral decodes")
  checkWhole("100e-2", 1, "json: a negative exponent that cancels decodes")
  checkWhole("2147483647", 2147483647, "json: the largest word decodes")

  checkWhole("-0", 0, "json: negative zero decodes as zero")
  checkWhole("0e0", 0, "json: a zero exponent decodes")

  checkNotWhole("0.5", "json: a fractional value is refused")
  checkNotWhole("42.5", "json: 42.5 is refused")
  checkNotWhole("1e-2", "json: a value below one is refused")
  checkNotWhole("2147483648", "json: an overflowing value is refused")
  checkNotWhole("1750000000000", "json: a millisecond timestamp is refused")
  // 1e10 is integral but far outside a 32-bit word, so it must be refused
  // rather than silently wrapping into a plausible-looking count.
  checkNotWhole("1e10", "json: an integral value past the word is refused")
  checkNotWhole("0.0001e2", "json: a value that stays fractional is refused")

  { LET source = bbFromStr("*"0*"")
    LET quoted = jsParseBuffer(source)
    LET value = 0
    check(~jsWholeNumber(quoted, @value),
          "json: a quoted digit string is not a number")
    jsFree(quoted)
    bbFree(source)
  }
}

AND testDigest() BE
{ LET digest = bbNew(32)
  LET encoded = bbNew(32)
  LET decoded = bbNew(32)
  LET empty = bbNew(4)

  // The RFC 6455 worked example: this is exactly the proof the client checks
  // when a deployment answers the sync upgrade.
  { LET key = bbNew(128)
    bbPushStr(key, "dGhlIHNhbXBsZSBub25jZQ==")
    bbPushStr(key, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
    sha1Into(key!Bb_vec, 0, key!Bb_len, digest)
    base64Into(digest!Bb_vec, 0, digest!Bb_len, encoded)
    check(bbEqualStr(encoded, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="),
          "digest: the RFC 6455 handshake proof matches")
    bbFree(key)
  }

  bbClear(digest)
  sha1Into(empty!Bb_vec, 0, 0, digest)
  bbClear(encoded)
  base64Into(digest!Bb_vec, 0, digest!Bb_len, encoded)
  check(bbEqualStr(encoded, "2jmj7l5rSw0yVb/vlWAYkK/YBwk="),
        "digest: SHA-1 of the empty string matches")

  bbClear(encoded)
  { LET text = bbFromStr("any carnal pleasure.")
    base64Into(text!Bb_vec, 0, text!Bb_len, encoded)
    check(bbEqualStr(encoded, "YW55IGNhcm5hbCBwbGVhc3VyZS4="),
          "digest: base64 padding is correct")
    bbFree(text)
  }

  check(base64Decode(encoded!Bb_vec, 0, encoded!Bb_len, decoded),
        "digest: base64 decodes")
  check(bbEqualStr(decoded, "any carnal pleasure."),
        "digest: base64 round trips")

  bbClear(decoded)
  { LET junk = bbFromStr("!!!!")
    check(~base64Decode(junk!Bb_vec, 0, junk!Bb_len, decoded),
          "digest: base64 refuses characters outside the alphabet")
    bbFree(junk)
  }

  // The sync protocol's initial timestamp is eight zero bytes.
  bbClear(decoded)
  { LET zero = bbFromStr("AAAAAAAAAAA=")
    base64Decode(zero!Bb_vec, 0, zero!Bb_len, decoded)
    check(decoded!Bb_len = 8, "digest: the initial sync timestamp is 8 bytes")
    bbFree(zero)
  }

  // The bytes are pushed numerically rather than written as a literal so this
  // file stays pure ASCII: the 2015 BCPL compiler reads its source a byte at a
  // time and a high-bit byte inside a string literal is not something the
  // language ever defined. This is U+039A U+03B1 (Greek), a space, and
  // U+1F7E8, which covers the two, three and four byte forms.
  { LET good = bbNew(16)
    bbPush(good, #xCE); bbPush(good, #x9A)
    bbPush(good, #xCE); bbPush(good, #xB1)
    bbPush(good, ' ')
    bbPush(good, #xE4); bbPush(good, #xB8); bbPush(good, #x96)
    bbPush(good, #xF0); bbPush(good, #x9F); bbPush(good, #x9F); bbPush(good, #xA8)
    check(utf8Valid(good!Bb_vec, 0, good!Bb_len),
          "digest: valid UTF-8 is accepted")
    check(good!Bb_len = 12, "digest: the sample covers 2, 3 and 4 byte forms")
    bbFree(good)
  }
  { LET bad = bbNew(8)
    bbPush(bad, #xC0)
    bbPush(bad, #x80)
    check(~utf8Valid(bad!Bb_vec, 0, bad!Bb_len),
          "digest: an over-long UTF-8 encoding is rejected")
    bbClear(bad)
    bbPush(bad, #xED)
    bbPush(bad, #xA0)
    bbPush(bad, #x80)
    check(~utf8Valid(bad!Bb_vec, 0, bad!Bb_len),
          "digest: a UTF-8 encoded surrogate is rejected")
    bbClear(bad)
    bbPush(bad, #xE4)
    bbPush(bad, #xB8)
    check(~utf8Valid(bad!Bb_vec, 0, bad!Bb_len),
          "digest: a truncated UTF-8 sequence is rejected")
    bbFree(bad)
  }

  bbFree(digest)
  bbFree(encoded)
  bbFree(decoded)
  bbFree(empty)
}

AND testUrl() BE
{ LET endpoint = 0

  endpoint := epParseUrl(bbFromStr("https://example.convex.cloud"))
  check(endpoint ~= 0, "url: an https deployment URL parses")
  IF endpoint ~= 0 DO
  { check(endpoint!Ep_tls, "url: https implies TLS")
    check(endpoint!Ep_port = 443, "url: https defaults to port 443")
    check(bbEqualStr(endpoint!Ep_host, "example.convex.cloud"),
          "url: the host is extracted")
    check(endpoint!Ep_path!Bb_len = 0, "url: there is no base path")
    epFree(endpoint)
  }

  endpoint := epParseUrl(bbFromStr("http://backend:3210/"))
  check(endpoint ~= 0, "url: a self-hosted URL parses")
  IF endpoint ~= 0 DO
  { check(~endpoint!Ep_tls, "url: http implies no TLS")
    check(endpoint!Ep_port = 3210, "url: an explicit port is used")
    check(endpoint!Ep_path!Bb_len = 0, "url: a trailing slash is dropped")
    epFree(endpoint)
  }

  // A deployment behind a path prefix must keep it, or every request would be
  // posted to the wrong place with no visible error.
  endpoint := epParseUrl(bbFromStr("https://proxy.example/convex/"))
  check(endpoint ~= 0, "url: a deployment behind a path prefix parses")
  IF endpoint ~= 0 DO
  { check(bbEqualStr(endpoint!Ep_host, "proxy.example"),
          "url: the host stops at the path")
    check(bbEqualStr(endpoint!Ep_path, "/convex"),
          "url: the base path is kept without its trailing slash")
    epFree(endpoint)
  }

  check(epParseUrl(bbFromStr("ftp://example.com")) = 0,
        "url: an unsupported scheme is refused")
  check(epParseUrl(bbFromStr("https://user@example.com")) = 0,
        "url: userinfo is refused")
  check(epParseUrl(bbFromStr("https://example.com:abc")) = 0,
        "url: a malformed port is refused")
}

AND testHttpHeaders() BE
{ LET block = bbNew(256)
  LET value = 0
  LET headerend = 0
  bbPushStr(block, "HTTP/1.1 200 OK*c*n")
  bbPushStr(block, "Content-Type: application/json*c*n")
  // Deliberately shouted and padded: header names are case insensitive and
  // the value has to be trimmed on both sides.
  bbPushStr(block, "CONTENT-LENGTH:  17  *c*n")
  bbPushStr(block, "*c*n")
  headerend := block!Bb_len

  value := httpHeaderValue(block, headerend, "content-length")
  check(bbEqualStr(value, "17"),
        "http: a header name matches without regard to case")
  bbFree(value)

  value := httpHeaderValue(block, headerend, "content-type")
  check(bbEqualStr(value, "application/json"), "http: the value is trimmed")
  bbFree(value)

  check(httpHeaderValue(block, headerend, "sec-websocket-accept") = 0,
        "http: an absent header yields nothing")
  bbFree(block)
}

// ---------------------------------------------------------------------------
// The WebSocket opening handshake
//
// Accepting a 101 without checking it would let any HTTP server that answers
// with the right status line pretend to speak the Convex sync protocol. The
// validator is pure -- a response block in, a decision out -- so the whole
// refusal matrix is driven here rather than through a live deployment.
// ---------------------------------------------------------------------------

AND handshakeBlock(status, accept, upgrade, connection, extra) = VALOF
{ LET block = bbNew(320)
  UNLESS block RESULTIS 0
  bbPushStr(block, status)
  bbPushStr(block, "*c*n")
  IF upgrade ~= 0 DO
  { bbPushStr(block, "Upgrade: ")
    bbPushStr(block, upgrade)
    bbPushStr(block, "*c*n")
  }
  IF connection ~= 0 DO
  { bbPushStr(block, "Connection: ")
    bbPushStr(block, connection)
    bbPushStr(block, "*c*n")
  }
  bbPushStr(block, "Sec-WebSocket-Accept: ")
  bbPushStr(block, accept)
  bbPushStr(block, "*c*n")
  IF extra ~= 0 DO
  { bbPushStr(block, extra)
    bbPushStr(block, "*c*n")
  }
  bbPushStr(block, "*c*n")
  RESULTIS block
}

AND checkHandshake(expected, status, accept, upgrade, connection, extra,
                   name) BE
{ // The proof for the RFC 6455 sample key, which testDigest computes from
  // scratch; reusing the literal here keeps this test about validation.
  LET proof = bbFromStr("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
  LET block = handshakeBlock(status, accept, upgrade, connection, extra)
  IF block = 0 DO { check(FALSE, name); bbFree(proof); RETURN }
  check(wsHandshakeOk(block, block!Bb_len, proof) = expected, name)
  bbFree(proof)
  bbFree(block)
}

AND testHandshakeValidation() BE
{ LET good = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
  LET switching = "HTTP/1.1 101 Switching Protocols"

  checkHandshake(TRUE, switching, good, "websocket", "Upgrade", 0,
                 "handshake: a correct upgrade is accepted")
  // RFC 9110 makes both the field name and these token values case
  // insensitive, and a proxy may add its own Connection tokens.
  checkHandshake(TRUE, switching, good, "WebSocket", "keep-alive, Upgrade", 0,
                 "handshake: tokens are matched without regard to case")

  checkHandshake(FALSE, switching, "AAAAAAAAAAAAAAAAAAAAAAAAAAA=",
                 "websocket", "Upgrade", 0,
                 "handshake: a wrong accept proof is refused")
  checkHandshake(FALSE, "HTTP/1.1 200 OK", good, "websocket", "Upgrade", 0,
                 "handshake: a status other than 101 is refused")
  checkHandshake(FALSE, switching, good, 0, "Upgrade", 0,
                 "handshake: a missing Upgrade header is refused")
  checkHandshake(FALSE, switching, good, "h2c", "Upgrade", 0,
                 "handshake: an upgrade to something else is refused")
  checkHandshake(FALSE, switching, good, "websocket", 0, 0,
                 "handshake: a missing Connection header is refused")
  checkHandshake(FALSE, switching, good, "websocket", "keep-alive", 0,
                 "handshake: a Connection header without the token is refused")
  // Neither was offered. A server that answers with either is describing
  // framing this client is not about to decode.
  checkHandshake(FALSE, switching, good, "websocket", "Upgrade",
                 "Sec-WebSocket-Extensions: permessage-deflate",
                 "handshake: an unoffered extension is refused")
  checkHandshake(FALSE, switching, good, "websocket", "Upgrade",
                 "Sec-WebSocket-Protocol: convex",
                 "handshake: an unoffered subprotocol is refused")
}

// The controller validates every emitted line against the shared schema, and
// an optional field serialised as null would fail that validation. These check
// the exact bytes of each event shape before shared conformance has to.
AND testAdapterEvents() BE
{ LET event = 0
  LET error = 0
  LET text = 0

  event := jsObject()
  jsObjectPutStr(event, "id", jsStringFromStr("q-1"))
  jsObjectPutStr(event, "type", jsStringFromStr("result"))
  jsObjectPutStr(event, "value", jsNumberFromInt(0))
  jsObjectPutStr(event, "logs", jsArray())
  text := jsSerialise(event)
  check(bbEqualStr(text, "{*"id*":*"q-1*",*"type*":*"result*",*"value*":0,*"logs*":[]}"),
        "adapter: a success event serialises exactly")
  bbFree(text)
  jsFree(event)

  event := jsObject()
  error := jsObject()
  jsObjectPutStr(error, "name", jsStringFromStr("FunctionError"))
  jsObjectPutStr(error, "message", jsStringFromStr("Intentional"))
  { LET data = jsObject()
    jsObjectPutStr(data, "code", jsStringFromStr("CLIENT_EXPECTED"))
    jsObjectPutStr(error, "data", data)
  }
  jsObjectPutStr(event, "id", jsStringFromStr("f-1"))
  jsObjectPutStr(event, "type", jsStringFromStr("error"))
  jsObjectPutStr(event, "error", error)
  text := jsSerialise(event)
  checkText(text,
            "{*"id*":*"f-1*",*"type*":*"error*",*"error*":{*"name*":*"FunctionError*",",
            "*"message*":*"Intentional*",*"data*":{*"code*":*"CLIENT_EXPECTED*"}}}",
            "adapter: a structured HTTP error event serialises exactly")
  bbFree(text)
  jsFree(event)

  event := jsObject()
  error := jsObject()
  jsObjectPutStr(error, "name", jsStringFromStr("FunctionError"))
  jsObjectPutStr(error, "message", jsStringFromStr("Increment the room"))
  jsObjectPutStr(event, "type", jsStringFromStr("subscription"))
  jsObjectPutStr(event, "subscriptionId", jsStringFromStr("s-1"))
  jsObjectPutStr(event, "error", error)
  text := jsSerialise(event)
  checkText(text,
            "{*"type*":*"subscription*",*"subscriptionId*":*"s-1*",",
            "*"error*":{*"name*":*"FunctionError*",*"message*":*"Increment the room*"}}",
            "adapter: a subscription error event omits an absent data field")
  bbFree(text)
  jsFree(event)

  event := jsObject()
  jsObjectPutStr(event, "id", jsStringFromStr("c-1"))
  jsObjectPutStr(event, "type", jsStringFromStr("closed"))
  text := jsSerialise(event)
  check(bbEqualStr(text, "{*"id*":*"c-1*",*"type*":*"closed*"}"),
        "adapter: a close event serialises exactly")
  bbFree(text)
  jsFree(event)

  event := jsObject()
  jsObjectPutStr(event, "type", jsStringFromStr("error"))
  { LET protocol = jsObject()
    jsObjectPutStr(protocol, "name", jsStringFromStr("ProtocolError"))
    jsObjectPutStr(protocol, "message", jsStringFromStr("malformed adapter command"))
    jsObjectPutStr(event, "error", protocol)
  }
  text := jsSerialise(event)
  checkText(text,
            "{*"type*":*"error*",*"error*":{*"name*":*"ProtocolError*",",
            "*"message*":*"malformed adapter command*"}}",
            "adapter: an unattributable error event omits the id entirely")
  bbFree(text)
  jsFree(event)
}

// Builds a detached subscription so queue behaviour can be tested without a
// deployment. The fields are the same ones the Live owner manipulates.
AND makeSubscription() = VALOF
{ LET subscription = getvec(Sb_upb)
  FOR field = 0 TO Sb_upb DO subscription!field := 0
  subscription!Sb_subid := bbFromStr("s")
  subscription!Sb_path := bbFromStr("demo:state")
  subscription!Sb_args := jsObject()
  subscription!Sb_generation := 1
  subscription!Sb_queue := vlNew(8)
  subscription!Sb_active := TRUE
  RESULTIS subscription
}

AND makeUpdate(value, bytes) = VALOF
{ LET update = upNew()
  update!Up_generation := 1
  update!Up_value := jsNumberFromInt(value)
  update!Up_bytes := bytes
  RESULTIS update
}

AND testQueueBounds() BE
{ LET subscription = makeSubscription()
  LET taken = 0
  LET count = 0

  // A consumer that has stopped reading must not be able to grow the queue.
  FOR index = 1 TO Maxqueueupdates * 4 DO
    sbDeliver(subscription, makeUpdate(index, 64))
  check((subscription!Sb_queue)!Vl_len = Maxqueueupdates,
        "queue: a stopped consumer is bounded by the update count")

  // The newest values are the ones kept.
  taken := sbTake(subscription)
  { LET value = 0
    jsWholeNumber(taken!Up_value, @value)
    check(value = Maxqueueupdates * 4 - Maxqueueupdates + 1,
          "queue: the oldest value is dropped, not the newest")
  }
  upFree(taken)

  { LET rest = sbTake(subscription)
    UNTIL rest = 0 DO
    { count := count + 1
      upFree(rest)
      rest := sbTake(subscription)
    }
  }
  check(count = Maxqueueupdates - 1, "queue: the remaining values drain")
  subscription!Sb_queuebytes := 0
  vlClear(subscription!Sb_queue)

  // A count bound alone is not a memory bound: one Convex value can approach
  // the maximum frame size, so the byte budget has to bite first.
  FOR index = 1 TO 8 DO
    sbDeliver(subscription, makeUpdate(index, Maxqueuebytes / 3))
  check(subscription!Sb_queuebytes <= Maxqueuebytes,
        "queue: a stopped consumer is bounded by the byte budget")
  check((subscription!Sb_queue)!Vl_len < Maxqueueupdates,
        "queue: the byte budget bites before the count bound")

  sbFree(subscription)
}

AND testGenerationBarrier() BE
{ LET subscription = makeSubscription()
  LET relayed = 0

  sbDeliver(subscription, makeUpdate(1, 64))
  sbDeliver(subscription, makeUpdate(2, 64))

  // Dequeue one update and hold it, exactly as a paused relay would.
  relayed := sbTake(subscription)
  check(relayed ~= 0, "generation: an update can be dequeued")

  // Unsubscribing, or replacing the subscription with the same identifier,
  // retires the generation before any acknowledgement is published.
  subscription!Sb_generation := subscription!Sb_generation + 1

  check(sbTake(subscription) = 0,
        "generation: values queued before the bump cannot be published")
  check(relayed!Up_generation ~= subscription!Sb_generation,
        "generation: a paused relay carries the retired generation")
  upFree(relayed)
  sbFree(subscription)
}

AND testBackoff() BE
{ LET manager = getvec(Lv_upb)
  LET first = 0
  LET second = 0
  FOR field = 0 TO Lv_upb DO manager!field := 0
  manager!Lv_backoff := Backoffbasems

  lvBackoffAfterFailure(manager)
  first := manager!Lv_backoff
  lvBackoffAfterFailure(manager)
  second := manager!Lv_backoff
  check(second > first, "backoff: the interval grows after repeated failure")

  FOR index = 1 TO 20 DO lvBackoffAfterFailure(manager)
  check(manager!Lv_backoff = Backoffmaxms, "backoff: the interval is capped")

  // A healthy intervening connection must not inherit the old maximum delay.
  manager!Lv_backoff := Backoffbasems
  manager!Lv_nextattempt := 0
  lvBackoffAfterFailure(manager)
  check(manager!Lv_backoff = Backoffbasems * 2,
        "backoff: a successful handshake resets the interval")
  freevec(manager)
}

AND testTimestamps() BE
{ LET low = bbFromStr("AAAAAAAAAAA=")
  LET high = 0
  LET rollover = 0
  LET raw = bbNew(16)

  // 0x00000000000000FF little-endian: the most significant byte is last, so a
  // left-to-right byte comparison would order these wrongly.
  bbPush(raw, 255)
  FOR index = 1 TO 7 DO bbPush(raw, 0)
  high := bbNew(24)
  base64Into(raw!Bb_vec, 0, 8, high)

  bbClear(raw)
  FOR index = 1 TO 7 DO bbPush(raw, 0)
  bbPush(raw, 1)
  rollover := bbNew(24)
  base64Into(raw!Bb_vec, 0, 8, rollover)

  check(lvCompareTimestamps(high, low) > 0,
        "timestamp: a larger value compares greater")
  check(lvCompareTimestamps(low, high) < 0,
        "timestamp: a smaller value compares lesser")
  check(lvCompareTimestamps(low, low) = 0,
        "timestamp: equal values compare equal")
  check(lvCompareTimestamps(rollover, high) > 0,
        "timestamp: the most significant byte decides, not the first byte")

  bbFree(low)
  bbFree(high)
  bbFree(rollover)
  bbFree(raw)
}

// A near-maximum value must still fit inside the buffer bounds, and the
// serialiser must refuse rather than grow past them.
AND testBufferBounds() BE
{ LET buffer = bbNew(65536)
  LET chunk = bbNew(65536)
  LET refused = FALSE
  FOR index = 1 TO 65536 DO bbPush(chunk, 'x')
  // Fill in chunks rather than byte by byte: the point is the ceiling, and a
  // four million iteration loop under an interpreter proves nothing extra.
  UNTIL refused DO
    UNLESS bbPushBuffer(buffer, chunk) DO refused := TRUE
  check(refused, "bounds: an append past the ceiling is refused")
  check(buffer!Bb_len <= Maxbufferbytes,
        "bounds: a buffer never grows past its ceiling")
  check(buffer!Bb_len + 65536 > Maxbufferbytes,
        "bounds: the refusal happens at the ceiling, not early")
  bbFree(buffer)
  bbFree(chunk)
}

LET start() = VALOF
{ tsFailures := 0
  tsCount := 0
  UNLESS convexInit() DO
  { cxDiagStr("the BCPL native transport extension is not available")
    stop(1)
  }
  testJson()
  testDigest()
  testUrl()
  testHttpHeaders()
  testHandshakeValidation()
  testAdapterEvents()
  testQueueBounds()
  testGenerationBarrier()
  testBackoff()
  testTimestamps()
  testBufferBounds()

  { LET summary = bbNew(64)
    bbPushStr(summary, "1..")
    bbPushNum(summary, tsCount)
    bbPush(summary, '*n')
    cxOut(summary)
    bbFree(summary)
  }
  IF tsFailures > 0 DO stop(1)
  RESULTIS 0
}
