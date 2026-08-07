// Convex's documented JSON HTTP API, spoken by Pike.
//
// This fragment is textually included by convex.pike. The HTTP/1.1 exchange is
// written out here rather than delegated so that one absolute deadline, one
// header budget, and one body budget cover the whole request, and so the
// envelope classifier can be tested byte-for-byte without a deployment.
#ifndef CONVEX_HTTP_PIKE
#define CONVEX_HTTP_PIKE

constant MAX_HTTP_HEADER_BYTES = 32 * 1024;
constant MAX_HTTP_BODY_BYTES = 2 * 1024 * 1024;
constant HTTP_REQUEST_TIMEOUT_MS = 30000;

string trim_ascii(string text)
{
  int start = 0;
  int stop = sizeof(text);
  while (start < stop &&
         (text[start] == ' ' || text[start] == '\t' || text[start] == '\r' ||
          text[start] == '\n'))
    start++;
  while (stop > start &&
         (text[stop - 1] == ' ' || text[stop - 1] == '\t' ||
          text[stop - 1] == '\r' || text[stop - 1] == '\n'))
    stop--;
  return text[start..stop - 1];
}

class HttpResponse
{
  int status;
  string reason = "";
  mapping(string:string) headers = ([]);
  string body = "";

  protected void create(int response_status, string response_body,
                        void|mapping(string:string) response_headers,
                        void|string response_reason)
  {
    status = response_status;
    body = response_body;
    headers = response_headers || ([]);
    reason = response_reason || "";
  }
}

// An incremental HTTP/1.1 response reader. It is fed whatever arrives from the
// channel, in whatever sized pieces the network chose, and refuses to grow past
// its header and body budgets rather than trusting a peer-supplied length.
class HttpResponseParser
{
  string operation;
  string buffer = "";
  int header_done;
  int complete;
  int status;
  string reason = "";
  mapping(string:string) headers = ([]);

  // Body framing: exactly one of these is selected from the headers.
  int content_length = -1;
  int chunked;
  int until_eof;

  string body = "";
  // Chunked sub-state: 0 expects a size line, 1 reads chunk data, 2 expects the
  // CRLF after a chunk, 3 reads trailers.
  int chunk_stage;
  int chunk_remaining;

  protected void create(void|string parser_operation)
  {
    operation = parser_operation || "http";
  }

  void feed(string data)
  {
    if (complete)
      return;
    buffer += data;
    step();
  }

  // The peer closed. A body framed only by connection close is finished; any
  // other pending state is a truncated response and must not decode.
  void end_of_stream()
  {
    if (complete)
      return;
    if (header_done && until_eof) {
      body += buffer;
      buffer = "";
      guard_body();
      complete = 1;
      return;
    }
    throw(transport_error("HTTP response ended before it was complete",
                          operation));
  }

  void guard_body()
  {
    if (sizeof(body) > MAX_HTTP_BODY_BYTES)
      throw(protocol_error("HTTP response body exceeds its byte budget",
                           operation));
  }

  void step()
  {
    if (!header_done) {
      int end = search(buffer, "\r\n\r\n");
      if (end < 0) {
        if (sizeof(buffer) > MAX_HTTP_HEADER_BYTES)
          throw(protocol_error("HTTP response headers exceed their byte budget",
                               operation));
        return;
      }
      if (end + 4 > MAX_HTTP_HEADER_BYTES)
        throw(protocol_error("HTTP response headers exceed their byte budget",
                             operation));
      parse_head(buffer[..end - 1]);
      buffer = buffer[end + 4..];
      header_done = 1;
    }
    step_body();
  }

  void parse_head(string head)
  {
    array(string) lines = head / "\r\n";
    string status_line = lines[0];
    if (!has_prefix(status_line, "HTTP/1.1 ") &&
        !has_prefix(status_line, "HTTP/1.0 "))
      throw(protocol_error("HTTP response is not HTTP/1.x", operation));
    string code = status_line[9..11];
    if (sizeof(code) != 3)
      throw(protocol_error("HTTP response has no status code", operation));
    foreach (code / "", string digit)
      if (digit < "0" || digit > "9")
        throw(protocol_error("HTTP response status is not numeric", operation));
    status = (int)code;
    reason = trim_ascii(status_line[12..]);

    foreach (lines[1..], string line) {
      if (!sizeof(line))
        continue;
      if (line[0] == ' ' || line[0] == '\t')
        throw(protocol_error("HTTP response uses obsolete header folding",
                             operation));
      int colon = search(line, ":");
      if (colon < 1)
        throw(protocol_error("HTTP response has a malformed header",
                             operation));
      string name = lower_case(trim_ascii(line[..colon - 1]));
      string value = trim_ascii(line[colon + 1..]);
      if (!sizeof(name))
        throw(protocol_error("HTTP response has an empty header name",
                             operation));
      // Repeated headers keep their documented list semantics rather than
      // silently discarding either value.
      headers[name] = headers[name] ? headers[name] + ", " + value : value;
    }

    if (headers["transfer-encoding"]) {
      string encoding = lower_case(headers["transfer-encoding"]);
      if (encoding == "chunked")
        chunked = 1;
      else if (encoding != "identity")
        throw(protocol_error("unsupported HTTP transfer encoding: " + encoding,
                             operation));
    }
    if (!chunked && headers["content-length"]) {
      string raw_length = headers["content-length"];
      if (!sizeof(raw_length) || sizeof(raw_length) > 10)
        throw(protocol_error("HTTP response has a malformed content length",
                             operation));
      foreach (raw_length / "", string digit)
        if (digit < "0" || digit > "9")
          throw(protocol_error("HTTP response has a malformed content length",
                               operation));
      content_length = (int)raw_length;
      if (content_length > MAX_HTTP_BODY_BYTES)
        throw(protocol_error("HTTP response body exceeds its byte budget",
                             operation));
    }
    // 204 and 304 never carry a body; anything else without a length is framed
    // by the connection closing.
    if (!chunked && content_length < 0 && status != 204 && status != 304)
      until_eof = 1;
  }

