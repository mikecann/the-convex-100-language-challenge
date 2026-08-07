' NDJSON adapter protocol v1 implementation.

#include once "adapter_core.bi"

dim shared as OutputGate Gate
dim shared as AdapterRelay Relays(0 to ADAPTER_MAX_SUBSCRIPTIONS - 1)
dim shared as ConvexClient Client
dim shared as boolean ClientReady
dim shared as boolean CloseRequested

declare sub RelayThread(byval userdata as any ptr)

function AdapterRuntimeName() as string
  ' The compiler that produced this binary is the runtime the controller
  ' records, so it is taken from the build rather than guessed at run time.
  return "FreeBASIC " & __FB_VERSION__
end function

function ValidCommandId(byref id as string) as boolean
  if len(id) < 1 orelse not IsValidUtf8(id) then
    return false
  end if
  dim as long codepoints = 0
  dim as boolean nonblank = false
  for index as integer = 0 to len(id) - 1
    ' UTF-8 continuation bytes begin 10xxxxxx. Every other byte begins exactly
    ' one code point because the JSON parser already proved the encoding valid.
    if (id[index] and &hc0) <> &h80 then
      codepoints += 1
    end if
    if id[index] > 32 then
      nonblank = true
    end if
  next
  return nonblank andalso codepoints <= ADAPTER_MAX_ID_CODEPOINTS
end function

' COMMAND is a FreeBASIC built-in (command-line argument access), so the
' parsed value is named commandValue throughout this file rather than
' command.
function CommandShapeValid( _
    byval commandValue as JsonValue ptr, _
    byref operation as string, _
    byref reason as string) as boolean
  if commandValue = 0 orelse commandValue->kind <> JSON_OBJECT then
    reason = "adapter command must be a JSON object"
    return false
  end if
  for index as integer = 0 to cast(integer, commandValue->count) - 1
    dim as string fieldName = commandValue->children[index]->memberKey
    dim as boolean allowed = (fieldName = "id" orelse fieldName = "op")
    select case operation
      case "hello"
        allowed or= (fieldName = "protocolVersion")
      case "query", "mutation", "action"
        allowed or= (fieldName = "path" orelse fieldName = "args")
      case "setAuth"
        allowed or= (fieldName = "token")
      case "subscribe"
        allowed or= (fieldName = "subscriptionId" orelse _
                     fieldName = "path" orelse fieldName = "args")
      case "unsubscribe"
        allowed or= (fieldName = "subscriptionId")
      case "debugDisconnect", "close"
        ' id and op are the complete schema for control commands.
      case else
        reason = "unknown adapter operation " & operation
        return false
    end select
    if not allowed then
      reason = "adapter " & operation & " command has unexpected field " & fieldName
      return false
    end if
  next
  return true
end function

private sub Diagnostic(byref text as string)
  ' stdout is reserved for protocol events, so diagnostics go to stderr.
  dim as string textLine = text & chr(10)
  dim as string reason
  WriteAllFd(2, textLine, MonotonicMs() + 200, reason)
end sub

' --- serialization -------------------------------------------------------

private sub PutString(byref sink as StrBuf, byref text as string)
  dim as JsonValue ptr node = JsonNewString(text)
  JsonRenderInto(node, sink)
  JsonFree(node)
end sub

function RenderReady(byref id as string, byref runtime as string) as string
  dim as StrBuf sink
  sink.Append("{""protocolVersion"":1,""id"":")
  PutString(sink, id)
  sink.Append(",""type"":""ready"",""language"":")
  PutString(sink, ADAPTER_LANGUAGE)
  sink.Append(",""implementation"":")
  PutString(sink, ADAPTER_IMPLEMENTATION)
  sink.Append(",""runtime"":")
  PutString(sink, runtime)
  sink.Append("}")
  return sink.Take()
end function

