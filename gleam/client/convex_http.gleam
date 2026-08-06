//// HTTP/1.1 for Convex, spoken directly over a socket.
////
//// Convex's HTTP API is one POST with a JSON body, so the client writes the
//// request and reads the response itself instead of pulling in a general HTTP
//// stack. The same head parser is reused by the WebSocket handshake, which is
//// an HTTP request whose connection deliberately stays open.

import convex_sys.{type Socket, type Transport, Tcp, Tls}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// Largest response head this client will read before giving up. A server that
/// never finishes its headers must not be able to grow the process forever.
const max_head_bytes = 65_536

/// Largest response body. Convex query results in this demonstration are tiny;
/// the bound exists so a runaway response is a clear error, not memory growth.
const max_body_bytes = 8_388_608

/// A deployment origin, split into the parts a request needs.
pub type Url {
  Url(
    transport: Transport,
    host: String,
    port: Int,
    /// Value for the `host` header, including the port when it is not the
    /// default for the scheme.
    authority: String,
    /// Prefix for every request target, empty for a bare origin.
    base_path: String,
  )
}

pub type Response {
  Response(status: Int, headers: List(#(String, String)), body: BitArray)
}

/// The status line and headers of a response, before any body is read.
pub type Head {
  Head(status: Int, headers: List(#(String, String)))
}

/// Parse a Convex deployment URL such as `https://example.convex.cloud`.
pub fn parse_url(text: String) -> Result(Url, String) {
  case valid_url_text(text) {
    False ->
      Error(
        "Convex URL contains whitespace, control characters, or unsupported components",
      )
    True -> parse_valid_url(text)
  }
}

fn parse_valid_url(text: String) -> Result(Url, String) {
  case split_scheme(text) {
    Ok(#(transport, default_port, rest)) -> {
      let #(authority, path) = case string.split_once(rest, "/") {
        Ok(#(authority, path)) -> #(authority, "/" <> path)
        Error(_) -> #(rest, "")
      }
      use #(host, port) <- result.try(split_port(authority, default_port))
      case host {
        "" -> Error("Convex URL has no host")
        _ ->
          Ok(Url(
            transport: transport,
            host: host,
            port: port,
            authority: authority,
            base_path: normalise_base_path(path),
          ))
      }
    }
    Error(message) -> Error(message)
  }
}

fn valid_url_text(text: String) -> Bool {
  bit_array.byte_size(bit_array.from_string(text)) <= 4096
  && text == string.trim(text)
  && !string.contains(text, "@")
  && !string.contains(text, "?")
  && !string.contains(text, "#")
  && list.all(string.to_utf_codepoints(text), fn(codepoint) {
    let value = string.utf_codepoint_to_int(codepoint)
    value > 0x20 && value != 0x7F
  })
}

fn split_scheme(text: String) -> Result(#(Transport, Int, String), String) {
  case string.lowercase(text) {
    "https://" <> _ -> Ok(#(Tls, 443, string.drop_start(text, 8)))
    "http://" <> _ -> Ok(#(Tcp, 80, string.drop_start(text, 7)))
    _ -> Error("Convex URL must use http or https")
  }
}

fn split_port(
  authority: String,
  default_port: Int,
) -> Result(#(String, Int), String) {
  case string.split_once(authority, ":") {
    Error(_) -> Ok(#(authority, default_port))
    Ok(#(host, port)) ->
      case int.parse(port) {
        Ok(port) if port > 0 && port < 65_536 -> Ok(#(host, port))
        _ -> Error("Convex URL has an invalid port")
      }
  }
}

/// A trailing slash on the deployment URL is common and means nothing, so it
/// is dropped rather than turned into an empty path segment.
fn normalise_base_path(path: String) -> String {
  case path {
    "/" -> ""
    other -> other
  }
}

/// Perform one request and read the complete response.
///
/// The connection is closed afterwards. Convex calls in this demonstration are
/// occasional, and a fresh connection keeps failure handling simple: there is
/// no pooled socket that can be found stale by the next caller.
pub fn request(
  url: Url,
  method: String,
  path: String,
  headers: List(#(String, String)),
  body: BitArray,
  timeout: Int,
  verify_peer: Bool,
) -> Result(Response, String) {
  case bit_array.byte_size(body) > max_body_bytes {
    True -> Error("HTTP request body is too large")
    False ->
      request_within_limit(
        url,
        method,
        path,
        headers,
        body,
        timeout,
        verify_peer,
      )
  }
}

fn request_within_limit(
  url: Url,
  method: String,
  path: String,
  headers: List(#(String, String)),
  body: BitArray,
  timeout: Int,
  verify_peer: Bool,
) -> Result(Response, String) {
  let deadline = convex_sys.monotonic_ms() + timeout
  use socket <- result.try(convex_sys.connect(
    url.transport,
    url.host,
    url.port,
    timeout,
    verify_peer,
  ))
  let outcome = exchange(socket, url, method, path, headers, body, deadline)
  convex_sys.close(socket)
  outcome
}

fn exchange(
  socket: Socket,
  url: Url,
  method: String,
  path: String,
  headers: List(#(String, String)),
  body: BitArray,
  deadline: Int,
) -> Result(Response, String) {
  let request =
    render_request(url, method, path, headers, bit_array.byte_size(body))
  use _ <- result.try(convex_sys.send(
    socket,
    <<request:utf8, body:bits>>,
    remaining(deadline),
  ))
  use #(head, rest) <- result.try(read_head(socket, <<>>, deadline))
  use head <- result.try(parse_head(head))
  use body <- result.try(read_body(socket, head, rest, deadline))
  Ok(Response(status: head.status, headers: head.headers, body: body))
}

/// Build the request line and headers. `connection: close` is explicit so the
/// server does not keep a socket open that this client will never reuse.
pub fn render_request(
  url: Url,
  method: String,
  path: String,
  headers: List(#(String, String)),
  content_length: Int,
) -> String {
  let lines =
    [
      method <> " " <> url.base_path <> path <> " HTTP/1.1",
      "host: " <> url.authority,
      "content-length: " <> int.to_string(content_length),
      "connection: close",
    ]
    |> list.append(
      list.map(headers, fn(header) { header.0 <> ": " <> header.1 }),
    )
  string.join(lines, "\r\n") <> "\r\n\r\n"
}

/// Read until the blank line that ends the head, returning the head bytes and
/// whatever body bytes arrived in the same read.
pub fn read_head(
  socket: Socket,
  buffer: BitArray,
  deadline: Int,
) -> Result(#(BitArray, BitArray), String) {
  case split_head(buffer, <<>>) {
    Ok(#(head, rest)) ->
      case bit_array.byte_size(head) > max_head_bytes {
        True -> Error("HTTP response head is too large")
        False -> Ok(#(head, rest))
      }
    Error(_) ->
      case bit_array.byte_size(buffer) > max_head_bytes {
        True -> Error("HTTP response head is too large")
        False -> {
          use chunk <- result.try(read_more(socket, deadline))
          read_head(socket, <<buffer:bits, chunk:bits>>, deadline)
        }
      }
  }
}

fn split_head(
  input: BitArray,
  seen: BitArray,
) -> Result(#(BitArray, BitArray), Nil) {
  case input {
    <<"\r\n\r\n":utf8, rest:bits>> -> Ok(#(seen, rest))
    <<byte, rest:bits>> -> split_head(rest, <<seen:bits, byte>>)
    _ -> Error(Nil)
  }
}

/// Parse a status line and headers. Header names are lowercased once here so
/// every later lookup is a plain comparison.
pub fn parse_head(head: BitArray) -> Result(Head, String) {
  use text <- result.try(
    bit_array.to_string(head)
    |> result.replace_error("HTTP response head is not valid UTF-8"),
  )
  case string.split(text, "\r\n") {
    [status_line, ..header_lines] -> {
      use status <- result.try(parse_status(status_line))
      use headers <- result.try(
        list.try_map(header_lines, parse_header)
        |> result.replace_error("HTTP response has a malformed header"),
      )
      case duplicate_header(headers) {
        True -> Error("HTTP response repeats a header")
        False -> Ok(Head(status: status, headers: headers))
      }
    }
    [] -> Error("HTTP response has no status line")
  }
}

fn parse_status(line: String) -> Result(Int, String) {
  case string.split(line, " ") {
    [version, code, ..] ->
      case
        version == "HTTP/1.0" || version == "HTTP/1.1",
        string.length(code) == 3,
        int.parse(code)
      {
        True, True, Ok(status) if status >= 100 && status <= 999 -> Ok(status)
        _, _, _ -> Error("HTTP response has a malformed status line")
      }
    _ -> Error("HTTP response has a malformed status line")
  }
}

fn parse_header(line: String) -> Result(#(String, String), Nil) {
  use #(name, value) <- result.try(string.split_once(line, ":"))
  let name = string.lowercase(string.trim(name))
  case name == "" {
    True -> Error(Nil)
    False -> Ok(#(name, string.trim(value)))
  }
}

fn duplicate_header(headers: List(#(String, String))) -> Bool {
  case headers {
    [] -> False
    [first, ..rest] ->
      list.any(rest, fn(entry) { entry.0 == first.0 }) || duplicate_header(rest)
  }
}

/// Look up a header that has already been lowercased by `parse_head`.
pub fn header(head: Head, name: String) -> Result(String, Nil) {
  case list.filter(head.headers, fn(entry) { entry.0 == name }) {
    [#(_, value)] -> Ok(value)
    _ -> Error(Nil)
  }
}

fn read_body(
  socket: Socket,
  head: Head,
  buffer: BitArray,
  deadline: Int,
) -> Result(BitArray, String) {
  case header(head, "transfer-encoding"), header(head, "content-length") {
    Ok(_), Ok(_) -> Error("HTTP response has ambiguous framing")
    Ok(encoding), Error(_) ->
      case string.lowercase(string.trim(encoding)) == "chunked" {
        True -> read_chunked(socket, buffer, [], 0, deadline)
        False -> Error("unsupported HTTP transfer-encoding")
      }
    Error(_), length ->
      case length {
        Ok(length) ->
          case int.parse(string.trim(length)) {
            Ok(length) if length >= 0 && length <= max_body_bytes ->
              read_exactly(socket, buffer, length, deadline)
            _ -> Error("HTTP response has an invalid content-length")
          }
        // Without a length the body ends when the server closes, which is
        // exactly what `connection: close` invites it to do.
        Error(_) ->
          read_until_close(
            socket,
            case buffer {
              <<>> -> []
              _ -> [buffer]
            },
            bit_array.byte_size(buffer),
            deadline,
          )
      }
  }
}

fn read_exactly(
  socket: Socket,
  buffer: BitArray,
  length: Int,
  deadline: Int,
) -> Result(BitArray, String) {
  read_exactly_chunks(
    socket,
    case buffer {
      <<>> -> []
      _ -> [buffer]
    },
    bit_array.byte_size(buffer),
    length,
    deadline,
  )
}

fn read_exactly_chunks(
  socket: Socket,
  chunks: List(BitArray),
  total: Int,
  length: Int,
  deadline: Int,
) -> Result(BitArray, String) {
  case total >= length {
    True ->
      convex_sys.concat_binaries(list.reverse(chunks))
      |> bit_array.slice(0, length)
      |> result.replace_error("HTTP response body was truncated")
    False -> {
      use chunk <- result.try(read_more(socket, deadline))
      read_exactly_chunks(
        socket,
        [chunk, ..chunks],
        total + bit_array.byte_size(chunk),
        length,
        deadline,
      )
    }
  }
}

fn read_until_close(
  socket: Socket,
  chunks: List(BitArray),
  total: Int,
  deadline: Int,
) -> Result(BitArray, String) {
  case total > max_body_bytes {
    True -> Error("HTTP response body is too large")
    False ->
      case convex_sys.recv(socket, 0, remaining(deadline)) {
        convex_sys.Received(chunk) ->
          read_until_close(
            socket,
            [chunk, ..chunks],
            total + bit_array.byte_size(chunk),
            deadline,
          )
        convex_sys.RecvClosed ->
          Ok(convex_sys.concat_binaries(list.reverse(chunks)))
        convex_sys.RecvTimeout -> Error("HTTP response timed out")
        convex_sys.RecvFailed(reason) -> Error(reason)
      }
  }
}

fn read_chunked(
  socket: Socket,
  buffer: BitArray,
  chunks: List(BitArray),
  total: Int,
  deadline: Int,
) -> Result(BitArray, String) {
  case split_line(buffer, <<>>) {
    Error(_) -> {
      case bit_array.byte_size(buffer) > 128 {
        True -> Error("HTTP chunk size line is too large")
        False -> {
          use chunk <- result.try(read_more(socket, deadline))
          read_chunked(
            socket,
            <<buffer:bits, chunk:bits>>,
            chunks,
            total,
            deadline,
          )
        }
      }
    }
    Ok(#(line, rest)) -> {
      use _ <- result.try(case bit_array.byte_size(line) <= 128 {
        True -> Ok(Nil)
        False -> Error("HTTP chunk size line is too large")
      })
      use size <- result.try(parse_chunk_size(line))
      case size {
        0 -> {
          use rest <- result.try(ensure_bytes(socket, rest, 2, deadline))
          use terminator <- result.try(
            bit_array.slice(rest, 0, 2)
            |> result.replace_error("malformed HTTP chunk terminator"),
          )
          case terminator == <<"\r\n":utf8>> {
            True -> Ok(convex_sys.concat_binaries(list.reverse(chunks)))
            False -> Error("HTTP trailers are not supported")
          }
        }
        _ ->
          case total + size > max_body_bytes {
            True -> Error("HTTP response body is too large")
            False -> {
              // Each chunk is followed by its own CRLF, which is consumed
              // along with the chunk before the next size line is read.
              use rest <- result.try(ensure_bytes(
                socket,
                rest,
                size + 2,
                deadline,
              ))
              use chunk <- result.try(
                bit_array.slice(rest, 0, size)
                |> result.replace_error("malformed HTTP chunk"),
              )
              use terminator <- result.try(
                bit_array.slice(rest, size, 2)
                |> result.replace_error("malformed HTTP chunk terminator"),
              )
              use _ <- result.try(case terminator == <<"\r\n":utf8>> {
                True -> Ok(Nil)
                False -> Error("malformed HTTP chunk terminator")
              })
              use tail <- result.try(
                bit_array.slice(
                  rest,
                  size + 2,
                  bit_array.byte_size(rest) - size - 2,
                )
                |> result.replace_error("malformed HTTP chunk"),
              )
              read_chunked(
                socket,
                tail,
                [chunk, ..chunks],
                total + size,
                deadline,
              )
            }
          }
      }
    }
  }
}

fn parse_chunk_size(line: BitArray) -> Result(Int, String) {
  use text <- result.try(
    bit_array.to_string(line)
    |> result.replace_error("malformed HTTP chunk size"),
  )
  case valid_hex(line), int.base_parse(text, 16) {
    True, Ok(size) if size >= 0 -> Ok(size)
    _, _ -> Error("malformed HTTP chunk size")
  }
}

fn valid_hex(input: BitArray) -> Bool {
  case input {
    <<>> -> False
    _ ->
      // Gleam guards cannot call helpers, so measure the line after excluding
      // the empty case. Chunk sizes above seven hex digits exceed the 8 MiB
      // body limit before the value could be used to allocate anything.
      case bit_array.byte_size(input) > 7 {
        True -> False
        False -> all_hex(input)
      }
  }
}

fn all_hex(input: BitArray) -> Bool {
  case input {
    <<>> -> True
    <<byte, rest:bits>> ->
      case
        { byte >= 0x30 && byte <= 0x39 }
        || { byte >= 0x41 && byte <= 0x46 }
        || { byte >= 0x61 && byte <= 0x66 }
      {
        True -> all_hex(rest)
        False -> False
      }
    // JSON-like HTTP metadata must be whole bytes. A raw BitArray may carry a
    // trailing partial byte, which cannot be a valid hexadecimal chunk size.
    _ -> False
  }
}

fn ensure_bytes(
  socket: Socket,
  buffer: BitArray,
  length: Int,
  deadline: Int,
) -> Result(BitArray, String) {
  case bit_array.byte_size(buffer) >= length {
    True -> Ok(buffer)
    False -> {
      case
        convex_sys.recv(
          socket,
          length - bit_array.byte_size(buffer),
          remaining(deadline),
        )
      {
        convex_sys.Received(chunk) ->
          ensure_bytes(socket, <<buffer:bits, chunk:bits>>, length, deadline)
        convex_sys.RecvClosed -> Error("HTTP connection closed early")
        convex_sys.RecvTimeout -> Error("HTTP response timed out")
        convex_sys.RecvFailed(reason) -> Error(reason)
      }
    }
  }
}

fn split_line(
  input: BitArray,
  seen: BitArray,
) -> Result(#(BitArray, BitArray), Nil) {
  case input {
    <<"\r\n":utf8, rest:bits>> -> Ok(#(seen, rest))
    <<byte, rest:bits>> -> split_line(rest, <<seen:bits, byte>>)
    _ -> Error(Nil)
  }
}

fn read_more(socket: Socket, deadline: Int) -> Result(BitArray, String) {
  case convex_sys.recv(socket, 0, remaining(deadline)) {
    convex_sys.Received(chunk) -> Ok(chunk)
    convex_sys.RecvClosed -> Error("HTTP connection closed early")
    convex_sys.RecvTimeout -> Error("HTTP response timed out")
    convex_sys.RecvFailed(reason) -> Error(reason)
  }
}

/// Milliseconds left before the deadline, never negative so a socket call
/// still returns promptly rather than blocking with a nonsensical timeout.
pub fn remaining(deadline: Int) -> Int {
  int.max(0, deadline - convex_sys.monotonic_ms())
}
