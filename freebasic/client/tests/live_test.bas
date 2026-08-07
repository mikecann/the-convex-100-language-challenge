' Deterministic coverage for the Live sync state machine and the bounded
' delivery mailbox. The manager is driven with hand-written Transition
' messages so the version rules, the structured failure path, the rehydration
' suppression, and the queue bounds are all proved without a network.

#include once "convex.bi"
#include once "testing.bi"

dim as string reason

function VersionAt( _
    byval querySet as long, _
    byval identity as long, _
    byref timestamp as string) as string
  return "{""querySet"":" & FormatInteger(querySet) & ",""identity"":" & _
    FormatInteger(identity) & ",""ts"":""" & timestamp & """}"
end function

function TransitionMessage( _
    byref startVersion as string, _
    byref endVersion as string, _
    byref modifications as string) as string
  return "{""type"":""Transition"",""startVersion"":" & startVersion & _
    ",""endVersion"":" & endVersion & ",""modifications"":" & modifications & "}"
end function

' Base64 of eight little-endian bytes; these are the first few sync positions.
dim as string ts0 = "AAAAAAAAAAA="
dim as string ts1 = "AQAAAAAAAAA="
dim as string ts2 = "AgAAAAAAAAA="

' --- timestamps -----------------------------------------------------------
dim as ulongint decodedTs
Check(DecodeSyncTimestamp(ts0, decodedTs) andalso decodedTs = 0, "the zero sync timestamp")
Check(DecodeSyncTimestamp(ts1, decodedTs) andalso decodedTs = 1, "sync timestamp one")
Check(DecodeSyncTimestamp("/wAAAAAAAAA=", decodedTs) andalso decodedTs = 255, _
  "a sync timestamp is little endian")
Check(not DecodeSyncTimestamp("AQAAAAAAAA==", decodedTs), "a seven byte timestamp is rejected")
Check(not DecodeSyncTimestamp("AAAAAAAAAAB=", decodedTs), _
  "a noncanonical base64 timestamp is rejected")
Check(not DecodeSyncTimestamp("not-base64!!", decodedTs), "a non base64 timestamp is rejected")
Check(not DecodeSyncTimestamp("AAAA", decodedTs), "a short timestamp is rejected")

' --- transitions ----------------------------------------------------------
dim as LiveManager ptr manager = LiveNewManagerForTest("http://127.0.0.1:9")
Check(manager <> 0, "the test manager is created")
dim as LiveSubscription ptr handle = LiveAddSubscriptionForTest(manager, "demo:state")

' A transition whose start version does not match the local position is a
' protocol failure, not something to apply optimistically.
Check(not LiveApplyTransition(manager, TransitionMessage( _
  VersionAt(1, 0, ts1), VersionAt(1, 0, ts2), "[]"), reason), _
  "a mismatched start version is rejected")

Check(LiveApplyTransition(manager, TransitionMessage( _
  VersionAt(0, 0, ts0), VersionAt(1, 0, ts1), _
  "[{""type"":""QueryUpdated"",""queryId"":0,""value"":{""count"":0}}]"), reason), _
  "the first transition applies")
dim as LiveUpdate ptr update = LiveTakeForTest(manager, handle)
Check(update <> 0, "the initial value is delivered")
Check(update->hasValue, "the initial delivery carries a value")
CheckEqual(JsonRender(update->value), "{""count"":0}", "the initial value is exact")
LiveUpdateFree(update)

' A transition that moves the sync position backwards must be refused.
Check(not LiveApplyTransition(manager, TransitionMessage( _
  VersionAt(1, 0, ts1), VersionAt(1, 0, ts0), "[]"), reason), _
  "an end version that moves backwards is rejected")

Check(LiveApplyTransition(manager, TransitionMessage( _
  VersionAt(1, 0, ts1), VersionAt(1, 0, ts2), _
  "[{""type"":""QueryUpdated"",""queryId"":0,""value"":{""count"":1}," & _
  """logLines"":[""hello""]}]"), reason), "an external update applies")
update = LiveTakeForTest(manager, handle)
Check(update <> 0 andalso update->hasValue, "the external update is delivered")
CheckEqual(JsonRender(update->value), "{""count"":1}", "the updated value is exact")
CheckEqual(JsonRender(update->logs), "[""hello""]", "log lines travel with the update")
LiveUpdateFree(update)