function RenderResult( _
    byref id as string, _
    byval value as JsonValue ptr, _
    byval logs as JsonValue ptr) as string
  dim as StrBuf sink
  sink.Append("{""id"":")
  PutString(sink, id)
  sink.Append(",""type"":""result"",""value"":")
  JsonRenderInto(value, sink)
  sink.Append(",""logs"":")
  if logs = 0 then
    sink.Append("[]")
  else
    JsonRenderInto(logs, sink)
  end if
  sink.Append("}")
  return sink.Take()
end function

private sub RenderFaultInto(byref sink as StrBuf, byref fault as ConvexFault)
  sink.Append("{""name"":")
  if len(fault.kind) = 0 then
    PutString(sink, FAULT_CLIENT)
  else
    PutString(sink, fault.kind)
  end if
  sink.Append(",""message"":")
  PutString(sink, fault.message)
  ' errorData is optional in the Convex envelope. Omitting it, rather than
  ' sending null, is what the shared schema and the pilot's data check expect.
  if fault.hasData then
    sink.Append(",""data"":")
    sink.Append(fault.dataJson)
  end if
  sink.Append("}")
end sub

function RenderError(byref id as string, byref fault as ConvexFault) as string
  dim as StrBuf sink
  sink.Append("{")
  ' An absent id must not be serialized at all; the schema forbids an empty
  ' string and the controller would never match a null.
  if len(id) > 0 then
    sink.Append("""id"":")
    PutString(sink, id)
    sink.Append(",")
  end if
  sink.Append("""type"":""error"",""error"":")
  RenderFaultInto(sink, fault)
  sink.Append("}")
  return sink.Take()
end function

function RenderAck(byref id as string) as string
  dim as StrBuf sink
  sink.Append("{""id"":")
  PutString(sink, id)
  sink.Append(",""type"":""ack""}")
  return sink.Take()
end function

function RenderClosed(byref id as string) as string
  dim as StrBuf sink
  sink.Append("{""id"":")
  PutString(sink, id)
  sink.Append(",""type"":""closed""}")
  return sink.Take()
end function

function RenderSubscriptionValue( _
    byref subscriptionId as string, _
    byval value as JsonValue ptr, _
    byval logs as JsonValue ptr) as string
  dim as StrBuf sink
  sink.Append("{""type"":""subscription"",""subscriptionId"":")
  PutString(sink, subscriptionId)
  sink.Append(",""value"":")
  JsonRenderInto(value, sink)
  sink.Append(",""logs"":")
  if logs = 0 then
    sink.Append("[]")
  else
    JsonRenderInto(logs, sink)
  end if
  sink.Append("}")
  return sink.Take()
end function

function RenderSubscriptionError( _
    byref subscriptionId as string, _
    byref fault as ConvexFault) as string
  dim as StrBuf sink
  sink.Append("{""type"":""subscription"",""subscriptionId"":")
  PutString(sink, subscriptionId)
  sink.Append(",""error"":")
  RenderFaultInto(sink, fault)
  sink.Append("}")
  return sink.Take()
end function

' --- output gate ---------------------------------------------------------

private sub GateInit(byval fd as long)
  Gate.mutex = mutexcreate()
  Gate.fd = fd
  Gate.closed = false
  Gate.failed = false
end sub

private function GateWriteLocked(byref payload as string) as boolean
  if Gate.closed orelse Gate.failed then
    return false
  end if
  if len(payload) > ADAPTER_MAX_OUTPUT_LINE then
    dim as ConvexFault fault
    FaultSet(fault, FAULT_PROTOCOL, "adapter event exceeded the output bound")
    dim as string replacement = RenderError("", fault) & chr(10)
    dim as string reason
    WriteAllFd(Gate.fd, replacement, MonotonicMs() + ADAPTER_OUTPUT_DEADLINE_MS, reason)
    Gate.failed = true
    return false
  end if
  dim as string textLine = payload & chr(10)
  dim as string reason
  ' A stalled controller must not turn into unbounded buffering, so the write
  ' has a deadline and a failure retires the gate.
  if not WriteAllFd(Gate.fd, textLine, MonotonicMs() + ADAPTER_OUTPUT_DEADLINE_MS, reason) then
    Gate.failed = true
    return false
  end if
  return true
end function

private function GateEmit(byref payload as string) as boolean
  mutexlock(Gate.mutex)
  dim as boolean ok = GateWriteLocked(payload)
  mutexunlock(Gate.mutex)
  return ok
end function

private function RelayGenerationCurrentLocked( _
    byval slot as long, _
    byval generation as ulongint) as boolean
  return Relays(slot).used andalso Relays(slot).generation = generation
end function

' Publish only if the relay's generation is still current. The generation is
' bumped under this same mutex, so a stale event can never cross a
' replacement, unsubscribe, or close acknowledgement.
private function GateEmitForRelay( _
    byval slot as long, _
    byval generation as ulongint, _
    byref payload as string) as boolean
  mutexlock(Gate.mutex)
  dim as boolean ok = false
  if RelayGenerationCurrentLocked(slot, generation) then
    ok = GateWriteLocked(payload)
  end if
  mutexunlock(Gate.mutex)
  return ok
end function

private function GateInvalidate(byval slot as long) as ulongint
  mutexlock(Gate.mutex)
  Relays(slot).generation += 1
  dim as ulongint generation = Relays(slot).generation
  mutexunlock(Gate.mutex)
  return generation
end function

' The adapter unit test uses the exact predicate from GateEmitForRelay. Its
' captured generation represents a relay paused immediately after dequeue.
function AdapterBeginGenerationFixture() as ulongint
  if Gate.mutex = 0 then
    Gate.mutex = mutexcreate()
  end if
  mutexlock(Gate.mutex)
  Relays(0).used = true
  Relays(0).generation = 41
  dim as ulongint generation = Relays(0).generation
  mutexunlock(Gate.mutex)
  return generation
end function

sub AdapterInvalidateGenerationFixture()
  GateInvalidate(0)
end sub

function AdapterGenerationCurrentForTest(byval generation as ulongint) as boolean
  mutexlock(Gate.mutex)
  dim as boolean current = RelayGenerationCurrentLocked(0, generation)
  mutexunlock(Gate.mutex)
  return current
end function

' --- relays --------------------------------------------------------------

private function FindRelay(byref subscriptionId as string) as long
  for slot as long = 0 to ADAPTER_MAX_SUBSCRIPTIONS - 1
    if Relays(slot).used andalso Relays(slot).subscriptionId = subscriptionId then
      return slot
    end if
  next
  return -1
end function

private function FreeRelaySlot() as long
  for slot as long = 0 to ADAPTER_MAX_SUBSCRIPTIONS - 1
    if not Relays(slot).used then
      return slot
    end if
  next
  return -1
end function

' Retire a relay completely: invalidate first so nothing further can publish,
' then stop the worker and remove the Convex subscription.
private sub RetireRelay(byval slot as long, byval timeoutMs as long)
  if slot < 0 orelse not Relays(slot).used then
    exit sub
  end if
  GateInvalidate(slot)
  Relays(slot).stopping = true
  dim as any ptr worker = Relays(slot).worker
  Relays(slot).worker = 0
  if worker <> 0 then
    threadwait(worker)
  end if
  ConvexUnsubscribe(Client, Relays(slot).handle, timeoutMs)
  mutexlock(Gate.mutex)
  Relays(slot).used = false
  Relays(slot).subscriptionId = ""
  Relays(slot).handle = 0
  Relays(slot).stopping = false
  mutexunlock(Gate.mutex)
end sub

sub RelayThread(byval userdata as any ptr)
  dim as long slot = cast(long, cast(integer, userdata))
  dim as string subscriptionId = Relays(slot).subscriptionId
  dim as ulongint generation = Relays(slot).generation
  dim as LiveSubscription ptr handle = Relays(slot).handle
  do
    if Relays(slot).stopping then
      exit do
    end if
    dim as LiveUpdate ptr update = ConvexNext(Client, handle, 100)
    if update = 0 then
      continue do
    end if
    dim as string payload
    if update->hasValue then
      payload = RenderSubscriptionValue(subscriptionId, update->value, update->logs)
    else
      payload = RenderSubscriptionError(subscriptionId, update->fault)
    end if
    LiveUpdateFree(update)
    GateEmitForRelay(slot, generation, payload)
  loop
end sub

' --- command handling ----------------------------------------------------

private function EnsureClient(byref fault as ConvexFault) as boolean
  if ClientReady then
    return true
  end if
  dim as string url = environ("CONVEX_URL")
  if len(url) = 0 then
    FaultSet(fault, FAULT_PROTOCOL, "CONVEX_URL is required")
    return false
  end if
  if not ConvexOpen(Client, url, fault) then
    return false
  end if
  ClientReady = true
  return true
end function

private sub HandleCall( _
    byref id as string, _
    byref operation as string, _
    byval commandValue as JsonValue ptr)
  dim as ConvexFault fault
  FaultClear(fault)
  dim as string path
  if not JsonStringField(commandValue, "path", path) then
    FaultSet(fault, FAULT_PROTOCOL, "adapter command is missing path")
    GateEmit(RenderError(id, fault))
    exit sub
  end if
  dim as JsonValue ptr args = JsonMember(commandValue, "args")
  if args = 0 orelse args->kind <> JSON_OBJECT then
    FaultSet(fault, FAULT_PROTOCOL, "adapter command args must be a JSON object")
    GateEmit(RenderError(id, fault))
    exit sub
  end if
  if not EnsureClient(fault) then
    GateEmit(RenderError(id, fault))
    exit sub
  end if

  dim as ConvexResult result
  ConvexResultInit(result)
  dim as boolean ok
  select case operation
    case "query"
      ok = ConvexQuery(Client, path, args, result, fault)
    case "mutation"
      ok = ConvexMutation(Client, path, args, result, fault)
    case else
      ok = ConvexAction(Client, path, args, result, fault)
  end select
  if ok then
    GateEmit(RenderResult(id, result.value, result.logs))
  else
    ' A structured function failure stays a failure; it is never flattened
    ' into a successful value.
    GateEmit(RenderError(id, fault))
  end if
  ConvexResultFree(result)
end sub

private sub HandleSubscribe(byref id as string, byval commandValue as JsonValue ptr)
  dim as ConvexFault fault
  FaultClear(fault)
  dim as string subscriptionId
  if not JsonStringField(commandValue, "subscriptionId", subscriptionId) orelse _
     not ValidCommandId(subscriptionId) then
    FaultSet(fault, FAULT_PROTOCOL, _
      "adapter subscriptionId must be 1 to 128 Unicode code points")
    GateEmit(RenderError(id, fault))
    exit sub
  end if
  dim as string path
  if not JsonStringField(commandValue, "path", path) then
    FaultSet(fault, FAULT_PROTOCOL, "adapter subscribe is missing path")
    GateEmit(RenderError(id, fault))
    exit sub
  end if
  dim as JsonValue ptr args = JsonMember(commandValue, "args")
  if args = 0 orelse args->kind <> JSON_OBJECT then
    FaultSet(fault, FAULT_PROTOCOL, "adapter subscribe args must be a JSON object")
    GateEmit(RenderError(id, fault))
    exit sub
  end if
  if not EnsureClient(fault) then
    GateEmit(RenderError(id, fault))
    exit sub
  end if

  ' Replacing the same subscriptionId must invalidate the old relay before the
  ' new acknowledgement, so the controller never sees the old query's value
  ' attributed to the new one.
  dim as long existing = FindRelay(subscriptionId)
  if existing >= 0 then
    RetireRelay(existing, 2000)
  end if
  dim as long slot = FreeRelaySlot()
  if slot < 0 then
    FaultSet(fault, FAULT_PROTOCOL, "adapter subscription limit reached")
    GateEmit(RenderError(id, fault))
    exit sub
  end if

  dim as LiveSubscription ptr handle = ConvexSubscribe(Client, path, args, fault)
  if handle = 0 then
    GateEmit(RenderError(id, fault))
    exit sub
  end if
  mutexlock(Gate.mutex)
  Relays(slot).used = true
  Relays(slot).subscriptionId = subscriptionId
  Relays(slot).generation += 1
  Relays(slot).handle = handle
  Relays(slot).stopping = false
  Relays(slot).slot = slot
  mutexunlock(Gate.mutex)
  Relays(slot).worker = threadcreate(@RelayThread, cast(any ptr, cast(integer, slot)))
  if Relays(slot).worker = 0 then
    FaultSet(fault, FAULT_CLIENT, "could not start the subscription relay")
    RetireRelay(slot, 2000)
    GateEmit(RenderError(id, fault))
    exit sub
  end if
  GateEmit(RenderAck(id))
end sub

private sub HandleUnsubscribe(byref id as string, byval commandValue as JsonValue ptr)
  dim as ConvexFault fault
  FaultClear(fault)
  dim as string subscriptionId
  if not JsonStringField(commandValue, "subscriptionId", subscriptionId) orelse _
     not ValidCommandId(subscriptionId) then
    FaultSet(fault, FAULT_PROTOCOL, _
      "adapter subscriptionId must be 1 to 128 Unicode code points")
    GateEmit(RenderError(id, fault))
    exit sub
  end if
  dim as long slot = FindRelay(subscriptionId)
  if slot >= 0 then
    RetireRelay(slot, 2000)
  end if
  GateEmit(RenderAck(id))
end sub

private sub RetireAllRelays()
  for slot as long = 0 to ADAPTER_MAX_SUBSCRIPTIONS - 1
    if Relays(slot).used then
      RetireRelay(slot, 2000)
    end if
  next
end sub

private sub HandleCommand(byref textLine as string)
  dim as ConvexFault fault
  FaultClear(fault)
  dim as string reason
  dim as JsonValue ptr commandValue = JsonParse(textLine, reason)
  if commandValue = 0 orelse commandValue->kind <> JSON_OBJECT then
    JsonFree(commandValue)
    FaultSet(fault, FAULT_PROTOCOL, "adapter command was not a JSON object: " & reason)
    GateEmit(RenderError("", fault))
    exit sub
  end if

  dim as string id
  if not JsonStringField(commandValue, "id", id) orelse not ValidCommandId(id) then
    JsonFree(commandValue)
    FaultSet(fault, FAULT_PROTOCOL, "adapter command id must be 1 to 128 Unicode code points")
    GateEmit(RenderError("", fault))
    exit sub
  end if
  dim as string op
  if not JsonStringField(commandValue, "op", op) then
    JsonFree(commandValue)
    FaultSet(fault, FAULT_PROTOCOL, "adapter command is missing op")
    GateEmit(RenderError(id, fault))
    exit sub
  end if
  if not CommandShapeValid(commandValue, op, reason) then
    JsonFree(commandValue)
    FaultSet(fault, FAULT_PROTOCOL, reason)
    GateEmit(RenderError(id, fault))
    exit sub
  end if

  select case op
    case "hello"
      dim as ulongint version
      if not JsonUnsignedField(commandValue, "protocolVersion", version) orelse version <> 1 then
        FaultSet(fault, FAULT_PROTOCOL, "unsupported adapter protocol version")
        GateEmit(RenderError(id, fault))
      else
        GateEmit(RenderReady(id, AdapterRuntimeName()))
      end if

    case "query", "mutation", "action"
      HandleCall(id, op, commandValue)

    case "setAuth"
      dim as string token
      if not JsonStringField(commandValue, "token", token) then
        FaultSet(fault, FAULT_PROTOCOL, "adapter setAuth is missing token")
        GateEmit(RenderError(id, fault))
      elseif not EnsureClient(fault) then
        GateEmit(RenderError(id, fault))
      else
        ConvexSetAuth(Client, token)
        GateEmit(RenderAck(id))
      end if

    case "subscribe"
      HandleSubscribe(id, commandValue)

    case "unsubscribe"
      HandleUnsubscribe(id, commandValue)

    case "debugDisconnect"
      if not ClientReady then
        FaultSet(fault, FAULT_TRANSPORT, "the Live WebSocket is not connected")
        GateEmit(RenderError(id, fault))
      elseif ConvexDebugDisconnect(Client, 5000, fault) then
        GateEmit(RenderAck(id))
      else
        GateEmit(RenderError(id, fault))
      end if

    case "close"
      RetireAllRelays()
      if ClientReady then
        ConvexClose(Client, 3000)
        ClientReady = false
      end if
      GateEmit(RenderClosed(id))
      CloseRequested = true

    case else
      FaultSet(fault, FAULT_PROTOCOL, "unknown adapter operation " & op)
      GateEmit(RenderError(id, fault))
  end select
  JsonFree(commandValue)
end sub

' --- transport -----------------------------------------------------------

function AdapterRun(byval inputFd as long, byval outputFd as long) as long
  GateInit(outputFd)
  MakeNonBlocking(inputFd)
  CloseRequested = false
  ClientReady = false

  dim as StrBuf pending
  dim as string scratch = space(16384)
  dim as string textLine
  dim as integer newline
  dim as integer scanned = 0
  dim as long received
  do
    if Gate.failed then
      exit do
    end if
    ' Frame one NDJSON command at a time. The scan resumes where it stopped so
    ' a long line is not re-examined on every read.
    newline = -1
    for index as integer = scanned to cast(integer, pending.count) - 1
      if pending.store[index] = 10 then
        newline = index
        exit for
      end if
    next
    if newline >= 0 then
      textLine = pending.Slice(0, newline)
      pending.DropFront(newline + 1)
      scanned = 0
      if len(textLine) > 0 andalso textLine[len(textLine) - 1] = 13 then
        textLine = left(textLine, len(textLine) - 1)
      end if
      if len(textLine) > 0 then
        HandleCommand(textLine)
        if CloseRequested orelse Gate.failed then
          exit do
        end if
      end if
      continue do
    end if
    scanned = cast(integer, pending.count)
    ' A line beyond the bound is fatal rather than silently truncated, so a
    ' hostile stream cannot grow the input buffer without limit.
    if pending.count > ADAPTER_MAX_INPUT_LINE then
      Diagnostic("adapter input line exceeded the bound")
      return 1
    end if

    if PollDescriptor(inputFd, POLLIN, 100) <= 0 then
      continue do
    end if
    received = ReadFd(inputFd, strptr(scratch), 16384)
    if received = 0 orelse received = -2 then
      ' The controller closed or broke the stream without a close command.
      exit do
    end if
    if received < 0 then
      continue do
    end if
    pending.Append(left(scratch, received))
  loop

  if not CloseRequested then
    RetireAllRelays()
    if ClientReady then
      ConvexClose(Client, 3000)
      ClientReady = false
    end if
  end if
  if Gate.failed then
    Diagnostic("adapter output stalled and the gate was retired")
    return 1
  end if
  return 0
end function

function AdapterMain() as long
  dim as string listenAddress = environ("ADAPTER_LISTEN")
  if len(listenAddress) = 0 then
    return AdapterRun(0, 1)
  end if
  dim as ConvexFault fault
  FaultClear(fault)
  dim as long listener = ListenLoopback(listenAddress, fault)
  if listener < 0 then
    Diagnostic("adapter listen failed: " & fault.message)
    return 1
  end if
  dim as long connection = AcceptOne(listener, ADAPTER_ACCEPT_TIMEOUT_MS, fault)
  if connection < 0 then
    Diagnostic("adapter accept failed: " & fault.message)
    CloseFd(listener)
    return 1
  end if
  ' Exactly one controller connection carries the same NDJSON stream.
  CloseFd(listener)
  dim as long status = AdapterRun(connection, connection)
  CloseFd(connection)
  return status
end function
