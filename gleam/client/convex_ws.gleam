//// RFC 6455 WebSocket client framing, written in Gleam.
////
//// Convex's sync protocol runs over a WebSocket, so the framing is part of
//// what this demonstration has to show rather than something to hide behind a
//// library. Two behaviours matter beyond "it works":
////
//// * Fragmented messages are reassembled before any text is decoded, so a
////   multi-byte character split across two frames is never mangled.
//// * The decoder is a value, not a process. Its buffer and partial-message
////   state survive a read timeout, so a slow peer cannot make the reader
////   restart at a byte that only looks like a frame boundary.

import convex_http
import convex_sys.{type Socket}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The fixed value RFC 6455 appends to the client key before hashing.
const handshake_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

/// Largest single message this client will reassemble. Convex transitions in
/// this demonstration are kilobytes; the bound turns a hostile or broken peer
/// into a clear protocol error instead of unbounded growth.
const max_message_bytes = 7_340_032

/// Largest handshake response head, matching the HTTP client's own bound.
const max_head_bytes = 65_536

pub type Message {
  TextMessage(text: String)
  BinaryMessage(payload: BitArray)
  Ping(payload: BitArray)
  Pong(payload: BitArray)
  Close(code: Int, reason: String)
}

/// Incremental frame decoder. Incoming TCP chunks stay separate until a whole
/// frame is present, avoiding a quadratic copy of every partial large frame.
/// `fragment` applies the same rule across continuation frames.
pub opaque type Decoder {
  Decoder(
    chunks: List(BitArray),
    buffered_bytes: Int,
    fragment: Option(Fragment),
  )
}

type Fragment {
  Fragment(opcode: Int, chunks: List(BitArray), bytes: Int)
}

/// One step of decoding: either a complete message, or a request for more
/// bytes, or a protocol failure that must retire the connection.
pub type Step {
  Decoded(message: Message, decoder: Decoder)
  NeedMore(decoder: Decoder)
  Failed(reason: String)
}

pub fn new_decoder() -> Decoder {
  Decoder(chunks: [], buffered_bytes: 0, fragment: None)
}

/// Add freshly read bytes. Buffered bytes are kept, which is what makes a read
/// timeout harmless part-way through a frame.
pub fn feed(decoder: Decoder, bytes: BitArray) -> Decoder {
  Decoder(
    ..decoder,
    chunks: [bytes, ..decoder.chunks],
    buffered_bytes: decoder.buffered_bytes + bit_array.byte_size(bytes),
  )
}

/// True when the decoder is holding bytes of a frame it has not finished. A
/// caller that wants to abandon a stalled connection can tell the difference
/// between "idle" and "mid-frame".
pub fn is_mid_message(decoder: Decoder) -> Bool {
  decoder.fragment != None || decoder.buffered_bytes > 0
}

