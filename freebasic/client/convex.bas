' Convex envelope policy and the single-owner Live sync implementation.

#include once "convex.bi"

declare sub LiveOwnerThread(byval userdata as any ptr)
declare function LiveWaitStopped( _
  byval manager as LiveManager ptr, _
  byval timeoutMs as long) as boolean

sub ConvexResultInit(byref result as ConvexResult)
  result.value = 0
  result.logs = 0
end sub

sub ConvexResultFree(byref result as ConvexResult)
  JsonFree(result.value)
  JsonFree(result.logs)
  result.value = 0
  result.logs = 0
end sub

sub LiveUpdateFree(byval update as LiveUpdate ptr)
  if update = 0 then
    exit sub
  end if
  JsonFree(update->value)
  JsonFree(update->logs)
  delete update
end sub

' Convex reports console output as logLines. Malformed logs invalidate the
' envelope instead of being silently filtered into a different successful value.
private function CollectLogs( _
    byval envelope as JsonValue ptr, _
    byref logs as JsonValue ptr, _
    byref reason as string) as boolean
  logs = JsonNew(JSON_ARRAY)
  dim as JsonValue ptr lines = JsonMember(envelope, "logLines")
  if lines = 0 then
    return true
  end if
  if lines->kind <> JSON_ARRAY then
    reason = "logLines must be an array of strings"
    JsonFree(logs)
    logs = 0
    return false
  end if
  for index as integer = 0 to cast(integer, lines->count) - 1
    dim as JsonValue ptr entry = lines->children[index]
    if entry->kind <> JSON_STRING then
      reason = "logLines must contain only strings"
      JsonFree(logs)
      logs = 0
      return false
    end if
    JsonAppend(logs, JsonNewString(entry->text))
  next
  return true
end function

function DecodeEnvelope( _
    byval httpStatus as long, _
    byref body as string, _
    byref result as ConvexResult, _
    byref fault as ConvexFault) as boolean
  ConvexResultInit(result)
  ' HTTP framing takes precedence over a body that merely looks like a Convex
  ' result. Gateways and auth failures are transport faults, even if their body
  ' is malformed JSON or happens to copy an envelope shape.
  if httpStatus < 200 orelse httpStatus > 299 then
    FaultSet(fault, FAULT_TRANSPORT, _
      "Convex returned HTTP " & FormatInteger(httpStatus))
    return false
  end if
  dim as string reason
  dim as JsonValue ptr envelope = JsonParse(body, reason)
  if envelope = 0 then
    FaultSet(fault, FAULT_PROTOCOL, _
      "Convex HTTP response was not valid JSON: " & reason)
    return false
  end if
  if envelope->kind <> JSON_OBJECT then
    JsonFree(envelope)
    FaultSet(fault, FAULT_PROTOCOL, "Convex HTTP response was not a JSON object")
    return false
  end if

  dim as string statusText
  dim as string logsReason
  if not JsonStringField(envelope, "status", statusText) then
    JsonFree(envelope)
    FaultSet(fault, FAULT_PROTOCOL, "Convex HTTP response had no status field")
    return false
  end if

  if statusText = "success" then
    dim as JsonValue ptr value = JsonMember(envelope, "value")
    if value = 0 then
      JsonFree(envelope)
      FaultSet(fault, FAULT_PROTOCOL, "Convex success response omitted value")
      return false
    end if
    if not CollectLogs(envelope, result.logs, logsReason) then
      JsonFree(envelope)
      FaultSet(fault, FAULT_PROTOCOL, logsReason)
      return false
    end if
    result.value = JsonClone(value)
    JsonFree(envelope)
    return true
  end if

  if statusText = "error" then
    dim as string message
    if not JsonStringField(envelope, "errorMessage", message) then
      JsonFree(envelope)
      FaultSet(fault, FAULT_PROTOCOL, "Convex error response omitted errorMessage")
      return false
    end if
    FaultSet(fault, FAULT_FUNCTION, message)
    dim as JsonValue ptr errorData = JsonMember(envelope, "errorData")
    if errorData <> 0 then
      fault.hasData = true
      fault.dataJson = JsonRender(errorData)
    end if
    if not CollectLogs(envelope, result.logs, logsReason) then
      JsonFree(envelope)
      FaultSet(fault, FAULT_PROTOCOL, logsReason)
      return false
    end if
    JsonFree(envelope)
    return false
  end if

  JsonFree(envelope)
  FaultSet(fault, FAULT_PROTOCOL, "Convex HTTP response had an unknown status")
  return false
end function

private function ConvexCall( _
    byref client as ConvexClient, _
    byref operation as string, _
    byref path as string, _
    byval args as JsonValue ptr, _
    byref result as ConvexResult, _
    byref fault as ConvexFault) as boolean
  ConvexResultInit(result)
  mutexlock(client.mutex)
  dim as boolean closed = client.closed
  dim as string bearer = client.token
  dim as ConvexUrl target = client.target
  mutexunlock(client.mutex)
  if closed then
    FaultSet(fault, FAULT_CLIENT, "Convex client is closed")
    return false
  end if
  if len(path) < 3 then
    FaultSet(fault, FAULT_PROTOCOL, "Convex function path is required")
    return false
  end if
  if args = 0 orelse args->kind <> JSON_OBJECT then
    FaultSet(fault, FAULT_PROTOCOL, "Convex arguments must be a JSON object")
    return false
  end if

  dim as JsonValue ptr request = JsonNew(JSON_OBJECT)
  JsonSet(request, "path", JsonNewString(path))
  JsonSet(request, "args", JsonClone(args))
  ' The documented value format for the HTTP endpoints.
  JsonSet(request, "format", JsonNewString("json"))
  dim as string payload = JsonRender(request)
  JsonFree(request)
  if len(payload) > HTTP_MAX_BODY_BYTES then
    FaultSet(fault, FAULT_PROTOCOL, "Convex request body exceeds 2 MiB")
    return false
  end if

  dim as long status
  dim as string body
  if not HttpPostJson(target, "/api/" & operation, payload, bearer, _
                      CONVEX_HTTP_TIMEOUT_MS, status, body, fault) then
    return false
  end if
  return DecodeEnvelope(status, body, result, fault)
