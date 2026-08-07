// Convex's documented HTTP function endpoints.
//
// `POST /api/{query,mutation,action}` takes `{path, args, format}` and answers
// with `{status: "success", value, logLines}` or
// `{status: "error", errorMessage, errorData, logLines}`. The transport is
// ordinary HTTP/1.1 over TLS from `moonbitlang/async`; everything Convex
// specific - the envelope, the status discrimination, the log lines, and the
// bounded read - is implemented here.

///|
/// One completed HTTP exchange: the status line and the decoded body.
///
/// The status and the body are carried together because neither one decides the
/// outcome on its own. Convex reports a function that threw with an `error`
/// envelope, and a deployment or a proxy in front of it may deliver that
/// envelope under a non-2xx status; the envelope is still the truth about what
/// the function did.
struct HttpResponse {
  code : Int
  reason : String
  text : String
}

///|
/// Send one Convex function call and decode its envelope.
///
/// The whole exchange runs under a single absolute deadline. A per-read timeout
/// would let a peer that dribbles one byte before each timeout keep the call
/// alive forever, which is exactly the shape of a slow-loris stall.
async fn Client::call(
  self : Client,
  operation : String,
  path : String,
  args : Json,
) -> CallResult {
  guard !self.closed else { raise closed_error("client is closed") }
  guard path.length() >= 3 && path.contains(":") else {
    raise protocol_error("Convex function path must look like module:function")
  }
  guard args is Object(_) else {
    raise protocol_error("Convex arguments must be a JSON object")
  }
  let body = json_object([
    ("path", Json::string(path)),
    ("args", args),
    // `format: "json"` asks Convex for the plain JSON encoding rather than the
    // tagged value encoding. This client documents support for the JSON-safe
    // subset only, so requesting anything else would be dishonest.
    ("format", Json::string("json")),
  ])
  let endpoint = "/api/" + operation
  let response = @async.with_timeout(HTTP_TIMEOUT_MS, () => {
    self.send_request(endpoint, body)
  }) catch {
    error => raise as_convex_error(error, "Convex HTTP call failed")
  }
  decode_response(response)
}

///|
/// Perform the request and return the response body as text.
///
/// A fresh connection per call keeps the demonstration easy to reason about:
/// there is no pooled socket whose state could leak between a call that failed
/// mid-body and the next one. `close` runs on every path, including the failure
/// path, so a raised error never strands the file descriptor.
async fn Client::send_request(
  self : Client,
  endpoint : String,
  body : Json,
) -> HttpResponse {
  let headers : Map[String, String] = Map::new()
  headers["Content-Type"] = "application/json"
  headers["Accept"] = "application/json"
  headers["Convex-Client"] = CLIENT_VERSION
  // Convex authenticates function calls with a bearer token. It is attached
  // per request rather than per connection so that clearing it takes effect
  // immediately instead of on the next reconnect.
  match self.token {
    Some(token) => headers["Authorization"] = "Bearer " + token
    None => ()
  }
  // `@http.Client` verifies the peer certificate chain and the hostname
  // against the system trust store by default; `trust=SystemRoot` states that
  // intent explicitly so nobody has to infer it from a default.
  let http = @http.Client(self.origin, trust=@tls.TrustedRoot::SystemRoot)
  let outcome = try {
    let response = http.post(endpoint, body.stringify(), extra_headers=headers)
    // The body is read under the same bound whatever the status said. A failing
    // status may still be carrying the Convex error envelope, and an oversized
    // body has to be refused before it is retained either way, so there is no
    // status for which skipping this read would be safe.
    let text = read_bounded_text(http, HTTP_MAX_RESPONSE_BYTES, "HTTP response")
    HttpResponse::{ code: response.code, reason: response.reason, text }
  } catch {
    error => {
      http.close()
      raise error
    }
  }
  http.close()
  outcome
}

