// A small, strict HTTP/1.1 client for the documented Convex Functions API.
//
// Convex needs exactly one request shape: a POST of a JSON object to
// `/api/query`, `/api/mutation`, or `/api/action`. Writing it here rather than
// reaching for a general HTTP library keeps the client honestly native, and
// lets every limit be a Convex-sized limit rather than a web-scale one.
//
// The response reader is incremental and bounded at every stage. A header
// block that never terminates, a `Content-Length` larger than the budget, or a
// chunked body that overruns it all abandon the connection instead of growing
// a buffer.

class val HttpResponse
  let status: U16
  let body: String

  new val create(status': U16, body': String) =>
    status = status'
    body = body'

primitive HttpRequest
  """
  Serialises the one request shape this client sends.
  """

  fun post_json(
    endpoint: ConvexEndpoint,
    path: String,
    body: String,
    client_version: String,
    auth_token: String)
    : Array[U8] val ?
  =>
    if body.size() > ConvexLimits.max_request_bytes() then error end
    if not HttpRequest.safe_header_value(client_version) then error end
    if not HttpRequest.safe_header_value(auth_token) then error end
    if not HttpRequest.safe_header_value(path) then error end

    recover val
      let out = Array[U8](body.size() + 256)
      Bytes.append_string(out, "POST ")
      Bytes.append_string(out, path)
      Bytes.append_string(out, " HTTP/1.1\r\n")
      Bytes.append_string(out, "Host: ")
      Bytes.append_string(out, endpoint.authority)
      Bytes.append_string(out, "\r\n")
      Bytes.append_string(out, "Accept: application/json\r\n")
      Bytes.append_string(out, "Content-Type: application/json\r\n")
      Bytes.append_string(out, "Convex-Client: ")
      Bytes.append_string(out, client_version)
      Bytes.append_string(out, "\r\n")
      if auth_token.size() > 0 then
        Bytes.append_string(out, "Authorization: Bearer ")
        Bytes.append_string(out, auth_token)
        Bytes.append_string(out, "\r\n")
      end
      Bytes.append_string(out, "Content-Length: ")
      Bytes.append_string(out, body.size().string())
      Bytes.append_string(out, "\r\n")
      // One request per connection. Convex calls in this demonstration are
      // infrequent, and a fresh connection removes a whole class of pooled
      // keep-alive bugs from a client whose job is to be readable.
      Bytes.append_string(out, "Connection: close\r\n\r\n")
      Bytes.append_string(out, body)
      out
    end

  fun safe_header_value(value: String): Bool =>
    """
    Rejects anything that could terminate a header line early and inject
    another header, and anything outside printable ASCII.
    """
    var index: USize = 0
    while index < value.size() do
      let byte = try value(index)? else return false end
      if (byte < 0x20) or (byte > 0x7e) then return false end
      index = index + 1
    end
    true