  void step_body()
  {
    if (complete)
      return;
    if (chunked) {
      step_chunked();
      return;
    }
    if (content_length >= 0) {
      if (sizeof(buffer) < content_length)
        return;
      body = buffer[..content_length - 1];
      buffer = buffer[content_length..];
      complete = 1;
      return;
    }
    if (until_eof) {
      body += buffer;
      buffer = "";
      guard_body();
      return;
    }
    complete = 1;
  }

  void step_chunked()
  {
    while (!complete) {
      if (chunk_stage == 0) {
        int end = search(buffer, "\r\n");
        if (end < 0) {
          if (sizeof(buffer) > 1024)
            throw(protocol_error("HTTP chunk size line is too long",
                                 operation));
          return;
        }
        string line = buffer[..end - 1];
        buffer = buffer[end + 2..];
        // A chunk extension after ';' is legal and ignored.
        int semicolon = search(line, ";");
        if (semicolon >= 0)
          line = line[..semicolon - 1];
        line = trim_ascii(line);
        if (!sizeof(line) || sizeof(line) > 8)
          throw(protocol_error("HTTP chunk size is malformed", operation));
        int size = 0;
        foreach (line / "", string digit) {
          int value = hex_digit(digit);
          if (value < 0)
            throw(protocol_error("HTTP chunk size is malformed", operation));
          size = size * 16 + value;
        }
        if (size == 0) {
          chunk_stage = 3;
          continue;
        }
        if (sizeof(body) + size > MAX_HTTP_BODY_BYTES)
          throw(protocol_error("HTTP response body exceeds its byte budget",
                               operation));
        chunk_remaining = size;
        chunk_stage = 1;
        continue;
      }
      if (chunk_stage == 1) {
        if (sizeof(buffer) < chunk_remaining)
          return;
        body += buffer[..chunk_remaining - 1];
        buffer = buffer[chunk_remaining..];
        chunk_remaining = 0;
        chunk_stage = 2;
        continue;
      }
      if (chunk_stage == 2) {
        if (sizeof(buffer) < 2)
          return;
        if (buffer[..1] != "\r\n")
          throw(protocol_error("HTTP chunk is not terminated correctly",
                               operation));
        buffer = buffer[2..];
        chunk_stage = 0;
        continue;
      }
      // Trailers, terminated by a blank line.
      int end = search(buffer, "\r\n");
      if (end < 0) {
        if (sizeof(buffer) > MAX_HTTP_HEADER_BYTES)
          throw(protocol_error("HTTP trailers exceed their byte budget",
                               operation));
        return;
      }
      string line = buffer[..end - 1];
      buffer = buffer[end + 2..];
      if (!sizeof(line)) {
        guard_body();
        complete = 1;
        return;
      }
    }
  }

  int hex_digit(string digit)
  {
    if (digit >= "0" && digit <= "9")
      return digit[0] - '0';
    string lowered = lower_case(digit);
    if (lowered >= "a" && lowered <= "f")
      return lowered[0] - 'a' + 10;
    return -1;
  }

  HttpResponse response()
  {
    if (!complete)
      throw(transport_error("HTTP response is not complete", operation));
    return HttpResponse(status, body, headers, reason);
  }
}

// Header values reach the wire verbatim, and one of them carries a bearer
// token. Refusing control characters here is what stops a hostile or merely
// careless token from injecting extra request lines.
void guard_header_value(string name, string value, void|string operation)
{
  foreach ((array(int))value, int character)
    if (character < 32 || character == 127)
      throw(protocol_error(
        sprintf("header %s must not contain control characters", name),
        operation));
}