end function

function ConvexOpen( _
    byref client as ConvexClient, _
    byref deploymentUrl as string, _
    byref fault as ConvexFault) as boolean
  client.token = ""
  client.closed = false
  client.live = 0
  client.mutex = 0
  if not ParseDeploymentUrl(deploymentUrl, client.target, fault) then
    return false
  end if
  client.mutex = mutexcreate()
  if client.mutex = 0 then
    FaultSet(fault, FAULT_CLIENT, "could not create the Convex client mutex")
    return false
  end if
  NetInitialize()
  return true
end function

sub ConvexSetAuth(byref client as ConvexClient, byref token as string)
  mutexlock(client.mutex)
  client.token = token
  mutexunlock(client.mutex)
end sub

function ConvexQuery( _
    byref client as ConvexClient, _
    byref path as string, _
    byval args as JsonValue ptr, _
    byref result as ConvexResult, _
    byref fault as ConvexFault) as boolean
  return ConvexCall(client, "query", path, args, result, fault)
end function

function ConvexMutation( _
    byref client as ConvexClient, _
    byref path as string, _
    byval args as JsonValue ptr, _
    byref result as ConvexResult, _
    byref fault as ConvexFault) as boolean
  return ConvexCall(client, "mutation", path, args, result, fault)
end function

function ConvexAction( _
    byref client as ConvexClient, _
    byref path as string, _
    byval args as JsonValue ptr, _
    byref result as ConvexResult, _
    byref fault as ConvexFault) as boolean
  return ConvexCall(client, "action", path, args, result, fault)
end function

' ---------------------------------------------------------------------------
' Live sync
'
' Exactly one worker thread owns the WebSocket, the reconnect schedule, and
' the query-set version. Subscriber threads only take the manager mutex to
' post intent and to drain their own mailbox; they never touch the socket.
' ---------------------------------------------------------------------------

function DecodeSyncTimestamp( _
    byref encoded as string, _
    byref value as ulongint) as boolean
  value = 0
  if len(encoded) <> 12 then
    return false
  end if
  dim as string decoded
  if not Base64Decode(encoded, decoded) then
    return false
  end if
  if len(decoded) <> 8 then
    return false
  end if
  ' Reject a noncanonical spelling so two encodings cannot claim one position.
  if Base64Encode(decoded) <> encoded then
    return false
  end if
  for index as integer = 0 to 7
    value or= cast(ulongint, decoded[index]) shl (8 * index)
  next
  return true
end function

private function LiveEstimateBytes(byval update as LiveUpdate ptr) as uinteger
  ' A count bound alone is not a memory bound when one value can approach the
  ' maximum frame size, so every queued update is charged its encoded size
  ' plus a fixed per-update overhead.
  dim as uinteger total = 256
  if update->value <> 0 then
    total += culngint(len(JsonRender(update->value)))
  end if
  if update->logs <> 0 then
    total += culngint(len(JsonRender(update->logs)))
  end if
  total += culngint(len(update->fault.message) + len(update->fault.dataJson))
  return total
end function

private sub LiveDropFrontLocked( _
    byval manager as LiveManager ptr, _
    byval handle as LiveSubscription ptr)
  dim as LiveUpdate ptr front = handle->head
  if front = 0 then
    exit sub
  end if
  handle->head = front->nextUpdate
  if handle->head = 0 then
    handle->tail = 0
  end if
  handle->queued -= 1
  manager->queuedBytes -= front->retainedBytes
  LiveUpdateFree(front)
end sub

private sub LiveClearQueueLocked( _
    byval manager as LiveManager ptr, _
    byval handle as LiveSubscription ptr)
  while handle->head <> 0
    LiveDropFrontLocked(manager, handle)
  wend
end sub

private function LiveEvictGlobalOldestLocked(byval manager as LiveManager ptr) as boolean
  dim as LiveSubscription ptr oldest = 0
  dim as ulongint serial = not cast(ulongint, 0)
  dim as LiveSubscription ptr scan = manager->subscriptions
  while scan <> 0
    if scan->head <> 0 andalso scan->head->serial < serial then
      serial = scan->head->serial
      oldest = scan
    end if
    scan = scan->nextSubscription
  wend
  if oldest = 0 then
    return false
  end if
  LiveDropFrontLocked(manager, oldest)
  return true
end function

private sub LiveEnqueueLocked( _
    byval manager as LiveManager ptr, _
    byval handle as LiveSubscription ptr, _
    byval update as LiveUpdate ptr)
  manager->updateSerial += 1
  update->serial = manager->updateSerial
  update->retainedBytes = LiveEstimateBytes(update)
  update->nextUpdate = 0
  while handle->queued >= CONVEX_LIVE_QUEUE_DEPTH
    LiveDropFrontLocked(manager, handle)
  wend
  if handle->tail = 0 then
    handle->head = update
  else
    handle->tail->nextUpdate = update
  end if
  handle->tail = update
  handle->queued += 1
  manager->queuedBytes += update->retainedBytes
  ' The global budget is enforced after insertion so a single oversized update
  ' still arrives, but never at the cost of the process memory bound.
  while manager->queuedBytes > CONVEX_LIVE_QUEUE_BYTES
    if not LiveEvictGlobalOldestLocked(manager) then
      exit while
    end if
  wend
end sub

private sub LivePublishFaultLocked( _
    byval manager as LiveManager ptr, _
    byref kind as string, _
    byref message as string, _
    byval establishedOnly as boolean)
  dim as LiveSubscription ptr scan = manager->subscriptions
  while scan <> 0
    if scan->active andalso (not scan->removePending) andalso _
       ((not establishedOnly) orelse (not scan->addPending)) then
      dim as LiveUpdate ptr update = new LiveUpdate
      update->hasValue = false
      update->value = 0
      update->logs = JsonNew(JSON_ARRAY)
      update->nextUpdate = 0
      FaultSet(update->fault, kind, message)
      LiveEnqueueLocked(manager, scan, update)
    end if
    scan = scan->nextSubscription
  wend
