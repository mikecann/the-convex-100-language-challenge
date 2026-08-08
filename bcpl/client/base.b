// base.b -- the transport boundary as BCPL sees it, growable byte buffers,
// pointer lists, and the structured failure the rest of the client reports.
//
// Every byte the client sends or receives passes through the six sys(Sys_ext)
// calls below. Nothing above this file knows that a socket or TLS exists.

// ---------------------------------------------------------------------------
// Native transport boundary
// ---------------------------------------------------------------------------

LET cxInit() = sys(Sys_ext, Cx_init)

AND cxNow() = sys(Sys_ext, Cx_now)

// Deadlines are absolute values on the native monotonic clock. Passing an
// absolute deadline down through every layer is what stops a long operation
// from silently restarting its own timeout at each nested step.
AND cxDeadline(ms) = sys(Sys_ext, Cx_now) + ms

AND cxExpired(deadline) = sys(Sys_ext, Cx_now) >= deadline

AND cxConnect(host, port, tls, deadline) =
      sys(Sys_ext, Cx_connect, host, port, tls, deadline)

AND cxRead(handle, buffer, offset, maxbytes, deadline) =
      sys(Sys_ext, Cx_read, handle, buffer, offset, maxbytes, deadline)

AND cxWrite(handle, buffer, offset, bytes, deadline) =
      sys(Sys_ext, Cx_write, handle, buffer, offset, bytes, deadline)

AND cxCloseHandle(handle) = sys(Sys_ext, Cx_closefn, handle)

AND cxListen(host, port) = sys(Sys_ext, Cx_listen, host, port)

AND cxAccept(handle, deadline) = sys(Sys_ext, Cx_accept, handle, deadline)

AND cxWait(first, second, deadline) =
      sys(Sys_ext, Cx_wait, first, second, deadline)

// Sleep until an absolute deadline. Waiting on no descriptor at all is how the
// boundary spells "just wait", and it is what stops a client that is sitting
// out a reconnect backoff from spinning through its caller's poll loop at the
// speed of the interpreter.
AND cxSleepUntil(deadline) BE cxWait(-1, -1, deadline)

AND cxRandomBytes(buffer, offset, bytes) =
      sys(Sys_ext, Cx_random, buffer, offset, bytes)

// The most recent native failure, as a fresh byte buffer, or 0.
AND cxLastError() = VALOF
{ LET store = VEC 64
  LET length = sys(Sys_ext, Cx_errtext, store, 250)
  LET result = 0
  IF length <= 0 RESULTIS 0
  result := bbNew(length)
  UNLESS result RESULTIS 0
  FOR index = 1 TO length DO bbPush(result, store%index)
  RESULTIS result
}

// Named environment value as a fresh byte buffer, or 0 when unset.
AND cxGetenv(name) = VALOF
{ LET store = VEC 64
  LET length = sys(Sys_ext, Cx_getenv, name, store, 250)
  LET result = 0
  IF length < 0 RESULTIS 0
  result := bbNew(length + 1)
  UNLESS result RESULTIS 0
  FOR index = 1 TO length DO bbPush(result, store%index)
  RESULTIS result
}

AND cxWriteBuffer(handle, buffer, deadline) = VALOF
{ IF buffer!Bb_len = 0 RESULTIS 0
  RESULTIS cxWrite(handle, buffer!Bb_vec, 0, buffer!Bb_len, deadline)
}

// Protocol output. The launcher has moved the real stdout here, so this is the
// only route to the transcript the verifier compares.
AND cxOut(buffer) BE cxWriteBuffer(Cx_hout, buffer, cxDeadline(Httptimeoutms))

AND cxDiag(buffer) BE cxWriteBuffer(Cx_hdiag, buffer, cxDeadline(1000))

AND cxDiagStr(text) BE
{ LET line = bbNew(text%0 + 2)
  UNLESS line RETURN
  bbPushStr(line, text)
  bbPush(line, '*n')
  cxDiag(line)
  bbFree(line)
}

