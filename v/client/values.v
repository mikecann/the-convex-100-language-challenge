module convex

import x.json2

// Every JSON boundary in this client is bounded before it is decoded. The
// limits are deliberately small compared with the 128 MiB container budget the
// shared harness enforces, so a hostile or broken peer cannot turn one message
// into unbounded memory or unbounded recursion inside the decoder.
pub const max_json_bytes = 2 * 1024 * 1024
pub const max_json_depth = 128
pub const max_json_nodes = 8192
pub const max_json_string_bytes = 1024 * 1024

// Adapter and subscription identifiers are compared, logged, and echoed back,
// so they are limited by Unicode scalars rather than bytes. 128 scalars is the
// shared adapter schema's `id` limit.
pub const max_identifier_scalars = 128

// utf8_scalars validates a byte string as strict UTF-8 and returns the number
// of Unicode scalar values in it. Overlong encodings, surrogate halves, and
// values above U+10FFFF are rejected, because Convex and the shared controller
// both exchange real UTF-8 and a lenient decoder would let malformed bytes
// through as if they were text.
pub fn utf8_scalars(text string) ?int {
	mut index := 0
	mut scalars := 0
	for index < text.len {
		first := text[index]
		mut width := 0
		mut code := u32(0)
		if first < 0x80 {
			width = 1
			code = u32(first)
		} else if first & 0xe0 == 0xc0 {
			width = 2
			code = u32(first & 0x1f)
		} else if first & 0xf0 == 0xe0 {
			width = 3
			code = u32(first & 0x0f)
		} else if first & 0xf8 == 0xf0 {
			width = 4
			code = u32(first & 0x07)
		} else {
			return none
		}
		if index + width > text.len {
			return none
		}
		for offset in 1 .. width {
			continuation := text[index + offset]
			if continuation & 0xc0 != 0x80 {
				return none
			}
			code = (code << 6) | u32(continuation & 0x3f)
		}
		// Reject the encodings that have a shorter canonical form, the UTF-16
		// surrogate range, and anything past the last Unicode scalar.
		minimum := match width {
			1 { u32(0) }
			2 { u32(0x80) }
			3 { u32(0x800) }
			else { u32(0x10000) }
		}
		if code < minimum || (code >= 0xd800 && code <= 0xdfff) || code > 0x10ffff {
			return none
		}
		index += width
		scalars++
	}
	return scalars
}

// is_bounded_identifier applies the shared adapter schema's `id` rule in the
// client rather than trusting the controller to only ever send valid ids.
fn is_bounded_identifier(text string) bool {
	scalars := utf8_scalars(text) or { return false }
	return scalars >= 1 && scalars <= max_identifier_scalars
}

// scan_json_text walks the raw text once before any decoder sees it and
// enforces the byte, depth, node, and string limits. Doing this on the text
// instead of on a decoded tree is what keeps a deeply nested payload from
// exhausting the decoder's own stack.
fn scan_json_text(text string, operation string) ! {
	if text.len > max_json_bytes {
		return protocol_error(operation, 'JSON payload exceeds ${max_json_bytes} bytes')
	}
	utf8_scalars(text) or { return protocol_error(operation, 'JSON payload is not valid UTF-8') }
	mut depth := 0
	mut nodes := 0
	mut index := 0
	for index < text.len {
		character := text[index]
		match character {
			`{`, `[` {
				depth++
				nodes++
				if depth > max_json_depth {
					return protocol_error(operation, 'JSON payload nests deeper than ${max_json_depth}')
				}
			}
			`}`, `]` {
				depth--
				if depth < 0 {
					return protocol_error(operation, 'JSON payload has unbalanced brackets')
				}
			}
			`,`, `:` {
				nodes++
			}
			`"` {
				start := index
				index++
				for index < text.len {
					if text[index] == `\\` {
						index += 2
						continue
					}
					if text[index] == `"` {
						break
					}
					index++
				}
				if index >= text.len {
					return protocol_error(operation, 'JSON payload has an unterminated string')
				}
				if index - start > max_json_string_bytes {
					return protocol_error(operation, 'JSON string exceeds ${max_json_string_bytes} bytes')
				}
				nodes++
			}
			else {}
		}
		if nodes > max_json_nodes {
			return protocol_error(operation, 'JSON payload exceeds ${max_json_nodes} structural nodes')
		}
		index++
	}
	if depth != 0 {
		return protocol_error(operation, 'JSON payload has unbalanced brackets')
	}
}