end sub

private sub LiveRetireSocketLocked(byval manager as LiveManager ptr, byref why as string)
  if StreamIsOpen(manager->conn.stream) then
    WsShutdown(manager->conn, MonotonicMs() + CONVEX_LIVE_WRITE_TIMEOUT_MS)
  else
    StreamClose(manager->conn.stream)
  end if
  WsReset(manager->conn)
  manager->connected = false
  manager->connectionCount += 1
  if len(why) > 0 then
    manager->lastCloseReason = why
  else
    manager->lastCloseReason = "TransportError"
  end if
  ' A new connection starts a new query set and a new sync position.
  manager->querySetVersion = 0
  manager->remoteQuerySet = 0
  manager->remoteIdentity = 0
  manager->remoteTimestamp = 0
  manager->remoteTimestampEncoded = CONVEX_INITIAL_TIMESTAMP
  dim as LiveSubscription ptr scan = manager->subscriptions
  while scan <> 0
    ' No value or fault from the retired transport may cross the reconnect
    ' boundary. The new owner will publish fresh state or a fresh fault.
    LiveClearQueueLocked(manager, scan)
    if scan->active andalso (not scan->removePending) then
      scan->rehydrating = scan->hasLastValue
      scan->addPending = true
      scan->addDone = false
    end if
    scan = scan->nextSubscription
  wend
end sub

private function LiveActiveCountLocked(byval manager as LiveManager ptr) as long
  dim as long total = 0
  dim as LiveSubscription ptr scan = manager->subscriptions
  while scan <> 0
    if scan->active andalso (not scan->removePending) then
      total += 1
    end if
    scan = scan->nextSubscription
  wend
  return total
end function

private function LiveConnectMessageLocked(byval manager as LiveManager ptr) as string
  dim as JsonValue ptr message = JsonNew(JSON_OBJECT)
  JsonSet(message, "type", JsonNewString("Connect"))
  JsonSet(message, "sessionId", JsonNewString(manager->sessionId))
  JsonSet(message, "connectionCount", JsonNewInteger(manager->connectionCount))
  JsonSet(message, "lastCloseReason", JsonNewString(manager->lastCloseReason))
  ' Carrying the highest observed timestamp lets Convex resume rather than
  ' replay the whole query set after a reconnect.
  if manager->hasMaxTimestamp then
    JsonSet(message, "maxObservedTimestamp", JsonNewString(manager->maxTimestampEncoded))
  end if
  JsonSet(message, "clientTs", JsonNewInteger(0))
  dim as string encoded = JsonRender(message)
  JsonFree(message)
  return encoded
end function

private function LiveModifyMessageLocked( _
    byval manager as LiveManager ptr, _
    byval chosen as LiveSubscription ptr, _
    byval removing as boolean) as string
  dim as JsonValue ptr message = JsonNew(JSON_OBJECT)
  JsonSet(message, "type", JsonNewString("ModifyQuerySet"))
  JsonSet(message, "baseVersion", JsonNewInteger(manager->querySetVersion))
  JsonSet(message, "newVersion", JsonNewInteger(manager->querySetVersion + 1))
  dim as JsonValue ptr modifications = JsonNew(JSON_ARRAY)
  dim as LiveSubscription ptr scan = manager->subscriptions
  while scan <> 0
    dim as boolean includeScan = false
    if chosen <> 0 then
      includeScan = (scan = chosen)
    else
      includeScan = scan->active andalso (not scan->removePending)
    end if
    if includeScan then
      dim as JsonValue ptr entry = JsonNew(JSON_OBJECT)
      if removing then
        JsonSet(entry, "type", JsonNewString("Remove"))
      else
        JsonSet(entry, "type", JsonNewString("Add"))
      end if
      JsonSet(entry, "queryId", JsonNewInteger(scan->queryId))
      if not removing then
        JsonSet(entry, "udfPath", JsonNewString(scan->path))
        dim as string ignored
        dim as JsonValue ptr args = JsonParse(scan->argsJson, ignored)
        dim as JsonValue ptr wrapper = JsonNew(JSON_ARRAY)
        if args <> 0 then
          JsonAppend(wrapper, args)
        end if
        JsonSet(entry, "args", wrapper)
      end if
      JsonAppend(modifications, entry)
    end if
    scan = scan->nextSubscription
  wend
  JsonSet(message, "modifications", modifications)
  dim as string encoded = JsonRender(message)
  JsonFree(message)
  return encoded
end function

private function LiveDecodeVersion( _
    byval root as JsonValue ptr, _
    byref fieldName as string, _
    byref querySet as ulong, _
    byref identity as ulong, _
    byref timestamp as ulongint, _
    byref encoded as string, _
    byref reason as string) as boolean
  dim as JsonValue ptr node = JsonMember(root, fieldName)
  if node = 0 orelse node->kind <> JSON_OBJECT then
    reason = "Transition omitted " & fieldName
    return false
  end if
  dim as ulongint querySetValue
  dim as ulongint identityValue
  if not JsonUnsignedField(node, "querySet", querySetValue) orelse _
     not JsonUnsignedField(node, "identity", identityValue) orelse _
     not JsonStringField(node, "ts", encoded) then
    reason = "Transition has an invalid " & fieldName
    return false
  end if
  if querySetValue > 4294967295ull orelse identityValue > 4294967295ull then
    reason = "Transition version is out of range"
    return false
  end if
  if not DecodeSyncTimestamp(encoded, timestamp) then
    reason = "Transition has a noncanonical timestamp"
    return false
  end if
  querySet = cast(ulong, querySetValue)
  identity = cast(ulong, identityValue)
  return true
end function

private function LiveFindLocked( _
    byval manager as LiveManager ptr, _
    byval queryId as ulong) as LiveSubscription ptr
  dim as LiveSubscription ptr scan = manager->subscriptions
  while scan <> 0
    if scan->queryId = queryId then
      return scan
    end if
    scan = scan->nextSubscription
  wend
  return 0
end function

