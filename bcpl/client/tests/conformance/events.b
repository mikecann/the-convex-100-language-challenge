// events.b -- the exact JSON shape of every NDJSON adapter protocol v1 event.
//
// Test infrastructure, not public client code. It exists so that the bytes the
// language-local tests assert are the bytes the conformance adapter actually
// emits: both programs include this file, so there is one definition of an
// event rather than an adapter and a test that can each agree with the shared
// schema while disagreeing with one another.
//
// Every builder returns 0 rather than a partly filled event when any allocation
// or any field insertion fails. The adapter turns that into a reported error,
// which is what stops a value the client could not render from being published
// as a successful event with the value quietly missing.

LET evPut(object, key, child) = VALOF
{ IF object = 0 DO { jsFree(child); RESULTIS FALSE }
  RESULTIS jsObjectPutStr(object, key, child)
}

AND evLogs(logs) = VALOF
{ LET array = jsArray()
  UNLESS array RESULTIS 0
  IF logs ~= 0 DO
    FOR index = 0 TO logs!Vl_len - 1 DO
    { LET line = jsStringFromBuffer(bbCopy(vlGet(logs, index)))
      UNLESS jsArrayPush(array, line) DO { jsFree(array); RESULTIS 0 }
    }
  RESULTIS array
}

AND evError(name, message, data) = VALOF
{ LET error = jsObject()
  LET ok = TRUE
  UNLESS error RESULTIS 0
  ok := evPut(error, "name",
              (name = 0 -> jsStringFromStr("Error"),
                           jsStringFromBuffer(bbCopy(name))))
  IF ok DO
    ok := evPut(error, "message",
                (message = 0 -> jsStringFromStr("the operation failed"),
                                jsStringFromBuffer(bbCopy(message))))
  // An absent data field is absent. A ConvexError payload this client could
  // not clone is a failure, not an absence, so it fails the whole event.
  IF ok DO IF data ~= 0 DO ok := evPut(error, "data", jsClone(data))
  UNLESS ok DO { jsFree(error); RESULTIS 0 }
  RESULTIS error
}

// The runtime string is built from the client's own pinned toolchain commit,
// so the version the controller records cannot describe an interpreter other
// than the one that produced it.
AND evReady(id) = VALOF
{ LET event = jsObject()
  LET runtime = convexRuntime()
  LET ok = TRUE
  IF event = 0 DO { bbFree(runtime); RESULTIS 0 }
  IF runtime = 0 DO { jsFree(event); RESULTIS 0 }
  ok := evPut(event, "protocolVersion", jsNumberFromInt(1))
  IF ok DO ok := evPut(event, "id", jsStringFromBuffer(bbCopy(id)))
  IF ok DO ok := evPut(event, "type", jsStringFromStr("ready"))
  IF ok DO ok := evPut(event, "language", jsStringFromStr("bcpl"))
  IF ok DO ok := evPut(event, "implementation",
                       jsStringFromStr(convexImplementation()))
  TEST ok
  THEN ok := evPut(event, "runtime", jsStringFromBuffer(runtime))
  ELSE bbFree(runtime)
  UNLESS ok DO { jsFree(event); RESULTIS 0 }
  RESULTIS event
}

AND evAck(id) = VALOF
{ LET event = jsObject()
  LET ok = TRUE
  UNLESS event RESULTIS 0
  ok := evPut(event, "id", jsStringFromBuffer(bbCopy(id)))
  IF ok DO ok := evPut(event, "type", jsStringFromStr("ack"))
  UNLESS ok DO { jsFree(event); RESULTIS 0 }
  RESULTIS event
}

AND evResult(id, result) = VALOF
{ LET event = jsObject()
  LET ok = TRUE
  UNLESS event RESULTIS 0
  ok := evPut(event, "id", jsStringFromBuffer(bbCopy(id)))
  IF ok DO ok := evPut(event, "type", jsStringFromStr("result"))
  IF ok DO ok := evPut(event, "value", jsClone(result!Rs_value))
  IF ok DO ok := evPut(event, "logs", evLogs(result!Rs_logs))
  UNLESS ok DO { jsFree(event); RESULTIS 0 }
  RESULTIS event
}

// A subscription event carries either a value or an error, never both.
AND evSubscription(subid, update) = VALOF
{ LET event = jsObject()
  LET ok = TRUE
  UNLESS event RESULTIS 0
  ok := evPut(event, "type", jsStringFromStr("subscription"))
  IF ok DO ok := evPut(event, "subscriptionId",
                       jsStringFromBuffer(bbCopy(subid)))
  IF ok DO
    TEST update!Up_errname ~= 0
    THEN ok := evPut(event, "error",
                     evError(update!Up_errname, update!Up_errmsg,
                             update!Up_errdata))
    ELSE
    { ok := evPut(event, "value", jsClone(update!Up_value))
      IF ok DO ok := evPut(event, "logs", evLogs(update!Up_logs))
    }
  UNLESS ok DO { jsFree(event); RESULTIS 0 }
  RESULTIS event
}

AND evClosed(id) = VALOF
{ LET event = jsObject()
  LET ok = TRUE
  UNLESS event RESULTIS 0
  ok := evPut(event, "id", jsStringFromBuffer(bbCopy(id)))
  IF ok DO ok := evPut(event, "type", jsStringFromStr("closed"))
  UNLESS ok DO { jsFree(event); RESULTIS 0 }
  RESULTIS event
}

// An error the adapter itself raised. `id` may be 0, in which case the event
// carries no id at all rather than a null one, which the controller's schema
// would reject.
AND evProtocolError(id, name, message) = VALOF
{ LET event = jsObject()
  LET ok = TRUE
  UNLESS event RESULTIS 0
  IF id ~= 0 DO ok := evPut(event, "id", jsStringFromBuffer(bbCopy(id)))
  IF ok DO ok := evPut(event, "type", jsStringFromStr("error"))
  IF ok DO
  { LET error = jsObject()
    TEST error = 0
    THEN ok := FALSE
    ELSE
    { ok := evPut(error, "name", jsStringFromStr(name))
      IF ok DO ok := evPut(error, "message", jsStringFromStr(message))
      TEST ok
      THEN ok := evPut(event, "error", error)
      ELSE jsFree(error)
    }
  }
  UNLESS ok DO { jsFree(event); RESULTIS 0 }
  RESULTIS event
}

// Whatever the client left in the structured failure globals, so a Convex
// function error keeps its name and its data and is never flattened into a
// result.
AND evFromError(id) = VALOF
{ LET event = jsObject()
  LET ok = TRUE
  UNLESS event RESULTIS 0
  IF id ~= 0 DO ok := evPut(event, "id", jsStringFromBuffer(bbCopy(id)))
  IF ok DO ok := evPut(event, "type", jsStringFromStr("error"))
  IF ok DO ok := evPut(event, "error", evError(errName, errMessage, errData))
  UNLESS ok DO { jsFree(event); RESULTIS 0 }
  RESULTIS event
}
