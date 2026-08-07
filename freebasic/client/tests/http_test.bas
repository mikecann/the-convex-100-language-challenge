' Adversarial coverage for URL parsing, the incremental HTTP/1.1 reader, and
' the Convex envelope policy. The reader is fed one byte at a time so a split
' status line, header, or chunk cannot desynchronise it, and the smuggling
' shapes are rejected outright rather than guessed at.

#include once "http.bi"
#include once "convex.bi"
#include once "testing.bi"

' Feed a whole response one byte at a time. Any parser that only works on
' whole reads fails here.
function FeedByteByByte( _
    byref reader as HttpReader, _
    byref wire as string) as long
  HttpReaderReset(reader)
  dim as long outcome = HTTP_NEED_MORE
  for index as integer = 0 to len(wire) - 1
    outcome = HttpReaderFeed(reader, mid(wire, index + 1, 1))
    if outcome <> HTTP_NEED_MORE then
      return outcome
    end if
  next
  return outcome
end function

function FeedWhole(byref reader as HttpReader, byref wire as string) as long
  HttpReaderReset(reader)
  return HttpReaderFeed(reader, wire)
end function

dim as HttpReader reader
dim as ConvexUrl target
dim as ConvexFault fault
dim as string crlf = chr(13, 10)

' --- deployment URLs ------------------------------------------------------
FaultClear(fault)
Check(ParseDeploymentUrl("http://backend:3210", target, fault), "a plain http URL parses")
CheckEqual(target.host, "backend", "the host is extracted")
Check(target.port = 3210, "an explicit port is used")
Check(not target.useTls, "http does not enable TLS")

FaultClear(fault)
Check(ParseDeploymentUrl("https://example.convex.cloud/", target, fault), _
  "a trailing slash is tolerated")
Check(target.port = 443, "https defaults to port 443")
Check(target.useTls, "https enables TLS")

FaultClear(fault)
Check(not ParseDeploymentUrl("ftp://example.com", target, fault), _
  "a foreign scheme is rejected")
FaultClear(fault)
Check(not ParseDeploymentUrl("https://user:pass@example.com", target, fault), _
  "embedded credentials are rejected")
FaultClear(fault)
Check(not ParseDeploymentUrl("https://example.com/api", target, fault), _
  "a path is rejected so traffic cannot be redirected")
FaultClear(fault)
Check(not ParseDeploymentUrl("https://example.com:0", target, fault), "port zero is rejected")
FaultClear(fault)
Check(not ParseDeploymentUrl("https://example.com:70000", target, fault), _
  "an out of range port is rejected")
FaultClear(fault)
Check(not ParseDeploymentUrl("https://", target, fault), "a missing host is rejected")

Check(IsSafeHeaderValue("token-value"), "an ordinary token is a safe header value")
Check(not IsSafeHeaderValue("token" & chr(13, 10) & "X-Injected: 1"), _
  "a CRLF in a bearer token is rejected before it reaches the wire")
Check(not IsSafeHeaderValue("token" & chr(9) & "suffix"), _
  "other HTTP control bytes are rejected before they reach the wire")

' --- content-length framing ----------------------------------------------
dim as string body = "{""status"":""success"",""value"":1}"
dim as string wire = "HTTP/1.1 200 OK" & crlf & _
  "Content-Type: application/json" & crlf & _
  "Content-Length: " & FormatInteger(len(body)) & crlf & crlf & body
Check(FeedWhole(reader, wire) = HTTP_DONE, "a content-length response completes")
Check(reader.status = 200, "the status code is decoded")
CheckEqual(reader.body.Take(), body, "the body is exact")
Check(FeedByteByByte(reader, wire) = HTTP_DONE, "the same response completes byte by byte")
CheckEqual(reader.body.Take(), body, "byte by byte framing produces the same body")

' A body that arrives with trailing bytes must stop at the declared length.
dim as string overrun = wire & "GARBAGE"
Check(FeedWhole(reader, overrun) = HTTP_DONE, "trailing bytes do not break framing")
CheckEqual(reader.body.Take(), body, "the reader stops at the declared length")

' --- chunked framing ------------------------------------------------------
dim as string chunked = "HTTP/1.1 200 OK" & crlf & _
  "Transfer-Encoding: chunked" & crlf & crlf & _
  "5" & crlf & "{""sta" & crlf & _
  "19" & crlf & "tus"":""success"",""value"":1}" & crlf & _
  "0" & crlf & crlf
Check(FeedWhole(reader, chunked) = HTTP_DONE, "a chunked response completes")
CheckEqual(reader.body.Take(), body, "chunks reassemble into the exact body")
Check(FeedByteByByte(reader, chunked) = HTTP_DONE, _
  "the chunked response completes byte by byte")
