"""HTTP/1.1 over the raw byte stream from `net.mojo`.

Only what Convex needs is implemented: one request per connection, a status
line, response headers, and a body delimited by `Content-Length`, by chunked
transfer encoding, or by end of stream. The same header reader is reused for
the WebSocket upgrade handshake, which is an ordinary HTTP request until the
server answers `101`.
"""

from net import Conn, connect, now_ms

comptime MAX_HEADER_BYTES = 65536
comptime MAX_BODY_BYTES = 8 * 1024 * 1024


struct Endpoint(Copyable, Movable):
    """A deployment URL split into the parts a socket call needs."""

    var host: String
    var port: Int
    var tls: Bool

    fn __init__(out self, host: String, port: Int, tls: Bool):
        self.host = host
        self.port = port
        self.tls = tls


fn parse_url(url: String) raises -> Endpoint:
    """Split `http://host[:port]` or `https://host[:port]` into its parts."""
    var tls: Bool
    var rest: String
    if url.startswith("https://"):
        tls = True
        rest = String(url[byte = 8 : len(url.as_bytes())])
    elif url.startswith("http://"):
        tls = False
        rest = String(url[byte = 7 : len(url.as_bytes())])
    else:
        raise Error(
            "ProtocolError|CONVEX_URL must start with http:// or https://"
        )
    var slash = rest.find("/")
    if slash >= 0:
        rest = String(rest[byte=0:slash])
    if not rest:
        raise Error("ProtocolError|CONVEX_URL has no host")
    var colon = rest.rfind(":")
    if colon > 0:
        var port = Int(rest[byte = colon + 1 : len(rest.as_bytes())])
        return Endpoint(String(rest[byte=0:colon]), port, tls)
    return Endpoint(rest, 443 if tls else 80, tls)


struct Response(Copyable, Movable):
    var status: Int
    var body: String

    fn __init__(out self, status: Int, body: String):
        self.status = status
        self.body = body


struct HeaderBlock(Copyable, Movable):
    """A parsed status line plus its header lines, lowercased for lookup."""

    var status: Int
    var lines: List[String]

    fn __init__(out self, status: Int, var lines: List[String]):
        self.status = status
        self.lines = lines^

    fn value(self, name: String) -> String:
        """The first value for `name`, or an empty string when it is absent."""
        var wanted = name.lower() + ":"
        for i in range(len(self.lines)):
            var line = self.lines[i]
            if line.lower().startswith(wanted):
                return String(
                    line[byte = len(wanted) : len(line.as_bytes())].strip()
                )
        return String()


fn read_headers(mut conn: Conn, deadline: Int) raises -> HeaderBlock:
    """Consume bytes up to the blank line that ends the header block."""
    var seen = 0
    while True:
        var terminator = _find_header_end(conn, seen)
        if terminator >= 0:
            return _parse_headers(conn, terminator)
        seen = conn.buffered()
        if conn.buffered() > MAX_HEADER_BYTES:
            raise Error("ProtocolError|HTTP headers exceeded the size limit")
        if conn.fill(deadline) <= 0:
            raise Error(
                "TransportError|connection closed before the headers ended"
            )


fn _find_header_end(conn: Conn, from_offset: Int) -> Int:
    """Return the offset just past the CRLFCRLF, or -1 if it is not there yet.
    """
    var start = from_offset - 3
    if start < 0:
        start = 0
    var limit = conn.buffered() - 3
    for i in range(start, limit):
        if (
            conn.peek(i) == 0x0D
            and conn.peek(i + 1) == 0x0A
            and conn.peek(i + 2) == 0x0D
            and conn.peek(i + 3) == 0x0A
        ):
            return i + 4
    return -1


fn _parse_headers(mut conn: Conn, terminator: Int) raises -> HeaderBlock:
    var raw = List[UInt8]()
    for i in range(terminator):
        raw.append(conn.peek(i))
    conn.consume(terminator)
    var text = String(from_utf8=Span(raw))
    var lines = List[String]()
    var start = 0
    while start < len(text.as_bytes()):
        var end = text.find("\r\n", start)
        if end < 0:
            end = len(text.as_bytes())
        if end > start:
            lines.append(String(text[byte=start:end]))
        start = end + 2
    if len(lines) == 0:
        raise Error("ProtocolError|HTTP response had no status line")
    var status_line = lines[0]
    var first = status_line.find(" ")
    if first < 0:
        raise Error("ProtocolError|HTTP status line is malformed")
    var second = status_line.find(" ", first + 1)
    if second < 0:
        second = len(status_line.as_bytes())
    var status = Int(status_line[byte = first + 1 : second])
    var headers = List[String]()
    for i in range(1, len(lines)):
        headers.append(lines[i])
    return HeaderBlock(status, headers^)


