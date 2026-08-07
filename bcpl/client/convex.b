// convex.b -- the public BCPL Convex client.
//
// This file is the whole library: it GETs each module in dependency order and
// then defines the small surface a program actually uses. A BCPL program
// includes it as its own first section, which is the ordinary way to build a
// multi-module BCPL program on this system.
//
//   HTTP query, mutation and action  -- convexCall
//   Live subscriptions               -- convexSubscribe / convexNextUpdate
//
// Everything Convex-specific happens in BCPL. The only native code beneath
// this is a byte transport: sockets, TLS, a monotonic clock and random bytes.

GET "base.b"
GET "digest.b"
GET "json.b"
GET "http.b"
GET "ws.b"
GET "live.b"

// The identity this client reports, in one place so that the Convex-Client
// header, the conformance adapter's ready event and manifest.yaml cannot drift
// apart from each other or from the toolchain the image actually contains.
//
// convexToolchainCommit is the commit of Martin Richards' Cintcode
// distribution that the image is built from. The build asserts that this
// literal equals the commit it fetched, so a reported runtime version can
// never describe an interpreter other than the one running it.
LET convexVersion() = "bcpl-0.1.0"

AND convexImplementation() = "native-bcpl-0.1.0"

AND convexToolchainCommit() = "bad6eec7682368ca7ded866005cc4a47e8a67569"

AND convexRuntime() = VALOF
{ LET text = bbNew(96)
  UNLESS text RESULTIS 0
  bbPushStr(text, "BCPL Cintcode 64-bit cintsys64 (8l/bcpl ")
  bbPushStr(text, convexToolchainCommit())
  bbPushStr(text, ")")
  RESULTIS text
}

AND convexInit() = VALOF
{ errKind, errName, errMessage, errData, errLogs := Ek_none, 0, 0, 0, 0
  jsParseError := 0
  wsStatus := Wss_message
  RESULTIS cxInit()
}

// `url` is the deployment URL, for example https://example.convex.cloud.
AND convexNew(url) = VALOF
{ LET client = getvec(Cl_upb)
  UNLESS client RESULTIS 0
  FOR field = 0 TO Cl_upb DO client!field := 0
  client!Cl_ep := epParseUrl(url)
  UNLESS client!Cl_ep DO { freevec(client); RESULTIS 0 }
  client!Cl_token := bbNew(8)
  client!Cl_version := bbFromStr(convexVersion())
  IF client!Cl_token = 0 DO { convexFree(client); RESULTIS 0 }
  IF client!Cl_version = 0 DO { convexFree(client); RESULTIS 0 }
  RESULTIS client
}

AND convexFree(client) BE
{ UNLESS client RETURN
  IF client!Cl_live DO lvFree(client!Cl_live)
  IF client!Cl_ep DO epFree(client!Cl_ep)
  bbFree(client!Cl_token)
  bbFree(client!Cl_version)
  freevec(client)
}

// An empty token clears authentication; anything else is sent as a bearer
// token on every subsequent HTTP call.
AND convexSetAuth(client, token) BE
{ bbClear(client!Cl_token)
  IF token ~= 0 DO bbPushBuffer(client!Cl_token, token)
}

AND convexResultFree(result) BE
{ UNLESS result RETURN
  IF result!Rs_value DO jsFree(result!Rs_value)
  IF result!Rs_logs DO
  { FOR index = 0 TO (result!Rs_logs)!Vl_len - 1 DO
      bbFree(vlGet(result!Rs_logs, index))
    vlFree(result!Rs_logs)
  }
  freevec(result)
}

// Collects a response's logLines, which the conformance adapter reports so a
// function's console output is visible to the caller. Returns 0 only when the
// list could not be built, never as a way of saying "there were none": an
// empty list is an empty list, and a caller must be able to tell the two apart
// rather than report a truncated transcript as a complete one.
AND convexCopyLogs(node) = VALOF
{ LET lines = jsObjectGet(node, "logLines")
  LET logs = vlNew(4)
  UNLESS logs RESULTIS 0
  IF lines ~= 0 DO
    IF lines!Js_type = Jt_array DO
      FOR index = 0 TO (lines!Js_a)!Vl_len - 1 DO
      { LET line = vlGet(lines!Js_a, index)
        IF line!Js_type = Jt_string DO
        { LET copy = bbCopy(line!Js_a)
          IF copy = 0 DO { lvFreeLogs(logs); RESULTIS 0 }
          UNLESS vlPush(logs, copy) DO
          { bbFree(copy); lvFreeLogs(logs); RESULTIS 0 }
        }
      }
  RESULTIS logs
}