class ref HttpResponseParser
  """
  Feed bytes in, get one response out.

  `push` raises on anything malformed or oversized so the caller can turn it
  into a `TransportError` and drop the socket. `finish` handles the legal case
  of a body delimited only by connection close.
  """

  let _buffer: Array[U8] = Array[U8]
  var _status: U16 = 0
  var _headers_done: Bool = false
  var _body_start: USize = 0
  var _content_length: USize = 0
  var _has_content_length: Bool = false
  var _chunked: Bool = false
  var _close_delimited: Bool = false
  var _chunk_position: USize = 0
  var _reading_trailers: Bool = false
  var _trailer_count: USize = 0
  let _body: Array[U8] = Array[U8]
  var _complete: Bool = false

  new ref create() =>
    None

  fun ref push(data: Array[U8] val) ? =>
    if _complete then return end
    if (_buffer.size() + data.size()) >
      (ConvexLimits.max_response_bytes() + ConvexLimits.max_header_bytes())
    then
      error
    end
    Bytes.append_all(_buffer, data)
    _advance()?

  fun ref finish(): HttpResponse ? =>
    """
    Called once the peer closes. Only a close-delimited body may complete here.
    """
    if _complete then return response()? end
    if not (_headers_done and _close_delimited) then error end
    _body.clear()
    Bytes.append_all(_body, Bytes.freeze(_buffer, _body_start, _buffer.size()))
    if _body.size() > ConvexLimits.max_response_bytes() then error end
    _complete = true
    response()?

  fun ref ready(): Bool => _complete

  fun ref response(): HttpResponse ? =>
    if not _complete then error end
    let text = Bytes.to_string(Bytes.freeze(_body, 0, _body.size()))
    HttpResponse(_status, text)

  fun ref _advance() ? =>
    if not _headers_done then
      match _find_header_end()
      | let position: USize =>
        _parse_head(position)?
        _headers_done = true
        _body_start = position + 4
        _chunk_position = _body_start
      | None =>
        if _buffer.size() > ConvexLimits.max_header_bytes() then error end
        return
      end
    end

    if _chunked then
      _advance_chunked()?
    elseif _has_content_length then
      let available = _buffer.size() - _body_start
      if available >= _content_length then
        _body.clear()
        Bytes.append_all(
          _body,
          Bytes.freeze(_buffer, _body_start, _body_start + _content_length))
        _complete = true
      end
    else
      // Close delimited. `finish` completes it; here only the budget matters.
      if (_buffer.size() - _body_start) > ConvexLimits.max_response_bytes() then
        error
      end
    end

  fun ref _find_header_end(): (USize | None) =>
    if _buffer.size() < 4 then return None end
    var index: USize = 0
    while (index + 4) <= _buffer.size() do
      try
        if (_buffer(index)? == '\r') and (_buffer(index + 1)? == '\n') and
          (_buffer(index + 2)? == '\r') and (_buffer(index + 3)? == '\n')
        then
          return index
        end
      end
      index = index + 1
    end
    None

  fun ref _parse_head(header_end: USize) ? =>
    let head = Bytes.to_string(Bytes.freeze(_buffer, 0, header_end))
    let lines = HttpText.split_lines(head)
    if lines.size() == 0 then error end
    if lines.size() > (ConvexLimits.max_header_count() + 1) then error end

    let status_line = lines(0)?
    if status_line.size() > ConvexLimits.max_status_line_bytes() then error end
    if not (Bytes.starts_with(status_line, "HTTP/1.0 ") or
      Bytes.starts_with(status_line, "HTTP/1.1 "))
    then
      error
    end
    if status_line.size() < 12 then error end
    if status_line(8)? != ' ' then error end
    var code: U16 = 0
    var index: USize = 9
    while index < 12 do
      let byte = status_line(index)?
      if (byte < '0') or (byte > '9') then error end
      code = (code * 10) + (byte - '0').u16()
      index = index + 1
    end
    if (status_line.size() > 12) and (status_line(12)? != ' ') then error end
    _status = code
    if (_status < 200) or (_status > 599) then error end

    var seen_content_length = false
    var line_index: USize = 1
    while line_index < lines.size() do
      let line = lines(line_index)?
      line_index = line_index + 1
      if line.size() == 0 then continue end
      // Obsolete line folding is not accepted; a header must start its line.
      if (line(0)? == ' ') or (line(0)? == '\t') then error end
      let colon = HttpText.index_of(line, ':')?
      let name = Bytes.lower(HttpText.slice(line, 0, colon))
      let value = HttpText.trim(HttpText.slice(line, colon + 1, line.size()))
      if name == "content-length" then
        if seen_content_length then error end
        seen_content_length = true
        _has_content_length = true
        _content_length = HttpText.parse_decimal(value)?
        if _content_length > ConvexLimits.max_response_bytes() then error end
      elseif name == "transfer-encoding" then
        if Bytes.lower(value) != "chunked" then error end
        _chunked = true
      end
    end

    // A response that claims both framings is ambiguous, and ambiguity in a
    // message boundary is exactly how request smuggling starts.
    if _chunked and _has_content_length then error end
    // A 1xx informational response is followed by the real one; this client
    // has no reason to see one and treats it as a protocol failure.
    if (_status == 204) or (_status == 304) then
      _has_content_length = true
      _content_length = 0
      _chunked = false
    end
    _close_delimited = not (_chunked or _has_content_length)

  fun ref _advance_chunked() ? =>
    while not _complete do
      if _reading_trailers then
        _advance_trailers()?
        return
      end
      match _find_crlf(_chunk_position)
      | let line_end: USize =>
        let header =
          Bytes.to_string(Bytes.freeze(_buffer, _chunk_position, line_end))
        // Chunk extensions are legal but unused by Convex; ignore after `;`.
        let size_text = HttpText.trim(HttpText.before(header, ';'))
        let size = HttpText.parse_hex(size_text)?
        if size > ConvexLimits.max_response_bytes() then error end
        let data_start = line_end + 2
        if size == 0 then
          // A zero chunk does not complete the response by itself. The final
          // empty trailer line is part of the framing and must arrive too.
          _reading_trailers = true
          _chunk_position = data_start
          continue
        end
        if (_buffer.size() < (data_start + size + 2)) then return end
        if _buffer(data_start + size)? != '\r' then error end
        if _buffer(data_start + size + 1)? != '\n' then error end
        Bytes.append_all(
          _body, Bytes.freeze(_buffer, data_start, data_start + size))
        if _body.size() > ConvexLimits.max_response_bytes() then error end
        _chunk_position = data_start + size + 2
      | None =>
        if (_buffer.size() - _chunk_position) >
          ConvexLimits.max_status_line_bytes()
        then
          error
        end
        return
      end
    end

  fun ref _advance_trailers() ? =>
    while true do
      match _find_crlf(_chunk_position)
      | let line_end: USize =>
        if line_end == _chunk_position then
          _complete = true
          return
        end
        _trailer_count = _trailer_count + 1
        if _trailer_count > ConvexLimits.max_header_count() then error end
        let line = Bytes.to_string(
          Bytes.freeze(_buffer, _chunk_position, line_end))
        if line.size() > ConvexLimits.max_status_line_bytes() then error end
        // Validate the trailer field shape even though this client does not
        // consume trailer values.
        HttpText.index_of(line, ':')?
        _chunk_position = line_end + 2
      | None =>
        if (_buffer.size() - _chunk_position) >
          ConvexLimits.max_status_line_bytes()
        then
          error
        end
        return
      end
    end

  fun ref _find_crlf(from: USize): (USize | None) =>
    var index = from
    while (index + 2) <= _buffer.size() do
      try
        if (_buffer(index)? == '\r') and (_buffer(index + 1)? == '\n') then
          return index
        end
      end
      index = index + 1
    end
    None