/// Pull the next complete message out of the buffer.
pub fn next(decoder: Decoder) -> Step {
  let header = first_bytes(list.reverse(decoder.chunks), 10, [])
  case frame_wire_bytes(header) {
    Error(message) -> Failed(message)
    Ok(None) -> NeedMore(decoder)
    Ok(Some(frame_bytes)) ->
      case decoder.buffered_bytes < frame_bytes {
        True -> NeedMore(decoder)
        False -> {
          // Join once at the complete-frame boundary. The old implementation
          // appended on every TCP read, making a near-limit frame quadratic.
          let input =
            decoder.chunks
            |> list.reverse
            |> convex_sys.concat_binaries
          case parse_frame(input) {
            Error(message) -> Failed(message)
            Ok(None) -> Failed("complete WebSocket frame could not be decoded")
            Ok(Some(#(final, opcode, payload, rest))) -> {
              let rest_bytes = bit_array.byte_size(rest)
              let decoder =
                Decoder(
                  ..decoder,
                  chunks: case rest_bytes == 0 {
                    True -> []
                    False -> [rest]
                  },
                  buffered_bytes: rest_bytes,
                )
              apply_frame(decoder, final, opcode, payload)
            }
          }
        }
      }
  }
}

/// Copy at most the ten bytes needed to inspect an RFC 6455 frame header.
fn first_bytes(
  chunks: List(BitArray),
  remaining: Int,
  taken: List(BitArray),
) -> BitArray {
  case chunks, remaining {
    _, 0 | [], _ ->
      taken
      |> list.reverse
      |> convex_sys.concat_binaries
    [chunk, ..rest], _ -> {
      let size = bit_array.byte_size(chunk)
      case size <= remaining {
        True -> first_bytes(rest, remaining - size, [chunk, ..taken])
        False -> {
          let assert Ok(prefix) = bit_array.slice(chunk, 0, remaining)
          first_bytes([], 0, [prefix, ..taken])
        }
      }
    }
  }
}

/// Return the complete on-wire frame size as soon as its header is present.
/// Oversized frames fail from the header without retaining their payload.
fn frame_wire_bytes(header: BitArray) -> Result(Option(Int), String) {
  case header {
    <<
      final:size(1),
      reserved:size(3),
      opcode:size(4),
      masked:size(1),
      length:size(7),
      rest:bits,
    >> ->
      case
        reserved != 0,
        masked == 1,
        control_frame_is_valid(opcode, final == 1, length)
      {
        True, _, _ -> Error("reserved WebSocket bits are set")
        _, True, _ -> Error("server sent a masked WebSocket frame")
        _, _, False -> Error("fragmented or oversized control frame")
        False, False, True -> frame_wire_bytes_for_length(length, rest)
      }
    _ -> Ok(None)
  }
}

fn frame_wire_bytes_for_length(
  length: Int,
  rest: BitArray,
) -> Result(Option(Int), String) {
  case length {
    126 ->
      case rest {
        <<extended:size(16)-unsigned-big-int, _rest:bits>> ->
          case extended >= 126, extended <= max_message_bytes {
            False, _ -> Error("WebSocket length is not minimally encoded")
            _, False -> Error("WebSocket frame exceeds the client limit")
            True, True -> Ok(Some(4 + extended))
          }
        _ -> Ok(None)
      }
    127 ->
      case rest {
        <<extended:size(64)-unsigned-big-int, _rest:bits>> ->
          case extended >= 65_536, extended <= max_message_bytes {
            False, _ -> Error("WebSocket length is not minimally encoded")
            _, False -> Error("WebSocket frame exceeds the client limit")
            True, True -> Ok(Some(10 + extended))
          }
        _ -> Ok(None)
      }
    _ -> Ok(Some(2 + length))
  }
}

/// Fold one frame into the decoder. Control frames are always complete and may
/// legally arrive in the middle of a fragmented data message.
fn apply_frame(
  decoder: Decoder,
  final: Bool,
  opcode: Int,
  payload: BitArray,
) -> Step {
  case opcode {
    0x9 -> Decoded(Ping(payload), decoder)
    0xA -> Decoded(Pong(payload), decoder)
    0x8 -> decode_close(payload, decoder)
    0x0 ->
      case decoder.fragment {
        None -> Failed("continuation frame without a started message")
        Some(Fragment(started, chunks, bytes)) ->
          finish(
            decoder,
            final,
            started,
            [payload, ..chunks],
            bytes + bit_array.byte_size(payload),
          )
      }
    0x1 | 0x2 ->
      case decoder.fragment {
        Some(_) -> Failed("new data frame while a message was still arriving")
        None ->
          finish(
            decoder,
            final,
            opcode,
            [payload],
            bit_array.byte_size(payload),
          )
      }
    _ -> Failed("unknown WebSocket opcode")
  }
}

fn finish(
  decoder: Decoder,
  final: Bool,
  opcode: Int,
  chunks: List(BitArray),
  bytes: Int,
) -> Step {
  case bytes > max_message_bytes {
    True -> Failed("WebSocket message exceeds the client limit")
    False ->
      case final {
        False ->
          NeedMore(
            Decoder(..decoder, fragment: Some(Fragment(opcode, chunks, bytes))),
          )
        True -> {
          let bytes =
            chunks
            |> list.reverse
            |> convex_sys.concat_binaries
          case opcode {
            0x1 ->
              // Text is decoded only once the whole message is present, so a
              // character split across frames still decodes correctly.
              case bit_array.to_string(bytes) {
                Ok(text) -> Decoded(TextMessage(text), clear(decoder))
                Error(_) -> Failed("WebSocket text message is not valid UTF-8")
              }
            _ -> Decoded(BinaryMessage(bytes), clear(decoder))
          }
        }
      }
  }
}

fn clear(decoder: Decoder) -> Decoder {
  Decoder(..decoder, fragment: None)
}

fn decode_close(payload: BitArray, decoder: Decoder) -> Step {
  case payload {
    <<>> -> Decoded(Close(1005, ""), decoder)
    <<code:size(16)-unsigned-big-int, rest:bits>> ->
      case valid_close_code(code), bit_array.to_string(rest) {
        False, _ -> Failed("WebSocket close code is invalid")
        _, Error(_) -> Failed("WebSocket close reason is not valid UTF-8")
        True, Ok(reason) -> Decoded(Close(code, reason), decoder)
      }
    _ -> Failed("malformed WebSocket close frame")
  }
}

fn valid_close_code(code: Int) -> Bool {
  let outside_reserved_range = case code >= 1016 && code < 3000 {
    True -> False
    False -> True
  }
  code >= 1000
  && code < 5000
  && code != 1004
  && code != 1005
  && code != 1006
  && code != 1015
  && outside_reserved_range
}

/// Split one frame off the front of the buffer. `Ok(None)` means the frame is
/// still incomplete, which is not an error.
fn parse_frame(
  input: BitArray,
) -> Result(Option(#(Bool, Int, BitArray, BitArray)), String) {
  case input {
    <<
      final:size(1),
      reserved:size(3),
      opcode:size(4),
      masked:size(1),
      length:size(7),
      rest:bits,
    >> -> {
      case reserved != 0 {
        True -> Error("reserved WebSocket bits are set")
        False ->
          case control_frame_is_valid(opcode, final == 1, length) {
            False -> Error("fragmented or oversized control frame")
            True ->
              case extended_length(length, rest) {
                Error(message) -> Error(message)
                Ok(None) -> Ok(None)
                Ok(Some(#(length, rest))) ->
                  take_payload(final == 1, opcode, masked == 1, length, rest)
              }
          }
      }
    }
    _ -> Ok(None)
  }
}

/// Control frames carry at most 125 bytes and are never fragmented.
fn control_frame_is_valid(opcode: Int, final: Bool, length: Int) -> Bool {
  case opcode >= 0x8 {
    False -> True
    True -> final && length <= 125
  }
}

fn extended_length(
  length: Int,
  rest: BitArray,
) -> Result(Option(#(Int, BitArray)), String) {
  case length {
    126 ->
      case rest {
        <<extended:size(16)-unsigned-big-int, rest:bits>> ->
          case extended >= 126 {
            True -> Ok(Some(#(extended, rest)))
            False -> Error("WebSocket length is not minimally encoded")
          }
        _ -> Ok(None)
      }
    127 ->
      case rest {
        <<extended:size(64)-unsigned-big-int, rest:bits>> ->
          case extended < 65_536, extended > max_message_bytes {
            True, _ -> Error("WebSocket length is not minimally encoded")
            _, True -> Error("WebSocket frame exceeds the client limit")
            False, False -> Ok(Some(#(extended, rest)))
          }
        _ -> Ok(None)
      }
    _ -> Ok(Some(#(length, rest)))
  }
}

fn take_payload(
  final: Bool,
  opcode: Int,
  masked: Bool,
  length: Int,
  rest: BitArray,
) -> Result(Option(#(Bool, Int, BitArray, BitArray)), String) {
  case masked {
    // A server must not mask, and accepting a masked frame would hide a peer
    // that is not speaking the client half of the protocol.
    True -> Error("server sent a masked WebSocket frame")
    False ->
      case length > max_message_bytes {
        True -> Error("WebSocket frame exceeds the client limit")
        False ->
          case bit_array.byte_size(rest) >= length {
            False -> Ok(None)
            True -> {
              let assert Ok(payload) = bit_array.slice(rest, 0, length)
              let assert Ok(tail) =
                bit_array.slice(
                  rest,
                  length,
                  bit_array.byte_size(rest) - length,
                )
              Ok(Some(#(final, opcode, payload, tail)))
            }
          }
      }
  }
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

/// Encode a client text frame. Every client frame is masked with a fresh
/// random key, as RFC 6455 requires.
pub fn text_frame(text: String) -> BitArray {
  encode(0x1, bit_array.from_string(text))
}

pub fn pong_frame(payload: BitArray) -> BitArray {
  encode(0xA, payload)
}

pub fn close_frame(code: Int, reason: String) -> BitArray {
  encode(0x8, <<code:size(16)-big-int, reason:utf8>>)
}

fn encode(opcode: Int, payload: BitArray) -> BitArray {
  let length = bit_array.byte_size(payload)
  let key = convex_sys.random_bytes(4)
  let header = case length {
    _ if length < 126 -> <<
      1:size(1),
      0:size(3),
      opcode:size(4),
      1:size(1),
      length:size(7),
    >>
    _ if length < 65_536 -> <<
      1:size(1),
      0:size(3),
      opcode:size(4),
      1:size(1),
      126:size(7),
      length:size(16)-big-int,
    >>
    _ -> <<
      1:size(1),
      0:size(3),
      opcode:size(4),
      1:size(1),
      127:size(7),
      length:size(64)-big-int,
    >>
  }
  <<header:bits, key:bits, convex_sys.xor_repeating(payload, key):bits>>
}

// ---------------------------------------------------------------------------
// Handshake
// ---------------------------------------------------------------------------

/// Perform the opening handshake on an already connected socket.
///
/// Returns any bytes that arrived after the response head; the server may
/// legally start sending frames in the same packet, and dropping those bytes
/// would lose the first Convex transition.
pub fn handshake(
  socket: Socket,
  authority: String,
  path: String,
  headers: List(#(String, String)),
  deadline: Int,
) -> Result(BitArray, String) {
  let key = convex_sys.base64_encode(convex_sys.random_bytes(16))
  let request =
    string.join(
      list.append(
        [
          "GET " <> path <> " HTTP/1.1",
          "host: " <> authority,
          "upgrade: websocket",
          "connection: Upgrade",
          "sec-websocket-key: " <> key,
          "sec-websocket-version: 13",
        ],
        list.map(headers, fn(header) { header.0 <> ": " <> header.1 }),
      ),
      "\r\n",
    )
    <> "\r\n\r\n"
  use _ <- result.try(convex_sys.send(
    socket,
    <<request:utf8>>,
    int.max(0, deadline - convex_sys.monotonic_ms()),
  ))
  use #(head, rest) <- result.try(read_head(socket, <<>>, deadline))
  use _ <- result.try(validate_upgrade(head, key))
  Ok(rest)
}

/// Validate the response. The accept header proves the peer processed this
/// client's key rather than replaying a cached upgrade.
pub fn validate_upgrade(head: BitArray, key: String) -> Result(Nil, String) {
  use parsed <- result.try(convex_http.parse_head(head))
  use upgrade <- result.try(
    convex_http.header(parsed, "upgrade")
    |> result.replace_error("WebSocket Upgrade token is missing"),
  )
  use connection <- result.try(
    convex_http.header(parsed, "connection")
    |> result.replace_error("WebSocket Connection token is missing"),
  )
  use accept <- result.try(
    convex_http.header(parsed, "sec-websocket-accept")
    |> result.replace_error("WebSocket upgrade has no accept header"),
  )
  case
    parsed.status == 101,
    has_token(upgrade, "websocket"),
    has_token(connection, "upgrade"),
    accept == expected_accept(key),
    convex_http.header(parsed, "sec-websocket-extensions"),
    convex_http.header(parsed, "sec-websocket-protocol")
  {
    False, _, _, _, _, _ -> Error("WebSocket upgrade did not return HTTP 101")
    _, False, _, _, _, _ -> Error("WebSocket Upgrade token is missing")
    _, _, False, _, _, _ -> Error("WebSocket Connection token is missing")
    _, _, _, False, _, _ ->
      Error("WebSocket accept header does not match the key")
    _, _, _, _, Ok(_), _ -> Error("WebSocket selected an unrequested extension")
    _, _, _, _, _, Ok(_) ->
      Error("WebSocket selected an unrequested subprotocol")
    True, True, True, True, Error(_), Error(_) -> Ok(Nil)
  }
}

/// base64(sha1(key <> GUID)), the value RFC 6455 requires the server to echo.
pub fn expected_accept(key: String) -> String {
  convex_sys.base64_encode(
    convex_sys.sha1(bit_array.from_string(key <> handshake_guid)),
  )
}

fn has_token(value: String, token: String) -> Bool {
  value
  |> string.split(",")
  |> list.any(fn(part) { string.lowercase(string.trim(part)) == token })
}

fn read_head(
  socket: Socket,
  buffer: BitArray,
  deadline: Int,
) -> Result(#(BitArray, BitArray), String) {
  case split_head(buffer, <<>>) {
    Ok(#(head, rest)) ->
      case bit_array.byte_size(head) > max_head_bytes {
        True -> Error("WebSocket upgrade response head is too large")
        False -> Ok(#(head, rest))
      }
    Error(_) ->
      case bit_array.byte_size(buffer) > max_head_bytes {
        True -> Error("WebSocket upgrade response head is too large")
        False ->
          case
            convex_sys.recv(
              socket,
              0,
              int.max(0, deadline - convex_sys.monotonic_ms()),
            )
          {
            convex_sys.Received(chunk) ->
              read_head(socket, <<buffer:bits, chunk:bits>>, deadline)
            convex_sys.RecvClosed ->
              Error("WebSocket upgrade connection closed early")
            convex_sys.RecvTimeout -> Error("WebSocket upgrade timed out")
            convex_sys.RecvFailed(reason) -> Error(reason)
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
