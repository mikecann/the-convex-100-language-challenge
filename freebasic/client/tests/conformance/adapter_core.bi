' Test-only NDJSON adapter protocol v1 for the shared conformance controller.
'
' This is test infrastructure, not public client code. It calls the real
' FreeBASIC client for every operation. One output gate owns subscription
' generations and every physical write, so an event dequeued before an
' unsubscribe or replacement cannot cross that acknowledgement.

#pragma once

#include once "convex.bi"

const ADAPTER_LANGUAGE = "freebasic"
const ADAPTER_IMPLEMENTATION = "native-freebasic-0.1.0"
const ADAPTER_MAX_SUBSCRIPTIONS = 16
const ADAPTER_MAX_ID_CODEPOINTS = 128
const ADAPTER_MAX_INPUT_LINE = 2097152
const ADAPTER_MAX_OUTPUT_LINE = 3145728
const ADAPTER_OUTPUT_DEADLINE_MS = 1000
const ADAPTER_SUBSCRIBE_TIMEOUT_MS = 8000
const ADAPTER_ACCEPT_TIMEOUT_MS = 30000

type AdapterRelay
  used as boolean
  subscriptionId as string
  ' Bumped under the output gate whenever a subscription is replaced, removed,
  ' or the adapter closes. A relay may only publish at its own generation.
  generation as ulongint
  handle as LiveSubscription ptr
  worker as any ptr
  stopping as boolean
  slot as long
end type

' The gate is the only writer. Everything else hands it a complete line.
type OutputGate
  mutex as any ptr
  fd as long
  closed as boolean
  failed as boolean
end type

declare function AdapterRun(byval inputFd as long, byval outputFd as long) as long
declare function AdapterMain() as long

' Pure serializers, exposed so the unit tests can prove the exact wire shape,
' including that absent fields are omitted rather than sent as null.
declare function RenderReady(byref id as string, byref runtime as string) as string
declare function RenderResult( _
  byref id as string, _
  byval value as JsonValue ptr, _
  byval logs as JsonValue ptr) as string
declare function RenderError(byref id as string, byref fault as ConvexFault) as string
declare function RenderAck(byref id as string) as string
declare function RenderClosed(byref id as string) as string
declare function RenderSubscriptionValue( _
  byref subscriptionId as string, _
  byval value as JsonValue ptr, _
  byval logs as JsonValue ptr) as string
declare function RenderSubscriptionError( _
  byref subscriptionId as string, _
  byref fault as ConvexFault) as string
declare function AdapterRuntimeName() as string
declare function ValidCommandId(byref id as string) as boolean
declare function CommandShapeValid( _
  byval commandValue as JsonValue ptr, _
  byref operation as string, _
  byref reason as string) as boolean
declare function AdapterBeginGenerationFixture() as ulongint
declare sub AdapterInvalidateGenerationFixture()
declare function AdapterGenerationCurrentForTest(byval generation as ulongint) as boolean