' Malformed modifications are rejected before anything is committed.
Check(not LiveApplyTransition(manager, TransitionMessage( _
  VersionAt(1, 0, ts2), VersionAt(2, 0, ts2), _
  "[{""type"":""QueryUpdated"",""queryId"":0}]"), reason), _
  "QueryUpdated without a value is rejected")
Check(not LiveApplyTransition(manager, TransitionMessage( _
  VersionAt(1, 0, ts2), VersionAt(2, 0, ts2), _
  "[{""type"":""QueryFailed"",""queryId"":0}]"), reason), _
  "QueryFailed without an errorMessage is rejected")
Check(not LiveApplyTransition(manager, TransitionMessage( _
  VersionAt(1, 0, ts2), VersionAt(2, 0, ts2), _
  "[{""type"":""QueryInvented"",""queryId"":0}]"), reason), _
  "an unknown modification type is rejected")
Check(not LiveApplyTransition(manager, TransitionMessage( _
  VersionAt(1, 0, ts2), VersionAt(2, 0, ts2), _
  "[{""type"":""QueryUpdated"",""queryId"":0,""value"":1,""logLines"":""oops""}]"), reason), _
  "non array logLines are rejected")
Check(not LiveApplyTransition(manager, TransitionMessage( _
  VersionAt(1, 0, ts2), VersionAt(2, 0, ts2), _
  "[{""type"":""QueryUpdated"",""queryId"":0,""value"":1,""logLines"":[""ok"",7]}]"), _
  reason), "non-string entries in logLines are rejected")
Check(LiveTakeForTest(manager, handle) = 0, _
  "a rejected transition delivers nothing")

