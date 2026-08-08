// The canonical BCPL Convex example: watch a shared counter go from 0 to 1.
//
// The first section of this file is the client library itself. BCPL builds a
// multi-module program by textual inclusion, so GET "convex.b" pulls in the
// HTTP, WebSocket, JSON and sync-protocol code, and the second section below
// is the program that uses it.

SECTION "convexclient"

GET "libhdr"
GET "convexhdr"
GET "convex.b"

.

SECTION "convexbasics"

GET "libhdr"
GET "convexhdr"

// Every line of the transcript goes to the process's real stdout through the
// transport boundary. BCPL's own writef would go to the Cintcode console,
// which the launcher has pointed at stderr precisely so that runtime chatter
// can never appear in a verified transcript.
LET emit(text) BE
{ LET line = bbNew(64)
  UNLESS line RETURN
  bbPushStr(line, text)
  bbPush(line, '*n')
  cxOut(line)
  bbFree(line)
}

// Prints a label and a number that came out of Convex. Rendering the decoded
// value, rather than the constant the run is hoping for, is what makes the
// transcript evidence instead of a script.
AND emitCount(label, count) BE
{ LET line = bbNew(64)
  UNLESS line RETURN
  bbPushStr(line, label)
  bbPushNum(line, count)
  bbPush(line, '*n')
  cxOut(line)
  bbFree(line)
}

// Diagnostics belong on stderr, and a disagreement anywhere in the journey has
// to end the run: the example is only evidence if it fails on a wrong value.
AND fail(reason) BE
{ cxDiagStr(reason)
  IF errMessage DO
  { LET detail = bbNew(280)
    IF detail ~= 0 DO
    { bbPushStr(detail, "  ")
      bbPushBuffer(detail, errMessage)
      bbPush(detail, '*n')
      cxDiag(detail)
      bbFree(detail)
    }
  }
  stop(1)
}

// Convex may encode a whole count as 0 or as 0.0 depending on the path the
// value took, so both have to decode to the same integer. jsWholeNumber
// accepts either and refuses a fractional, quoted or out-of-range value rather
// than truncating it, which is what makes -1 here a genuine mismatch.
AND countOf(state) = VALOF
{ LET count = 0
  UNLESS jsWholeNumber(jsObjectGet(state, "count"), @count) RESULTIS -1
  RESULTIS count
}

// The room to use. The verifier passes a unique one as the first argument;
// running the image by hand without arguments gets a friendly default.
AND exampleRoom() = VALOF
{ LET room = cxGetenv("CONVEX_ROOM_ARG")
  IF room ~= 0 DO IF room!Bb_len > 0 RESULTIS room
  IF room ~= 0 DO bbFree(room)
  room := cxGetenv("EXAMPLE_ROOM")
  IF room ~= 0 DO IF room!Bb_len > 0 RESULTIS room
  IF room ~= 0 DO bbFree(room)
  RESULTIS bbFromStr("bcpl-basic-example")
}