string build_request(mapping target, string method, string path,
                     mapping(string:string) headers, string body,
                     void|string operation)
{
  array(string) lines = ({ sprintf("%s %s HTTP/1.1", method, path) });
  // Connection: close keeps one request per connection. Convex calls are
  // infrequent enough that a pool would add reuse hazards for no benefit, and
  // it makes the end-of-body condition unambiguous.
  // The framing headers win over anything a caller supplied, so no argument can
  // desynchronise the declared length from the bytes actually sent.
  mapping(string:string) all = headers + ([
    "host": target->authority,
    "connection": "close",
    "content-length": sprintf("%d", sizeof(body)),
  ]);
  foreach (sort(indices(all)), string name) {
    guard_header_value(name, all[name], operation);
    lines += ({ name + ": " + all[name] });
  }
  return lines * "\r\n" + "\r\n\r\n" + body;
}

class HttpTransport
{
  HttpResponse request(mapping target, string method, string path,
                       mapping(string:string) headers, string body,
                       int deadline_ms, void|string operation)
  {
    error("HttpTransport.request must be implemented\n");
    return 0;
  }
}

// The production transport: one non-blocking TCP or TLS channel per call, with
// the caller's absolute deadline covering connect, handshake, write, and read.
class SocketHttpTransport
{
  inherit HttpTransport;

  HttpResponse request(mapping target, string method, string path,
                       mapping(string:string) headers, string body,
                       int deadline_ms, void|string operation)
  {
    if (sizeof(body) > MAX_HTTP_BODY_BYTES)
      throw(protocol_error("HTTP request body exceeds its byte budget",
                           operation));
    Channel channel = connect_channel(target, deadline_ms, operation);
    HttpResponseParser parser = HttpResponseParser(operation);
    // Callbacks run inside the Pike backend, which does not propagate a thrown
    // value out to whoever pumped it. Everything a callback observes is
    // recorded in this shared mapping and re-raised below, in the caller's own
    // control flow, so no failure can be lost inside the backend.
    mapping progress = ([ "failure": 0, "closed": 0, "reason": "" ]);

    channel->set_handlers(
      lambda(string data) {
        if (progress->failure)
          return;
        mixed failed = catch { parser->feed(data); };
        if (failed)
          progress->failure = failed;
      },
      lambda(string reason) {
        progress->closed = 1;
        progress->reason = reason;
        if (progress->failure)
          return;
        mixed failed = catch { parser->end_of_stream(); };
        if (failed)
          progress->failure = failed;
      });

    if (!channel->write(build_request(target, method, path, headers, body,
                                      operation))) {
      string reason = channel->failure_reason();
      channel->hard_close("request could not be written");
      if (!sizeof(reason))
        reason = "HTTP request could not be written";
      throw(transport_error(reason, operation));
    }

    int finished = pump_until(
      lambda() {
        return parser->complete || progress->failure || progress->closed;
      },
      deadline_ms);
    channel->hard_close("request finished");

    if (parser->complete)
      return parser->response();
    // The deadline is reported ahead of any truncation the close handler
    // recorded, because a stalled peer is the more useful diagnosis.
    if (!finished)
      throw(transport_error("HTTP request timed out", operation));
    if (progress->failure)
      throw(as_convex_error(progress->failure, operation));
    throw(transport_error(sizeof(progress->reason)
                            ? progress->reason
                            : "HTTP response ended before it was complete",
                          operation));
  }
}

// One successful Convex call.
class CallResult
{
  mixed value;
  array(string) logs;

  protected void create(mixed result_value, void|array(string) result_logs)
  {
    value = result_value;
    logs = result_logs || ({});
  }
}

// Classify a Convex HTTP envelope.
//
// The envelope is decoded before the HTTP status is consulted, because Convex
// can return a structured function failure with a non-2xx status. The reverse
// case, a non-2xx response claiming success, stays protocol drift and is
// never reported as a value.
CallResult decode_envelope(HttpResponse response, string operation)
{
  mixed decoded = json_parse_bytes(
    response->body,
    sprintf("HTTP %d response", response->status), operation);
  mapping envelope = require_object(
    decoded, sprintf("HTTP %d response", response->status), operation);
  string status = require_string(envelope->status, "response status",
                                 operation);

  if (status == "success") {
    if (response->status < 200 || response->status > 299)
      throw(protocol_error(
        sprintf("HTTP %d response cannot carry a success envelope",
                response->status), operation));
    if (zero_type(envelope->value))
      throw(protocol_error("success envelope omitted value", operation));
    return CallResult(envelope->value,
                      require_log_lines(envelope->logLines, operation));
  }

  if (status == "error") {
    ConvexError failure = function_error(
      require_nonempty_string(envelope->errorMessage, "errorMessage",
                              operation),
      operation);
    if (!zero_type(envelope->errorData))
      failure = failure->with_data(envelope->errorData);
    throw(failure->with_logs(require_log_lines(envelope->logLines, operation)));
  }

  throw(protocol_error("unknown Convex envelope status: " + status, operation));
}

#endif
