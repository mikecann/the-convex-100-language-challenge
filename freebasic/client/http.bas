' Bounded HTTP/1.1 client implementation.

#include once "http.bi"

' Sent as Convex-Client so a deployment log can attribute traffic to this
' educational demonstration rather than an official SDK.
const CONVEX_CLIENT_HEADER = "freebasic-0.1.0"

' A header value that could contain CR or LF would let a caller-supplied bearer
' token inject an extra request line.
function IsSafeHeaderValue(byref value as string) as boolean
  for index as integer = 0 to len(value) - 1
    dim as ubyte octet = value[index]
    if octet < 32 orelse octet = 127 then
      return false
    end if
  next
  return true
end function

function ParseDeploymentUrl( _
    byref raw as string, _
    byref parsed as ConvexUrl, _
    byref fault as ConvexFault) as boolean
  dim as string trimmed = AsciiTrim(raw)
  while len(trimmed) > 0 andalso trimmed[len(trimmed) - 1] = asc("/")
    trimmed = left(trimmed, len(trimmed) - 1)
  wend
  dim as string lowered = AsciiLower(trimmed)
  parsed.useTls = false
  dim as string rest
  if left(lowered, 8) = "https://" then
    parsed.useTls = true
    parsed.port = 443
    rest = mid(trimmed, 9)
  elseif left(lowered, 7) = "http://" then
    parsed.port = 80
    rest = mid(trimmed, 8)
  else
    FaultSet(fault, FAULT_PROTOCOL, "Convex deployment URL must use http or https")
    return false
  end if

  ' Reject credentials, a path, and a query so a misconfigured URL cannot
  ' silently redirect Convex traffic somewhere else.
  if instr(rest, "@") > 0 then
    FaultSet(fault, FAULT_PROTOCOL, "Convex deployment URL must not carry credentials")
    return false
  end if
  if instr(rest, "/") > 0 orelse instr(rest, "?") > 0 orelse instr(rest, "#") > 0 then
    FaultSet(fault, FAULT_PROTOCOL, "Convex deployment URL must not include a path")
    return false
  end if
  dim as integer colon = instr(rest, ":")
  if colon > 0 then
    dim as ulongint port
    if not DecimalToUlong(mid(rest, colon + 1), port) orelse port = 0 orelse port > 65535 then
      FaultSet(fault, FAULT_PROTOCOL, "Convex deployment URL has an invalid port")
      return false
    end if
    parsed.port = cast(long, port)
    rest = left(rest, colon - 1)
  end if
  if len(rest) = 0 then
    FaultSet(fault, FAULT_PROTOCOL, "Convex deployment URL must include a host")
    return false
  end if
  if not IsSafeHeaderValue(rest) then
    FaultSet(fault, FAULT_PROTOCOL, "Convex deployment host is not a valid header value")
    return false
  end if
  parsed.host = rest
  parsed.origin = trimmed
  return true
end function

sub HttpReaderReset(byref reader as HttpReader)
  reader.buffer.Clear()
  reader.body.Clear()
  reader.cursor = 0
  reader.state = HTTP_STATE_STATUS
  reader.status = 0
  reader.headerBytes = 0
  reader.headerCount = 0
  reader.hasContentLength = false
  reader.contentLength = 0
  reader.hasTransferEncoding = false
  reader.chunked = false
  reader.chunkRemaining = 0
  reader.reason = ""
end sub

private function ReaderFail(byref reader as HttpReader, byref reason as string) as long
  if len(reader.reason) = 0 then
    reader.reason = reason
  end if
  reader.state = HTTP_STATE_DONE
  return HTTP_FAILED
end function

