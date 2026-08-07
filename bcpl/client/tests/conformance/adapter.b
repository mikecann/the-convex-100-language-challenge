// adapter.b -- the NDJSON adapter protocol v1 conformance executable.
//
// Test infrastructure, not public client code. It exists so the shared
// controller can drive the real BCPL client black-box, and it calls the same
// convex* entry points the canonical example uses. Nothing here reimplements
// Convex behaviour.
//
// Stdout, or the accepted TCP connection when ADAPTER_LISTEN is set, carries
// protocol events and nothing else. Diagnostics go to stderr.

SECTION "convexclient"

GET "libhdr"
GET "convexhdr"
GET "convex.b"

.

SECTION "convexadapter"

GET "libhdr"
GET "convexhdr"
GET "eventshdr"

// The event builders are shared with client/tests/clienttests.b, so the bytes
// that file asserts are the bytes this program emits rather than a second copy
// of the same intention.
GET "events.b"

// Adapter state. These sit above the client's global range, which ends well
// below 700, and below the event builders' range, which starts at 800.
GLOBAL {
adOut:      700
adControl:  701
adListener: 702
adClient:   703
adInbuf:    704
adFinished: 705
}

// The last resort. Every builder refuses to produce a partly filled event, so
// a controller command must still be answered with something it can parse when
// the client has run out of memory. This line needs one small buffer and
// nothing else.
LET adEmitFallback() BE
{ LET line = bbNew(128)
  UNLESS line RETURN
  bbPushStr(line, "{*"type*":*"error*",*"error*":{*"name*":*"InternalError*",")
  bbPushStr(line, "*"message*":*"the BCPL client ran out of memory*"}}")
  IF bbPush(line, '*n') DO
    cxWriteBuffer(adOut, line, cxDeadline(Httptimeoutms))
  bbFree(line)
}

// Every event is built as a JSON value and serialised, so an absent field is
// absent rather than serialised as null. The shared controller validates each
// line strictly, and a stray "id": null would fail that validation.
AND adEmit(event) BE
{ LET text = 0
  UNLESS event DO { adEmitFallback(); RETURN }
  text := jsSerialise(event)
  jsFree(event)
  UNLESS text DO { adEmitFallback(); RETURN }
  // A line without its terminator would merge into the next event and fail the
  // controller's parse, so a refused newline abandons the line instead.
  TEST bbPush(text, '*n')
  THEN cxWriteBuffer(adOut, text, cxDeadline(Httptimeoutms))
  ELSE
  { cxDiagStr("an adapter event exceeded its buffer bound")
    adEmitFallback()
  }
  bbFree(text)
}

// Reports whatever the client left in the structured failure globals, so a
// Convex function error keeps its data and is never flattened into a result.
AND adEmitError(id) BE adEmit(evFromError(id))

AND adEmitProtocolError(id, message) BE
  adEmit(evProtocolError(id, "ProtocolError", message))

AND adEmitInternalError(id, message) BE
  adEmit(evProtocolError(id, "InternalError", message))

AND adEmitAck(id) BE adEmit(evAck(id))

// A result event that could not be rendered is reported as a failure against
// the same command id. Emitting the event with its value field missing would
// be a successful answer that had lost the answer.
AND adEmitResult(id, result) BE
{ LET event = evResult(id, result)
  TEST event = 0
  THEN adEmitInternalError(id, "the Convex result could not be rendered")
  ELSE adEmit(event)
}

AND adEmitReady(id) BE
{ LET event = evReady(id)
  TEST event = 0
  THEN adEmitInternalError(id, "the adapter ready event could not be built")
  ELSE adEmit(event)
}