// ---------------------------------------------------------------------------
// Byte buffers
//
// A buffer is a small handle so that growing it can replace the data vector
// without every holder needing to learn the new address. Growth is capped at
// Maxbufferbytes; a refused append is reported, never silently truncated.
// ---------------------------------------------------------------------------

AND bbNew(capacity) = VALOF
{ LET handle = getvec(Bb_upb)
  LET words = 1
  UNLESS handle RESULTIS 0
  IF capacity < 4 DO capacity := 4
  IF capacity > Maxbufferbytes DO capacity := Maxbufferbytes
  words := (capacity + bytesperword - 1) / bytesperword
  handle!Bb_vec := getvec(words - 1)
  UNLESS handle!Bb_vec DO { freevec(handle); RESULTIS 0 }
  handle!Bb_cap := words * bytesperword
  handle!Bb_len := 0
  RESULTIS handle
}

AND bbFree(buffer) BE
{ UNLESS buffer RETURN
  IF buffer!Bb_vec DO freevec(buffer!Bb_vec)
  freevec(buffer)
}

AND bbClear(buffer) BE buffer!Bb_len := 0

AND bbEnsure(buffer, extra) = VALOF
{ LET needed = buffer!Bb_len + extra
  LET capacity = buffer!Bb_cap
  LET words = 0
  LET fresh = 0
  IF extra < 0 RESULTIS FALSE
  IF needed <= buffer!Bb_cap RESULTIS TRUE
  IF needed > Maxbufferbytes RESULTIS FALSE
  UNTIL capacity >= needed DO capacity := capacity * 2
  IF capacity > Maxbufferbytes DO capacity := Maxbufferbytes
  words := (capacity + bytesperword - 1) / bytesperword
  fresh := getvec(words - 1)
  UNLESS fresh RESULTIS FALSE
  FOR index = 0 TO buffer!Bb_len - 1 DO
    fresh%index := (buffer!Bb_vec)%index
  freevec(buffer!Bb_vec)
  buffer!Bb_vec := fresh
  buffer!Bb_cap := words * bytesperword
  RESULTIS TRUE
}

AND bbPush(buffer, byte) = VALOF
{ UNLESS bbEnsure(buffer, 1) RESULTIS FALSE
  (buffer!Bb_vec)%(buffer!Bb_len) := byte & 255
  buffer!Bb_len := buffer!Bb_len + 1
  RESULTIS TRUE
}

AND bbPushBytes(buffer, source, offset, count) = VALOF
{ UNLESS bbEnsure(buffer, count) RESULTIS FALSE
  FOR index = 0 TO count - 1 DO
    (buffer!Bb_vec)%(buffer!Bb_len + index) := source%(offset + index)
  buffer!Bb_len := buffer!Bb_len + count
  RESULTIS TRUE
}

AND bbPushBuffer(buffer, other) =
      bbPushBytes(buffer, other!Bb_vec, 0, other!Bb_len)

AND bbPushStr(buffer, text) = VALOF
{ UNLESS bbEnsure(buffer, text%0) RESULTIS FALSE
  FOR index = 1 TO text%0 DO bbPush(buffer, text%index)
  RESULTIS TRUE
}

// Decimal rendering. BCPL has no string formatting that produces bytes, and
// the client must never depend on the Cintcode console for protocol output.
AND bbPushNum(buffer, value) = VALOF
{ LET digits = VEC 16
  LET count = 0
  LET remaining = value
  IF value < 0 DO
  { UNLESS bbPush(buffer, '-') RESULTIS FALSE
    remaining := -value
  }
  IF remaining = 0 RESULTIS bbPush(buffer, '0')
  UNTIL remaining = 0 DO
  { digits!count := remaining REM 10
    remaining := remaining / 10
    count := count + 1
  }
  FOR index = count - 1 TO 0 BY -1 DO
    UNLESS bbPush(buffer, '0' + digits!index) RESULTIS FALSE
  RESULTIS TRUE
}

AND bbPushHexDigit(buffer, value) = VALOF
{ LET digit = value & 15
  IF digit < 10 RESULTIS bbPush(buffer, '0' + digit)
  RESULTIS bbPush(buffer, 'a' + digit - 10)
}