' Validate the whole Transition before any of it becomes current. A partially
' applied transition would leave the local sync position unable to match the
' next start version.
private function LiveHandleTransition( _
    byval manager as LiveManager ptr, _
    byval message as JsonValue ptr, _
    byref reason as string) as boolean
  dim as ulong startQuerySet, startIdentity, endQuerySet, endIdentity
  dim as ulongint startTimestamp, endTimestamp
  dim as string startEncoded, endEncoded
  if not LiveDecodeVersion(message, "startVersion", startQuerySet, startIdentity, _
                           startTimestamp, startEncoded, reason) then
    return false
  end if
  if not LiveDecodeVersion(message, "endVersion", endQuerySet, endIdentity, _
                           endTimestamp, endEncoded, reason) then
    return false
  end if
  dim as JsonValue ptr modifications = JsonMember(message, "modifications")
  if modifications = 0 orelse modifications->kind <> JSON_ARRAY then
    reason = "Transition omitted modifications"
    return false
  end if
  if startQuerySet <> manager->remoteQuerySet orelse _
     startIdentity <> manager->remoteIdentity orelse _
     startTimestamp <> manager->remoteTimestamp then
    reason = "Transition start version does not match the local version"
    return false
  end if
  if endQuerySet < startQuerySet orelse endIdentity < startIdentity orelse _
     endTimestamp < startTimestamp then
    reason = "Transition end version moved backwards"
    return false
  end if

  ' Locals are shared by both passes so the two loops cannot collide on a name.
  dim as JsonValue ptr entry
  dim as string kind
  dim as ulongint queryId

  ' First pass: validate every modification.
  for index as integer = 0 to cast(integer, modifications->count) - 1
    entry = modifications->children[index]
    if entry->kind <> JSON_OBJECT orelse not JsonStringField(entry, "type", kind) orelse _
       not JsonUnsignedField(entry, "queryId", queryId) then
      reason = "Transition modification omitted type or queryId"
      return false
    end if
    if kind = "QueryUpdated" then
      if JsonMember(entry, "value") = 0 then
        reason = "QueryUpdated omitted value"
        return false
      end if
    elseif kind = "QueryFailed" then
      dim as string ignored
      if not JsonStringField(entry, "errorMessage", ignored) then
        reason = "QueryFailed omitted errorMessage"
        return false
      end if
    elseif kind <> "QueryRemoved" then
      reason = "unknown Transition modification " & kind
      return false
    end if
    dim as JsonValue ptr logLines = JsonMember(entry, "logLines")
    if logLines <> 0 andalso logLines->kind <> JSON_ARRAY then
      reason = "Transition modification has invalid logLines"
      return false
    end if
    if logLines <> 0 then
      for logIndex as integer = 0 to cast(integer, logLines->count) - 1
        if logLines->children[logIndex]->kind <> JSON_STRING then
          reason = "Transition modification logLines must contain only strings"
          return false
        end if
      next
    end if
  next

  ' Second pass: commit.
  manager->remoteQuerySet = endQuerySet
  manager->remoteIdentity = endIdentity
  manager->remoteTimestamp = endTimestamp
  manager->remoteTimestampEncoded = endEncoded
  if (not manager->hasMaxTimestamp) orelse endTimestamp > manager->maxTimestamp then
    manager->hasMaxTimestamp = true
    manager->maxTimestamp = endTimestamp
    manager->maxTimestampEncoded = endEncoded
  end if

  for index as integer = 0 to cast(integer, modifications->count) - 1
    entry = modifications->children[index]
    JsonStringField(entry, "type", kind)
    JsonUnsignedField(entry, "queryId", queryId)
    ' Convex may mention the same query more than once in one Transition. Only
    ' the final modification is observable, matching the server's final state.
    dim as boolean superseded = false
    for laterIndex as integer = index + 1 to cast(integer, modifications->count) - 1
      dim as ulongint laterQueryId
      JsonUnsignedField(modifications->children[laterIndex], "queryId", laterQueryId)
      if laterQueryId = queryId then
        superseded = true
        exit for
      end if
    next
    if superseded then
      continue for
    end if
    dim as LiveSubscription ptr handle = LiveFindLocked(manager, cast(ulong, queryId))
    if handle = 0 orelse (not handle->active) orelse handle->removePending orelse _
       kind = "QueryRemoved" then
      continue for
    end if
    dim as LiveUpdate ptr update = new LiveUpdate
    update->hasValue = false
    update->value = 0
    dim as string ignoredLogsReason
    if not CollectLogs(entry, update->logs, ignoredLogsReason) then
      delete update
      reason = ignoredLogsReason
      return false
    end if
    update->nextUpdate = 0
    FaultClear(update->fault)
    if kind = "QueryUpdated" then
      dim as JsonValue ptr value = JsonMember(entry, "value")
      dim as string encoded = JsonRender(value)
      dim as boolean unchanged = handle->hasLastValue andalso (handle->lastValueJson = encoded)
      dim as boolean suppress = handle->rehydrating andalso unchanged
      handle->lastValueJson = encoded
      handle->hasLastValue = true
      handle->rehydrating = false
      if suppress then
        ' A reconnect that replays the same value is not an observable change.
        LiveUpdateFree(update)
        continue for
      end if
      update->hasValue = true
      update->value = JsonClone(value)
    else
      handle->hasLastValue = false
      handle->rehydrating = false
      dim as string message2
      JsonStringField(entry, "errorMessage", message2)
      FaultSet(update->fault, FAULT_FUNCTION, message2)
      dim as JsonValue ptr errorData = JsonMember(entry, "errorData")
      if errorData <> 0 then
        update->fault.hasData = true
        update->fault.dataJson = JsonRender(errorData)
      end if
    end if
    LiveEnqueueLocked(manager, handle, update)
  next
  return true
end function

private function LiveSendText( _
    byval manager as LiveManager ptr, _
    byref payload as string, _
    byref reason as string) as boolean
  return WsSendText(manager->conn, payload, _
                    MonotonicMs() + CONVEX_LIVE_WRITE_TIMEOUT_MS, reason)
end function

private function LiveNextBackoff(byval current as long) as long
  if current < 7500 then
    return current * 2
  end if
  return 15000