// A subscription event carries either a value or an error, never both. One
// that could not be rendered becomes a subscription error rather than a
// subscription event with no value in it.
AND adEmitSubscription(subid, update) BE
{ LET event = evSubscription(subid, update)
  UNLESS event DO
  { LET failure = jsObject()
    LET ok = failure ~= 0
    IF ok DO ok := evPut(failure, "type", jsStringFromStr("subscription"))
    IF ok DO ok := evPut(failure, "subscriptionId",
                         jsStringFromBuffer(bbCopy(subid)))
    IF ok DO ok := evPut(failure, "error",
                         evError(0, 0, 0))
    UNLESS ok DO { jsFree(failure); failure := 0 }
    adEmit(failure)
    RETURN
  }
  adEmit(event)
}

// Publish everything the Live owner has queued. Values a retired generation
// left behind are discarded inside sbTake, so nothing stale escapes here.
AND adDrain() BE
{ LET manager = adClient!Cl_live
  UNLESS manager RETURN
  FOR index = 0 TO (manager!Lv_subs)!Vl_len - 1 DO
  { LET subscription = vlGet(manager!Lv_subs, index)
    { LET update = sbTake(manager, subscription)
      UNTIL update = 0 DO
      { adEmitSubscription(subscription!Sb_subid, update)
        upFree(update)
        update := sbTake(manager, subscription)
      }
    }
  }
}

AND adStringArg(command, key) = VALOF
{ LET node = jsObjectGet(command, key)
  IF node = 0 RESULTIS 0
  UNLESS node!Js_type = Jt_string RESULTIS 0
  RESULTIS bbCopy(node!Js_a)
}

AND adCall(command, id, target) BE
{ LET path = adStringArg(command, "path")
  LET arguments = jsObjectGet(command, "args")
  LET result = 0
  IF path = 0 DO
  { adEmitProtocolError(id, "the adapter command had no function path")
    RETURN
  }
  result := convexCall(adClient, target, path, arguments,
                       cxDeadline(Httptimeoutms))
  bbFree(path)
  TEST result = 0
  THEN adEmitError(id)
  ELSE { adEmitResult(id, result); convexResultFree(result) }
}

AND adSubscribe(command, id) BE
{ LET subid = adStringArg(command, "subscriptionId")
  LET path = adStringArg(command, "path")
  LET arguments = jsObjectGet(command, "args")
  LET cloned = 0
  LET subscription = 0
  IF subid = 0 DO
  { adEmitProtocolError(id, "the adapter command had no subscription id")
    bbFree(path)
    RETURN
  }
  IF path = 0 DO
  { adEmitProtocolError(id, "the adapter command had no function path")
    bbFree(subid)
    RETURN
  }
  // Arguments this adapter could not clone would silently become {}, which is
  // a different query. Refuse instead.
  IF arguments ~= 0 DO
  { cloned := jsClone(arguments)
    IF cloned = 0 DO
    { adEmitInternalError(id,
        "the subscription arguments could not be held")
      bbFree(subid)
      bbFree(path)
      RETURN
    }
  }
  // Replacing a live subscription with the same identifier retires the old
  // relay first. That barrier lives in lvSubscribe, so it holds for every
  // caller rather than only for this adapter, and the acknowledgement below is
  // therefore sent only once the old generation can no longer publish.
  //
  // convexSubscribe owns subid, path and the cloned arguments from here,
  // whether it succeeds or fails.
  subscription := convexSubscribe(adClient, subid, path, cloned)
  TEST subscription = 0
  THEN adEmitError(id)
  ELSE adEmitAck(id)
}

AND adUnsubscribe(command, id) BE
{ LET subid = adStringArg(command, "subscriptionId")
  LET subscription = 0
  IF subid = 0 DO
  { adEmitProtocolError(id, "the adapter command had no subscription id")
    RETURN
  }
  IF adClient!Cl_live DO
  { subscription := lvFindSub(adClient!Cl_live, subid)
    IF subscription ~= 0 DO convexUnsubscribe(adClient, subscription)
  }
  bbFree(subid)
  // The acknowledgement is sent only after the relay has been invalidated.
  adEmitAck(id)
}

