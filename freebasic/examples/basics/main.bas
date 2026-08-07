' Convex from FreeBASIC: one room, counted from 0 to 1.
'
' The journey is deliberately small. Read the counter over HTTP, start a Live
' subscription before changing anything, apply one idempotent mutation, and
' only claim success once HTTP and Live agree.

#include once "convex.bi"

' Diagnostics go to stderr because stdout is the transcript the shared
' verifier compares line for line.
sub Fail(byref message as string)
  dim as integer handle = freefile
  open err for output as #handle
  print #handle, "convex example failed: " & message
  close #handle
  end 1
end sub

' Convex may spell a whole counter as 1 or as 1.0. Accept both, and reject a
' fraction, a quoted number, or anything out of range, so a wrong shape fails
' the example instead of quietly reading as zero.
function CounterFrom(byval state as JsonValue ptr, byref operation as string) as longint
  dim as longint counted
  if not JsonWholeNumber(JsonMember(state, "count"), counted) orelse counted < 0 then
    Fail(operation & " did not return a whole nonnegative count")
  end if
  return counted
end function

' The shared verifier passes a unique room as the first argument; the default
' only exists so the image is pleasant to run by hand.
dim as string room = command(1)
if len(room) = 0 then
  room = "freebasic-basic-example"
end if

' The deployment to talk to. Never a hardcoded URL, so the same binary can be
' pointed at the local backend or the hosted drift target.
dim as string deploymentUrl = environ("CONVEX_URL")
if len(deploymentUrl) = 0 then
  Fail("CONVEX_URL is required")
end if

' Create the native FreeBASIC client. Nothing has touched the network yet.
dim as ConvexClient client
dim as ConvexFault fault
FaultClear(fault)
if not ConvexOpen(client, deploymentUrl, fault) then
  Fail(fault.message)
end if

' Every Convex call takes a JSON object of named arguments.
dim as JsonValue ptr roomArgs = JsonNew(JSON_OBJECT)
JsonSet(roomArgs, "room", JsonNewString(room))

' Read the current counter over Convex's documented HTTP query endpoint.
dim as ConvexResult current
ConvexResultInit(current)
if not ConvexQuery(client, "demo:state", roomArgs, current, fault) then
  Fail(fault.message)
end if
dim as longint before = CounterFrom(current.value, "the HTTP query")
if before <> 0 then
  Fail("expected a fresh room to start at zero")
end if
ConvexResultFree(current)
print "current count: 0"

' Start Live before mutating. Subscribing first is what makes the later update
' evidence of a reactive WebSocket rather than a second HTTP read.
dim as LiveSubscription ptr live = ConvexSubscribe(client, "demo:state", roomArgs, fault)
if live = 0 then
  Fail(fault.message)
end if

' The first Live delivery is the current value, so it must agree with HTTP.
dim as LiveUpdate ptr initial = ConvexNext(client, live, 10000)
if initial = 0 orelse (not initial->hasValue) then
  Fail("the initial Live value did not arrive")
end if
if CounterFrom(initial->value, "the initial Live value") <> before then
  Fail("the initial Live value disagreed with the HTTP query")
end if
LiveUpdateFree(initial)
print "live initial count: 0"

' Increment once. runId is the idempotency key: because the room is unique to
' this run, a retry after a lost response still counts exactly one increment.
dim as JsonValue ptr incrementArgs = JsonNew(JSON_OBJECT)
JsonSet(incrementArgs, "room", JsonNewString(room))
JsonSet(incrementArgs, "language", JsonNewString("FreeBASIC"))
JsonSet(incrementArgs, "runId", JsonNewString(room & "-once"))

dim as ConvexResult mutated
ConvexResultInit(mutated)
if not ConvexMutation(client, "demo:increment", incrementArgs, mutated, fault) then
  Fail(fault.message)
end if
dim as JsonValue ptr applied = JsonMember(mutated.value, "applied")
if applied = 0 orelse applied->kind <> JSON_BOOL orelse (not applied->boolValue) then
  Fail("the mutation was not applied")
end if
dim as longint after = CounterFrom(JsonMember(mutated.value, "state"), "the mutation")
if after <> before + 1 then
  Fail("the mutation did not increment exactly once")
end if
ConvexResultFree(mutated)
print "mutation applied: true"
print "mutation count: 1"

' The mutation should now arrive over the same Live subscription.
dim as LiveUpdate ptr updated = ConvexNext(client, live, 10000)
if updated = 0 orelse (not updated->hasValue) then
  Fail("the Live update did not arrive")
end if
if CounterFrom(updated->value, "the Live update") <> after then
  Fail("the Live update disagreed with the mutation")
end if
LiveUpdateFree(updated)
print "live updated count: 1"

' Release the subscription, then the client and its Live owner thread.
ConvexUnsubscribe(client, live, 2000)
JsonFree(roomArgs)
JsonFree(incrementArgs)
ConvexClose(client, 3000)

' Only claim the journey once HTTP and Live have agreed on every step.
print "verified count: 0 -> 1"