end function

private function LiveConnect( _
    byval manager as LiveManager ptr, _
    byref reason as string) as boolean
  dim as ConvexFault fault
  FaultClear(fault)
  mutexlock(manager->mutex)
  dim as ConvexUrl target = manager->target
  mutexunlock(manager->mutex)

  if not WsHandshake(manager->conn, target, "/api/sync", _
                     CONVEX_LIVE_DIAL_TIMEOUT_MS, fault) then
    reason = fault.message
    return false
  end if

  mutexlock(manager->mutex)
  dim as string connectMessage = LiveConnectMessageLocked(manager)
  dim as long active = LiveActiveCountLocked(manager)
  dim as string modifyMessage
  if active > 0 then
    modifyMessage = LiveModifyMessageLocked(manager, 0, false)
  end if
  mutexunlock(manager->mutex)

  if not LiveSendText(manager, connectMessage, reason) then
    WsShutdown(manager->conn, MonotonicMs() + CONVEX_LIVE_WRITE_TIMEOUT_MS)
    return false
  end if
  ' Every new connection resends the active Add operations, so a reconnect
  ' rebuilds the whole query set rather than assuming server-side memory.
  if active > 0 andalso not LiveSendText(manager, modifyMessage, reason) then
    WsShutdown(manager->conn, MonotonicMs() + CONVEX_LIVE_WRITE_TIMEOUT_MS)
    return false
  end if

  mutexlock(manager->mutex)
  if active > 0 then
    manager->querySetVersion = 1
  else
    manager->querySetVersion = 0
  end if
  dim as LiveSubscription ptr scan = manager->subscriptions
  while scan <> 0
    if scan->active andalso (not scan->removePending) then
      scan->addPending = false
      scan->addDone = true
    end if
    scan = scan->nextSubscription
  wend
  manager->connected = true
  mutexunlock(manager->mutex)
  return true
end function

sub LiveOwnerThread(byval userdata as any ptr)
  dim as LiveManager ptr manager = cast(LiveManager ptr, userdata)
  dim as longint reconnectAt = 0
  dim as long backoff = 100
  dim as string reason
  dim as string message
  ' Hoisted so every branch of the dispatch below shares one scope.
  dim as string parseReason
  dim as string kind
  dim as string detail
  dim as JsonValue ptr node
  dim as boolean ok

  do
    mutexlock(manager->mutex)
    if manager->closing then
      mutexunlock(manager->mutex)
      exit do
    end if
    if manager->debugRequested then
      ' Retire the old connection and schedule reconnect work before the
      ' acknowledgement is published, so the caller can rely on the ordering.
      manager->debugRequested = false
      dim as string why = "DebugDisconnect"
      LiveRetireSocketLocked(manager, why)
      manager->debugCompleted = manager->debugGeneration
      reconnectAt = MonotonicMs() + 100
    end if
    dim as boolean hasSocket = manager->connected
    if not hasSocket then
      ' With no socket there is nothing to unsubscribe from remotely, so a
      ' pending Remove completes immediately.
      dim as LiveSubscription ptr scan = manager->subscriptions
      while scan <> 0
        if scan->removePending andalso (not scan->removeDone) then
          scan->active = false
          scan->removeDone = true
          LiveClearQueueLocked(manager, scan)
        end if
        scan = scan->nextSubscription
      wend
    end if

    dim as LiveSubscription ptr pendingAdd = 0
    dim as LiveSubscription ptr pendingRemove = 0
    if hasSocket then
      dim as LiveSubscription ptr scan = manager->subscriptions
      while scan <> 0
        if pendingAdd = 0 andalso scan->active andalso scan->addPending andalso _
           (not scan->removePending) then
          pendingAdd = scan
        end if
        if pendingRemove = 0 andalso scan->removePending andalso (not scan->removeDone) then
          pendingRemove = scan
        end if
        scan = scan->nextSubscription
      wend
    end if

    if pendingAdd <> 0 then
      message = LiveModifyMessageLocked(manager, pendingAdd, false)
      mutexunlock(manager->mutex)
      if LiveSendText(manager, message, reason) then
        mutexlock(manager->mutex)
        manager->querySetVersion += 1
        pendingAdd->addPending = false
        pendingAdd->addDone = true
        mutexunlock(manager->mutex)
      else
        mutexlock(manager->mutex)
        LiveRetireSocketLocked(manager, reason)
        LivePublishFaultLocked(manager, FAULT_TRANSPORT, reason, false)
        mutexunlock(manager->mutex)
        reconnectAt = MonotonicMs() + backoff
        backoff = LiveNextBackoff(backoff)
      end if
      continue do
    end if

    if pendingRemove <> 0 then
      message = LiveModifyMessageLocked(manager, pendingRemove, true)
      mutexunlock(manager->mutex)
      dim as boolean sent = LiveSendText(manager, message, reason)
      mutexlock(manager->mutex)
      if sent then
        manager->querySetVersion += 1
        pendingRemove->active = false
        pendingRemove->removeDone = true
        ' Invalidate the mailbox before the acknowledgement is visible so no
        ' stale event can cross the unsubscribe boundary.
        LiveClearQueueLocked(manager, pendingRemove)
        mutexunlock(manager->mutex)
      else
        LiveRetireSocketLocked(manager, reason)
        LivePublishFaultLocked(manager, FAULT_TRANSPORT, reason, false)
        mutexunlock(manager->mutex)
        reconnectAt = MonotonicMs() + backoff
        backoff = LiveNextBackoff(backoff)
      end if
      continue do
    end if

    dim as long active = LiveActiveCountLocked(manager)
    mutexunlock(manager->mutex)

    if (not hasSocket) andalso active > 0 andalso MonotonicMs() >= reconnectAt then
      if LiveConnect(manager, reason) then
        ' A completed RFC 6455 handshake is a healthy boundary, so a later
        ' failure restarts at the initial delay instead of inheriting the old
        ' maximum.
        backoff = 100
      else
        mutexlock(manager->mutex)
        manager->connectionCount += 1
        if len(reason) > 0 then
          manager->lastCloseReason = reason
        else
          manager->lastCloseReason = "TransportError"
        end if
        LivePublishFaultLocked(manager, FAULT_TRANSPORT, manager->lastCloseReason, false)
        mutexunlock(manager->mutex)
        reconnectAt = MonotonicMs() + backoff
        backoff = LiveNextBackoff(backoff)
      end if
      continue do
    end if

    if not hasSocket then
      SleepMs(10)
      continue do
    end if

    dim as long outcome = WsReceive(manager->conn, message, MonotonicMs() + 20, reason)
    select case outcome
      case WS_NEED_MORE
        ' Nothing complete arrived inside the slice; loop and re-check intent.

      case WS_CONTROL
        backoff = 100

      case WS_MESSAGE
        backoff = 100
        node = JsonParse(message, parseReason)
        ok = false
        if node <> 0 andalso node->kind = JSON_OBJECT andalso _
           JsonStringField(node, "type", kind) then
          if kind = "Transition" then
            mutexlock(manager->mutex)
            ok = LiveHandleTransition(manager, node, reason)
            mutexunlock(manager->mutex)
          elseif kind = "Ping" orelse kind = "MutationResponse" orelse _
                 kind = "ActionResponse" then
            ok = true
          else
            reason = "unexpected Convex sync message " & kind
            if JsonStringField(node, "error", detail) then
              reason &= ": " & detail
            end if
          end if
        else
          reason = "Convex sync message was not a typed JSON object: " & parseReason
        end if
        JsonFree(node)
        if not ok then
          mutexlock(manager->mutex)
          LiveRetireSocketLocked(manager, reason)
          LivePublishFaultLocked(manager, FAULT_PROTOCOL, reason, false)
          mutexunlock(manager->mutex)
          reconnectAt = MonotonicMs() + backoff
          backoff = LiveNextBackoff(backoff)
        end if

      case else
        mutexlock(manager->mutex)
        if outcome = WS_PROTOCOL_ERROR then
          LiveRetireSocketLocked(manager, reason)
          LivePublishFaultLocked(manager, FAULT_PROTOCOL, reason, false)
        elseif not manager->closing then
          LiveRetireSocketLocked(manager, reason)
          LivePublishFaultLocked(manager, FAULT_TRANSPORT, reason, true)
        else
          LiveRetireSocketLocked(manager, reason)
        end if
        mutexunlock(manager->mutex)
        reconnectAt = MonotonicMs() + backoff
        backoff = LiveNextBackoff(backoff)
    end select
  loop

  WsShutdown(manager->conn, MonotonicMs() + CONVEX_LIVE_WRITE_TIMEOUT_MS)
  mutexlock(manager->mutex)
  manager->connected = false
  manager->stopped = true
  mutexunlock(manager->mutex)
