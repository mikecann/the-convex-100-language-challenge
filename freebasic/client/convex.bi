' The native FreeBASIC Convex client.
'
' HTTP queries, mutations, and actions use Convex's documented JSON endpoints.
' Live queries use the /api/sync WebSocket protocol, implemented here against
' the pinned sync profile recorded in manifest.yaml. TLS, sockets, and the
' CSPRNG come from OpenSSL and libc; every Convex behaviour above them, and
' all of RFC 6455 and the HTTP framing, is written in FreeBASIC.
'
' This is an educational demonstration, not an official Convex SDK.

#pragma once

#include once "core.bi"
#include once "json.bi"
#include once "net.bi"
#include once "http.bi"
#include once "ws.bi"

const CONVEX_CLIENT_VERSION = "freebasic-0.1.0"
const CONVEX_HTTP_TIMEOUT_MS = 15000
const CONVEX_LIVE_DIAL_TIMEOUT_MS = 10000
const CONVEX_LIVE_COMMAND_TIMEOUT_MS = 8000
const CONVEX_LIVE_WRITE_TIMEOUT_MS = 500

' Live delivery is an explicit, bounded mailbox owned by this client rather
' than a runtime queue. A slow consumer drops the oldest updates for its own
' subscription first, and a global byte budget caps every mailbox together.
const CONVEX_LIVE_QUEUE_DEPTH = 16
const CONVEX_LIVE_QUEUE_BYTES = 8388608
const CONVEX_LIVE_MAX_SUBSCRIPTIONS = 16
const CONVEX_LIVE_MAX_LIFETIME_SUBSCRIPTIONS = 4096
const CONVEX_LIVE_MAX_PATH_BYTES = 1024
const CONVEX_LIVE_MAX_ARGS_BYTES = 65536

' The zero sync timestamp: base64 of eight zero bytes.
const CONVEX_INITIAL_TIMESTAMP = "AAAAAAAAAAA="

type ConvexResult
  value as JsonValue ptr
  ' Always a JSON array of strings, so an absent logLines and an empty one are
  ' represented the same way and neither serializes as null.
  logs as JsonValue ptr
end type

type LiveUpdate
  hasValue as boolean
  value as JsonValue ptr
  logs as JsonValue ptr
  fault as ConvexFault
  serial as ulongint
  retainedBytes as uinteger
  nextUpdate as LiveUpdate ptr
end type

type LiveSubscription
  queryId as ulong
  path as string
  argsJson as string
  active as boolean
  addPending as boolean
  addDone as boolean
  removePending as boolean
  removeDone as boolean
  ' Set after a reconnect so an identical rehydrated value is suppressed and
  ' the observable sequence stays initial, disconnect, change.
  rehydrating as boolean
  hasLastValue as boolean
  lastValueJson as string
  head as LiveUpdate ptr
  tail as LiveUpdate ptr
  queued as long
  nextSubscription as LiveSubscription ptr
end type

type LiveManager
  mutex as any ptr
  worker as any ptr
  subscriptions as LiveSubscription ptr
  nextQueryId as ulong
  querySetVersion as ulong
  remoteQuerySet as ulong
  remoteIdentity as ulong
  remoteTimestamp as ulongint
  remoteTimestampEncoded as string
  hasMaxTimestamp as boolean
  maxTimestamp as ulongint
  maxTimestampEncoded as string
  connectionCount as ulong
  lastCloseReason as string
  closing as boolean
  stopped as boolean
  connected as boolean
  debugRequested as boolean
  debugGeneration as ulongint
  debugCompleted as ulongint
  updateSerial as ulongint
  queuedBytes as uinteger
  sessionId as string
  target as ConvexUrl
  conn as WsConnection
end type

type ConvexClient
  target as ConvexUrl
  token as string
  closed as boolean
  mutex as any ptr
  live as LiveManager ptr
end type

declare function ConvexOpen( _
  byref client as ConvexClient, _
  byref deploymentUrl as string, _
  byref fault as ConvexFault) as boolean
declare sub ConvexSetAuth(byref client as ConvexClient, byref token as string)
declare function ConvexQuery( _
  byref client as ConvexClient, _
  byref path as string, _
  byval args as JsonValue ptr, _
  byref result as ConvexResult, _
  byref fault as ConvexFault) as boolean
declare function ConvexMutation( _
  byref client as ConvexClient, _
  byref path as string, _
  byval args as JsonValue ptr, _
  byref result as ConvexResult, _
  byref fault as ConvexFault) as boolean
declare function ConvexAction( _
  byref client as ConvexClient, _
  byref path as string, _
  byval args as JsonValue ptr, _
  byref result as ConvexResult, _
  byref fault as ConvexFault) as boolean
declare function ConvexSubscribe( _
  byref client as ConvexClient, _
  byref path as string, _
  byval args as JsonValue ptr, _
  byref fault as ConvexFault) as LiveSubscription ptr
' Returns the next queued update, or null when the deadline expires or the
' subscription has ended. The caller owns the returned update.
declare function ConvexNext( _
  byref client as ConvexClient, _
  byval handle as LiveSubscription ptr, _
  byval timeoutMs as long) as LiveUpdate ptr
declare sub ConvexUnsubscribe( _
  byref client as ConvexClient, _
  byval handle as LiveSubscription ptr, _
  byval timeoutMs as long)
declare sub ConvexClose(byref client as ConvexClient, byval timeoutMs as long)

declare sub ConvexResultInit(byref result as ConvexResult)
declare sub ConvexResultFree(byref result as ConvexResult)
declare sub LiveUpdateFree(byval update as LiveUpdate ptr)

' Decoding is separate from transport so success, structured function errors,
' malformed envelopes, and log lines can all be proved without a network.
declare function DecodeEnvelope( _
  byval httpStatus as long, _
  byref body as string, _
  byref result as ConvexResult, _
  byref fault as ConvexFault) as boolean
declare function DecodeSyncTimestamp( _
  byref encoded as string, _
  byref value as ulongint) as boolean

#ifdef CONVEX_ADAPTER
' Test-only fault injection for the shared conformance controller. It is
' compiled out of the educational client and the canonical example.
declare function ConvexDebugDisconnect( _
  byref client as ConvexClient, _
  byval timeoutMs as long, _
  byref fault as ConvexFault) as boolean
declare function LiveApplyTransition( _
  byval manager as LiveManager ptr, _
  byref text as string, _
  byref reason as string) as boolean
declare function LiveEnqueueForTest( _
  byval manager as LiveManager ptr, _
  byval handle as LiveSubscription ptr, _
  byref valueJson as string) as boolean
declare function LiveNewManagerForTest(byref deploymentUrl as string) as LiveManager ptr
declare sub LiveFreeManagerForTest(byval manager as LiveManager ptr)
declare function LiveAddSubscriptionForTest( _
  byval manager as LiveManager ptr, _
  byref path as string) as LiveSubscription ptr
declare function LiveQueuedBytes(byval manager as LiveManager ptr) as uinteger
declare function LiveTakeForTest( _
  byval manager as LiveManager ptr, _
  byval handle as LiveSubscription ptr) as LiveUpdate ptr
declare sub LiveUnsubscribeForTest( _
  byval manager as LiveManager ptr, _
  byval handle as LiveSubscription ptr)
declare sub LiveMarkRehydratingForTest(byval handle as LiveSubscription ptr)
#endif