AND bbGet(buffer, index) = (buffer!Bb_vec)%index

AND bbEqual(left, right) = VALOF
{ IF left = 0 RESULTIS FALSE
  IF right = 0 RESULTIS FALSE
  UNLESS left!Bb_len = right!Bb_len RESULTIS FALSE
  FOR index = 0 TO left!Bb_len - 1 DO
    UNLESS (left!Bb_vec)%index = (right!Bb_vec)%index RESULTIS FALSE
  RESULTIS TRUE
}

AND bbEqualStr(buffer, text) = VALOF
{ UNLESS buffer RESULTIS FALSE
  UNLESS buffer!Bb_len = text%0 RESULTIS FALSE
  FOR index = 1 TO text%0 DO
    UNLESS (buffer!Bb_vec)%(index - 1) = text%index RESULTIS FALSE
  RESULTIS TRUE
}

AND bbCopy(buffer) = VALOF
{ LET result = 0
  UNLESS buffer RESULTIS 0
  result := bbNew(buffer!Bb_len + 1)
  UNLESS result RESULTIS 0
  UNLESS bbPushBuffer(result, buffer) DO { bbFree(result); RESULTIS 0 }
  RESULTIS result
}

AND bbSlice(buffer, offset, count) = VALOF
{ LET result = bbNew(count + 1)
  UNLESS result RESULTIS 0
  UNLESS bbPushBytes(result, buffer!Bb_vec, offset, count) DO
  { bbFree(result); RESULTIS 0 }
  RESULTIS result
}

AND bbFromStr(text) = VALOF
{ LET result = bbNew(text%0 + 1)
  UNLESS result RESULTIS 0
  UNLESS bbPushStr(result, text) DO { bbFree(result); RESULTIS 0 }
  RESULTIS result
}

// Diagnostics only: BCPL strings hold at most 255 bytes, so this truncates.
AND bbToStr(buffer, target, maxbytes) BE
{ LET count = buffer!Bb_len
  IF count > maxbytes DO count := maxbytes
  target%0 := count
  FOR index = 1 TO count DO target%index := (buffer!Bb_vec)%(index - 1)
}

AND bbFind(buffer, from, byte) = VALOF
{ FOR index = from TO buffer!Bb_len - 1 DO
    IF (buffer!Bb_vec)%index = byte RESULTIS index
  RESULTIS -1
}

AND bbMatchStrAt(buffer, offset, text) = VALOF
{ IF offset + text%0 > buffer!Bb_len RESULTIS FALSE
  FOR index = 1 TO text%0 DO
    UNLESS (buffer!Bb_vec)%(offset + index - 1) = text%index RESULTIS FALSE
  RESULTIS TRUE
}

// Discard consumed bytes from the front of a streaming buffer. Callers adjust
// their own cursor; keeping the buffer compact is what bounds a long-lived
// receive buffer without ever discarding an unparsed prefix.
AND bbTrimFront(buffer, count) BE
{ LET remaining = buffer!Bb_len - count
  IF count <= 0 RETURN
  IF remaining < 0 DO remaining := 0
  FOR index = 0 TO remaining - 1 DO
    (buffer!Bb_vec)%index := (buffer!Bb_vec)%(index + count)
  buffer!Bb_len := remaining
}

// Read straight into the tail of a buffer. Returning the native result
// unchanged keeps the distinction between "nothing yet" (Cx_timeout), "peer
// closed" (Cx_eof) and "failed" visible to callers, which is what lets the
// WebSocket reader hold its parser state across a timeout instead of
// resynchronising.
AND bbReadInto(buffer, handle, want, deadline) = VALOF
{ LET got = 0
  UNLESS bbEnsure(buffer, want) RESULTIS Cx_failed
  got := cxRead(handle, buffer!Bb_vec, buffer!Bb_len, want, deadline)
  IF got > 0 DO buffer!Bb_len := buffer!Bb_len + got
  RESULTIS got
}