' Take one CRLF terminated line, or report that more bytes are needed. LF
' alone is rejected: a lenient line terminator is how response smuggling
' starts.
private function TakeLine( _
    byref reader as HttpReader, _
    byref textLine as string, _
    byval limit as uinteger, _
    byref found as boolean) as boolean
  found = false
  dim as uinteger scan = reader.cursor
  while scan + 1 < reader.buffer.count
    if reader.buffer.store[scan] = 13 andalso reader.buffer.store[scan + 1] = 10 then
      dim as uinteger length = scan - reader.cursor
      if length > limit then
        return false
      end if
      textLine = reader.buffer.Slice(reader.cursor, length)
      reader.cursor = scan + 2
      found = true
      return true
    end if
    if reader.buffer.store[scan] = 10 then
      return false
    end if
    scan += 1
  wend
  if (reader.buffer.count - reader.cursor) > limit then
    return false
  end if
  return true
end function

private function ParseHexSize(byref text as string, byref value as ulongint) as boolean
  value = 0
  if len(text) = 0 orelse len(text) > 16 then
    return false
  end if
  for index as integer = 0 to len(text) - 1
    dim as ubyte octet = text[index]
    dim as ulongint digit
    select case octet
      case asc("0") to asc("9")
        digit = octet - asc("0")
      case asc("a") to asc("f")
        digit = octet - asc("a") + 10
      case asc("A") to asc("F")
        digit = octet - asc("A") + 10
      case else
        return false
    end select
    value = (value shl 4) or digit
  next
  return true
end function

private function ConsumeStatus(byref reader as HttpReader) as long
  dim as string textLine
  dim as boolean found
  if not TakeLine(reader, textLine, HTTP_MAX_HEADER_BYTES, found) then
    return ReaderFail(reader, "HTTP status line was malformed or oversized")
  end if
  if not found then
    return HTTP_NEED_MORE
  end if
  if left(textLine, 7) <> "HTTP/1." orelse len(textLine) < 12 then
    return ReaderFail(reader, "HTTP response did not start with a 1.x status line")
  end if
  if textLine[8] <> asc(" ") then
    return ReaderFail(reader, "HTTP status line was malformed")
  end if
  dim as ulongint code
  if not DecimalToUlong(mid(textLine, 10, 3), code) orelse code < 100 orelse code > 599 then
    return ReaderFail(reader, "HTTP status code was not in range")
  end if
  ' Anything after the code must be a space delimited reason phrase.
  if len(textLine) > 12 andalso textLine[12] <> asc(" ") then
    return ReaderFail(reader, "HTTP status line was malformed")
  end if
  reader.status = cast(long, code)
  reader.state = HTTP_STATE_HEADERS
  return HTTP_NEED_MORE
end function

private function ConsumeHeaders(byref reader as HttpReader) as long
  do
    dim as string textLine
    dim as boolean found
    if not TakeLine(reader, textLine, HTTP_MAX_HEADER_BYTES, found) then
      return ReaderFail(reader, "HTTP header was malformed or oversized")
    end if
    if not found then
      return HTTP_NEED_MORE
    end if
    if len(textLine) = 0 then
      if reader.chunked then
        reader.state = HTTP_STATE_BODY_CHUNK_SIZE
      elseif reader.hasContentLength then
        reader.state = HTTP_STATE_BODY_LENGTH
      else
        ' No framing header at all: the body runs until the peer closes.
        reader.state = HTTP_STATE_BODY_EOF
      end if
      return HTTP_NEED_MORE
    end if
    reader.headerBytes += culng(len(textLine)) + 2
    reader.headerCount += 1
    if reader.headerBytes > HTTP_MAX_HEADER_BYTES orelse _
       reader.headerCount > HTTP_MAX_HEADER_COUNT then
      return ReaderFail(reader, "HTTP response headers exceeded the bound")
    end if
    dim as integer colon = instr(textLine, ":")
    if colon <= 1 then
      return ReaderFail(reader, "HTTP header was missing a name")
    end if
    dim as string fieldName = AsciiLower(AsciiTrim(left(textLine, colon - 1)))
    dim as string value = AsciiTrim(mid(textLine, colon + 1))
    if fieldName = "content-length" then
      dim as ulongint length
      if not DecimalToUlong(value, length) then
        return ReaderFail(reader, "Content-Length was not a decimal count")
      end if
      ' Even identical duplicates are rejected. Intermediaries disagree about
      ' how repeated framing fields combine, which is enough to make them unsafe.
      if reader.hasContentLength then
        return ReaderFail(reader, "HTTP response repeated Content-Length")
      end if
      if reader.hasTransferEncoding then
        return ReaderFail(reader, "HTTP response mixed Content-Length and Transfer-Encoding")
      end if
      if length > HTTP_MAX_BODY_BYTES then
        return ReaderFail(reader, "HTTP response body exceeds 2 MiB")
      end if
      reader.hasContentLength = true
      reader.contentLength = length
    elseif fieldName = "transfer-encoding" then
      if reader.hasTransferEncoding then
        return ReaderFail(reader, "HTTP response repeated Transfer-Encoding")
      end if
      if reader.hasContentLength then
        return ReaderFail(reader, "HTTP response mixed Content-Length and Transfer-Encoding")
      end if
      if AsciiLower(value) <> "chunked" then
        return ReaderFail(reader, "unsupported Transfer-Encoding")
      end if
      reader.hasTransferEncoding = true
      reader.chunked = true
    end if
  loop