fn _read_exact(mut conn: Conn, count: Int, deadline: Int) raises -> String:
    while conn.buffered() < count:
        if conn.fill(deadline) <= 0:
            raise Error("TransportError|connection closed mid-body")
    var raw = List[UInt8]()
    for i in range(count):
        raw.append(conn.peek(i))
    conn.consume(count)
    return String(from_utf8=Span(raw))


fn _read_chunked(mut conn: Conn, deadline: Int) raises -> String:
    """Reassemble a chunked body, ignoring any trailer section."""
    var body = String()
    var total = 0
    while True:
        var size = _read_chunk_size(conn, deadline)
        if size == 0:
            break
        total += size
        if total > MAX_BODY_BYTES:
            raise Error("ProtocolError|HTTP body exceeded the size limit")
        body += _read_exact(conn, size, deadline)
        _ = _read_line(conn, deadline)
    # Consume the trailer, which is terminated by a bare CRLF.
    while True:
        var line = _read_line(conn, deadline)
        if not line:
            break
    return body


fn _read_line(mut conn: Conn, deadline: Int) raises -> String:
    while True:
        for i in range(conn.buffered() - 1):
            if conn.peek(i) == 0x0D and conn.peek(i + 1) == 0x0A:
                var raw = List[UInt8]()
                for n in range(i):
                    raw.append(conn.peek(n))
                conn.consume(i + 2)
                return String(from_utf8=Span(raw))
        if conn.buffered() > MAX_HEADER_BYTES:
            raise Error(
                "ProtocolError|HTTP chunk header exceeded the size limit"
            )
        if conn.fill(deadline) <= 0:
            raise Error("TransportError|connection closed mid-chunk")


fn _read_chunk_size(mut conn: Conn, deadline: Int) raises -> Int:
    var line = _read_line(conn, deadline)
    var semicolon = line.find(";")
    if semicolon >= 0:
        line = String(line[byte=0:semicolon])
    line = String(line.strip())
    var value = 0
    var bytes = line.as_bytes()
    if len(bytes) == 0:
        raise Error("ProtocolError|HTTP chunk size is missing")
    for i in range(len(bytes)):
        var byte = Int(bytes[i])
        if byte >= 48 and byte <= 57:
            value = value * 16 + byte - 48
        elif byte >= 97 and byte <= 102:
            value = value * 16 + byte - 87
        elif byte >= 65 and byte <= 70:
            value = value * 16 + byte - 55
        else:
            raise Error("ProtocolError|HTTP chunk size is not hexadecimal")
    return value


fn read_body(
    mut conn: Conn, headers: HeaderBlock, deadline: Int
) raises -> String:
    var encoding = headers.value("transfer-encoding").lower()
    if encoding.find("chunked") >= 0:
        return _read_chunked(conn, deadline)
    var length = headers.value("content-length")
    if length:
        var count = Int(length)
        if count > MAX_BODY_BYTES:
            raise Error("ProtocolError|HTTP body exceeded the size limit")
        return _read_exact(conn, count, deadline)
    # No framing header: the body runs to end of stream.
    while conn.fill(deadline) > 0:
        if conn.buffered() > MAX_BODY_BYTES:
            raise Error("ProtocolError|HTTP body exceeded the size limit")
    var raw = List[UInt8]()
    for i in range(conn.buffered()):
        raw.append(conn.peek(i))
    conn.consume(conn.buffered())
    return String(from_utf8=Span(raw))


fn post_json(
    endpoint: Endpoint,
    path: String,
    body: String,
    client_version: String,
    token: String,
    ca_file: String,
    timeout_ms: Int,
) raises -> Response:
    """Send one JSON POST and read the whole response.

    A fresh connection per call keeps failure handling simple: there is no
    pooled socket that a deployment can close between requests, so a stale
    connection can never be mistaken for a Convex error.
    """
    var deadline = now_ms() + timeout_ms
    var conn = connect(
        endpoint.host, endpoint.port, endpoint.tls, ca_file, timeout_ms
    )
    var request = String("POST ")
    request += path
    request += " HTTP/1.1\r\nHost: "
    request += endpoint.host
    if (endpoint.tls and endpoint.port != 443) or (
        not endpoint.tls and endpoint.port != 80
    ):
        request += ":"
        request += String(endpoint.port)
    request += (
        "\r\nContent-Type: application/json\r\nAccept: application/json\r\n"
    )
    request += "Convex-Client: "
    request += client_version
    request += "\r\n"
    if token:
        request += "Authorization: Bearer "
        request += token
        request += "\r\n"
    request += "Content-Length: "
    request += String(len(body.as_bytes()))
    request += "\r\nConnection: close\r\n\r\n"
    request += body
    conn.write_all(request.as_bytes(), deadline)
    var headers = read_headers(conn, deadline)
    var payload = read_body(conn, headers, deadline)
    conn.shutdown()
    return Response(headers.status, payload)