CheckEqual(reader.body.Take(), body, "byte by byte chunking produces the same body")

dim as string extension = "HTTP/1.1 200 OK" & crlf & _
  "Transfer-Encoding: chunked" & crlf & crlf & _
  "5;name=value" & crlf & "hello" & crlf & "0" & crlf & crlf
Check(FeedWhole(reader, extension) = HTTP_DONE, "a chunk extension is ignored")
CheckEqual(reader.body.Take(), "hello", "the chunk extension does not corrupt the body")

dim as string trailered = "HTTP/1.1 200 OK" & crlf & _
  "Transfer-Encoding: chunked" & crlf & crlf & _
  "5" & crlf & "hello" & crlf & "0" & crlf & "X-Trailer: 1" & crlf & crlf
Check(FeedWhole(reader, trailered) = HTTP_DONE, "trailers after the last chunk are consumed")
CheckEqual(reader.body.Take(), "hello", "trailers do not appear in the body")

' --- rejected framings ----------------------------------------------------
Check(FeedWhole(reader, "ICY 200 OK" & crlf & crlf) = HTTP_FAILED, _
  "a non HTTP status line is rejected")
Check(FeedWhole(reader, "HTTP/1.1 99 Nope" & crlf & crlf) = HTTP_FAILED, _
  "an out of range status code is rejected")
Check(FeedWhole(reader, "HTTP/1.1 200 OK" & chr(10) & "Content-Length: 0" & chr(10) & chr(10)) _
  = HTTP_FAILED, "a bare LF line terminator is rejected")
Check(FeedWhole(reader, "HTTP/1.1 200 OK" & crlf & "Content-Length: 5" & crlf & _
  "Content-Length: 6" & crlf & crlf & "hello") = HTTP_FAILED, _
  "two disagreeing Content-Length headers are rejected")
Check(FeedWhole(reader, "HTTP/1.1 200 OK" & crlf & "Content-Length: 5" & crlf & _
  "Content-Length: 5" & crlf & crlf & "hello") = HTTP_FAILED, _
  "even identical repeated Content-Length headers are rejected")
Check(FeedWhole(reader, "HTTP/1.1 200 OK" & crlf & "Content-Length: 5" & crlf & _
  "Transfer-Encoding: chunked" & crlf & crlf) = HTTP_FAILED, _
  "Content-Length and Transfer-Encoding cannot be mixed")
Check(FeedWhole(reader, "HTTP/1.1 200 OK" & crlf & "Transfer-Encoding: chunked" & crlf & _
  "Transfer-Encoding: chunked" & crlf & crlf) = HTTP_FAILED, _
  "Transfer-Encoding cannot be repeated")
Check(FeedWhole(reader, "HTTP/1.1 200 OK" & crlf & "Content-Length: 5x" & crlf & crlf) _
  = HTTP_FAILED, "a non decimal Content-Length is rejected")
Check(FeedWhole(reader, "HTTP/1.1 200 OK" & crlf & "Transfer-Encoding: gzip" & crlf & crlf) _
  = HTTP_FAILED, "an unsupported Transfer-Encoding is rejected")
Check(FeedWhole(reader, "HTTP/1.1 200 OK" & crlf & "Transfer-Encoding: chunked" & crlf & _
  crlf & "zz" & crlf) = HTTP_FAILED, "a non hexadecimal chunk size is rejected")
Check(FeedWhole(reader, "HTTP/1.1 200 OK" & crlf & "Transfer-Encoding: chunked" & crlf & _
  crlf & "1" & crlf & "ab" & crlf) = HTTP_FAILED, "a chunk longer than its size is rejected")
Check(FeedWhole(reader, "HTTP/1.1 200 OK" & crlf & "Content-Length: 3000000" & crlf & crlf) _
  = HTTP_FAILED, "a Content-Length past the 2 MiB bound is rejected")
Check(FeedWhole(reader, "HTTP/1.1 200 OK" & crlf & "NoColonHere" & crlf & crlf) _
  = HTTP_FAILED, "a header without a colon is rejected")
Check(FeedWhole(reader, "HTTP/1.1 200 OK" & crlf & "Transfer-Encoding: chunked" & crlf & _
  crlf & "0" & crlf & "NoColonTrailer" & crlf & crlf) = HTTP_FAILED, _
  "a trailer without a field name is rejected")

' --- connection-close framing --------------------------------------------
HttpReaderReset(reader)
Check(HttpReaderFeed(reader, "HTTP/1.1 200 OK" & crlf & crlf & body) = HTTP_NEED_MORE, _
  "a response without framing headers waits for the peer to close")