end function

private function AppendBody(byref reader as HttpReader, byref chunk as string) as long
  if reader.body.count + culng(len(chunk)) > HTTP_MAX_BODY_BYTES then
    return ReaderFail(reader, "HTTP response body exceeds 2 MiB")
  end if
  reader.body.Append(chunk)
  return HTTP_NEED_MORE
end function

function HttpReaderFeed(byref reader as HttpReader, byref chunk as string) as long
  ' Locals are hoisted so every state shares one scope and the reader stays a
  ' plain loop over an explicit state machine.
  dim as long stepResult
  dim as string textLine
  dim as boolean found
  dim as uinteger available
  dim as uinteger take
  dim as string slice
  dim as ulongint outstanding
  dim as ulongint size
  dim as integer marker

  if reader.state = HTTP_STATE_DONE then
    if len(reader.reason) > 0 then
      return HTTP_FAILED
    end if
    return HTTP_DONE
  end if
  if len(chunk) > 0 then
    ' The header and framing bounds guard total memory; the raw buffer only
    ' holds the unparsed residue plus the newest read.
    if reader.buffer.count + culngint(len(chunk)) > HTTP_MAX_HEADER_BYTES + 262144 then
      return ReaderFail(reader, "HTTP response outran the read buffer")
    end if
    reader.buffer.Append(chunk)
  end if

  do
    select case reader.state
      case HTTP_STATE_STATUS
        stepResult = ConsumeStatus(reader)
        if stepResult <> HTTP_NEED_MORE then
          return stepResult
        end if
        if reader.state = HTTP_STATE_STATUS then
          exit do
        end if

      case HTTP_STATE_HEADERS
        stepResult = ConsumeHeaders(reader)
        if stepResult <> HTTP_NEED_MORE then
          return stepResult
        end if
        if reader.state = HTTP_STATE_HEADERS then
          exit do
        end if

      case HTTP_STATE_BODY_LENGTH
        outstanding = reader.contentLength - reader.body.count
        if outstanding = 0 then
          reader.state = HTTP_STATE_DONE
          return HTTP_DONE
        end if
        available = reader.buffer.count - reader.cursor
        if available = 0 then
          exit do
        end if
        take = available
        if cast(ulongint, take) > outstanding then
          take = cast(uinteger, outstanding)
        end if
        slice = reader.buffer.Slice(reader.cursor, take)
        reader.cursor += take
        if AppendBody(reader, slice) = HTTP_FAILED then
          return HTTP_FAILED
        end if
        if reader.body.count >= reader.contentLength then
          reader.state = HTTP_STATE_DONE
          return HTTP_DONE
        end if

      case HTTP_STATE_BODY_CHUNK_SIZE
        if not TakeLine(reader, textLine, HTTP_MAX_CHUNK_LINE, found) then
          return ReaderFail(reader, "HTTP chunk size line was malformed or oversized")
        end if
        if not found then
          exit do
        end if
        marker = instr(textLine, ";")
        if marker > 0 then
          textLine = left(textLine, marker - 1)
        end if
        if not ParseHexSize(AsciiTrim(textLine), size) then
          return ReaderFail(reader, "HTTP chunk size was not hexadecimal")
        end if
        if size > HTTP_MAX_BODY_BYTES then
          return ReaderFail(reader, "HTTP response body exceeds 2 MiB")
        end if
        reader.chunkRemaining = size
        if size = 0 then
          reader.state = HTTP_STATE_TRAILERS
        else
          reader.state = HTTP_STATE_BODY_CHUNK_DATA
        end if

      case HTTP_STATE_BODY_CHUNK_DATA
        available = reader.buffer.count - reader.cursor
        if available = 0 then
          exit do
        end if
        take = available
        if cast(ulongint, take) > reader.chunkRemaining then
          take = cast(uinteger, reader.chunkRemaining)
        end if
        slice = reader.buffer.Slice(reader.cursor, take)
        reader.cursor += take
        reader.chunkRemaining -= take
        if AppendBody(reader, slice) = HTTP_FAILED then
          return HTTP_FAILED
        end if
        if reader.chunkRemaining = 0 then
          reader.state = HTTP_STATE_BODY_CHUNK_CRLF
        end if

      case HTTP_STATE_BODY_CHUNK_CRLF
        if not TakeLine(reader, textLine, 2, found) then
          return ReaderFail(reader, "HTTP chunk was not terminated by CRLF")
        end if
        if not found then
          exit do
        end if
        if len(textLine) <> 0 then
          return ReaderFail(reader, "HTTP chunk was not terminated by CRLF")
        end if
        reader.state = HTTP_STATE_BODY_CHUNK_SIZE

      case HTTP_STATE_TRAILERS
        if not TakeLine(reader, textLine, HTTP_MAX_HEADER_BYTES, found) then
          return ReaderFail(reader, "HTTP trailer was malformed or oversized")
        end if
        if not found then
          exit do
        end if
        if len(textLine) = 0 then
          reader.state = HTTP_STATE_DONE
          return HTTP_DONE
        end if
        if instr(textLine, ":") <= 1 then
          return ReaderFail(reader, "HTTP trailer was missing a name")
        end if
        reader.headerBytes += culngint(len(textLine)) + 2
        if reader.headerBytes > HTTP_MAX_HEADER_BYTES then
          return ReaderFail(reader, "HTTP response headers exceeded the bound")
        end if

      case HTTP_STATE_BODY_EOF
        available = reader.buffer.count - reader.cursor
        if available = 0 then
          exit do
        end if
        slice = reader.buffer.Slice(reader.cursor, available)
        reader.cursor += available
        if AppendBody(reader, slice) = HTTP_FAILED then
          return HTTP_FAILED
        end if

      case else
        exit do
    end select
  loop

  ' Reclaim the consumed prefix so a long chunked response does not grow the
  ' raw buffer without bound.
  if reader.cursor > 0 then
    reader.buffer.DropFront(reader.cursor)
    reader.cursor = 0
  end if
  return HTTP_NEED_MORE
