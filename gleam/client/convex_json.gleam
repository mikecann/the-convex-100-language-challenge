//// JSON for Convex, written in Gleam rather than delegated to a library.
////
//// Two Convex details drive the design. Values must survive a round trip
//// unchanged, so objects keep their key order and integers never silently
//// become floats. And Convex may spell a whole number either way on the wire,
//// so decoding an integer is a deliberate, range-checked step
//// (`integral_int`) instead of a pattern match on one representation.

import convex_sys
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// A decoded JSON value. `JsonObject` keeps an ordered association list
/// because Convex arguments and results are re-encoded and compared elsewhere.
pub type Json {
  JsonNull
  JsonBool(Bool)
  JsonInt(Int)
  JsonFloat(Float)
  JsonString(String)
  JsonArray(List(Json))
  JsonObject(List(#(String, Json)))
}

/// Nesting bound for decoding. The adapter parses input it did not produce, so
/// a hostile document must exhaust a counter rather than the process stack.
const max_depth = 64

/// A shallow but extremely wide document can exhaust memory without reaching
/// the nesting bound. Count structural values before recursive decoding too.
const max_nodes = 65_536

/// Signed 64-bit range. Convex counters are teaching-sized integers; anything
/// outside this range is rejected instead of silently wrapping or losing
/// precision through a float.
pub const min_safe_int = -9_223_372_036_854_775_808

pub const max_safe_int = 9_223_372_036_854_775_807

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

/// Render a value as compact JSON text.
pub fn to_string(value: Json) -> String {
  value
  |> render([])
  |> list.reverse
  |> string.concat
}

/// Render into a reversed accumulator of chunks. Building one list and
/// concatenating once avoids repeatedly copying a growing string.
fn render(value: Json, acc: List(String)) -> List(String) {
  case value {
    JsonNull -> ["null", ..acc]
    JsonBool(True) -> ["true", ..acc]
    JsonBool(False) -> ["false", ..acc]
    JsonInt(number) -> [int.to_string(number), ..acc]
    JsonFloat(number) -> [float.to_string(number), ..acc]
    JsonString(text) -> [escape(text), ..acc]
    JsonArray(items) -> {
      let acc = render_items(items, ["[", ..acc])
      ["]", ..acc]
    }
    JsonObject(entries) -> {
      let acc = render_entries(entries, ["{", ..acc])
      ["}", ..acc]
    }
  }
}

fn render_items(items: List(Json), acc: List(String)) -> List(String) {
  case items {
    [] -> acc
    [only] -> render(only, acc)
    [first, ..rest] -> render_items(rest, [",", ..render(first, acc)])
  }
}

fn render_entries(
  entries: List(#(String, Json)),
  acc: List(String),
) -> List(String) {
  case entries {
    [] -> acc
    [#(key, value)] -> render(value, [":", escape(key), ..acc])
    [#(key, value), ..rest] ->
      render_entries(rest, [",", ..render(value, [":", escape(key), ..acc])])
  }
}

/// Quote and escape a string. Non-ASCII text is emitted as raw UTF-8, which is
/// what Convex expects and what keeps the emoji in the conformance suite
/// readable in captured evidence.
fn escape(text: String) -> String {
  let escaped =
    text
    |> bit_array.from_string
    |> escape_bytes([])
    |> list.reverse
    |> convex_sys.concat_binaries
  "\"" <> result.unwrap(bit_array.to_string(escaped), "") <> "\""
}

fn escape_bytes(input: BitArray, chunks: List(BitArray)) -> List(BitArray) {
  case convex_sys.scan_json_string(input) {
    convex_sys.StringQuote(chunk, rest) ->
      escape_bytes(rest, [<<"\\\"":utf8>>, chunk, ..chunks])
    convex_sys.StringEscape(chunk, rest) ->
      escape_bytes(rest, [<<"\\\\":utf8>>, chunk, ..chunks])
    convex_sys.StringControl(chunk, byte, rest) ->
      escape_bytes(rest, [
        bit_array.from_string(escape_control(byte)),
        chunk,
        ..chunks
      ])
    convex_sys.StringEnd(chunk) -> [chunk, ..chunks]
  }
}

fn escape_control(byte: Int) -> String {
  case byte {
    0x0A -> "\\n"
    0x0D -> "\\r"
    0x09 -> "\\t"
    0x08 -> "\\b"
    0x0C -> "\\f"
    other -> "\\u" <> pad_hex(other)
  }
}

fn pad_hex(value: Int) -> String {
  let digits = string.lowercase(int.to_base16(value))
  string.repeat("0", 4 - string.length(digits)) <> digits
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

/// Decode a complete JSON document. Trailing content is an error, so a
/// truncated or doubled NDJSON line cannot be mistaken for a valid command.
pub fn parse(text: String) -> Result(Json, String) {
  parse_bits(bit_array.from_string(text))
}

/// Decode a document that is still a byte string. The adapter reads bytes from
/// a socket, so it never has to build an intermediate `String` first.
pub fn parse_bits(input: BitArray) -> Result(Json, String) {
  use _ <- result.try(check_shape(input, False, False, 0, 1))
  use #(value, rest) <- result.try(parse_value(skip_space(input), 0))
  case skip_space(rest) {
    <<>> -> Ok(value)
    _ -> Error("trailing content after JSON value")
  }
}

fn check_shape(
  input: BitArray,
  quoted: Bool,
  escaped: Bool,
  depth: Int,
  nodes: Int,
) -> Result(Nil, String) {
  case nodes > max_nodes, depth > max_depth, input {
    True, _, _ -> Error("JSON has too many structural values")
    _, True, _ -> Error("JSON nesting is too deep")
    _, _, <<>> -> Ok(Nil)
    _, _, <<byte, rest:bits>> ->
      case quoted, escaped, byte {
        True, True, _ -> check_shape(rest, True, False, depth, nodes)
        True, False, 0x5C -> check_shape(rest, True, True, depth, nodes)
        True, False, 0x22 -> check_shape(rest, False, False, depth, nodes)
        True, False, _ -> check_shape(rest, True, False, depth, nodes)
        False, _, 0x22 -> check_shape(rest, True, False, depth, nodes)
        False, _, byte if byte == 0x7B || byte == 0x5B ->
          check_shape(rest, False, False, depth + 1, nodes + 1)
        False, _, byte if byte == 0x7D || byte == 0x5D ->
          check_shape(rest, False, False, depth - 1, nodes)
        False, _, 0x2C -> check_shape(rest, False, False, depth, nodes + 1)
        _, _, _ -> check_shape(rest, False, False, depth, nodes)
      }
    // BitArray can contain a trailing partial byte. JSON is byte-oriented, so
    // reject that input rather than leaving a compiler-visible unmatched case.
    _, _, _ -> Error("JSON input is not byte aligned")
  }
}

fn parse_value(input: BitArray, depth: Int) -> Result(#(Json, BitArray), String) {
  case depth > max_depth {
    True -> Error("JSON nesting is too deep")
    False ->
      case input {
        <<"null":utf8, rest:bits>> -> Ok(#(JsonNull, rest))
        <<"true":utf8, rest:bits>> -> Ok(#(JsonBool(True), rest))
        <<"false":utf8, rest:bits>> -> Ok(#(JsonBool(False), rest))
        <<"\"":utf8, rest:bits>> -> {
          use #(text, rest) <- result.try(parse_string(rest, []))
          Ok(#(JsonString(text), rest))
        }
        <<"[":utf8, rest:bits>> -> parse_array(skip_space(rest), [], depth + 1)
        <<"{":utf8, rest:bits>> ->
          parse_object(skip_space(rest), [], dict.new(), depth + 1)
        <<byte, _:bits>> ->
          case is_number_start(byte) {
            True -> parse_number(input)
            False -> Error("unexpected JSON byte")
          }
        _ -> Error("unexpected end of JSON input")
      }
  }
}

fn parse_array(
  input: BitArray,
  acc: List(Json),
  depth: Int,
) -> Result(#(Json, BitArray), String) {
  case input, acc {
    <<"]":utf8, rest:bits>>, [] -> Ok(#(JsonArray([]), rest))
    _, _ -> {
      use #(value, rest) <- result.try(parse_value(input, depth))
      case skip_space(rest) {
        <<",":utf8, rest:bits>> ->
          parse_array(skip_space(rest), [value, ..acc], depth)
        <<"]":utf8, rest:bits>> ->
          Ok(#(JsonArray(list.reverse([value, ..acc])), rest))
        _ -> Error("expected , or ] in JSON array")
      }
    }
  }
}

fn parse_object(
  input: BitArray,
  acc: List(#(String, Json)),
  seen: Dict(String, Nil),
  depth: Int,
) -> Result(#(Json, BitArray), String) {
  case input, acc {
    <<"}":utf8, rest:bits>>, [] -> Ok(#(JsonObject([]), rest))
    <<"\"":utf8, rest:bits>>, _ -> {
      use #(key, rest) <- result.try(parse_string(rest, []))
      use seen <- result.try(case dict.has_key(seen, key) {
        True -> Error("duplicate key in JSON object")
        False -> Ok(dict.insert(seen, key, Nil))
      })
      case skip_space(rest) {
        <<":":utf8, rest:bits>> -> {
          use #(value, rest) <- result.try(parse_value(skip_space(rest), depth))
          case skip_space(rest) {
            <<",":utf8, rest:bits>> ->
              parse_object(
                skip_space(rest),
                [#(key, value), ..acc],
                seen,
                depth,
              )
            <<"}":utf8, rest:bits>> ->
              Ok(#(JsonObject(list.reverse([#(key, value), ..acc])), rest))
            _ -> Error("expected , or } in JSON object")
          }
        }
        _ -> Error("expected : after JSON object key")
      }
    }
    _, _ -> Error("expected string key in JSON object")
  }
}

/// Decode string contents up to the closing quote. Escapes are expanded into
/// UTF-8 bytes as they are read so the accumulator is always valid so far.
fn parse_string(
  input: BitArray,
  chunks: List(BitArray),
) -> Result(#(String, BitArray), String) {
  case convex_sys.scan_json_string(input) {
    convex_sys.StringQuote(chunk, rest) ->
      case
        convex_sys.concat_binaries(list.reverse([chunk, ..chunks]))
        |> bit_array.to_string
      {
        Ok(text) -> Ok(#(text, rest))
        Error(_) -> Error("JSON string is not valid UTF-8")
      }
    convex_sys.StringEscape(chunk, rest) ->
      parse_escape(rest, [chunk, ..chunks])
    convex_sys.StringControl(_, _, _) ->
      Error("unescaped control character in JSON string")
    convex_sys.StringEnd(_) -> Error("unterminated JSON string")
  }
}

fn parse_escape(
  input: BitArray,
  chunks: List(BitArray),
) -> Result(#(String, BitArray), String) {
  case input {
    <<"\"":utf8, rest:bits>> -> parse_string(rest, [<<"\"":utf8>>, ..chunks])
    <<"\\":utf8, rest:bits>> -> parse_string(rest, [<<"\\":utf8>>, ..chunks])
    <<"/":utf8, rest:bits>> -> parse_string(rest, [<<"/":utf8>>, ..chunks])
    <<"b":utf8, rest:bits>> -> parse_string(rest, [<<0x08>>, ..chunks])
    <<"f":utf8, rest:bits>> -> parse_string(rest, [<<0x0C>>, ..chunks])
    <<"n":utf8, rest:bits>> -> parse_string(rest, [<<0x0A>>, ..chunks])
    <<"r":utf8, rest:bits>> -> parse_string(rest, [<<0x0D>>, ..chunks])
    <<"t":utf8, rest:bits>> -> parse_string(rest, [<<0x09>>, ..chunks])
    <<"u":utf8, rest:bits>> -> parse_unicode_escape(rest, chunks)
    _ -> Error("unknown escape in JSON string")
  }
}

/// `\u` escapes carry UTF-16 code units, so an astral character such as an
/// emoji arrives as a surrogate pair that has to be recombined before it can
/// become a codepoint.
fn parse_unicode_escape(
  input: BitArray,
  chunks: List(BitArray),
) -> Result(#(String, BitArray), String) {
  use #(unit, rest) <- result.try(parse_hex4(input))
  case unit >= 0xD800 && unit <= 0xDBFF {
    True ->
      case rest {
        <<"\\u":utf8, tail:bits>> -> {
          use #(low, rest) <- result.try(parse_hex4(tail))
          case low >= 0xDC00 && low <= 0xDFFF {
            True -> {
              let combined =
                0x10000 + { { unit - 0xD800 } * 0x400 } + { low - 0xDC00 }
              use bytes <- result.try(encode_codepoint(combined))
              parse_string(rest, [bytes, ..chunks])
            }
            False -> Error("invalid low surrogate in JSON string")
          }
        }
        _ -> Error("unpaired high surrogate in JSON string")
      }
    False ->
      case unit >= 0xDC00 && unit <= 0xDFFF {
        True -> Error("unpaired low surrogate in JSON string")
        False -> {
          use bytes <- result.try(encode_codepoint(unit))
          parse_string(rest, [bytes, ..chunks])
        }
      }
  }
}

fn encode_codepoint(value: Int) -> Result(BitArray, String) {
  case string.utf_codepoint(value) {
    Ok(codepoint) -> Ok(<<codepoint:utf8_codepoint>>)
    Error(_) -> Error("escape is not a Unicode codepoint")
  }
}

fn parse_hex4(input: BitArray) -> Result(#(Int, BitArray), String) {
  case input {
    <<a, b, c, d, rest:bits>> -> {
      use a <- result.try(hex_digit(a))
      use b <- result.try(hex_digit(b))
      use c <- result.try(hex_digit(c))
      use d <- result.try(hex_digit(d))
      Ok(#({ { { a * 16 + b } * 16 } + c } * 16 + d, rest))
    }
    _ -> Error("truncated \\u escape in JSON string")
  }
}

fn hex_digit(byte: Int) -> Result(Int, String) {
  case byte {
    _ if byte >= 0x30 && byte <= 0x39 -> Ok(byte - 0x30)
    _ if byte >= 0x61 && byte <= 0x66 -> Ok(byte - 0x61 + 10)
    _ if byte >= 0x41 && byte <= 0x46 -> Ok(byte - 0x41 + 10)
    _ -> Error("invalid hex digit in JSON string")
  }
}

fn is_number_start(byte: Int) -> Bool {
  byte == 0x2D || { byte >= 0x30 && byte <= 0x39 }
}

fn is_number_byte(byte: Int) -> Bool {
  is_number_start(byte)
  || byte == 0x2B
  || byte == 0x2E
  || byte == 0x45
  || byte == 0x65
}

/// Numbers are collected as a token and then classified. A token with a
/// fraction or exponent is a float; anything else stays an exact integer.
fn parse_number(input: BitArray) -> Result(#(Json, BitArray), String) {
  let #(token, rest) = take_number(input, <<>>)
  use _ <- result.try(case valid_number(token) {
    True -> Ok(Nil)
    False -> Error("invalid JSON number")
  })
  use text <- result.try(
    bit_array.to_string(token)
    |> result.replace_error("invalid JSON number"),
  )
  case
    string.contains(text, ".")
    || string.contains(text, "e")
    || string.contains(text, "E")
  {
    False ->
      case int.parse(text) {
        Ok(number) -> Ok(#(JsonInt(number), rest))
        Error(_) -> Error("invalid JSON integer")
      }
    True ->
      case float.parse(erlang_float_text(text)) {
        Ok(number) -> Ok(#(JsonFloat(number), rest))
        Error(_) -> Error("invalid or out of range JSON number")
      }
  }
}

fn valid_number(input: BitArray) -> Bool {
  let unsigned = case input {
    <<0x2D, rest:bits>> -> rest
    other -> other
  }
  case integer_part(unsigned) {
    Error(_) -> False
    Ok(rest) ->
      case fraction_part(rest) {
        Error(_) -> False
        Ok(rest) ->
          case exponent_part(rest) {
            Ok(<<>>) -> True
            _ -> False
          }
      }
  }
}

fn integer_part(input: BitArray) -> Result(BitArray, Nil) {
  case input {
    <<0x30, rest:bits>> ->
      case rest {
        <<next, _:bits>> if next >= 0x30 && next <= 0x39 -> Error(Nil)
        _ -> Ok(rest)
      }
    <<first, rest:bits>> if first >= 0x31 && first <= 0x39 ->
      Ok(drop_digits(rest))
    _ -> Error(Nil)
  }
}

fn fraction_part(input: BitArray) -> Result(BitArray, Nil) {
  case input {
    <<0x2E, digit, rest:bits>> if digit >= 0x30 && digit <= 0x39 ->
      Ok(drop_digits(rest))
    <<0x2E, _:bits>> -> Error(Nil)
    _ -> Ok(input)
  }
}

fn exponent_part(input: BitArray) -> Result(BitArray, Nil) {
  case input {
    <<marker, rest:bits>> if marker == 0x45 || marker == 0x65 -> {
      let unsigned = case rest {
        <<sign, rest:bits>> if sign == 0x2B || sign == 0x2D -> rest
        _ -> rest
      }
      case unsigned {
        <<digit, rest:bits>> if digit >= 0x30 && digit <= 0x39 ->
          Ok(drop_digits(rest))
        _ -> Error(Nil)
      }
    }
    _ -> Ok(input)
  }
}

fn drop_digits(input: BitArray) -> BitArray {
  case input {
    <<digit, rest:bits>> if digit >= 0x30 && digit <= 0x39 -> drop_digits(rest)
    _ -> input
  }
}

fn take_number(input: BitArray, acc: BitArray) -> #(BitArray, BitArray) {
  case input {
    <<byte, rest:bits>> ->
      case is_number_byte(byte) {
        True -> take_number(rest, <<acc:bits, byte>>)
        False -> #(acc, input)
      }
    _ -> #(acc, input)
  }
}

/// JSON allows `1e3`, but the BEAM float parser insists on a fraction before
/// the exponent. Inserting `.0` keeps the value identical while making the
/// token acceptable.
fn erlang_float_text(text: String) -> String {
  let lowered = string.lowercase(text)
  case string.contains(lowered, "."), string.split_once(lowered, "e") {
    False, Ok(#(mantissa, exponent)) -> mantissa <> ".0e" <> exponent
    _, _ -> lowered
  }
}

fn skip_space(input: BitArray) -> BitArray {
  case input {
    <<0x20, rest:bits>> -> skip_space(rest)
    <<0x09, rest:bits>> -> skip_space(rest)
    <<0x0A, rest:bits>> -> skip_space(rest)
    <<0x0D, rest:bits>> -> skip_space(rest)
    _ -> input
  }
}

// ---------------------------------------------------------------------------
// Accessors
// ---------------------------------------------------------------------------

/// Look up one key of a JSON object. Absent keys and non-objects are both
/// `Error(Nil)`; callers that must distinguish them use `object_entry`.
pub fn field(value: Json, key: String) -> Result(Json, Nil) {
  case value {
    JsonObject(entries) ->
      list.find_map(entries, fn(entry) {
        case entry.0 == key {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })
    _ -> Error(Nil)
  }
}

/// True when the object physically carries the key, even if its value is
/// `null`. Convex treats an absent `errorData` and an explicit null
/// differently, and the adapter has to preserve that distinction.
pub fn has_field(value: Json, key: String) -> Bool {
  case field(value, key) {
    Ok(_) -> True
    Error(_) -> False
  }
}

pub fn string_field(value: Json, key: String) -> Result(String, Nil) {
  case field(value, key) {
    Ok(JsonString(text)) -> Ok(text)
    _ -> Error(Nil)
  }
}

pub fn as_string(value: Json) -> Result(String, Nil) {
  case value {
    JsonString(text) -> Ok(text)
    _ -> Error(Nil)
  }
}

pub fn as_bool(value: Json) -> Result(Bool, Nil) {
  case value {
    JsonBool(flag) -> Ok(flag)
    _ -> Error(Nil)
  }
}

pub fn as_object(value: Json) -> Result(List(#(String, Json)), Nil) {
  case value {
    JsonObject(entries) -> Ok(entries)
    _ -> Error(Nil)
  }
}

/// Require exactly the fields one adapter command shape permits.
pub fn only_fields(value: Json, allowed: List(String)) -> Bool {
  case value {
    JsonObject(entries) ->
      list.all(entries, fn(entry) { list.contains(allowed, entry.0) })
    _ -> False
  }
}

/// JSON Schema measures string length in Unicode scalar values, not bytes or
/// grapheme clusters.
pub fn codepoint_length(value: String) -> Int {
  value
  |> string.to_utf_codepoints
  |> list.length
}

pub fn as_array(value: Json) -> Result(List(Json), Nil) {
  case value {
    JsonArray(items) -> Ok(items)
    _ -> Error(Nil)
  }
}

/// Decode a whole number that Convex may have spelled either way.
///
/// `1` and `1.0` are the same counter value, so both are accepted. A fraction,
/// a quoted number, or a value outside the signed 64-bit range is rejected,
/// because silently rounding a Convex value would hide real drift.
pub fn integral_int(value: Json) -> Result(Int, Nil) {
  case value {
    JsonInt(number) -> in_range(number)
    JsonFloat(number) -> {
      let truncated = float.truncate(number)
      case int.to_float(truncated) == number {
        True -> in_range(truncated)
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn in_range(number: Int) -> Result(Int, Nil) {
  case number >= min_safe_int && number <= max_safe_int {
    True -> Ok(number)
    False -> Error(Nil)
  }
}

/// Decode an unsigned 32-bit wire field. Query identifiers and both sync
/// version counters are u32 on the wire; BEAM integers are unbounded, so the
/// range has to be enforced here rather than assumed.
pub fn u32_field(value: Json, key: String) -> Result(Int, Nil) {
  use raw <- result.try(field(value, key))
  use number <- result.try(integral_int(raw))
  case number >= 0 && number <= 4_294_967_295 {
    True -> Ok(number)
    False -> Error(Nil)
  }
}

/// Decode the optional `logLines` array that Convex attaches to results and
/// query failures. An absent array is empty; a malformed one is an error.
pub fn log_lines(value: Json) -> Result(List(String), Nil) {
  case field(value, "logLines") {
    Error(_) -> Ok([])
    Ok(JsonArray(items)) -> list.try_map(items, as_string)
    Ok(_) -> Error(Nil)
  }
}