// A 2xx body the client cannot understand is protocol drift; any other status
// is the deployment refusing the request, which is a transport concern.
AND convexClassify(status, message) BE
{ LET ok = FALSE
  IF status >= 200 DO IF status <= 299 DO ok := TRUE
  TEST ok
  THEN errSet(Ek_protocol, "ProtocolError", message, 0, 0)
  ELSE errSet(Ek_transport, "TransportError", message, 0, 0)
}

// One HTTP query, mutation or action. Returns a result record, or 0 with the
// structured failure left in the err globals: a Convex function that threw is
// Ek_function and keeps its error data, which is what stops a failed function
// from being reported as a successful value.
//
// `path` and `arguments` are borrowed: both are copied into the request, and
// both still belong to the caller when this returns.
AND convexCall(client, operation, path, arguments, deadline) = VALOF
{ LET request = jsObject()
  LET text = 0
  LET response = 0
  LET node = 0
  LET status = 0
  LET result = 0

  errClear()
  IF client!Cl_closed DO
  { errSetStr(Ek_closed, "ClosedError", "the Convex client is closed")
    RESULTIS 0
  }
  UNLESS request DO
  { errSetStr(Ek_internal, "InternalError",
              "the Convex request could not be built")
    RESULTIS 0
  }
  // Every field is checked. A request that reached the deployment missing its
  // path or its arguments would come back as a Convex error about the wrong
  // thing, which is a worse failure than refusing to send it.
  { LET ok = jsObjectPutStr(request, "path", jsStringFromBuffer(bbCopy(path)))
    IF ok DO
    { // Convex always expects a named argument object, even an empty one, and
      // an argument object this client could not clone is not an empty one.
      LET named = (arguments = 0 -> jsObject(), jsClone(arguments))
      TEST named = 0
      THEN ok := FALSE
      ELSE ok := jsObjectPutStr(request, "args", named)
    }
    IF ok DO ok := jsObjectPutStr(request, "format", jsStringFromStr("json"))
    UNLESS ok DO
    { errSetStr(Ek_internal, "InternalError",
                "the Convex request could not be built")
      jsFree(request)
      RESULTIS 0
    }
  }
  text := jsSerialise(request)
  jsFree(request)
  UNLESS text DO
  { errSetStr(Ek_internal, "InternalError",
              "the Convex request could not be serialised")
    RESULTIS 0
  }

  response := httpRequest(client!Cl_ep, "POST", operation, text,
                          client!Cl_token, client!Cl_version, deadline)
  bbFree(text)
  UNLESS response RESULTIS 0

  node := jsParseBuffer(response!Hr_body)
  status := response!Hr_status

  UNLESS node DO
  { LET message = bbNew(128)
    // A non-JSON body is normal for an authentication rejection, so report the
    // status rather than pretending the deployment spoke a protocol it did not.
    IF message ~= 0 DO
    { bbPushStr(message, "the Convex deployment answered with HTTP status ")
      bbPushNum(message, status)
    }
    convexClassify(status, message)
    httpFree(response)
    RESULTIS 0
  }
  httpFree(response)

  IF jsStringEqualsStr(jsObjectGet(node, "status"), "success") DO
  { LET value = jsObjectGet(node, "value")
    result := getvec(Rs_upb)
    UNLESS result DO
    { errSetStr(Ek_internal, "InternalError",
                "the Convex result could not be held")
      jsFree(node)
      RESULTIS 0
    }
    result!Rs_value := 0
    result!Rs_logs := 0
    // A function that returned nothing really did return null. A clone this
    // client could not allocate did not, and must never be reported as if it
    // had: that is the exact shape of a failure disguised as a success.
    TEST value = 0
    THEN result!Rs_value := jsNull()
    ELSE result!Rs_value := jsClone(value)
    IF result!Rs_value ~= 0 DO result!Rs_logs := convexCopyLogs(node)
    IF result!Rs_logs = 0 DO
    { errSetStr(Ek_internal, "InternalError",
                "the Convex result could not be held")
      convexResultFree(result)
      jsFree(node)
      RESULTIS 0
    }
    jsFree(node)
    RESULTIS result
  }

  IF jsStringEqualsStr(jsObjectGet(node, "status"), "error") DO
  { LET message = jsObjectGet(node, "errorMessage")
    LET data = jsObjectGet(node, "errorData")
    LET text2 = 0
    LET clone = 0
    LET logs = 0
    TEST message = 0
    THEN text2 := bbFromStr("the Convex function failed")
    ELSE TEST message!Js_type = Jt_string
    THEN text2 := bbCopy(message!Js_a)
    ELSE text2 := bbFromStr("the Convex function failed")
    // ConvexError data that could not be cloned must not silently vanish from
    // the reported error: an absent data field and a lost one look identical
    // to the caller, and only one of them is true.
    IF data ~= 0 DO clone := jsClone(data)
    logs := convexCopyLogs(node)
    jsFree(node)
    IF text2 = 0 DO
    { jsFree(clone); lvFreeLogs(logs)
      errSetStr(Ek_internal, "InternalError",
                "the Convex function error could not be held")
      RESULTIS 0
    }
    IF logs = 0 DO
    { bbFree(text2); jsFree(clone)
      errSetStr(Ek_internal, "InternalError",
                "the Convex function error could not be held")
      RESULTIS 0
    }
    IF data ~= 0 DO
      IF clone = 0 DO
      { bbFree(text2); lvFreeLogs(logs)
        errSetStr(Ek_internal, "InternalError",
                  "the Convex function error could not be held")
        RESULTIS 0
      }
    errSet(Ek_function, "FunctionError", text2, clone, logs)
    RESULTIS 0
  }

  jsFree(node)
  { LET message = bbNew(128)
    IF message ~= 0 DO
    { bbPushStr(message, "the Convex response had no usable status, HTTP ")
      bbPushNum(message, status)
    }
    convexClassify(status, message)
  }
  RESULTIS 0
}

