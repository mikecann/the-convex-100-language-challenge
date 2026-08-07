// Strict readers for the JSON values Convex sends back.
//
// The shared conformance suite deliberately feeds this client values that a
// permissive decoder would mangle: a document id that must survive a round trip
// as a string, an integral count that may arrive as `0` or `0.0`, and objects
// whose members are legitimately JSON `null`. Every helper here fails loudly
// instead of substituting a default, because a silent default turns a protocol
// bug into a wrong answer.

///|
/// Look up an object member. Returns `None` when the key is absent, which is a
/// different thing from a member whose value is JSON `null`; the callers below
/// depend on being able to tell those apart.
pub fn json_field(value : Json, key : String) -> Json? {
  match value {
    Object(members) => members.get(key)
    _ => None
  }
}

///|
/// True when the member exists at all, regardless of its value. Convex encodes
/// "the query returned null" as a present `value` member holding `null`, so
/// presence has to be checked before the value is read.
pub fn json_has_field(value : Json, key : String) -> Bool {
  match value {
    Object(members) => members.contains(key)
    _ => false
  }
}

///|
fn expect_string(value : Json, what : String) -> String raise ConvexError {
  match value {
    String(text) => text
    _ => raise protocol_error(what + " was not a JSON string")
  }
}

///|
fn expect_array(value : Json, what : String) -> Array[Json] raise ConvexError {
  match value {
    Array(items) => items
    _ => raise protocol_error(what + " was not a JSON array")
  }
}

///|
/// Read a JSON number that must be a non-negative integer inside the 32 bit
/// range. Convex's Live protocol carries `querySet` and `identity` as counters;
/// accepting a fractional or out-of-range value there would let a drifting
/// server desynchronise the local version barrier silently.
fn expect_counter(value : Json, what : String) -> Int64 raise ConvexError {
  guard value is Number(number, ..) else {
    raise protocol_error(what + " was not a JSON number")
  }
  guard !number.is_nan() && !number.is_inf() else {
    raise protocol_error(what + " was not finite")
  }
  guard number >= 0.0 && number <= 4294967295.0 else {
    raise protocol_error(what + " was outside the protocol's counter range")
  }
  let integral = number.to_int64()
  guard integral.to_double() == number else {
    raise protocol_error(what + " was not an integer")
  }
  integral
}

///|
/// Read a Convex number that is expected to be a whole count.
///
/// Convex's JSON encoding may present an integral number in decimal form, so
/// `0` and `0.0` both mean zero. This accepts any mathematically integral value
/// that fits in `Int64` and rejects fractional, quoted, non-finite, or
/// overflowing input. The canonical example uses it to decode `count`, which is
/// exactly where a lenient `to_int64()` cast would quietly turn `0.5` into `0`.
pub fn integer_value(value : Json, what : String) -> Int64 raise ConvexError {
  guard value is Number(number, ..) else {
    raise protocol_error(what + " was not a JSON number")
  }
  guard !number.is_nan() && !number.is_inf() else {
    raise protocol_error(what + " was not a finite number")
  }
  // 2^63 is not representable as an Int64, so compare against it as a Double
  // before converting. `to_int64` on an out-of-range Double is saturating and
  // would otherwise report a bogus in-range answer.
  guard number >= -9223372036854775808.0 && number < 9223372036854775808.0 else {
    raise protocol_error(what + " was outside the 64 bit integer range")
  }
  let integral = number.to_int64()
  guard integral.to_double() == number else {
    raise protocol_error(what + " was not a whole number")
  }
  integral
}

///|
/// Compare two decoded values by what they mean rather than by how they were
/// written.
///
/// MoonBit's `Json` keeps the original text of a number alongside the parsed
/// double so that re-serialising a document is lossless, which means structural
/// equality reports `0` and `0.0` as different values. Convex's JSON encoding
/// uses those two spellings interchangeably, so structural equality would defeat
/// the rehydration suppression in `updates.mbt`: a reconnect that replayed `0.0`
/// where the consumer already holds `0` would surface as a change that never
/// happened. Member order is not meaning either, so objects are compared by key.
pub fn json_equivalent(left : Json, right : Json) -> Bool {
  match (left, right) {
    (Null, Null) => true
    (True, True) => true
    (False, False) => true
    (String(first), String(second)) => first == second
    // A NaN is not equal to itself, so a value this client cannot reason about
    // is reported as changed rather than silently suppressed. Convex never
    // sends one, which is why this costs nothing in practice.
    (Number(first, ..), Number(second, ..)) => first == second
    (Array(first), Array(second)) => {
      guard first.length() == second.length() else { return false }
      for index = 0; index < first.length(); index = index + 1 {
        if !json_equivalent(first[index], second[index]) {
          return false
        }
      }
      true
    }
    (Object(first), Object(second)) => {
      guard first.size() == second.size() else { return false }
      for key, value in first {
        guard second.get(key) is Some(other) else { return false }
        if !json_equivalent(value, other) {
          return false
        }
      }
      true
    }
    _ => false
  }
}

///|
/// Read a required object member, failing with the member name in the message.
pub fn required_field(
  value : Json,
  key : String,
  what : String,
) -> Json raise ConvexError {
  match json_field(value, key) {
    Some(found) => found
    None => raise protocol_error(what + " omitted the " + key + " member")
  }
}

///|
/// Convex log lines arrive as an array of strings. A malformed `logLines` is
/// dropped rather than failing the surrounding call, because losing diagnostics
/// must never turn a successful function result into an error.
fn log_lines(value : Json?) -> Array[String] {
  let lines : Array[String] = []
  match value {
    Some(Array(items)) =>
      for item in items {
        match item {
          String(line) => lines.push(line)
          other => lines.push(other.stringify())
        }
      }
    _ => ()
  }
  lines
}

///|
/// Build a JSON object from name/value pairs. The Live protocol messages below
/// are assembled with this so their shape stays readable.
fn json_object(fields : Array[(String, Json)]) -> Json {
  let members : Map[String, Json] = Map::new()
  for field in fields {
    members[field.0] = field.1
  }
  Json::object(members)
}