// Case-insensitive comparison against a BCPL string, used for HTTP header
// names, which RFC 9110 makes case-insensitive.
AND bbEqualFoldStr(buffer, offset, count, text) = VALOF
{ UNLESS count = text%0 RESULTIS FALSE
  FOR index = 1 TO count DO
  { LET left = (buffer!Bb_vec)%(offset + index - 1)
    LET right = text%index
    IF 'A' <= left <= 'Z' DO left := left + 'a' - 'A'
    IF 'A' <= right <= 'Z' DO right := right + 'a' - 'A'
    UNLESS left = right RESULTIS FALSE
  }
  RESULTIS TRUE
}

// ---------------------------------------------------------------------------
// Pointer lists
// ---------------------------------------------------------------------------

AND vlNew(capacity) = VALOF
{ LET handle = getvec(Vl_upb)
  UNLESS handle RESULTIS 0
  IF capacity < 4 DO capacity := 4
  handle!Vl_vec := getvec(capacity - 1)
  UNLESS handle!Vl_vec DO { freevec(handle); RESULTIS 0 }
  handle!Vl_cap := capacity
  handle!Vl_len := 0
  RESULTIS handle
}

AND vlFree(list) BE
{ UNLESS list RETURN
  IF list!Vl_vec DO freevec(list!Vl_vec)
  freevec(list)
}

AND vlClear(list) BE list!Vl_len := 0

AND vlPush(list, item) = VALOF
{ LET fresh = 0
  IF list!Vl_len >= list!Vl_cap DO
  { LET capacity = list!Vl_cap * 2
    fresh := getvec(capacity - 1)
    UNLESS fresh RESULTIS FALSE
    FOR index = 0 TO list!Vl_len - 1 DO fresh!index := (list!Vl_vec)!index
    freevec(list!Vl_vec)
    list!Vl_vec := fresh
    list!Vl_cap := capacity
  }
  (list!Vl_vec)!(list!Vl_len) := item
  list!Vl_len := list!Vl_len + 1
  RESULTIS TRUE
}

AND vlGet(list, index) = (list!Vl_vec)!index

AND vlRemoveAt(list, position) BE
{ FOR index = position TO list!Vl_len - 2 DO
    (list!Vl_vec)!index := (list!Vl_vec)!(index + 1)
  list!Vl_len := list!Vl_len - 1
}

AND vlShift(list) = VALOF
{ LET first = 0
  IF list!Vl_len = 0 RESULTIS 0
  first := (list!Vl_vec)!0
  vlRemoveAt(list, 0)
  RESULTIS first
}

// ---------------------------------------------------------------------------
// Structured failure
//
// The adapter must be able to tell a Convex function error from protocol drift
// and from a transport loss, so the client keeps the kind rather than
// collapsing everything into one message.
// ---------------------------------------------------------------------------

AND errClear() BE
{ IF errName DO bbFree(errName)
  IF errMessage DO bbFree(errMessage)
  IF errData DO jsFree(errData)
  IF errLogs DO
  { FOR index = 0 TO errLogs!Vl_len - 1 DO bbFree(vlGet(errLogs, index))
    vlFree(errLogs)
  }
  errKind, errName, errMessage, errData, errLogs := Ek_none, 0, 0, 0, 0
}

// Takes ownership of message, data and logs.
AND errSet(kind, name, message, data, logs) BE
{ errClear()
  errKind := kind
  errName := bbFromStr(name)
  errMessage := message
  errData := data
  errLogs := logs
}

AND errSetStr(kind, name, message) BE
  errSet(kind, name, bbFromStr(message), 0, 0)

// Attach the native layer's own description so a TLS or DNS failure is not
// reduced to "transport error".
AND errFromNative(kind, name, context) BE
{ LET message = bbFromStr(context)
  LET detail = cxLastError()
  IF message ~= 0 DO
    IF detail ~= 0 DO
    { bbPushStr(message, ": ")
      bbPushBuffer(message, detail)
    }
  IF detail DO bbFree(detail)
  errSet(kind, name, message, 0, 0)
}
