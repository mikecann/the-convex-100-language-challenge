//// Codec coverage for the pieces this client implements itself: JSON,
//// HTTP/1.1 response parsing, and WebSocket framing.
////
//// These are the layers where a subtle mistake would look like Convex drift,
//// so each one is exercised against the cases that actually bite: whole
//// numbers spelled as floats, astral characters split across frames, chunked
//// bodies, and control frames arriving mid-message.

import convex
import convex_check as check
import convex_http
import convex_json.{
  JsonArray, JsonBool, JsonFloat, JsonInt, JsonNull, JsonObject, JsonString,
} as json
import convex_ws as ws
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string

pub fn main() -> Nil {
  json_round_trips()
  json_number_semantics()
  json_rejections()
  http_parsing()
  websocket_framing()
  check.done("convex_codec_test")
}

fn json_round_trips() -> Nil {
  let value =
    JsonObject([
      #("unicode", JsonString("Hello, 世界 👋")),
      #(
        "nested",
        JsonObject([
          #("booleans", JsonArray([JsonBool(True), JsonBool(False)])),
          #("number", JsonFloat(42.5)),
          #("nil", JsonNull),
        ]),
      ),
    ])
  let encoded = json.to_string(value)
  check.ok("round trip preserves the value", json.parse(encoded) == Ok(value))
  // Key order is preserved so a value read from Convex can be written back
  // unchanged, which is what the echo conformance test checks.
  check.equal_string(
    "object key order is preserved",
    encoded,
    "{\"unicode\":\"Hello, 世界 👋\",\"nested\":{\"booleans\":[true,false],\"number\":42.5,\"nil\":null}}",
  )

  check.ok(
    "escaped surrogate pair decodes to one emoji",
    json.parse("\"\\uD83D\\uDE00\"") == Ok(JsonString("😀")),
  )
  check.ok(
    "short escapes decode",
    json.parse("\"a\\nb\\tc\\\"d\\\\e\\/f\"")
      == Ok(JsonString("a\nb\tc\"d\\e/f")),
  )
  check.ok(
    "control characters are escaped on the way out",
    json.to_string(JsonString("\u{0001}")) == "\"\\u0001\"",
  )
  check.ok(
    "empty containers round trip",
    json.parse("{}") == Ok(JsonObject([])),
  )
  check.ok("empty arrays round trip", json.parse("[]") == Ok(JsonArray([])))
  check.ok(
    "whitespace between tokens is ignored",
    json.parse(" { \"a\" : [ 1 , 2 ] } ")
      == Ok(JsonObject([#("a", JsonArray([JsonInt(1), JsonInt(2)]))])),
  )
}

/// Convex may spell a whole number either way, so the integer decoder has to
/// accept both without accepting anything that would lose information.
fn json_number_semantics() -> Nil {
  check.ok("integers stay integers", json.parse("7") == Ok(JsonInt(7)))
  check.ok("floats stay floats", json.parse("7.0") == Ok(JsonFloat(7.0)))
  check.ok("exponent form parses", json.parse("1e3") == Ok(JsonFloat(1000.0)))
  check.ok(
    "negative exponent form parses",
    json.parse("-2.5e-1") == Ok(JsonFloat(-0.25)),
  )

  check.ok(
    "an integral float decodes as an integer",
    json.integral_int(JsonFloat(1.0)) == Ok(1),
  )
  check.ok(
    "a plain integer decodes as an integer",
    json.integral_int(JsonInt(0)) == Ok(0),
  )
  check.ok(
    "a negative integral float decodes",
    json.integral_int(JsonFloat(-3.0)) == Ok(-3),
  )
  check.ok(
    "a fraction is rejected",
    json.integral_int(JsonFloat(1.5)) == Error(Nil),
  )
  check.ok(
    "a quoted number is rejected",
    json.integral_int(JsonString("1")) == Error(Nil),
  )
  check.ok(
    "a value beyond the signed 64-bit range is rejected",
    json.integral_int(JsonFloat(1.0e30)) == Error(Nil),
  )

  let version =
    JsonObject([#("querySet", JsonInt(3)), #("big", JsonFloat(5.0e9))])
  check.ok("u32 fields decode", json.u32_field(version, "querySet") == Ok(3))
  check.ok(
    "u32 fields reject values above the wire range",
    json.u32_field(version, "big") == Error(Nil),
  )
}

fn json_rejections() -> Nil {
  check.ok("trailing content is rejected", is_error(json.parse("{} {}")))
  check.ok(
    "duplicate object keys are rejected",
    is_error(json.parse("{\"a\":1,\"a\":2}")),
  )
  check.ok("a leading zero is rejected", is_error(json.parse("01")))
  check.ok("an incomplete fraction is rejected", is_error(json.parse("1.")))
  check.ok("truncated input is rejected", is_error(json.parse("{\"a\":")))
  check.ok("trailing commas are rejected", is_error(json.parse("[1,]")))
  check.ok("bare words are rejected", is_error(json.parse("nope")))
  check.ok(
    "unescaped control characters are rejected",
    is_error(json.parse("\"a\nb\"")),
  )
  check.ok(
    "an unpaired surrogate is rejected",
    is_error(json.parse("\"\\uD83D\"")),
  )
  check.ok(
    "invalid UTF-8 bytes are rejected",
    is_error(json.parse_bits(<<"\"":utf8, 0xFF, "\"":utf8>>)),
  )
  check.ok(
    "log lines must be strings",
    json.log_lines(JsonObject([#("logLines", JsonArray([JsonInt(1)]))]))
      == Error(Nil),
  )
  check.ok(
    "absent log lines are an empty list",
    json.log_lines(JsonObject([])) == Ok([]),
  )
}

fn http_parsing() -> Nil {
  let assert Ok(url) = convex_http.parse_url("https://example.convex.cloud/")
  check.equal_string("https host", url.host, "example.convex.cloud")
  check.equal_int("https default port", url.port, 443)
  check.equal_string("a trailing slash is not a path", url.base_path, "")

  let assert Ok(local) = convex_http.parse_url("http://127.0.0.1:3210")
  check.equal_int("explicit port", local.port, 3210)
  check.equal_string(
    "authority carries the port",
    local.authority,
    "127.0.0.1:3210",
  )
  check.ok(
    "a scheme other than http is refused",
    is_error(convex_http.parse_url("ws://example.convex.cloud")),
  )
  check.ok(
    "URL header injection is refused",
    is_error(convex_http.parse_url(
      "https://example.convex.cloud\r\nX-Evil: yes",
    )),
  )

  let request = convex_http.render_request(local, "POST", "/api/query", [], 12)
  check.ok(
    "the request line carries the target",
    request
      == "POST /api/query HTTP/1.1\r\nhost: 127.0.0.1:3210\r\ncontent-length: 12\r\nconnection: close\r\n\r\n",
  )

  let assert Ok(head) =
    convex_http.parse_head(<<
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked":utf8,
    >>)
  check.equal_int("status parses", head.status, 200)
  check.ok(
    "header names are lowercased",
    convex_http.header(head, "content-type") == Ok("application/json"),
  )
  check.ok(
    "duplicate framing headers are rejected",
    is_error(
      convex_http.parse_head(bit_array.from_string(
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 1",
      )),
    ),
  )

  check.ok(
    "a function envelope survives a non-2xx status",
    case
      convex.decode_response(
        560,
        bit_array.from_string(
          "{\"status\":\"error\",\"errorMessage\":\"boom\",\"errorData\":{\"code\":\"EXPECTED\"},\"logLines\":[]}",
        ),
      )
    {
      Error(error) -> error.name == "FunctionError" && error.message == "boom"
      Ok(_) -> False
    },
  )
  check.ok(
    "a non-2xx success-shaped body is rejected",
    case
      convex.decode_response(
        500,
        bit_array.from_string(
          "{\"status\":\"success\",\"value\":1,\"logLines\":[]}",
        ),
      )
    {
      Error(error) -> error.name == "ProtocolError"
      Ok(_) -> False
    },
  )
}

fn websocket_framing() -> Nil {
  check.equal_string(
    "the accept header follows RFC 6455",
    ws.expected_accept("dGhlIHNhbXBsZSBub25jZQ=="),
    "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
  )

  let key = "dGhlIHNhbXBsZSBub25jZQ=="
  check.ok(
    "the upgrade requires both case-insensitive protocol tokens",
    ws.validate_upgrade(
      bit_array.from_string(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: WebSocket\r\nConnection: keep-alive, UpGrAdE\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
      ),
      key,
    )
      == Ok(Nil),
  )
  check.ok(
    "a missing Connection upgrade token is rejected",
    is_error(ws.validate_upgrade(
      bit_array.from_string(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: keep-alive\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=",
      ),
      key,
    )),
  )

  // A short unmasked text frame from a server.
  let hello = <<0x81, 0x05, "hello":utf8>>
  check.ok(
    "a whole text frame decodes",
    case ws.next(ws.feed(ws.new_decoder(), hello)) {
      ws.Decoded(ws.TextMessage("hello"), _) -> True
      _ -> False
    },
  )

  // The same frame delivered one byte at a time proves the decoder keeps its
  // state between reads instead of restarting at a false boundary.
  check.ok("a byte-at-a-time frame decodes", drip_decodes(hello, "hello"))

  // An astral character split across two continuation frames must not be
  // decoded until the whole message has arrived.
  let split =
    <<0x01, 0x02, 0xF0, 0x9F>>
    |> bit_array.append(<<0x80, 0x02, 0x98, 0x80>>)
  check.ok(
    "a split character decodes once complete",
    case ws.next(ws.feed(ws.new_decoder(), split)) {
      ws.NeedMore(decoder) ->
        case ws.next(decoder) {
          ws.Decoded(ws.TextMessage("😀"), _) -> True
          _ -> False
        }
      _ -> False
    },
  )

  // A ping may legally interrupt a fragmented message.
  let interrupted = <<0x01, 0x01, "a":utf8, 0x89, 0x00, 0x80, 0x01, "b":utf8>>
  check.ok(
    "a control frame may interrupt a message",
    case ws.next(ws.feed(ws.new_decoder(), interrupted)) {
      ws.NeedMore(decoder) ->
        case ws.next(decoder) {
          ws.Decoded(ws.Ping(_), decoder) ->
            case ws.next(decoder) {
              ws.Decoded(ws.TextMessage("ab"), _) -> True
              _ -> False
            }
          _ -> False
        }
      _ -> False
    },
  )

  check.ok(
    "a masked server frame is refused",
    case
      ws.next(ws.feed(ws.new_decoder(), <<0x81, 0x81, 0, 0, 0, 0, "x":utf8>>))
    {
      ws.Failed(_) -> True
      _ -> False
    },
  )
  check.ok(
    "a reserved bit is refused",
    case ws.next(ws.feed(ws.new_decoder(), <<0xC1, 0x01, "x":utf8>>)) {
      ws.Failed(_) -> True
      _ -> False
    },
  )
  check.ok(
    "a fragmented control frame is refused",
    case ws.next(ws.feed(ws.new_decoder(), <<0x09, 0x00>>)) {
      ws.Failed(_) -> True
      _ -> False
    },
  )
  check.ok(
    "a continuation without a start is refused",
    case ws.next(ws.feed(ws.new_decoder(), <<0x80, 0x00>>)) {
      ws.Failed(_) -> True
      _ -> False
    },
  )
  check.ok(
    "a non-minimal extended length is refused",
    case ws.next(ws.feed(ws.new_decoder(), <<0x81, 126, 0, 1, "x":utf8>>)) {
      ws.Failed(_) -> True
      _ -> False
    },
  )
  check.ok(
    "an invalid close code is refused",
    case ws.next(ws.feed(ws.new_decoder(), <<0x88, 0x02, 0x03, 0xED>>)) {
      ws.Failed(_) -> True
      _ -> False
    },
  )
  check.ok(
    "a close frame decodes its code",
    case ws.next(ws.feed(ws.new_decoder(), <<0x88, 0x02, 0x03, 0xE8>>)) {
      ws.Decoded(ws.Close(1000, ""), _) -> True
      _ -> False
    },
  )
  check.ok("an empty buffer asks for more", case ws.next(ws.new_decoder()) {
    ws.NeedMore(_) -> True
    _ -> False
  })

  // A client frame this module produced must be masked, and must unmask back
  // to the original text.
  let encoded = ws.text_frame("ping")
  check.ok("client frames set the mask bit", masked(encoded))
  check.equal_string(
    "client frames unmask to the original",
    unmask(encoded),
    "ping",
  )

  // A 16-bit extended length is used past 125 bytes.
  let long = ws.text_frame(string.repeat("a", 200))
  check.ok("extended lengths are used", case long {
    <<_first, 0xFE, _rest:bits>> -> True
    _ -> False
  })
}

/// Feed one byte at a time. A decoder that restarted at a false frame
/// boundary would either fail or produce the wrong message here.
fn drip_decodes(frame: BitArray, expected: String) -> Bool {
  let #(_decoder, messages) =
    list.range(0, bit_array.byte_size(frame) - 1)
    |> list.fold(#(ws.new_decoder(), []), fn(state, index) {
      let #(decoder, seen) = state
      let assert Ok(byte) = bit_array.slice(frame, index, 1)
      case ws.next(ws.feed(decoder, byte)) {
        ws.NeedMore(decoder) -> #(decoder, seen)
        ws.Decoded(message, decoder) -> #(decoder, [message, ..seen])
        ws.Failed(_) -> #(decoder, seen)
      }
    })
  messages == [ws.TextMessage(expected)]
}

fn masked(frame: BitArray) -> Bool {
  case frame {
    <<_first, mask_bit:size(1), _length:size(7), _rest:bits>> -> mask_bit == 1
    _ -> False
  }
}

/// Reverse this module's own masking so an encoded frame can be checked
/// without a server on the other end.
fn unmask(frame: BitArray) -> String {
  case frame {
    <<_first, _mask:size(1), length:size(7), key:bytes-size(4), payload:bits>> -> {
      let bytes =
        list.range(0, length - 1)
        |> list.fold(<<>>, fn(acc, index) {
          let assert Ok(<<byte>>) = bit_array.slice(payload, index, 1)
          let assert Ok(<<key_byte>>) = bit_array.slice(key, index % 4, 1)
          <<acc:bits, int.bitwise_exclusive_or(byte, key_byte)>>
        })
      case bit_array.to_string(bytes) {
        Ok(text) -> text
        Error(_) -> ""
      }
    }
    _ -> ""
  }
}

fn is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}