' A structured query failure stays structured all the way to the mailbox.
Check(LiveApplyTransition(manager, TransitionMessage( _
  VersionAt(1, 0, ts2), VersionAt(2, 0, ts2), _
  "[{""type"":""QueryFailed"",""queryId"":0,""errorMessage"":""room is empty""," & _
  """errorData"":{""code"":""ROOM_EMPTY""}}]"), reason), "a query failure applies")
update = LiveTakeForTest(manager, handle)
Check(update <> 0 andalso (not update->hasValue), "the failure has no value")
CheckEqual(update->fault.kind, FAULT_FUNCTION, "a query failure is a FunctionError")
CheckEqual(update->fault.message, "room is empty", "the failure message is carried through")
Check(update->fault.hasData, "the failure carries errorData")
CheckEqual(update->fault.dataJson, "{""code"":""ROOM_EMPTY""}", "errorData is verbatim")
LiveUpdateFree(update)

' Recovery on the same subscription after a failure.
Check(LiveApplyTransition(manager, TransitionMessage( _
  VersionAt(2, 0, ts2), VersionAt(2, 0, "AwAAAAAAAAA="), _
  "[{""type"":""QueryUpdated"",""queryId"":0,""value"":{""count"":1}}]"), reason), _
  "the same subscription recovers after a failure")
update = LiveTakeForTest(manager, handle)
Check(update <> 0 andalso update->hasValue, "the repaired value is delivered")
LiveUpdateFree(update)

' A QueryRemoved modification is applied to the version but delivers nothing.
Check(LiveApplyTransition(manager, TransitionMessage( _
  VersionAt(2, 0, "AwAAAAAAAAA="), VersionAt(3, 0, "AwAAAAAAAAA="), _
  "[{""type"":""QueryRemoved"",""queryId"":0}]"), reason), "QueryRemoved applies")
Check(LiveTakeForTest(manager, handle) = 0, "QueryRemoved delivers nothing")

LiveFreeManagerForTest(manager)

' When one Transition mentions a query more than once, only its final state is
' observable. Delivering both would expose an intermediate server state.
manager = LiveNewManagerForTest("http://127.0.0.1:9")
handle = LiveAddSubscriptionForTest(manager, "demo:state")
Check(LiveApplyTransition(manager, TransitionMessage( _
  VersionAt(0, 0, ts0), VersionAt(1, 0, ts1), _
  "[{""type"":""QueryUpdated"",""queryId"":0,""value"":{""count"":0}}," & _
  "{""type"":""QueryUpdated"",""queryId"":0,""value"":{""count"":1}}]"), reason), _
  "duplicate modifications apply with last-write-wins semantics")
update = LiveTakeForTest(manager, handle)
Check(update <> 0 andalso JsonRender(update->value) = "{""count"":1}", _
  "only the final modification is delivered")
LiveUpdateFree(update)
Check(LiveTakeForTest(manager, handle) = 0, "the superseded value is never queued")
LiveFreeManagerForTest(manager)

' --- rehydration suppression ---------------------------------------------
manager = LiveNewManagerForTest("http://127.0.0.1:9")
handle = LiveAddSubscriptionForTest(manager, "demo:state")
Check(LiveApplyTransition(manager, TransitionMessage( _
  VersionAt(0, 0, ts0), VersionAt(1, 0, ts1), _
  "[{""type"":""QueryUpdated"",""queryId"":0,""value"":{""count"":0}}]"), reason), _
  "the pre-disconnect value applies")
update = LiveTakeForTest(manager, handle)
Check(update <> 0, "the pre-disconnect value is delivered once")
LiveUpdateFree(update)

' After a reconnect the server replays the current value. An identical replay
' is not an observable change, so the sequence stays initial then change.
LiveMarkRehydratingForTest(handle)
Check(LiveApplyTransition(manager, TransitionMessage( _
  VersionAt(1, 0, ts1), VersionAt(1, 0, ts1), _
  "[{""type"":""QueryUpdated"",""queryId"":0,""value"":{""count"":0}}]"), reason), _
  "the rehydrated transition applies")
Check(LiveTakeForTest(manager, handle) = 0, "an unchanged rehydration is suppressed")

LiveMarkRehydratingForTest(handle)
Check(LiveApplyTransition(manager, TransitionMessage( _
  VersionAt(1, 0, ts1), VersionAt(1, 0, ts2), _
  "[{""type"":""QueryUpdated"",""queryId"":0,""value"":{""count"":1}}]"), reason), _
  "a changed rehydration applies")
update = LiveTakeForTest(manager, handle)
Check(update <> 0 andalso update->hasValue, "a changed rehydration is delivered")
CheckEqual(JsonRender(update->value), "{""count"":1}", "the changed rehydration value is exact")
LiveUpdateFree(update)
LiveFreeManagerForTest(manager)

' --- bounded delivery -----------------------------------------------------
manager = LiveNewManagerForTest("http://127.0.0.1:9")
dim as LiveSubscription ptr slow = LiveAddSubscriptionForTest(manager, "demo:state")
dim as LiveSubscription ptr other = LiveAddSubscriptionForTest(manager, "demo:state")

' A consumer that never reads must not grow the mailbox without bound. The
' oldest updates for that subscription are dropped first.
dim as boolean queuedAll = true
for index as integer = 0 to 99
  if not LiveEnqueueForTest(manager, slow, FormatInteger(index)) then
    queuedAll = false
  end if
next
Check(queuedAll, "every update was accepted by the mailbox")
Check(slow->queued = CONVEX_LIVE_QUEUE_DEPTH, "the mailbox stops at its depth bound")
update = LiveTakeForTest(manager, slow)
Check(update <> 0, "the bounded mailbox still delivers")
CheckEqual(JsonRender(update->value), FormatInteger(100 - CONVEX_LIVE_QUEUE_DEPTH), _
  "the oldest updates were dropped, not the newest")
LiveUpdateFree(update)

' A count bound is not a memory bound when one value approaches the maximum
' frame size, so the global byte budget is enforced as well.
dim as string large = """" & string(1048576, "x") & """"
for index as integer = 0 to 19
  if (index mod 2) = 0 then
    LiveEnqueueForTest(manager, slow, large)
  else
    LiveEnqueueForTest(manager, other, large)
  end if
next
Check(LiveQueuedBytes(manager) <= CONVEX_LIVE_QUEUE_BYTES, _
  "the global delivery budget is never exceeded")

' Unsubscribe invalidates the mailbox immediately.
LiveUnsubscribeForTest(manager, slow)
Check(slow->queued = 0, "unsubscribe clears the mailbox")
Check(LiveTakeForTest(manager, slow) = 0, "no stale event survives an unsubscribe")
LiveFreeManagerForTest(manager)

end TestSummary("freebasic live")