// decode_json_object is the only entry point for untrusted JSON. Convex
// envelopes and pinned Live messages are always objects, so a bare array,
// number, or string at the root is rejected here instead of producing a
// confusing failure three layers deeper.
fn decode_json_object(text string, operation string) !map[string]json2.Any {
	scan_json_text(text, operation)!
	value := json2.raw_decode(text) or {
		return protocol_error(operation, 'payload is not valid JSON')
	}
	if value is map[string]json2.Any {
		return value
	}
	return protocol_error(operation, 'payload root must be a JSON object')
}

// decode_bounded_json_object exposes the same guarded decoder to the
// conformance adapter, which is a separate V module. Adapter commands are just
// as untrusted as server messages and must not reach json2 before the depth and
// structural-node scan.
pub fn decode_bounded_json_object(text string, operation string) !map[string]json2.Any {
	return decode_json_object(text, operation)
}

fn encode_json(value json2.Any) string {
	return json2.encode(value)
}

// The json2 sum type answers `.str()` for every case, so a lenient read would
// silently accept a number where a string is required. These accessors keep
// every protocol field strictly typed.
fn string_field(object map[string]json2.Any, key string) ?string {
	value := object[key] or { return none }
	if value is string {
		return value
	}
	return none
}

fn object_field(object map[string]json2.Any, key string) ?map[string]json2.Any {
	value := object[key] or { return none }
	if value is map[string]json2.Any {
		return value
	}
	return none
}

fn array_field(object map[string]json2.Any, key string) ?[]json2.Any {
	value := object[key] or { return none }
	if value is []json2.Any {
		return value
	}
	return none
}

// integral_number accepts Convex's integral decimal encodings, including the
// `0.0` and `1.0` forms a JSON number may arrive in, while rejecting quoted,
// fractional, non-finite, and out-of-range values.
pub fn integral_number(value json2.Any) ?i64 {
	if value is i64 {
		return value
	}
	if value is int {
		return i64(value)
	}
	if value is f64 {
		number := f64(value)
		if number != number || number > 9.007199254740992e15 || number < -9.007199254740992e15 {
			return none
		}
		truncated := i64(number)
		if f64(truncated) != number {
			return none
		}
		return truncated
	}
	if value is f32 {
		return integral_number(json2.Any(f64(value)))
	}
	return none
}

// uint32_field carries the sync profile's unsigned 32-bit query identifiers and
// version counters. Anything outside that range is a protocol violation rather
// than a value to clamp.
fn uint32_field(object map[string]json2.Any, key string) ?u32 {
	value := object[key] or { return none }
	number := integral_number(value) or { return none }
	if number < 0 || number > 4294967295 {
		return none
	}
	return u32(number)
}

// log_lines normalises Convex's optional `logLines` array. A non-array or a
// non-string entry is a protocol fault, not something to coerce.
fn log_lines(object map[string]json2.Any, operation string) ![]string {
	if key_missing(object, 'logLines') {
		return []string{}
	}
	entries := array_field(object, 'logLines') or {
		return protocol_error(operation, 'logLines must be an array')
	}
	mut lines := []string{cap: entries.len}
	for entry in entries {
		if entry is string {
			lines << entry
		} else {
			return protocol_error(operation, 'logLines entries must be strings')
		}
	}
	return lines
}

fn key_missing(object map[string]json2.Any, key string) bool {
	return key !in object
}
