// livetests.b -- deterministic WebSocket and Live tests over a loopback pair.
//
// Every test here drives the real client code against a peer this file
// controls byte by byte, so the failure modes that a friendly deployment never
// produces are exercised on purpose: masked server frames, reserved bits,
// impossible lengths, fragmented control frames, invalid UTF-8, a frame
// delivered one byte at a time across timeouts, and peers that are idle,
// endlessly chatty or stalled halfway through a frame.
//
// The Live half injects a connection into the manager and reads what actually
// goes on the wire, so the Connect announcement, the re-sent Add operations,
// the query-set version barrier and the rehydration suppression are checked
// against bytes rather than against intentions.

SECTION "convexclient"

GET "libhdr"
GET "convexhdr"
GET "convex.b"

.

SECTION "convexlivetests"

GET "libhdr"
GET "convexhdr"

GLOBAL {
tsFailures:  700
tsCount:     701
tsPort:      702
tsListener:  703
tsClient:    704
tsPeer:      705
}

LET report(prefix, name) BE
{ LET line = bbNew(200)
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

// A connected loopback pair. The listen backlog completes the TCP handshake
// before accept, so a single threaded test can hold both ends.
AND pairOpen() = VALOF
{ tsPort := tsPort + 1
  tsListener := cxListen("127.0.0.1", tsPort)
  IF tsListener < 0 RESULTIS FALSE
  tsClient := cxConnect("127.0.0.1", tsPort, FALSE, cxDeadline(2000))
  IF tsClient < 0 DO { cxCloseHandle(tsListener); RESULTIS FALSE }
  tsPeer := cxAccept(tsListener, cxDeadline(2000))
  IF tsPeer < 0 DO
  { cxCloseHandle(tsClient)
    cxCloseHandle(tsListener)
    RESULTIS FALSE
  }
  RESULTIS TRUE
}

AND pairClose() BE
{ IF tsPeer >= 0 DO cxCloseHandle(tsPeer)
  IF tsListener >= 0 DO cxCloseHandle(tsListener)
  tsPeer, tsListener := -1, -1
}

// Builds a WebSocket record around an already connected handle. The opening
// handshake is covered separately by the digest tests, which check the exact
// RFC 6455 accept proof this client requires.
AND wsAdopt(handle) = VALOF
{ LET connection = getvec(Ws_upb)
  UNLESS connection RESULTIS 0
  connection!Ws_handle := handle
  connection!Ws_rx := bbNew(8192)
  connection!Ws_msg := bbNew(4096)
  connection!Ws_rxpos := 0
  connection!Ws_msgop := 0
  connection!Ws_broken := FALSE
  connection!Ws_closesent := FALSE
  RESULTIS connection
}

// Writes a server frame: unmasked, as RFC 6455 requires of a server.
AND peerFrame(fin, opcode, payload, length) = VALOF
{ LET frame = bbNew(length + 16)
  LET sent = 0
  UNLESS frame RESULTIS FALSE
  bbPush(frame, (fin -> #x80, 0) | opcode)
  TEST length < 126
  THEN bbPush(frame, length)
  ELSE TEST length < 65536
  THEN { bbPush(frame, 126)
         bbPush(frame, shr32(length, 8) & 255)
         bbPush(frame, length & 255)
       }
  ELSE { bbPush(frame, 127)
         FOR index = 1 TO 4 DO bbPush(frame, 0)
         bbPush(frame, shr32(length, 24) & 255)
         bbPush(frame, shr32(length, 16) & 255)
         bbPush(frame, shr32(length, 8) & 255)
         bbPush(frame, length & 255)
       }
  IF payload ~= 0 DO bbPushBytes(frame, payload!Bb_vec, 0, length)
  sent := cxWriteBuffer(tsPeer, frame, cxDeadline(2000))
  bbFree(frame)
  RESULTIS sent >= 0
}

AND peerText(text) = VALOF
{ LET payload = bbFromStr(text)
  LET ok = peerFrame(TRUE, Op_text, payload, payload!Bb_len)
  bbFree(payload)
  RESULTIS ok
}

AND peerBytes(buffer) = VALOF
{ LET sent = cxWriteBuffer(tsPeer, buffer, cxDeadline(2000))
  RESULTIS sent >= 0
}

// Collects whatever the client has written, up to the deadline.
AND peerCollect(milliseconds) = VALOF
{ LET buffer = bbNew(4096)
  LET deadline = cxDeadline(milliseconds)
  UNLESS buffer RESULTIS 0
  { LET got = bbReadInto(buffer, tsPeer, 4096, deadline)
    IF got <= 0 DO BREAK
  } REPEAT
  RESULTIS buffer
}

// Decodes one masked client frame from `raw` at `position`, returning the
// payload and advancing the cursor. Returns 0 when nothing complete is there.
AND peerDecode(raw, position, opcode) = VALOF
{ LET start = !position
  LET available = raw!Bb_len - start
  LET length = 0
  LET header = 2
  LET payload = 0
  IF available < 2 RESULTIS 0
  !opcode := bbGet(raw, start) & 15
  length := bbGet(raw, start + 1) & 127
  UNLESS (bbGet(raw, start + 1) & #x80) ~= 0 RESULTIS 0
  TEST length = 126
  THEN { header := 4
         IF available < 4 RESULTIS 0
         length := (bbGet(raw, start + 2) << 8) | bbGet(raw, start + 3)
       }
  ELSE IF length = 127 DO
  { header := 10
    IF available < 10 RESULTIS 0
    length := (bbGet(raw, start + 8) << 8) | bbGet(raw, start + 9)
  }
  IF available < header + 4 + length RESULTIS 0
  payload := bbNew(length + 1)
  UNLESS payload RESULTIS 0
  FOR index = 0 TO length - 1 DO
    bbPush(payload, bbGet(raw, start + header + 4 + index) NEQV
                    bbGet(raw, start + header + (index REM 4)))
  !position := start + header + 4 + length
  RESULTIS payload
}

// ---------------------------------------------------------------------------
// WebSocket framing
// ---------------------------------------------------------------------------

AND testHappyFrame() BE
{ LET connection = 0
  LET message = 0
  UNLESS pairOpen() DO { check(FALSE, "frame: loopback pair opens"); RETURN }
  connection := wsAdopt(tsClient)
  peerText("{*"type*":*"Ping*"}")
  message := wsNextMessage(connection, cxDeadline(2000))
  check(message ~= 0, "frame: a complete text frame is delivered")
  IF message ~= 0 DO
    check(bbEqualStr(message, "{*"type*":*"Ping*"}"),
          "frame: the payload is exact")
  wsFree(connection)
  pairClose()
}

// The failure this guards against is a reader that abandons a partly received
// frame on timeout and then resynchronises on the wrong byte.
AND testResumableParse() BE
{ LET connection = 0
  LET whole = 0
  LET message = 0
  LET nones = 0
  UNLESS pairOpen() DO { check(FALSE, "frame: loopback pair opens"); RETURN }
  connection := wsAdopt(tsClient)

  // Build the frame by hand, then feed it one byte at a time with a timeout
  // between every byte.
  whole := bbNew(32)
  bbPush(whole, #x81)
  bbPush(whole, 5)
  bbPushStr(whole, "hello")

  FOR index = 0 TO whole!Bb_len - 1 DO
  { LET single = bbNew(2)
    bbPush(single, bbGet(whole, index))
    peerBytes(single)
    bbFree(single)
    message := wsNextMessage(connection, cxDeadline(40))
    IF message = 0 DO
      IF wsStatus = Wss_none DO nones := nones + 1
    IF message ~= 0 DO BREAK
  }
  check(nones = whole!Bb_len - 1,
        "frame: every incomplete step reports nothing rather than failing")
  check(message ~= 0, "frame: the frame completes on the final byte")
  IF message ~= 0 DO
    check(bbEqualStr(message, "hello"),
          "frame: parser state survives a timeout mid-frame")
  bbFree(whole)
  wsFree(connection)
  pairClose()
}

AND testFragmentAndPing() BE
{ LET connection = 0
  LET message = 0
  LET written = 0
  LET position = 0
  LET opcode = 0
  LET payload = 0
  LET part = 0
  UNLESS pairOpen() DO { check(FALSE, "frame: loopback pair opens"); RETURN }
  connection := wsAdopt(tsClient)

  part := bbFromStr("abc")
  peerFrame(FALSE, Op_text, part, 3)
  bbFree(part)
  part := bbFromStr("xy")
  peerFrame(TRUE, Op_ping, part, 2)
  bbFree(part)
  part := bbFromStr("def")
  peerFrame(TRUE, Op_continue, part, 3)
  bbFree(part)

  message := wsNextMessage(connection, cxDeadline(2000))
  check(message ~= 0, "frame: a fragmented message is reassembled")
  IF message ~= 0 DO
    check(bbEqualStr(message, "abcdef"),
          "frame: fragments join in order across an interleaved control frame")

  written := peerCollect(300)
  payload := peerDecode(written, @position, @opcode)
  check(opcode = Op_pong, "frame: a ping is answered with a pong")
  IF payload ~= 0 DO
  { check(bbEqualStr(payload, "xy"), "frame: the pong echoes the ping payload")
    bbFree(payload)
  }
  bbFree(written)
  wsFree(connection)
  pairClose()
}

// Sends `raw` to the client and asserts the reader rejects it as protocol
// drift rather than accepting it or hanging.
AND checkHostile(raw, name) BE
{ LET connection = 0
  LET message = 0
  UNLESS pairOpen() DO { check(FALSE, name); RETURN }
  connection := wsAdopt(tsClient)
  peerBytes(raw)
  message := wsNextMessage(connection, cxDeadline(1000))
  check(message = 0 & wsStatus = Wss_protocol, name)
  wsFree(connection)
  pairClose()
  bbFree(raw)
}

AND testHostilePeers() BE
{ LET raw = 0

  raw := bbNew(16)
  bbPush(raw, #x81)
  bbPush(raw, #x83)          // the mask bit, which a server must never set
  bbPush(raw, 0); bbPush(raw, 0); bbPush(raw, 0); bbPush(raw, 0)
  bbPushStr(raw, "abc")
  checkHostile(raw, "hostile: a masked server frame is refused")

  raw := bbNew(16)
  bbPush(raw, #xC1)          // RSV1 set without a negotiated extension
  bbPush(raw, 1)
  bbPush(raw, 'a')
  checkHostile(raw, "hostile: a reserved bit is refused")

  raw := bbNew(16)
  bbPush(raw, #x81)
  bbPush(raw, 127)
  FOR index = 1 TO 4 DO bbPush(raw, 0)
  bbPush(raw, #x7F); bbPush(raw, #xFF); bbPush(raw, #xFF); bbPush(raw, #xFF)
  checkHostile(raw, "hostile: a length beyond the frame bound is refused")

  raw := bbNew(16)
  bbPush(raw, #x81)
  bbPush(raw, 127)           // a 64-bit length with the top bit set
  bbPush(raw, #x80)
  FOR index = 1 TO 7 DO bbPush(raw, 0)
  checkHostile(raw, "hostile: an impossible 64-bit length is refused")

  raw := bbNew(16)
  bbPush(raw, #x09)          // a ping without FIN
  bbPush(raw, 1)
  bbPush(raw, 'a')
  checkHostile(raw, "hostile: a fragmented control frame is refused")

  raw := bbNew(16)
  bbPush(raw, #x89)          // an oversized ping
  bbPush(raw, 126)
  bbPush(raw, 0)
  bbPush(raw, 200)
  FOR index = 1 TO 200 DO bbPush(raw, 'a')
  checkHostile(raw, "hostile: an oversized control frame is refused")

  raw := bbNew(16)
  bbPush(raw, #x80)          // a continuation with nothing to continue
  bbPush(raw, 1)
  bbPush(raw, 'a')
  checkHostile(raw, "hostile: an orphan continuation frame is refused")

  raw := bbNew(16)
  bbPush(raw, #x01)          // start a fragmented message
  bbPush(raw, 1)
  bbPush(raw, 'a')
  bbPush(raw, #x81)          // then start another one before finishing it
  bbPush(raw, 1)
  bbPush(raw, 'b')
  checkHostile(raw, "hostile: an interleaved data frame is refused")

  raw := bbNew(16)
  bbPush(raw, #x81)
  bbPush(raw, 2)
  bbPush(raw, #xC0)          // an over-long UTF-8 encoding
  bbPush(raw, #x80)
  checkHostile(raw, "hostile: invalid UTF-8 in a text frame is refused")

  raw := bbNew(16)
  bbPush(raw, #x88)          // a close frame carrying half a status code
  bbPush(raw, 1)
  bbPush(raw, 3)
  checkHostile(raw, "hostile: a one byte close payload is refused")
}

AND testCloseHandshake() BE
{ LET connection = 0
  LET message = 0
  LET raw = 0
  UNLESS pairOpen() DO { check(FALSE, "close: loopback pair opens"); RETURN }
  connection := wsAdopt(tsClient)
  raw := bbNew(8)
  bbPush(raw, #x88)
  bbPush(raw, 2)
  bbPush(raw, 3)
  bbPush(raw, #xE8)          // status 1000
  peerBytes(raw)
  bbFree(raw)
  message := wsNextMessage(connection, cxDeadline(1000))
  check(message = 0, "close: a close frame ends the message stream")
  check(wsStatus = Wss_eof, "close: a close frame reports a clean end")
  { LET written = peerCollect(300)
    LET position = 0
    LET opcode = 0
    LET payload = peerDecode(written, @position, @opcode)
    check(opcode = Op_close, "close: the client echoes a close frame")
    IF payload DO bbFree(payload)
    // RFC 6455 allows one close frame per endpoint, so the echo must not be
    // followed by a second one when the client then closes for itself. The
    // recorded flag is checked directly as well as on the wire, because an
    // absent frame is otherwise indistinguishable from a lost one.
    check(connection!Ws_closesent,
          "close: echoing a close records that this end has sent one")
    wsCloseGracefully(connection, cxDeadline(200))
    connection := 0
    bbFree(written)
    written := peerCollect(200)
    check(written!Bb_len = 0, "close: the client sends exactly one close frame")
    bbFree(written)
  }
  IF connection ~= 0 DO wsFree(connection)
  pairClose()
}

AND testClientFramesAreMasked() BE
{ LET connection = 0
  LET payload = bbFromStr("{*"type*":*"Connect*"}")
  LET written = 0
  LET position = 0
  LET opcode = 0
  LET decoded = 0
  UNLESS pairOpen() DO { check(FALSE, "mask: loopback pair opens"); RETURN }
  connection := wsAdopt(tsClient)
  wsSendText(connection, payload, cxDeadline(2000))
  written := peerCollect(300)
  check(written!Bb_len > 6, "mask: the client wrote a frame")
  check((bbGet(written, 1) & #x80) ~= 0,
        "mask: a client frame always sets the mask bit")
  decoded := peerDecode(written, @position, @opcode)
  check(opcode = Op_text, "mask: the frame is a text frame")
  IF decoded ~= 0 DO
  { check(bbEqual(decoded, payload), "mask: unmasking recovers the payload")
    bbFree(decoded)
  }
  bbFree(written)
  bbFree(payload)
  wsFree(connection)
  pairClose()
}

// Close has to be bounded whatever the peer does. Each case asserts the
// elapsed time against the deadline, not merely that the call returned.
AND checkBoundedClose(prepare, name) BE
{ LET connection = 0
  LET started = 0
  LET elapsed = 0
  UNLESS pairOpen() DO { check(FALSE, name); RETURN }
  connection := wsAdopt(tsClient)
  prepare()
  started := cxNow()
  wsCloseGracefully(connection, cxDeadline(300))
  elapsed := cxNow() - started
  check(elapsed < 3000, name)
  pairClose()
}

AND prepareIdle() BE RETURN

AND prepareChatty() BE
{ LET payload = bbFromStr("keep talking")
  // Roughly 64 KiB of complete frames, all buffered before close begins, so
  // the reader always has something new to consume.
  FOR index = 1 TO 4000 DO peerFrame(TRUE, Op_text, payload, payload!Bb_len)
  bbFree(payload)
}

AND prepareStalled() BE
{ LET raw = bbNew(32)
  bbPush(raw, #x81)
  bbPush(raw, 126)
  bbPush(raw, #x03)
  bbPush(raw, #xE8)          // announces 1000 bytes
  FOR index = 1 TO 10 DO bbPush(raw, 'a')   // and then stops
  peerBytes(raw)
  bbFree(raw)
}

AND testBoundedClose() BE
{ checkBoundedClose(prepareIdle, "close: an idle peer cannot delay close")
  checkBoundedClose(prepareChatty,
                    "close: a continuously sending peer cannot delay close")
  checkBoundedClose(prepareStalled,
                    "close: a peer stalled mid-frame cannot delay close")
}

// ---------------------------------------------------------------------------
// The Live owner
// ---------------------------------------------------------------------------

AND makeManager() = VALOF
{ LET endpoint = epNew(FALSE, bbFromStr("127.0.0.1"), 1, bbNew(4))
  RESULTIS lvNew(endpoint, bbFromStr("bcpl-0.1.0"))
}

AND freeManager(manager) BE
{ LET endpoint = manager!Lv_ep
  lvFree(manager)
  epFree(endpoint)
}

AND addSubscription(manager, subid, path) =
      lvSubscribe(manager, bbFromStr(subid), bbFromStr(path), jsObject())

// Sync messages are assembled from short pieces: a BCPL string literal holds
// its length in its first byte, so no single literal may exceed 255 bytes.
AND modUpdated(queryid, count) = VALOF
{ LET mods = bbNew(128)
  bbPushStr(mods, "{*"type*":*"QueryUpdated*",*"queryId*":")
  bbPushNum(mods, queryid)
  bbPushStr(mods, ",*"value*":{*"count*":")
  bbPushNum(mods, count)
  bbPushStr(mods, "},*"logLines*":[]}")
  RESULTIS mods
}

AND modFailed(queryid) = VALOF
{ LET mods = bbNew(200)
  bbPushStr(mods, "{*"type*":*"QueryFailed*",*"queryId*":")
  bbPushNum(mods, queryid)
  bbPushStr(mods, ",*"errorMessage*":*"Increment the room*"")
  bbPushStr(mods, ",*"errorData*":{*"code*":*"ROOM_EMPTY*"}")
  bbPushStr(mods, ",*"logLines*":[]}")
  RESULTIS mods
}

// Delivers one Transition to the manager by writing it as a frame and stepping
// the owner once. Ownership of `mods` passes here.
AND serverTransition(manager, startquery, startts, endquery, endts, mods) BE
{ LET text = bbNew(512)
  bbPushStr(text, "{*"type*":*"Transition*",*"startVersion*":{*"querySet*":")
  bbPushNum(text, startquery)
  bbPushStr(text, ",*"identity*":0,*"ts*":*"")
  bbPushStr(text, startts)
  bbPushStr(text, "*"},*"endVersion*":{*"querySet*":")
  bbPushNum(text, endquery)
  bbPushStr(text, ",*"identity*":0,*"ts*":*"")
  bbPushStr(text, endts)
  bbPushStr(text, "*"},*"modifications*":[")
  IF mods ~= 0 DO bbPushBuffer(text, mods)
  bbPushStr(text, "]}")
  peerFrame(TRUE, Op_text, text, text!Bb_len)
  bbFree(text)
  IF mods ~= 0 DO bbFree(mods)
  lvStep(manager, cxDeadline(1000))
}

AND testAnnounce() BE
{ LET manager = makeManager()
  LET written = 0
  LET position = 0
  LET opcode = 0
  LET connect = 0
  LET modify = 0
  LET node = 0
  // Subscribe before the socket exists, so the only traffic on the wire is
  // what the announcement itself produces.
  addSubscription(manager, "s1", "demo:state")
  addSubscription(manager, "s2", "demo:roomId")
  manager!Lv_conncount := 3
  bbFree(manager!Lv_lastclose)
  manager!Lv_lastclose := bbFromStr("DebugDisconnect")
  UNLESS pairOpen() DO { check(FALSE, "live: loopback pair opens"); RETURN }
  manager!Lv_ws := wsAdopt(tsClient)

  check(lvAnnounce(manager, cxDeadline(2000)),
        "live: a fresh connection is announced")
  written := peerCollect(300)

  connect := peerDecode(written, @position, @opcode)
  check(connect ~= 0, "live: the announcement is a frame")
  IF connect ~= 0 DO
  { node := jsParseBuffer(connect)
    check(jsStringEqualsStr(jsObjectGet(node, "type"), "Connect"),
          "live: the first message is Connect")
    { LET count = -1
      jsWholeNumber(jsObjectGet(node, "connectionCount"), @count)
      check(count = 3, "live: Connect carries the connection count")
    }
    check(jsStringEqualsStr(jsObjectGet(node, "lastCloseReason"),
                            "DebugDisconnect"),
          "live: Connect carries the last close reason")
    check(jsObjectGet(node, "maxObservedTimestamp") = 0,
          "live: a first Connect omits the zero timestamp entirely")
    jsFree(node)
    bbFree(connect)
  }

  modify := peerDecode(written, @position, @opcode)
  check(modify ~= 0, "live: the query set follows the announcement")
  IF modify ~= 0 DO
  { LET adds = 0
    node := jsParseBuffer(modify)
    check(jsStringEqualsStr(jsObjectGet(node, "type"), "ModifyQuerySet"),
          "live: the second message is ModifyQuerySet")
    adds := jsObjectGet(node, "modifications")
    check(jsCount(adds) = 2,
          "live: every active subscription is re-sent as an Add")
    check(jsStringEqualsStr(jsObjectGet(jsArrayGet(adds, 0), "type"), "Add"),
          "live: the modification is an Add")
    check(jsStringEqualsStr(jsObjectGet(jsArrayGet(adds, 0), "udfPath"),
                            "demo:state"),
          "live: the Add names the original function")
    { LET base = -1
      jsWholeNumber(jsObjectGet(node, "baseVersion"), @base)
      check(base = 0, "live: the query set version starts at zero")
    }
    jsFree(node)
    bbFree(modify)
  }

  bbFree(written)

  // Once a transition has been seen the field must appear, because that is
  // what lets a reconnect resume instead of replaying.
  bbFree(manager!Lv_maxts)
  manager!Lv_maxts := bbFromStr("AQAAAAAAAAA=")
  lvAnnounce(manager, cxDeadline(2000))
  written := peerCollect(300)
  position := 0
  connect := peerDecode(written, @position, @opcode)
  IF connect ~= 0 DO
  { node := jsParseBuffer(connect)
    check(jsStringEqualsStr(jsObjectGet(node, "maxObservedTimestamp"),
                            "AQAAAAAAAAA="),
          "live: a later Connect carries the highest timestamp seen")
    jsFree(node)
    bbFree(connect)
  }
  bbFree(written)

  freeManager(manager)
  pairClose()
}

AND testTransitions() BE
{ LET manager = makeManager()
  LET subscription = 0
  LET update = 0
  subscription := addSubscription(manager, "s1", "demo:state")
  UNLESS pairOpen() DO { check(FALSE, "live: loopback pair opens"); RETURN }
  manager!Lv_ws := wsAdopt(tsClient)
  lvAnnounce(manager, cxDeadline(2000))
  bbFree(peerCollect(200))

  serverTransition(manager, 0, "AAAAAAAAAAA=", 1, "AQAAAAAAAAA=",
                   modUpdated(0, 0))
  update := sbTake(manager, subscription)
  check(update ~= 0, "live: an initial QueryUpdated is delivered")
  IF update ~= 0 DO
  { LET count = -1
    jsWholeNumber(jsObjectGet(update!Up_value, "count"), @count)
    check(count = 0, "live: the initial value decodes")
    upFree(update)
  }
  check(manager!Lv_remotequery = 1, "live: the remote query set version moves")
  check(bbEqualStr(manager!Lv_maxts, "AQAAAAAAAAA="),
        "live: the highest observed timestamp is recorded")

  serverTransition(manager, 1, "AQAAAAAAAAA=", 1, "AgAAAAAAAAA=",
                   modUpdated(0, 1))
  update := sbTake(manager, subscription)
  check(update ~= 0, "live: an external update is delivered")
  IF update ~= 0 DO
  { LET count = -1
    jsWholeNumber(jsObjectGet(update!Up_value, "count"), @count)
    check(count = 1, "live: the updated value decodes")
    upFree(update)
  }

  freeManager(manager)
  pairClose()
}

AND testVersionBarrier() BE
{ LET manager = makeManager()
  LET subscription = 0
  LET update = 0
  subscription := addSubscription(manager, "s1", "demo:state")
  UNLESS pairOpen() DO { check(FALSE, "live: loopback pair opens"); RETURN }
  manager!Lv_ws := wsAdopt(tsClient)
  lvAnnounce(manager, cxDeadline(2000))
  bbFree(peerCollect(200))

  // A Transition that does not continue from the version this client holds is
  // drift, not data: accepting it would silently desynchronise the query set.
  serverTransition(manager, 7, "AAAAAAAAAAA=", 8, "AQAAAAAAAAA=", 0)
  update := sbTake(manager, subscription)
  check(update ~= 0, "barrier: a version mismatch reaches the subscriber")
  IF update ~= 0 DO
  { check(bbEqualStr(update!Up_errname, "ProtocolError"),
          "barrier: the failure is reported as protocol drift")
    upFree(update)
  }
  check(manager!Lv_ws = 0, "barrier: the connection is retired")
  check(manager!Lv_nextattempt > 0, "barrier: a reconnect is scheduled")
  check(bbEqualStr(manager!Lv_lastclose, "ProtocolError"),
        "barrier: the close reason is recorded for the next Connect")
  freeManager(manager)
  pairClose()
}

AND testQueryFailureAndRecovery() BE
{ LET manager = makeManager()
  LET subscription = 0
  LET update = 0
  subscription := addSubscription(manager, "s1", "demo:requiresNonzero")
  UNLESS pairOpen() DO { check(FALSE, "live: loopback pair opens"); RETURN }
  manager!Lv_ws := wsAdopt(tsClient)
  lvAnnounce(manager, cxDeadline(2000))
  bbFree(peerCollect(200))

  serverTransition(manager, 0, "AAAAAAAAAAA=", 1, "AQAAAAAAAAA=",
                   modFailed(0))
  update := sbTake(manager, subscription)
  check(update ~= 0, "recovery: a failed query reaches the subscriber")
  IF update ~= 0 DO
  { check(bbEqualStr(update!Up_errname, "FunctionError"),
          "recovery: a query failure is a function error, not a transport one")
    check(jsStringEqualsStr(jsObjectGet(update!Up_errdata, "code"),
                            "ROOM_EMPTY"),
          "recovery: the Convex error data survives")
    upFree(update)
  }

  // The subscription must not be stranded by its own failure.
  serverTransition(manager, 1, "AQAAAAAAAAA=", 1, "AgAAAAAAAAA=",
                   modUpdated(0, 1))
  update := sbTake(manager, subscription)
  check(update ~= 0, "recovery: the repaired query delivers again")
  IF update ~= 0 DO
  { LET count = -1
    jsWholeNumber(jsObjectGet(update!Up_value, "count"), @count)
    check(count = 1, "recovery: the repaired value decodes")
    upFree(update)
  }
  freeManager(manager)
  pairClose()
}

AND testRehydrationSuppression() BE
{ LET manager = makeManager()
  LET subscription = 0
  LET update = 0
  subscription := addSubscription(manager, "s1", "demo:state")
  UNLESS pairOpen() DO { check(FALSE, "live: loopback pair opens"); RETURN }
  manager!Lv_ws := wsAdopt(tsClient)
  lvAnnounce(manager, cxDeadline(2000))
  bbFree(peerCollect(200))

  serverTransition(manager, 0, "AAAAAAAAAAA=", 1, "AQAAAAAAAAA=",
                   modUpdated(0, 0))
  update := sbTake(manager, subscription)
  check(update ~= 0, "rehydrate: the initial value is delivered")
  IF update DO upFree(update)

  // A reconnect replays the value the consumer already holds. Publishing it
  // would invent a change that never happened, which is exactly what turns a
  // reconnect test into a false pass.
  subscription!Sb_rehydrate := TRUE
  serverTransition(manager, 1, "AQAAAAAAAAA=", 1, "AgAAAAAAAAA=",
                   modUpdated(0, 0))
  check(sbTake(manager, subscription) = 0,
        "rehydrate: an unchanged rehydration is suppressed")

  // A genuinely different value after a reconnect must still arrive.
  subscription!Sb_rehydrate := TRUE
  serverTransition(manager, 1, "AgAAAAAAAAA=", 1, "AwAAAAAAAAA=",
                   modUpdated(0, 1))
  update := sbTake(manager, subscription)
  check(update ~= 0, "rehydrate: a changed value after a reconnect is kept")
  IF update DO upFree(update)

  freeManager(manager)
  pairClose()
}

AND testDebugDisconnect() BE
{ LET manager = makeManager()
  LET subscription = 0
  subscription := addSubscription(manager, "s1", "demo:state")
  UNLESS pairOpen() DO { check(FALSE, "live: loopback pair opens"); RETURN }
  manager!Lv_ws := wsAdopt(tsClient)
  lvAnnounce(manager, cxDeadline(2000))
  bbFree(peerCollect(200))
  manager!Lv_backoff := Backoffmaxms

  check(lvDisconnectForAdapter(manager),
        "disconnect: the adapter hook reports success")
  check(manager!Lv_ws = 0,
        "disconnect: the old connection is retired before the hook returns")
  check(manager!Lv_conncount = 1, "disconnect: the connection count advances")
  check(bbEqualStr(manager!Lv_lastclose, "DebugDisconnect"),
        "disconnect: the reason is recorded for the next Connect")
  check(subscription!Sb_rehydrate,
        "disconnect: the subscription expects a rehydration")
  check(manager!Lv_backoff = Backoffbasems,
        "disconnect: a deliberate disconnect does not inherit an old delay")
  check(manager!Lv_nextattempt <= cxNow(),
        "disconnect: reconnect work is already scheduled")
  freeManager(manager)
  pairClose()
}

AND testUnsubscribeWire() BE
{ LET manager = makeManager()
  LET subscription = 0
  LET written = 0
  LET position = 0
  LET opcode = 0
  LET payload = 0
  subscription := addSubscription(manager, "s1", "demo:state")
  addSubscription(manager, "s2", "demo:state")
  UNLESS pairOpen() DO { check(FALSE, "live: loopback pair opens"); RETURN }
  manager!Lv_ws := wsAdopt(tsClient)
  lvAnnounce(manager, cxDeadline(2000))
  bbFree(peerCollect(200))

  lvUnsubscribe(manager, subscription)
  written := peerCollect(300)
  payload := peerDecode(written, @position, @opcode)
  check(payload ~= 0, "unsubscribe: a Remove goes on the wire")
  IF payload ~= 0 DO
  { LET node = jsParseBuffer(payload)
    LET mods = jsObjectGet(node, "modifications")
    check(jsStringEqualsStr(jsObjectGet(jsArrayGet(mods, 0), "type"), "Remove"),
          "unsubscribe: the modification is a Remove")
    jsFree(node)
    bbFree(payload)
  }
  check((manager!Lv_subs)!Vl_len = 1,
        "unsubscribe: the subscription is gone from the query set")
  check(manager!Lv_ws ~= 0,
        "unsubscribe: a remaining subscription keeps the connection")
  bbFree(written)
  freeManager(manager)
  pairClose()
}

// Retiring the last subscription closes the socket, and it does so with a real
// closing handshake rather than by dropping TCP and leaving the deployment to
// time the connection out.
AND testUnsubscribeLastCloses() BE
{ LET manager = makeManager()
  LET subscription = 0
  LET written = 0
  LET position = 0
  LET opcode = 0
  LET payload = 0
  LET started = 0
  LET elapsed = 0
  LET raw = 0
  subscription := addSubscription(manager, "s1", "demo:state")
  UNLESS pairOpen() DO { check(FALSE, "live: loopback pair opens"); RETURN }
  manager!Lv_ws := wsAdopt(tsClient)
  lvAnnounce(manager, cxDeadline(2000))
  bbFree(peerCollect(200))

  // Stage the server's half of the closing handshake, so the drain finds it
  // immediately and the bound below is measuring the client, not the fixture.
  raw := bbNew(8)
  bbPush(raw, #x88)
  bbPush(raw, 2)
  bbPush(raw, 3)
  bbPush(raw, #xE8)          // status 1000
  peerBytes(raw)
  bbFree(raw)

  started := cxNow()
  lvUnsubscribe(manager, subscription)
  elapsed := cxNow() - started

  check(manager!Lv_ws = 0,
        "retire: the last unsubscribe releases the connection")
  check(manager!Lv_conncount = 1,
        "retire: retiring advances the connection count")
  check(bbEqualStr(manager!Lv_lastclose, "NoSubscriptions"),
        "retire: the reason is recorded for the next Connect")
  check(elapsed < Closetimeoutms,
        "retire: the closing handshake is bounded")

  written := peerCollect(300)
  payload := peerDecode(written, @position, @opcode)
  check(opcode = Op_text, "retire: the Remove goes out before the close")
  IF payload ~= 0 DO
  { LET node = jsParseBuffer(payload)
    LET mods = jsObjectGet(node, "modifications")
    check(jsStringEqualsStr(jsObjectGet(jsArrayGet(mods, 0), "type"), "Remove"),
          "retire: the modification is a Remove")
    jsFree(node)
    bbFree(payload)
  }
  payload := peerDecode(written, @position, @opcode)
  check(opcode = Op_close, "retire: the client sends a close frame")
  IF payload ~= 0 DO bbFree(payload)
  check(peerDecode(written, @position, @opcode) = 0,
        "retire: nothing follows the close frame")
  bbFree(written)
  freeManager(manager)
  pairClose()
}

LET start() = VALOF
{ tsFailures := 0
  tsCount := 0
  tsPort := 19080
  tsListener := -1
  tsPeer := -1
  UNLESS convexInit() DO
  { cxDiagStr("the BCPL native transport extension is not available")
    stop(1)
  }

  testHappyFrame()
  testResumableParse()
  testFragmentAndPing()
  testHostilePeers()
  testCloseHandshake()
  testClientFramesAreMasked()
  testBoundedClose()
  testAnnounce()
  testTransitions()
  testVersionBarrier()
  testQueryFailureAndRecovery()
  testRehydrationSuppression()
  testDebugDisconnect()
  testUnsubscribeWire()
  testUnsubscribeLastCloses()

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