Check(HttpReaderFinish(reader) = HTTP_DONE, "a clean close completes an EOF framed body")
CheckEqual(reader.body.Take(), body, "the EOF framed body is exact")

HttpReaderReset(reader)
HttpReaderFeed(reader, "HTTP/1.1 200 OK" & crlf & "Content-Length: 20" & crlf & crlf & "short")
Check(HttpReaderFinish(reader) = HTTP_FAILED, "a truncated content-length body is a failure")

' --- Convex envelopes -----------------------------------------------------
dim as ConvexResult result
ConvexResultInit(result)
FaultClear(fault)
Check(DecodeEnvelope(200, "{""status"":""success"",""value"":{""count"":0}}", result, fault), _
  "a success envelope decodes")
CheckEqual(JsonRender(result.value), "{""count"":0}", "the value is preserved exactly")
CheckEqual(JsonRender(result.logs), "[]", "an absent logLines becomes an empty array")
ConvexResultFree(result)

FaultClear(fault)
Check(not DecodeEnvelope(200, "{""status"":""success"",""value"":null," & _
  """logLines"":[""a"",1,""b""]}", result, fault), _
  "a non-string log line invalidates the envelope")
CheckEqual(fault.kind, FAULT_PROTOCOL, "malformed logLines are a ProtocolError")
ConvexResultFree(result)

FaultClear(fault)
Check(not DecodeEnvelope(200, "{""status"":""success"",""value"":null," & _
  """logLines"":""not-an-array""}", result, fault), _
  "a non-array logLines field invalidates the envelope")
ConvexResultFree(result)

FaultClear(fault)
Check(not DecodeEnvelope(200, "{""status"":""error"",""errorMessage"":""boom""," & _
  """errorData"":{""code"":""ROOM_EMPTY""}}", result, fault), _
  "an error envelope is a failure, not a value")
CheckEqual(fault.kind, FAULT_FUNCTION, _
  "a Convex function failure is classified as FunctionError")
CheckEqual(fault.message, "boom", "the error message is carried through")
Check(fault.hasData, "errorData presence is recorded")
CheckEqual(fault.dataJson, "{""code"":""ROOM_EMPTY""}", _
  "errorData is carried through verbatim")
ConvexResultFree(result)

FaultClear(fault)
Check(not DecodeEnvelope(200, "{""status"":""error"",""errorMessage"":""boom""}", _
  result, fault), "an error envelope without data still fails")
Check(not fault.hasData, "an absent errorData is never invented")
ConvexResultFree(result)

FaultClear(fault)
Check(not DecodeEnvelope(200, "{""status"":""error""}", result, fault), _
  "an error envelope without errorMessage is rejected")
CheckEqual(fault.kind, FAULT_PROTOCOL, "a missing errorMessage is a ProtocolError")
ConvexResultFree(result)

FaultClear(fault)
Check(not DecodeEnvelope(200, "{""status"":""success""}", result, fault), _
  "a success envelope without a value is a protocol failure")
CheckEqual(fault.kind, FAULT_PROTOCOL, "a missing value is a ProtocolError")
ConvexResultFree(result)

FaultClear(fault)
Check(not DecodeEnvelope(500, "{""status"":""success"",""value"":1}", result, fault), _
  "success with a non 2xx status is rejected before envelope acceptance")
CheckEqual(fault.kind, FAULT_TRANSPORT, "a non-2xx response is a TransportError")
ConvexResultFree(result)

FaultClear(fault)
Check(not DecodeEnvelope(500, "{""status"":""error"",""errorMessage"":""fake""}", _
  result, fault), "a function-shaped error cannot override HTTP 500")
CheckEqual(fault.kind, FAULT_TRANSPORT, "HTTP status takes precedence over the body")
ConvexResultFree(result)

FaultClear(fault)
Check(not DecodeEnvelope(502, "not json", result, fault), _
  "a malformed gateway body cannot override HTTP 502")
CheckEqual(fault.kind, FAULT_TRANSPORT, "HTTP status precedes JSON decoding")
ConvexResultFree(result)

FaultClear(fault)
Check(not DecodeEnvelope(401, "{""code"":""Unauthorized""}", result, fault), _
  "a non Convex error body is a protocol failure rather than a value")
CheckEqual(fault.kind, FAULT_TRANSPORT, "a non-2xx missing envelope is a TransportError")
ConvexResultFree(result)

FaultClear(fault)
Check(not DecodeEnvelope(200, "not json", result, fault), "a non JSON body is rejected")
ConvexResultFree(result)

FaultClear(fault)
Check(not DecodeEnvelope(200, "{""status"":""weird""}", result, fault), _
  "an unknown envelope status is rejected")
ConvexResultFree(result)

end TestSummary("freebasic http")