AND adSetAuth(command, id) BE
{ LET token = adStringArg(command, "token")
  IF token = 0 DO
  { adEmitProtocolError(id, "the adapter command had no token")
    RETURN
  }
  convexSetAuth(adClient, token)
  bbFree(token)
  adEmitAck(id)
}

AND adClose(id) BE
{ IF adClient!Cl_live DO
    UNTIL (adClient!Cl_live!Lv_subs)!Vl_len = 0 DO
      convexUnsubscribe(adClient, vlGet(adClient!Cl_live!Lv_subs, 0))
  convexClose(adClient)
  adEmit(evClosed(id))
  adFinished := TRUE
}

AND adHandleCommand(line) BE
{ LET command = jsParseBuffer(line)
  LET id = 0
  LET op = 0
  UNLESS command DO
  { adEmitProtocolError(0, "malformed adapter command")
    RETURN
  }
  id := adStringArg(command, "id")
  op := jsObjectGet(command, "op")

  IF jsStringEqualsStr(op, "hello") DO
  { LET version = 0
    IF id = 0 DO
    { adEmitProtocolError(0, "the adapter command had no id")
      jsFree(command)
      RETURN
    }
    UNLESS jsWholeNumber(jsObjectGet(command, "protocolVersion"), @version) DO
      version := -1
    TEST version = 1
    THEN adEmitReady(id)
    ELSE adEmitProtocolError(id, "unsupported adapter protocol version")
    bbFree(id)
    jsFree(command)
    RETURN
  }

  IF id = 0 DO
  { adEmitProtocolError(0, "the adapter command had no id")
    jsFree(command)
    RETURN
  }

  TEST jsStringEqualsStr(op, "query")
  THEN adCall(command, id, "/api/query")
  ELSE TEST jsStringEqualsStr(op, "mutation")
  THEN adCall(command, id, "/api/mutation")
  ELSE TEST jsStringEqualsStr(op, "action")
  THEN adCall(command, id, "/api/action")
  ELSE TEST jsStringEqualsStr(op, "setAuth")
  THEN adSetAuth(command, id)
  ELSE TEST jsStringEqualsStr(op, "subscribe")
  THEN adSubscribe(command, id)
  ELSE TEST jsStringEqualsStr(op, "unsubscribe")
  THEN adUnsubscribe(command, id)
  ELSE TEST jsStringEqualsStr(op, "debugDisconnect")
  THEN
  { // Adapter-only. It acknowledges only once the old connection has been
    // retired and the reconnect has been scheduled.
    TEST convexDebugDisconnect(adClient)
    THEN adEmitAck(id)
    ELSE adEmitError(id)
  }
  ELSE TEST jsStringEqualsStr(op, "close")
  THEN adClose(id)
  ELSE adEmitProtocolError(id, "unknown adapter operation")

  bbFree(id)
  jsFree(command)
}

// Extracts one newline terminated command from the input buffer, if there is
// one. The buffer is bounded, so a peer that never sends a newline is refused
// rather than allowed to grow it without limit.
AND adTakeLine() = VALOF
{ LET newline = bbFind(adInbuf, 0, '*n')
  LET length = 0
  LET line = 0
  IF newline < 0 DO
  { IF adInbuf!Bb_len > Maxlinebytes DO
    { adEmitProtocolError(0, "the adapter command line exceeded its bound")
      adFinished := TRUE
    }
    RESULTIS 0
  }
  length := newline
  IF length > 0 DO
    IF bbGet(adInbuf, length - 1) = 13 DO length := length - 1
  line := bbSlice(adInbuf, 0, length)
  bbTrimFront(adInbuf, newline + 1)
  RESULTIS line
}

AND adReadControl() BE
{ LET got = bbReadInto(adInbuf, adControl, 8192, cxDeadline(0))
  IF got = Cx_eof DO adFinished := TRUE
  IF got = Cx_failed DO adFinished := TRUE
  IF got = Cx_badhandle DO adFinished := TRUE
}