end sub

private function LiveNewManager(byref target as ConvexUrl) as LiveManager ptr
  dim as LiveManager ptr manager = new LiveManager
  manager->mutex = mutexcreate()
  manager->subscriptions = 0
  manager->nextQueryId = 0
  manager->querySetVersion = 0
  manager->remoteQuerySet = 0
  manager->remoteIdentity = 0
  manager->remoteTimestamp = 0
  manager->remoteTimestampEncoded = CONVEX_INITIAL_TIMESTAMP
  manager->hasMaxTimestamp = false
  manager->maxTimestamp = 0
  manager->maxTimestampEncoded = CONVEX_INITIAL_TIMESTAMP
  manager->connectionCount = 0
  manager->lastCloseReason = "InitialConnect"
  manager->closing = false
  manager->stopped = false
  manager->connected = false
  manager->debugRequested = false
  manager->debugGeneration = 0
  manager->debugCompleted = 0
  manager->updateSerial = 0
  manager->queuedBytes = 0
  manager->sessionId = SessionId()
  manager->target = target
  manager->worker = 0
  WsReset(manager->conn)
  return manager
end function

private sub LiveDestroyManager(byval manager as LiveManager ptr)
  if manager = 0 then
    exit sub
  end if
  dim as LiveSubscription ptr scan = manager->subscriptions
  while scan <> 0
    dim as LiveSubscription ptr following = scan->nextSubscription
    LiveClearQueueLocked(manager, scan)
    delete scan
    scan = following
  wend
  if manager->mutex <> 0 then
    mutexdestroy(manager->mutex)
  end if
  delete manager
end sub

private function LiveWaitUntilAdded( _
    byval manager as LiveManager ptr, _
    byval handle as LiveSubscription ptr, _
    byval timeoutMs as long) as boolean
  dim as longint deadline = MonotonicMs() + timeoutMs
  do
    mutexlock(manager->mutex)
    dim as boolean done = handle->addDone orelse (not handle->active) orelse manager->stopped
    mutexunlock(manager->mutex)
    if done then
      return true
    end if
    if MonotonicMs() >= deadline then
      return false
    end if
    SleepMs(5)
  loop
end function

