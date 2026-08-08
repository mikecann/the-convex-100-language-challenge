' RFC 6455 client framing for the Convex sync socket.
'
' The opening handshake, masking, fragmentation, control frames, and the
' closing handshake are all implemented here. Frame decoding is a pure
' function of the byte buffer, so the tests can drive it with hand-built
' frames, split reads, and deliberately malformed headers without a peer.

#pragma once

#include once "core.bi"
#include once "net.bi"
#include once "http.bi"

const WS_OP_CONTINUATION = 0
const WS_OP_TEXT = 1
const WS_OP_BINARY = 2
const WS_OP_CLOSE = 8
const WS_OP_PING = 9
const WS_OP_PONG = 10

const WS_MAX_MESSAGE_BYTES = 2097152
' The residue never needs to exceed one maximum frame plus its header.
const WS_MAX_BUFFER_BYTES = WS_MAX_MESSAGE_BYTES + 4096
const WS_FRAME_ASSEMBLY_TIMEOUT_MS = 5000
const WS_MESSAGE_ASSEMBLY_TIMEOUT_MS = 10000

' Decoder outcomes. Positive values are progress, negative values retire the
' connection, and the caller distinguishes a protocol violation from a
' transport loss so it can publish the right structured error.
const WS_NEED_MORE = 0
const WS_MESSAGE = 1
const WS_CONTROL = 2
const WS_TRANSPORT_LOST = -1
const WS_PROTOCOL_ERROR = -2

type WsConnection
  stream as ConvexStream
  inbound as StrBuf
  cursor as uinteger
  fragmentActive as boolean
  fragment as StrBuf
  frameDeadline as longint
  messageDeadline as longint
  sawCloseFrame as boolean
end type

declare sub WsReset(byref conn as WsConnection)
declare function WsHandshake( _
  byref conn as WsConnection, _
  byref target as ConvexUrl, _
  byref path as string, _
  byval timeoutMs as long, _
  byref fault as ConvexFault) as boolean
declare function WsSendFrame( _
  byref conn as WsConnection, _
  byval opcode as long, _
  byref payload as string, _
  byval deadline as longint, _
  byref reason as string) as boolean
declare function WsSendText( _
  byref conn as WsConnection, _
  byref payload as string, _
  byval deadline as longint, _
  byref reason as string) as boolean
' Decode whatever is already buffered. Never performs I/O except the Pong and
' Close replies RFC 6455 requires, which use the same bounded write path.
declare function WsDecode( _
  byref conn as WsConnection, _
  byref message as string, _
  byval deadline as longint, _
  byref reason as string) as long
declare function WsReceive( _
  byref conn as WsConnection, _
  byref message as string, _
  byval deadline as longint, _
  byref reason as string) as long
declare sub WsFeed(byref conn as WsConnection, byref chunk as string)
declare sub WsShutdown(byref conn as WsConnection, byval deadline as longint)
declare function WsBuildFrame( _
  byval opcode as long, _
  byref payload as string, _
  byref mask as string) as string
declare function WsAcceptToken(byref nonceKey as string) as string
' A Connection header is a comma-separated token list, not a substring.
declare function WsHeaderHasToken(byref value as string, byref wanted as string) as boolean
declare function WsValidateHandshake( _
  byref headers as string, _
  byref nonceKey as string, _
  byref reason as string) as boolean
