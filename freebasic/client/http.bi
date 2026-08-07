' A bounded HTTP/1.1 client for Convex's documented JSON endpoints.
'
' The response reader is incremental and separate from the socket so the
' adversarial tests can feed it one byte at a time and prove that a split
' status line, a split header, or a split chunk cannot desynchronise it.

#pragma once

#include once "core.bi"
#include once "net.bi"

const HTTP_MAX_HEADER_BYTES = 65536
const HTTP_MAX_HEADER_COUNT = 100
const HTTP_MAX_BODY_BYTES = 2097152
const HTTP_MAX_CHUNK_LINE = 64

const HTTP_NEED_MORE = 0
const HTTP_DONE = 1
const HTTP_FAILED = -1

const HTTP_STATE_STATUS = 0
const HTTP_STATE_HEADERS = 1
const HTTP_STATE_BODY_LENGTH = 2
const HTTP_STATE_BODY_CHUNK_SIZE = 3
const HTTP_STATE_BODY_CHUNK_DATA = 4
const HTTP_STATE_BODY_CHUNK_CRLF = 5
const HTTP_STATE_TRAILERS = 6
const HTTP_STATE_BODY_EOF = 7
const HTTP_STATE_DONE = 8

type ConvexUrl
  host as string
  port as long
  useTls as boolean
  origin as string
end type

type HttpReader
  buffer as StrBuf
  cursor as uinteger
  state as long
  status as long
  headerBytes as uinteger
  headerCount as long
  hasContentLength as boolean
  contentLength as ulongint
  hasTransferEncoding as boolean
  chunked as boolean
  chunkRemaining as ulongint
  body as StrBuf
  reason as string
end type

declare function ParseDeploymentUrl( _
  byref raw as string, _
  byref parsed as ConvexUrl, _
  byref fault as ConvexFault) as boolean
declare sub HttpReaderReset(byref reader as HttpReader)
declare function HttpReaderFeed(byref reader as HttpReader, byref chunk as string) as long
' Signals that the peer closed cleanly. A response framed only by connection
' close is complete here; anything mid-frame is a truncated response.
declare function HttpReaderFinish(byref reader as HttpReader) as long
declare function HttpPostJson( _
  byref target as ConvexUrl, _
  byref path as string, _
  byref payload as string, _
  byref bearer as string, _
  byval timeoutMs as long, _
  byref status as long, _
  byref responseBody as string, _
  byref fault as ConvexFault) as boolean
declare function IsSafeHeaderValue(byref value as string) as boolean