// Live is created lazily so an HTTP-only program never opens a WebSocket.
//
// Takes ownership of `subid`, `path` and `arguments` however it returns, so a
// caller never has to know which failure freed what.
AND convexSubscribe(client, subid, path, arguments) = VALOF
{ errClear()
  IF client!Cl_closed DO
  { errSetStr(Ek_closed, "ClosedError", "the Convex client is closed")
    bbFree(subid)
    bbFree(path)
    jsFree(arguments)
    RESULTIS 0
  }
  UNLESS client!Cl_live DO
  { client!Cl_live := lvNew(client!Cl_ep, client!Cl_version)
    UNLESS client!Cl_live DO
    { errSetStr(Ek_transport, "TransportError",
                "the Convex Live manager could not be created")
      bbFree(subid)
      bbFree(path)
      jsFree(arguments)
      RESULTIS 0
    }
  }
  // Convex always expects a named argument object on the query set, even an
  // empty one, so a missing args field becomes {} rather than nothing. An
  // object this client could not allocate is not an empty one, and a
  // subscription whose Add would go out without its arguments is refused here
  // rather than sent to watch the wrong query.
  IF arguments = 0 DO
  { arguments := jsObject()
    IF arguments = 0 DO
    { errSetStr(Ek_internal, "InternalError",
                "the Convex subscription arguments could not be built")
      bbFree(subid)
      bbFree(path)
      RESULTIS 0
    }
  }
  RESULTIS lvSubscribe(client!Cl_live, subid, path, arguments)
}

AND convexUnsubscribe(client, subscription) BE
  IF client!Cl_live DO lvUnsubscribe(client!Cl_live, subscription)

// One slice of Live work. A program that is doing something else must call
// this to let the owner make progress, because BCPL has no background thread
// to do it unasked.
AND convexPump(client, deadline) BE
  IF client!Cl_live DO lvStep(client!Cl_live, deadline)

// Waits for the next update on a subscription, pumping the owner while it
// waits. Returns 0 when the deadline passes with nothing to report.
AND convexNextUpdate(client, subscription, deadline) = VALOF
{ LET update = sbTake(client!Cl_live, subscription)
  UNTIL update ~= 0 DO
  { LET slice = cxDeadline(Pollslicems)
    IF cxExpired(deadline) RESULTIS 0
    IF slice > deadline DO slice := deadline
    // convexPump either does work or sleeps out the slice, so this loop waits
    // rather than spinning even while the owner is sitting out a backoff.
    convexPump(client, slice)
    update := sbTake(client!Cl_live, subscription)
  }
  RESULTIS update
}

// The adapter-only reconnect hook. It is not part of the educational API and
// is never called by the canonical example.
AND convexDebugDisconnect(client) = VALOF
{ errClear()
  UNLESS client!Cl_live DO
  { errSetStr(Ek_transport, "TransportError",
              "there is no Convex sync connection to disconnect")
    RESULTIS FALSE
  }
  UNLESS lvDisconnectForAdapter(client!Cl_live) DO
  { errSetStr(Ek_transport, "TransportError",
              "there is no Convex sync connection to disconnect")
    RESULTIS FALSE
  }
  RESULTIS TRUE
}

AND convexClose(client) BE
{ UNLESS client RETURN
  IF client!Cl_closed RETURN
  client!Cl_closed := TRUE
  IF client!Cl_live DO
  { lvClose(client!Cl_live)
    client!Cl_live := 0
  }
}