end function

function HttpReaderFinish(byref reader as HttpReader) as long
  select case reader.state
    case HTTP_STATE_DONE
      if len(reader.reason) > 0 then
        return HTTP_FAILED
      end if
      return HTTP_DONE
    case HTTP_STATE_BODY_EOF
      reader.state = HTTP_STATE_DONE
      return HTTP_DONE
    case else
      return ReaderFail(reader, "HTTP response was truncated")
  end select
end function

function HttpPostJson( _
    byref target as ConvexUrl, _
    byref path as string, _
    byref payload as string, _
    byref bearer as string, _
    byval timeoutMs as long, _
    byref status as long, _
    byref responseBody as string, _
    byref fault as ConvexFault) as boolean
  status = 0
  responseBody = ""
  if not IsSafeHeaderValue(bearer) then
    FaultSet(fault, FAULT_PROTOCOL, "bearer token must not contain control characters")
    return false
  end if
  if len(payload) > HTTP_MAX_BODY_BYTES then
    FaultSet(fault, FAULT_PROTOCOL, "Convex request body exceeds 2 MiB")
    return false
  end if

  dim as string hostHeader = target.host
  if (target.useTls andalso target.port <> 443) orelse _
     ((not target.useTls) andalso target.port <> 80) then
    hostHeader &= ":" & FormatInteger(target.port)
  end if

  dim as StrBuf request
  request.Append("POST " & path & " HTTP/1.1" & chr(13, 10))
  request.Append("Host: " & hostHeader & chr(13, 10))
  request.Append("Accept: application/json" & chr(13, 10))
  request.Append("Content-Type: application/json" & chr(13, 10))
  request.Append("Convex-Client: " & CONVEX_CLIENT_HEADER & chr(13, 10))
  if len(bearer) > 0 then
    request.Append("Authorization: Bearer " & bearer & chr(13, 10))
  end if
  request.Append("Content-Length: " & FormatInteger(len(payload)) & chr(13, 10))
  ' One request per connection keeps framing unambiguous; there is no keep
  ' alive pool to leak a response into the next call.
  request.Append("Connection: close" & chr(13, 10))
  request.Append(chr(13, 10))
  request.Append(payload)

  ' One absolute deadline covers connect, TLS, request write, and response read.
  ' Starting a fresh timeout after connect would silently double the API bound.
  dim as longint deadline = MonotonicMs() + timeoutMs
  dim as ConvexStream stream
  StreamReset(stream)
  dim as long remaining = cast(long, deadline - MonotonicMs())
  if remaining <= 0 then
    FaultSet(fault, FAULT_TRANSPORT, "Convex request timed out")
    return false
  end if
  if not StreamConnect(stream, target.host, target.port, target.useTls, remaining, fault) then
    return false
  end if

  dim as string wire = request.Take()
  dim as string reason
  if not StreamWriteAll(stream, wire, deadline, reason) then
    FaultSet(fault, FAULT_TRANSPORT, "could not send the Convex request: " & reason)
    StreamClose(stream)
    return false
  end if

  dim as HttpReader reader
  HttpReaderReset(reader)
  dim as string scratch = space(16384)
  do
    if MonotonicMs() >= deadline then
      FaultSet(fault, FAULT_TRANSPORT, "Convex response timed out")
      StreamClose(stream)
      return false
    end if
    dim as long received = StreamRead( _
      stream, cast(ubyte ptr, strptr(scratch)), 16384, deadline, reason)
    if received > 0 then
      dim as long progress = HttpReaderFeed(reader, left(scratch, received))
      if progress = HTTP_FAILED then
        FaultSet(fault, FAULT_PROTOCOL, reader.reason)
        StreamClose(stream)
        return false
      end if
      if progress = HTTP_DONE then
        exit do
      end if
    elseif received = -2 then
      dim as long progress = HttpReaderFinish(reader)
      if progress <> HTTP_DONE then
        FaultSet(fault, FAULT_PROTOCOL, reader.reason)
        StreamClose(stream)
        return false
      end if
      exit do
    elseif received < 0 then
      FaultSet(fault, FAULT_TRANSPORT, "could not read the Convex response: " & reason)
      StreamClose(stream)
      return false
    end if
  loop

  status = reader.status
  responseBody = reader.body.Take()
  StreamClose(stream)
  return true
end function