LET start() = VALOF
{ LET url = 0
  LET room = 0
  LET client = 0
  LET queryargs = 0
  LET mutationargs = 0
  LET runid = 0
  LET path = 0
  LET result = 0
  LET subscription = 0
  LET update = 0
  LET applied = 0
  LET started = 0
  LET finished = 0

  // Bring up the transport boundary: the monotonic clock, the random source
  // and the process descriptors all come from it.
  UNLESS convexInit() DO
  { cxDiagStr("the BCPL native transport extension is not available")
    stop(1)
  }

  // Configure the deployment from the environment, exactly as every other
  // client in this repository does.
  url := cxGetenv("CONVEX_URL")
  IF url = 0 DO fail("CONVEX_URL is required")
  IF url!Bb_len = 0 DO fail("CONVEX_URL is required")
  room := exampleRoom()

  // Creating the client parses the deployment URL and decides whether the
  // connection will be TLS. Nothing is opened yet.
  client := convexNew(url)
  IF client = 0 DO fail("the Convex client could not be created")

  // Both the query and the subscription watch the same room.
  queryargs := jsObject()
  jsObjectPutStr(queryargs, "room", jsStringFromBuffer(bbCopy(room)))

  // Read the counter over HTTP first, so the starting point is established
  // before anything reactive is involved. The function path is a byte buffer
  // the client copies into the request; it stays this program's to free.
  path := bbFromStr("demo:state")
  result := convexCall(client, "/api/query", path, queryargs,
                       cxDeadline(Httptimeoutms))
  IF result = 0 DO fail("the initial Convex query failed")
  started := countOf(result!Rs_value)
  UNLESS started = 0 DO fail("the room did not start at zero")
  convexResultFree(result)
  emitCount("current count: ", started)

  // Subscribe before the mutation. Starting Live first is what guarantees the
  // update caused by the mutation cannot be missed between the two calls.
  // The identifier, path and arguments belong to the client from here.
  subscription := convexSubscribe(client, bbFromStr("example"),
                                  bbCopy(path),
                                  jsClone(queryargs))
  IF subscription = 0 DO fail("the Convex subscription could not be created")

  // The first Live value is the current state, delivered as soon as the
  // WebSocket handshake and the query set have been established.
  update := convexNextUpdate(client, subscription, cxDeadline(15000))
  IF update = 0 DO fail("no initial Live value arrived")
  IF update!Up_errname DO fail("the initial Live value was an error")
  UNLESS countOf(update!Up_value) = started DO
    fail("the initial Live value disagreed with the HTTP query")
  emitCount("live initial count: ", countOf(update!Up_value))
  upFree(update)

  // The run identifier makes the mutation idempotent: replaying it with the
  // same identifier reports applied=false and leaves the count alone, so a
  // retry after a network failure cannot double-count.
  runid := bbCopy(room)
  bbPushStr(runid, "-once")
  mutationargs := jsObject()
  jsObjectPutStr(mutationargs, "room", jsStringFromBuffer(bbCopy(room)))
  jsObjectPutStr(mutationargs, "language", jsStringFromStr("BCPL"))
  jsObjectPutStr(mutationargs, "runId", jsStringFromBuffer(bbCopy(runid)))

  bbFree(path)
  path := bbFromStr("demo:increment")
  result := convexCall(client, "/api/mutation", path, mutationargs,
                       cxDeadline(Httptimeoutms))
  IF result = 0 DO fail("the Convex mutation failed")
  applied := jsObjectGet(result!Rs_value, "applied")
  UNLESS jsType(applied) = Jt_true DO fail("the mutation was not applied")
  finished := countOf(jsObjectGet(result!Rs_value, "state"))
  UNLESS finished = started + 1 DO
    fail("the mutation did not advance the count by one")
  convexResultFree(result)
  emit("mutation applied: true")
  emitCount("mutation count: ", finished)

  // The same write now arrives reactively, over the connection opened earlier.
  update := convexNextUpdate(client, subscription, cxDeadline(15000))
  IF update = 0 DO fail("no updated Live value arrived")
  IF update!Up_errname DO fail("the updated Live value was an error")
  UNLESS countOf(update!Up_value) = finished DO
    fail("the updated Live value disagreed with the mutation")
  emitCount("live updated count: ", countOf(update!Up_value))
  upFree(update)

  // Removing the subscription tells the deployment to stop tracking the query
  // and closes the WebSocket with a proper closing handshake.
  convexUnsubscribe(client, subscription)

  // Only now, with the HTTP read, the mutation and both Live values agreeing,
  // is the journey verified.
  { LET line = bbNew(64)
    IF line = 0 DO fail("out of memory")
    bbPushStr(line, "verified count: ")
    bbPushNum(line, started)
    bbPushStr(line, " -> ")
    bbPushNum(line, finished)
    bbPush(line, '*n')
    cxOut(line)
    bbFree(line)
  }

  convexClose(client)
  convexFree(client)
  jsFree(queryargs)
  jsFree(mutationargs)
  bbFree(path)
  bbFree(runid)
  bbFree(room)
  bbFree(url)
  RESULTIS 0
}