primitive HttpText
  """
  Text helpers for header parsing, kept as a primitive so they can be used from
  a constructor and from inside a `recover` block.
  """

  fun split_lines(head: String): Array[String] val =>
    var out: Array[String] iso = Array[String](8)
    var start: USize = 0
    var index: USize = 0
    while index < head.size() do
      let byte = try head(index)? else 0 end
      if (byte == '\r') and (try head(index + 1)? == '\n' else false end) then
        out.push(HttpText.slice(head, start, index))
        index = index + 2
        start = index
      else
        index = index + 1
      end
    end
    if start < head.size() then
      out.push(HttpText.slice(head, start, head.size()))
    end
    consume out

  fun slice(text: String, from: USize, upto: USize): String =>
    let limit = if upto > text.size() then text.size() else upto end
    var out: String iso = String(if limit > from then limit - from else 0 end)
    var index = from
    while index < limit do
      out.push(try text(index)? else 0 end)
      index = index + 1
    end
    consume out

  fun before(text: String, marker: U8): String =>
    var index: USize = 0
    while index < text.size() do
      if (try text(index)? else 0 end) == marker then
        return HttpText.slice(text, 0, index)
      end
      index = index + 1
    end
    text

  fun trim(text: String): String =>
    var start: USize = 0
    var stop = text.size()
    while start < stop do
      let byte = try text(start)? else 0 end
      if (byte == ' ') or (byte == '\t') then start = start + 1 else break end
    end
    while stop > start do
      let byte = try text(stop - 1)? else 0 end
      if (byte == ' ') or (byte == '\t') then stop = stop - 1 else break end
    end
    HttpText.slice(text, start, stop)

  fun has_token(list: String, token: String): Bool =>
    """
    True when `list`, a comma separated header value, contains `token` as one
    of its members. `keep-alive, upgrade` is a legal way for a proxy to write
    the `Connection` header, so a plain equality check would reject it.
    """
    var start: USize = 0
    var index: USize = 0
    while index < list.size() do
      if (try list(index)? else 0 end) == ',' then
        if HttpText.trim(HttpText.slice(list, start, index)) == token then
          return true
        end
        start = index + 1
      end
      index = index + 1
    end
    HttpText.trim(HttpText.slice(list, start, list.size())) == token

  fun index_of(text: String, marker: U8): USize ? =>
    var index: USize = 0
    while index < text.size() do
      if text(index)? == marker then return index end
      index = index + 1
    end
    error

  fun parse_decimal(text: String): USize ? =>
    if (text.size() == 0) or (text.size() > 12) then error end
    var value: USize = 0
    var index: USize = 0
    while index < text.size() do
      let byte = text(index)?
      if (byte < '0') or (byte > '9') then error end
      value = (value * 10) + (byte - '0').usize()
      index = index + 1
    end
    value

  fun parse_hex(text: String): USize ? =>
    if (text.size() == 0) or (text.size() > 8) then error end
    var value: USize = 0
    var index: USize = 0
    while index < text.size() do
      let byte = text(index)?
      let digit =
        if (byte >= '0') and (byte <= '9') then
          (byte - '0').usize()
        elseif (byte >= 'a') and (byte <= 'f') then
          ((byte - 'a') + 10).usize()
        elseif (byte >= 'A') and (byte <= 'F') then
          ((byte - 'A') + 10).usize()
        else
          error
        end
      value = (value * 16) + digit
      index = index + 1
    end
    value