///|
/// Read a reader to end of stream, refusing to retain more than `limit` bytes.
///
/// The check happens against the count already accepted plus the chunk just
/// read, before the chunk is appended, so an oversized body is rejected while
/// only one chunk of it is in memory. Convex sends UTF-8, and a body that is
/// not valid UTF-8 is protocol drift rather than a value.
async fn read_bounded_text(
  reader : &@io.Reader,
  limit : Int,
  what : String,
) -> String {
  let accumulated = @buffer.Buffer(size_hint=READ_CHUNK_BYTES)
  let chunk : FixedArray[Byte] = FixedArray::make(READ_CHUNK_BYTES, b'\x00')
  while true {
    let read = reader.read(chunk, max_len=READ_CHUNK_BYTES)
    if read <= 0 {
      break
    }
    guard accumulated.length() + read <= limit else {
      raise protocol_error(
        what + " exceeded " + limit.to_string() + " bytes and was refused",
      )
    }
    accumulated.write_bytes(chunk.unsafe_reinterpret_as_bytes()[0:read])
  }
  @utf8.decode(accumulated.to_bytes()[:]) catch {
    _ => raise protocol_error(what + " was not valid UTF-8")
  }
}

///|
/// What this client reports when the status line is the only thing it can
/// believe about a response.
fn status_detail(response : HttpResponse) -> String {
  "Convex HTTP endpoint answered " +
  response.code.to_string() +
  " " +
  response.reason
}

///|
/// Turn one HTTP exchange into a result or a structured failure.
///
/// The `status` member of the envelope decides which failure family applies,
/// and the HTTP status decides whether the envelope may be believed at all.
///
///   * A valid `error` envelope is honoured whatever status carried it. Convex
///     itself answers a thrown function with `200`, but a deployment behind a
///     proxy may deliver the same envelope as `4xx` or `5xx`, and discarding
///     `errorData` because of the status line would flatten an application
///     error the caller is expected to branch on into "the server said 500".
///   * A `success` envelope under a non-2xx status is a contradiction: the body
///     claims the function returned a value while the status says the call did
///     not succeed. It is refused, because trusting the body there would report
///     a proxy's cached or synthesised page as a Convex result.
///   * A non-2xx response whose body is not a Convex envelope at all is
///     reported as the status, since that is the only fact in it.
///
/// A success is also only a success when the `value` member is actually
/// present. Convex returns JSON `null` for a function that returns null, and
/// treating "absent" the same as "null" would report a truncated envelope as a
/// legitimate null result.
fn decode_response(response : HttpResponse) -> CallResult raise ConvexError {
  let ok = response.code >= 200 && response.code < 300
  // Every "this body is not an envelope" path collapses to the status when the
  // status already said the call failed, so that a caller is told the one thing
  // that is actually known rather than how the error page was punctuated.
  fn unusable(detail : String) -> ConvexError {
    protocol_error(if ok { detail } else { status_detail(response) })
  }
  let envelope = @json.parse(response.text) catch {
    _ => raise unusable("Convex HTTP response was not valid JSON")
  }
  guard envelope is Object(_) else {
    raise unusable("Convex HTTP response was not a JSON object")
  }
  let logs = log_lines(json_field(envelope, "logLines"))
  let status = match json_field(envelope, "status") {
    Some(String(status)) => status
    _ => raise unusable("Convex HTTP response omitted a string status member")
  }
  match status {
    "success" => {
      guard ok else {
        raise protocol_error(
          status_detail(response) + " while its body claimed success",
        )
      }
      guard json_has_field(envelope, "value") else {
        raise protocol_error("Convex success response omitted its value member")
      }
      { value: required_field(envelope, "value", "success response"), logs }
    }
    "error" => {
      let message = match json_field(envelope, "errorMessage") {
        Some(String(message)) => message
        _ => "Convex function failed"
      }
      // `errorData` is the application's own `ConvexError` payload. It is
      // forwarded untouched, including when it is absent, so callers can match
      // on their own error shape.
      let data = json_field(envelope, "errorData")
      raise function_error(message, data?, logs~)
    }
    other => raise unusable("Convex HTTP response had unknown status " + other)
  }
}
