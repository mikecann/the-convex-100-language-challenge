// The JSON boundary for the native Pike Convex client.
//
// This fragment is textually included by convex.pike. Pike's Standards.JSON
// supplies ordinary encoding and decoding only. Everything that decides whether
// a decoded value is *acceptable* Convex protocol data lives here, so no other
// layer has to guess what an absent, quoted, fractional, or oversized field
// means.
#ifndef CONVEX_JSON_PIKE
#define CONVEX_JSON_PIKE

// Pike distinguishes an absent mapping entry (UNDEFINED) from a decoded JSON
// null (Val.null), which is exactly the distinction Convex needs: demo:roomId
// legitimately answers null, while a success envelope with no `value` at all is
// protocol drift.
int json_is_null(mixed value)
{
  return value == Val.null;
}

int json_is_true(mixed value)
{
  // Accept both the Val object Pike 8 decodes booleans into and a plain 1, so
  // hand-built Pike mappings work in the same helpers as decoded wire data.
  return value == Val.true || (intp(value) && value == 1);
}

int json_is_false(mixed value)
{
  return value == Val.false || (intp(value) && value == 0);
}

// Encode to a Pike string. Convex bodies and frames always travel as UTF-8
// bytes, so callers on the wire use json_bytes below instead.
string json_text(mixed value)
{
  return Standards.JSON.encode(value);
}

string json_bytes(mixed value)
{
  return string_to_utf8(Standards.JSON.encode(value));
}

// A conservative allowance for what one encoded value costs in this process:
// the encoded text, the newline or frame header around it, and the Pike value
// graph that produced it. Byte budgets use this rather than the bare string
// length so a queue bound is a memory bound.
constant VALUE_OVERHEAD_BYTES = 256;

int accounted_bytes(string encoded)
{
  return sizeof(encoded) + VALUE_OVERHEAD_BYTES;
}

mixed json_parse_text(string text, string what, void|string operation)
{
  mixed decoded;
  mixed failure = catch { decoded = Standards.JSON.decode(text); };
  if (failure)
    throw(protocol_error(sprintf("%s is not valid JSON", what), operation));
  return decoded;
}

// Wire data is bytes. Invalid UTF-8 is a protocol failure in its own right and
// must not be repaired by substituting replacement characters, because that
// would let a corrupted frame decode into a plausible value.
mixed json_parse_bytes(string bytes, string what, void|string operation)
{
  string text;
  mixed failure = catch { text = utf8_to_string(bytes); };
  if (failure)
    throw(protocol_error(sprintf("%s is not valid UTF-8", what), operation));
  return json_parse_text(text, what, operation);
}

mapping require_object(mixed value, string what, void|string operation)
{
  if (!mappingp(value))
    throw(protocol_error(sprintf("%s must be a JSON object", what), operation));
  foreach (indices(value), mixed key)
    if (!stringp(key))
      throw(protocol_error(sprintf("%s must use string keys", what),
                           operation));
  return value;
}

array require_array(mixed value, string what, void|string operation)
{
  if (!arrayp(value))
    throw(protocol_error(sprintf("%s must be a JSON array", what), operation));
  return value;
}

string require_string(mixed value, string what, void|string operation)
{
  if (!stringp(value))
    throw(protocol_error(sprintf("%s must be a JSON string", what), operation));
  return value;
}

string require_nonempty_string(mixed value, string what, void|string operation)
{
  string text = require_string(value, what, operation);
  if (!sizeof(text))
    throw(protocol_error(sprintf("%s must not be empty", what), operation));
  return text;
}

// Sync-protocol counters are uint32 on the wire. Pike would happily accept a
// float or a bignum here, so reject anything that is not a plain non-negative
// integer in range before it can enter connection state.
int require_uint32(mixed value, string what, void|string operation)
{
  if (!intp(value) || value < 0 || value > 4294967295)
    throw(protocol_error(sprintf("%s must be a uint32 integer", what),
                         operation));
  return value;
}

// Convex JSON numbers may arrive in an integral decimal form such as 0.0 or
// 1.0. Accept values that are mathematically whole and representable, and
// reject fractional, quoted, boolean, null, non-finite, and overflowing ones.
int require_whole_number(mixed value, string what, void|string operation)
{
  if (intp(value))
    return value;
  if (!floatp(value))
    throw(protocol_error(sprintf("%s must be a JSON number", what), operation));
  // NaN is the only value not equal to itself; the range test then removes the
  // infinities and anything a Pike int cannot hold exactly.
  if (value != value || value < -9007199254740992.0 ||
      value > 9007199254740992.0)
    throw(protocol_error(sprintf("%s must be a finite whole number", what),
                         operation));
  int whole = (int)value;
  if ((float)whole != value)
    throw(protocol_error(sprintf("%s must not be fractional", what),
                         operation));
  return whole;
}

// Convex attaches log lines to both successful and failed results. An absent
// field is normal; a present field of the wrong shape is drift.
array(string) require_log_lines(mixed value, void|string operation)
{
  if (zero_type(value) || json_is_null(value))
    return ({});
  array lines = require_array(value, "logLines", operation);
  foreach (lines, mixed line)
    if (!stringp(line))
      throw(protocol_error("logLines must contain strings", operation));
  return [array(string)]lines;
}

#endif