function ConvexSubscribe( _
    byref client as ConvexClient, _
    byref path as string, _
    byval args as JsonValue ptr, _
    byref fault as ConvexFault) as LiveSubscription ptr
  if len(path) < 3 then
    FaultSet(fault, FAULT_PROTOCOL, "Live query path is required")
    return 0
  end if
  if len(path) > CONVEX_LIVE_MAX_PATH_BYTES orelse not IsValidUtf8(path) then
    FaultSet(fault, FAULT_PROTOCOL, "Live query path is invalid or exceeds 1024 bytes")
    return 0
  end if
  if args = 0 orelse args->kind <> JSON_OBJECT then
    FaultSet(fault, FAULT_PROTOCOL, "Live query arguments must be a JSON object")
    return 0
  end if
  dim as string argsJson = JsonRender(args)
  if len(argsJson) > CONVEX_LIVE_MAX_ARGS_BYTES then
    FaultSet(fault, FAULT_PROTOCOL, "Live query arguments exceed 64 KiB")
    return 0
  end if

  mutexlock(client.mutex)
  if client.closed then
    mutexunlock(client.mutex)
    FaultSet(fault, FAULT_CLIENT, "Convex client is closed")
    return 0
  end if
  if client.live = 0 then
    client.live = LiveNewManager(client.target)
    client.live->worker = threadcreate(@LiveOwnerThread, client.live)
    if client.live->worker = 0 then
      dim as LiveManager ptr orphan = client.live
      client.live = 0
      mutexunlock(client.mutex)
      LiveDestroyManager(orphan)
      FaultSet(fault, FAULT_CLIENT, "could not start the Live owner thread")
      return 0
    end if
  end if
  dim as LiveManager ptr manager = client.live
  mutexunlock(client.mutex)

  dim as LiveSubscription ptr handle = new LiveSubscription
  handle->path = path
  handle->argsJson = argsJson
  handle->active = true
  handle->addPending = true
  handle->addDone = false
  handle->removePending = false
  handle->removeDone = false
  handle->rehydrating = false
  handle->hasLastValue = false
  handle->head = 0
  handle->tail = 0
  handle->queued = 0
  handle->nextSubscription = 0

  mutexlock(manager->mutex)
  if manager->closing orelse manager->stopped then
    mutexunlock(manager->mutex)
    delete handle
    FaultSet(fault, FAULT_CLIENT, "Convex client is closed")
    return 0
  end if
  if LiveActiveCountLocked(manager) >= CONVEX_LIVE_MAX_SUBSCRIPTIONS then
    mutexunlock(manager->mutex)
    delete handle
    FaultSet(fault, FAULT_PROTOCOL, "Live subscription limit reached")
    return 0
  end if
  if manager->nextQueryId >= CONVEX_LIVE_MAX_LIFETIME_SUBSCRIPTIONS then
    mutexunlock(manager->mutex)
    delete handle
    FaultSet(fault, FAULT_PROTOCOL, "Live subscription lifetime limit reached")
    return 0
  end if
  handle->queryId = manager->nextQueryId
  manager->nextQueryId += 1
  if manager->subscriptions = 0 then
    manager->subscriptions = handle
  else
    dim as LiveSubscription ptr tail = manager->subscriptions
    while tail->nextSubscription <> 0
      tail = tail->nextSubscription
    wend
    tail->nextSubscription = handle
  end if
  mutexunlock(manager->mutex)

  ' Returning only after the owner has installed the Add keeps the caller's
  ' first read from racing the query set.
  if not LiveWaitUntilAdded(manager, handle, CONVEX_LIVE_COMMAND_TIMEOUT_MS) then
    mutexlock(manager->mutex)
    handle->removePending = true
    mutexunlock(manager->mutex)
    FaultSet(fault, FAULT_TRANSPORT, "timed out installing the Live query")
    return 0
  end if
  mutexlock(manager->mutex)
  dim as boolean installed = handle->addDone
  mutexunlock(manager->mutex)
  if not installed then
    FaultSet(fault, FAULT_TRANSPORT, "the Live owner stopped before Add completed")
    return 0
  end if
  return handle
end function

function ConvexNext( _
    byref client as ConvexClient, _
    byval handle as LiveSubscription ptr, _
    byval timeoutMs as long) as LiveUpdate ptr
  if handle = 0 then
    return 0
  end if
  mutexlock(client.mutex)
  dim as LiveManager ptr manager = client.live
  mutexunlock(client.mutex)
  if manager = 0 then
    return 0
  end if
  dim as longint deadline = MonotonicMs() + timeoutMs
  do
    mutexlock(manager->mutex)
    dim as LiveUpdate ptr update = handle->head
    if update <> 0 then
      handle->head = update->nextUpdate
      if handle->head = 0 then
        handle->tail = 0
      end if
      handle->queued -= 1
      manager->queuedBytes -= update->retainedBytes
      update->nextUpdate = 0
      mutexunlock(manager->mutex)
      return update
    end if
    dim as boolean finished = (not handle->active) orelse manager->stopped
    mutexunlock(manager->mutex)
    if finished then
      return 0
    end if
    if timeoutMs >= 0 andalso MonotonicMs() >= deadline then
      return 0
    end if
    SleepMs(5)
  loop
end function

sub ConvexUnsubscribe( _
    byref client as ConvexClient, _
    byval handle as LiveSubscription ptr, _
    byval timeoutMs as long)
  if handle = 0 then
    exit sub
  end if
  mutexlock(client.mutex)
  dim as LiveManager ptr manager = client.live
  mutexunlock(client.mutex)
  if manager = 0 then
    exit sub
  end if
  mutexlock(manager->mutex)
  if (not handle->active) orelse handle->removeDone then
    mutexunlock(manager->mutex)
    exit sub
  end if
  handle->removePending = true
  ' Drop anything already queued now, not after the owner acknowledges, so a
  ' dequeue in flight cannot deliver a stale value.
  LiveClearQueueLocked(manager, handle)
  mutexunlock(manager->mutex)

  dim as longint deadline = MonotonicMs() + timeoutMs
  do
    mutexlock(manager->mutex)
    dim as boolean done = handle->removeDone orelse manager->stopped
    mutexunlock(manager->mutex)
    if done then
      exit do
    end if
    if MonotonicMs() >= deadline then
      exit do
    end if
    SleepMs(5)
  loop
end sub

function LiveWaitStopped( _
    byval manager as LiveManager ptr, _
    byval timeoutMs as long) as boolean
  dim as longint deadline = MonotonicMs() + timeoutMs
  do
    mutexlock(manager->mutex)
    dim as boolean stopped = manager->stopped
    mutexunlock(manager->mutex)
    if stopped then
      return true
    end if
    if MonotonicMs() >= deadline then
      return false
    end if
    SleepMs(5)
  loop
end function