// The whole adapter is one loop on one thread, because BCPL has one thread.
// Control commands and Live socket activity are interleaved by waiting on both
// descriptors at once and giving the Live owner a slice each time round.
AND adRun() BE
  UNTIL adFinished DO
  { LET line = 0
    LET livehandle = -1
    LET mask = 0
    adDrain()
    line := adTakeLine()
    IF line ~= 0 DO
    { adHandleCommand(line)
      bbFree(line)
      LOOP
    }
    IF adFinished DO BREAK
    IF adClient!Cl_live DO
      IF (adClient!Cl_live)!Lv_ws DO
        livehandle := wsHandle((adClient!Cl_live)!Lv_ws)
    mask := cxWait(adControl, livehandle, cxDeadline(Pollslicems))
    IF mask < 0 DO { adFinished := TRUE; BREAK }
    IF (mask & 1) ~= 0 DO adReadControl()
    convexPump(adClient, cxDeadline(Pollslicems))
  }

// ADAPTER_LISTEN is "host:port". The shared controller reaches the adapter
// over the container network, so the listener must not be restricted to
// loopback.
AND adListen(address) = VALOF
{ LET separator = -1
  LET host = 0
  LET port = 0
  LET hostname = VEC 64
  FOR index = 0 TO address!Bb_len - 1 DO
    IF bbGet(address, index) = ':' DO separator := index
  IF separator < 1 DO
  { cxDiagStr("ADAPTER_LISTEN must be host:port")
    RESULTIS FALSE
  }
  FOR index = separator + 1 TO address!Bb_len - 1 DO
  { LET digit = bbGet(address, index)
    UNLESS '0' <= digit <= '9' DO
    { cxDiagStr("ADAPTER_LISTEN must be host:port")
      RESULTIS FALSE
    }
    port := port * 10 + digit - '0'
  }
  host := bbSlice(address, 0, separator)
  UNLESS host RESULTIS FALSE
  bbToStr(host, hostname, 250)
  bbFree(host)
  adListener := cxListen(hostname, port)
  IF adListener < 0 DO
  { cxDiagStr("the adapter could not listen on the requested address")
    RESULTIS FALSE
  }
  adControl := cxAccept(adListener, cxDeadline(60000))
  IF adControl < 0 DO
  { cxDiagStr("no controller connected to the adapter")
    RESULTIS FALSE
  }
  adOut := adControl
  RESULTIS TRUE
}

LET start() = VALOF
{ LET url = 0
  LET listen = 0

  adOut := Cx_hout
  adControl := Cx_hcontrol
  adListener := -1
  adFinished := FALSE

  UNLESS convexInit() DO
  { cxDiagStr("the BCPL native transport extension is not available")
    stop(70)
  }

  url := cxGetenv("CONVEX_URL")
  IF url = 0 DO { cxDiagStr("CONVEX_URL is required"); stop(70) }
  IF url!Bb_len = 0 DO { cxDiagStr("CONVEX_URL is required"); stop(70) }

  adClient := convexNew(url)
  bbFree(url)
  IF adClient = 0 DO
  { cxDiagStr("the Convex client could not be created")
    stop(70)
  }

  adInbuf := bbNew(8192)
  IF adInbuf = 0 DO { cxDiagStr("out of memory"); stop(70) }

  listen := cxGetenv("ADAPTER_LISTEN")
  IF listen ~= 0 DO
  { IF listen!Bb_len > 0 DO
      UNLESS adListen(listen) DO { bbFree(listen); stop(70) }
    bbFree(listen)
  }

  adRun()

  // Flush anything the Live owner produced before the stream goes away, then
  // let the controller see a clean close.
  adDrain()
  cxCloseHandle(adControl)
  IF adListener >= 0 DO cxCloseHandle(adListener)
  convexClose(adClient)
  RESULTIS 0
}
