class_name ConvexValues
extends RefCounted

# Decoding helpers shared by the HTTP and Live paths.
#
# Godot's JSON parser is deliberately lax: the class documentation states that
# numbers are parsed with String.to_float, so every JSON number arrives as a
# GDScript float and "1e999" becomes an infinity instead of a parse error.
# Convex also exports whole numbers in an integral decimal form such as 0.0.
# Both facts mean a client that wants an idiomatic int has to check the value
# rather than cast it, which is what count_from_json does below.

# JSON integers are safe only through 2^53 - 1. At 2^53 an adjacent input may
# already have rounded to the same float, so this client refuses that boundary
# and everything beyond it rather than silently changing the value.
const MAX_EXACT_INTEGER := 9007199254740991

# Convex timestamps are opaque base64 strings that decode to eight bytes.
const TIMESTAMP_BYTES := 8
const INITIAL_TIMESTAMP := "AAAAAAAAAAA="


# Parse one JSON document and require an object at its root. Convex response
# envelopes, Live server messages, and adapter commands are all objects, so a
# bare array or scalar is a protocol failure rather than an empty envelope.
static func parse_object(text: String, context: String) -> Dictionary:
	var parser := JSON.new()
	var status := parser.parse(text)
	if status != OK:
		var line := parser.get_error_line()
		var detail := "%s: %s (line %d)" % [context, parser.get_error_message(), line]
		return ConvexResult.protocol_failure(detail)
	if typeof(parser.data) != TYPE_DICTIONARY:
		return ConvexResult.protocol_failure("%s: expected a JSON object at the root" % context)
	if not is_json_safe(parser.data):
		return ConvexResult.protocol_failure(
			"%s: number is outside GDScript's exact range" % context
		)
	return ConvexResult.ok(parser.data)


# Accept a mathematically integral, in-range JSON number and return it as an
# int. Fractional, quoted, non-finite, and oversized values are rejected so a
# counter never advances on a value Convex did not actually send.
static func count_from_json(value: Variant, context: String) -> Dictionary:
	if typeof(value) == TYPE_INT:
		if value < -MAX_EXACT_INTEGER or value > MAX_EXACT_INTEGER:
			return ConvexResult.protocol_failure("%s is outside the exact integer range" % context)
		return ConvexResult.ok(value)
	if typeof(value) != TYPE_FLOAT:
		return ConvexResult.protocol_failure("%s is not a JSON number" % context)
	var number: float = value
	if not is_finite(number):
		return ConvexResult.protocol_failure("%s is not finite" % context)
	if number != floor(number):
		return ConvexResult.protocol_failure("%s is not a whole number" % context)
	if absf(number) > float(MAX_EXACT_INTEGER):
		return ConvexResult.protocol_failure("%s is outside the exact integer range" % context)
	return ConvexResult.ok(int(number))


# Reject values Godot can hold but JSON cannot represent. JSON.stringify turns
# an infinity into the bare token "inf", which would emit a line no strict
# JSON reader can parse, so the check happens before anything is serialized.
static func is_json_safe(value: Variant) -> bool:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_STRING, TYPE_STRING_NAME:
			return true
		TYPE_INT:
			return value >= -MAX_EXACT_INTEGER and value <= MAX_EXACT_INTEGER
		TYPE_FLOAT:
			return is_finite(value) and absf(value) <= float(MAX_EXACT_INTEGER)
		TYPE_ARRAY:
			for element in value:
				if not is_json_safe(element):
					return false
			return true
		TYPE_DICTIONARY:
			for key in value:
				if typeof(key) != TYPE_STRING and typeof(key) != TYPE_STRING_NAME:
					return false
				if not is_json_safe(value[key]):
					return false
			return true
		_:
			return false


# A detached copy of a decoded value. Live keeps the last delivered value to
# suppress unchanged rehydrations, so it must not hold a reference a caller
# could mutate after delivery.
static func copy(value: Variant) -> Variant:
	match typeof(value):
		TYPE_ARRAY, TYPE_DICTIONARY:
			return value.duplicate(true)
		_:
			return value


# Godot compares Array and Dictionary by reference, so structural equality has
# to be spelled out. Live uses it to decide whether a rehydrated query value is
# genuinely new.
static func equal_values(left: Variant, right: Variant) -> bool:
	if typeof(left) != typeof(right):
		return false
	match typeof(left):
		TYPE_ARRAY:
			if left.size() != right.size():
				return false
			for index in left.size():
				if not equal_values(left[index], right[index]):
					return false
			return true
		TYPE_DICTIONARY:
			if left.size() != right.size():
				return false
			for key in left:
				if not right.has(key):
					return false
				if not equal_values(left[key], right[key]):
					return false
			return true
		_:
			return left == right


static func is_timestamp(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING:
		return false
	return Marshalls.base64_to_raw(value).size() == TIMESTAMP_BYTES


# Convex sync timestamps are little-endian unsigned 64-bit values behind their
# base64 text, so the most significant byte is the last one.
static func is_later_timestamp(candidate: String, current: String) -> bool:
	if current.is_empty():
		return true
	var candidate_bytes := Marshalls.base64_to_raw(candidate)
	var current_bytes := Marshalls.base64_to_raw(current)
	if candidate_bytes.size() != TIMESTAMP_BYTES or current_bytes.size() != TIMESTAMP_BYTES:
		return false
	for index in range(TIMESTAMP_BYTES - 1, -1, -1):
		if candidate_bytes[index] > current_bytes[index]:
			return true
		if candidate_bytes[index] < current_bytes[index]:
			return false
	return false


static func same_timestamp(left: String, right: String) -> bool:
	return Marshalls.base64_to_raw(left) == Marshalls.base64_to_raw(right)


# A list of strings or nothing. Convex sends function logs as logLines, and a
# malformed log array is a protocol failure rather than a silently empty list.
static func log_lines(value: Variant, context: String) -> Dictionary:
	if value == null:
		return ConvexResult.ok([])
	if typeof(value) != TYPE_ARRAY:
		return ConvexResult.protocol_failure("%s must be an array" % context)
	for line in value:
		if typeof(line) != TYPE_STRING:
			return ConvexResult.protocol_failure("%s entries must be strings" % context)
	return ConvexResult.ok(value.duplicate())