sub ConvexClose(byref client as ConvexClient, byval timeoutMs as long)
  mutexlock(client.mutex)
  if client.closed then
    mutexunlock(client.mutex)
    exit sub
  end if
  client.closed = true
  client.token = ""
  dim as LiveManager ptr manager = client.live
  client.live = 0
  mutexunlock(client.mutex)

  if manager <> 0 then
    mutexlock(manager->mutex)
    manager->closing = true
    dim as LiveSubscription ptr scan = manager->subscriptions
    while scan <> 0
      scan->active = false
      scan->removeDone = true
      LiveClearQueueLocked(manager, scan)
      scan = scan->nextSubscription
    wend
    dim as any ptr worker = manager->worker
    mutexunlock(manager->mutex)
    LiveWaitStopped(manager, timeoutMs)
    if worker <> 0 then
      threadwait(worker)
    end if
    LiveDestroyManager(manager)
  end if

  if client.mutex <> 0 then
    mutexdestroy(client.mutex)
    client.mutex = 0
  end if
end sub

#ifdef CONVEX_ADAPTER
function ConvexDebugDisconnect( _
    byref client as ConvexClient, _
    byval timeoutMs as long, _
    byref fault as ConvexFault) as boolean
  mutexlock(client.mutex)
  dim as LiveManager ptr manager = client.live
  dim as boolean closed = client.closed
  mutexunlock(client.mutex)
  if closed orelse manager = 0 then
    FaultSet(fault, FAULT_TRANSPORT, "the Live WebSocket is not connected")
    return false
  end if
  mutexlock(manager->mutex)
  if not manager->connected then
    mutexunlock(manager->mutex)
    FaultSet(fault, FAULT_TRANSPORT, "the Live WebSocket is not connected")
    return false
  end if
  manager->debugGeneration += 1
  dim as ulongint generation = manager->debugGeneration
  manager->debugRequested = true
  mutexunlock(manager->mutex)

  dim as longint deadline = MonotonicMs() + timeoutMs
  do
    mutexlock(manager->mutex)
    dim as boolean done = (manager->debugCompleted >= generation) orelse manager->stopped
    dim as boolean retired = (manager->debugCompleted >= generation)
    mutexunlock(manager->mutex)
    if done then
      if retired then
        return true
      end if
      FaultSet(fault, FAULT_TRANSPORT, "the client closed during the debug disconnect")
      return false
    end if
    if MonotonicMs() >= deadline then
      FaultSet(fault, FAULT_TRANSPORT, "timed out retiring the Live WebSocket")
      return false
    end if
    SleepMs(5)
  loop
end function

function LiveApplyTransition( _
    byval manager as LiveManager ptr, _
    byref text as string, _
    byref reason as string) as boolean
  dim as string parseReason
  dim as JsonValue ptr node = JsonParse(text, parseReason)
  if node = 0 then
    reason = parseReason
    return false
  end if
  mutexlock(manager->mutex)
  dim as boolean ok = LiveHandleTransition(manager, node, reason)
  mutexunlock(manager->mutex)
  JsonFree(node)
  return ok
end function

function LiveEnqueueForTest( _
    byval manager as LiveManager ptr, _
    byval handle as LiveSubscription ptr, _
    byref valueJson as string) as boolean
  dim as string parseReason
  dim as JsonValue ptr value = JsonParse(valueJson, parseReason)
  if value = 0 then
    return false
  end if
  dim as LiveUpdate ptr update = new LiveUpdate
  update->hasValue = true
  update->value = value
  update->logs = JsonNew(JSON_ARRAY)
  update->nextUpdate = 0
  FaultClear(update->fault)
  mutexlock(manager->mutex)
  LiveEnqueueLocked(manager, handle, update)
  mutexunlock(manager->mutex)
  return true
end function

function LiveNewManagerForTest(byref deploymentUrl as string) as LiveManager ptr
  dim as ConvexUrl target
  dim as ConvexFault fault
  FaultClear(fault)
  if not ParseDeploymentUrl(deploymentUrl, target, fault) then
    return 0
  end if
  return LiveNewManager(target)
end function

sub LiveFreeManagerForTest(byval manager as LiveManager ptr)
  LiveDestroyManager(manager)
end sub

function LiveAddSubscriptionForTest( _
    byval manager as LiveManager ptr, _
    byref path as string) as LiveSubscription ptr
  dim as LiveSubscription ptr handle = new LiveSubscription
  handle->path = path
  handle->argsJson = "{}"
  handle->active = true
  handle->addPending = false
  handle->addDone = true
  handle->removePending = false
  handle->removeDone = false
  handle->rehydrating = false
  handle->hasLastValue = false
  handle->head = 0
  handle->tail = 0
  handle->queued = 0
  handle->nextSubscription = 0
  mutexlock(manager->mutex)
  handle->queryId = manager->nextQueryId
  manager->nextQueryId += 1
  if manager->subscriptions = 0 then
    manager->subscriptions = handle
  else
    dim as LiveSubscription ptr tail = manager->subscriptions
    while tail->nextSubscription <> 0
      tail = tail->nextSubscription
    wend
    tail->nextSubscription = handle
  end if
  mutexunlock(manager->mutex)
  return handle
end function

function LiveQueuedBytes(byval manager as LiveManager ptr) as uinteger
  mutexlock(manager->mutex)
  dim as uinteger total = manager->queuedBytes
  mutexunlock(manager->mutex)
  return total
end function

function LiveTakeForTest( _
    byval manager as LiveManager ptr, _
    byval handle as LiveSubscription ptr) as LiveUpdate ptr
  mutexlock(manager->mutex)
  dim as LiveUpdate ptr update = handle->head
  if update <> 0 then
    handle->head = update->nextUpdate
    if handle->head = 0 then
      handle->tail = 0
    end if
    handle->queued -= 1
    manager->queuedBytes -= update->retainedBytes
    update->nextUpdate = 0
  end if
  mutexunlock(manager->mutex)
  return update
end function

sub LiveUnsubscribeForTest( _
    byval manager as LiveManager ptr, _
    byval handle as LiveSubscription ptr)
  mutexlock(manager->mutex)
  handle->removePending = true
  LiveClearQueueLocked(manager, handle)
  mutexunlock(manager->mutex)
end sub

sub LiveMarkRehydratingForTest(byval handle as LiveSubscription ptr)
  ' Stand in for what a real reconnect does to the subscription, so the
  ' suppression rule can be proved without a socket.
  handle->rehydrating = handle->hasLastValue
end sub
#endif
