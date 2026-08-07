extends SceneTree

# Decoding regressions for the values Convex actually sends over JSON, rather
# than for a mocked integer-only fixture.


func _init() -> void:
	var harness := ConvexTestHarness.new("values")
	_test_integral_numbers(harness)
	_test_rejected_numbers(harness)
	_test_json_safety(harness)
	_test_structural_equality(harness)
	_test_timestamps(harness)
	_test_log_lines(harness)
	_test_object_parsing(harness)
	quit(harness.report())


# Convex exports whole numbers in an integral decimal form, and Godot's JSON
# parser turns every number into a float, so 0 arrives as 0.0. Both have to
# decode to an idiomatic int.
func _test_integral_numbers(harness: ConvexTestHarness) -> void:
	var zero := ConvexValues.count_from_json(0.0, "count")
	harness.succeeded(zero, "0.0 decodes")
	harness.check(zero["value"] == 0, "0.0 decodes to the integer 0")
	harness.check(typeof(zero["value"]) == TYPE_INT, "0.0 decodes to an int, not a float")
	var one := ConvexValues.count_from_json(1.0, "count")
	harness.check(one["value"] == 1, "1.0 decodes to the integer 1")
	var negative := ConvexValues.count_from_json(-7.0, "count")
	harness.check(negative["value"] == -7, "-7.0 decodes to the integer -7")
	var already_int := ConvexValues.count_from_json(42, "count")
	harness.check(already_int["value"] == 42, "an int passes through unchanged")
	var largest := ConvexValues.count_from_json(float(ConvexValues.MAX_EXACT_INTEGER), "count")
	harness.succeeded(largest, "the largest exactly representable integer decodes")


# Anything that is not a whole, finite, exactly representable JSON number is a
# protocol failure. A counter must never advance on a rounded value.
func _test_rejected_numbers(harness: ConvexTestHarness) -> void:
	harness.failed(ConvexValues.count_from_json(1.5, "count"), "ProtocolError", "1.5 is refused")
	var quoted := ConvexValues.count_from_json("1", "count")
	harness.failed(quoted, "ProtocolError", "a quoted number is refused")
	var missing := ConvexValues.count_from_json(null, "count")
	harness.failed(missing, "ProtocolError", "a null count is refused")
	var boolean := ConvexValues.count_from_json(true, "count")
	harness.failed(boolean, "ProtocolError", "a boolean count is refused")
	# Godot parses numbers with String.to_float, so an oversized literal
	# becomes an infinity instead of failing to parse.
	var infinite := ConvexValues.count_from_json(INF, "count")
	harness.failed(infinite, "ProtocolError", "an infinite count is refused")
	harness.failed(ConvexValues.count_from_json(NAN, "count"), "ProtocolError", "NaN is refused")
	var huge := ConvexValues.count_from_json(1.0e30, "count")
	harness.failed(huge, "ProtocolError", "a count beyond exact integers is refused")
	var rounded := ConvexValues.parse_object('{"value":9007199254740993}', "body")
	harness.failed(rounded, "ProtocolError", "a rounded JSON integer is refused")


# JSON.stringify would emit a bare inf token for a non-finite float, so values
# are screened before anything is serialized.
func _test_json_safety(harness: ConvexTestHarness) -> void:
	harness.check(ConvexValues.is_json_safe({"a": [1, "two", null, true]}), "plain JSON is safe")
	harness.check(not ConvexValues.is_json_safe({"a": INF}), "an infinity is not JSON-safe")
	harness.check(not ConvexValues.is_json_safe([NAN]), "a NaN is not JSON-safe")
	harness.check(not ConvexValues.is_json_safe({"a": Callable()}), "a Callable is not JSON-safe")
	harness.check(ConvexValues.is_json_safe(1.25), "a finite float is JSON-safe")
	harness.check(
		not ConvexValues.is_json_safe(9007199254740992), "an unsafe outbound integer is refused"
	)


# Godot compares dictionaries and arrays by reference, so Live's unchanged
# value suppression depends on this structural comparison being correct.
func _test_structural_equality(harness: ConvexTestHarness) -> void:
	var left := {"count": 1.0, "tags": ["a", "b"], "room": null}
	var right := {"room": null, "tags": ["a", "b"], "count": 1.0}
	harness.check(ConvexValues.equal_values(left, right), "key order does not change equality")
	harness.check(not ConvexValues.equal_values(left, {"count": 1.0}), "a missing key differs")
	harness.check(not ConvexValues.equal_values([1, 2], [2, 1]), "array order matters")
	harness.check(not ConvexValues.equal_values(1, 1.0), "an int and a float are not the same")
	var copied: Dictionary = ConvexValues.copy(left)
	copied["count"] = 9.0
	harness.check(left["count"] == 1.0, "copy detaches nested state from the original")


# Convex sync timestamps are base64 over eight little-endian bytes, so the
# most significant byte is the last one.
func _test_timestamps(harness: ConvexTestHarness) -> void:
	var low := _timestamp(1)
	var high := _timestamp(2)
	var carried := _timestamp(256)
	harness.check(ConvexValues.is_timestamp(low), "eight decoded bytes is a timestamp")
	harness.check(not ConvexValues.is_timestamp("AAAA"), "a short string is not a timestamp")
	harness.check(not ConvexValues.is_timestamp(7), "a number is not a timestamp")
	harness.check(ConvexValues.is_later_timestamp(high, low), "2 is later than 1")
	harness.check(not ConvexValues.is_later_timestamp(low, high), "1 is not later than 2")
	harness.check(not ConvexValues.is_later_timestamp(low, low), "equal timestamps are not later")
	harness.check(ConvexValues.is_later_timestamp(carried, high), "the high byte decides")
	harness.check(ConvexValues.is_later_timestamp(low, ""), "any timestamp beats none")


func _test_log_lines(harness: ConvexTestHarness) -> void:
	var absent := ConvexValues.log_lines(null, "logLines")
	harness.equal(absent["value"], [], "absent logs decode to an empty list")
	var lines := ConvexValues.log_lines(["one", "two"], "logLines")
	harness.equal(lines["value"], ["one", "two"], "log lines survive decoding")
	var wrong := ConvexValues.log_lines("one", "logLines")
	harness.failed(wrong, "ProtocolError", "a string instead of a log array is refused")
	var mixed := ConvexValues.log_lines(["one", 2], "logLines")
	harness.failed(mixed, "ProtocolError", "a non-string log entry is refused")


func _test_object_parsing(harness: ConvexTestHarness) -> void:
	var parsed := ConvexValues.parse_object('{"a": 1}', "body")
	harness.succeeded(parsed, "an object parses")
	var array_root := ConvexValues.parse_object("[1, 2]", "body")
	harness.failed(array_root, "ProtocolError", "an array root is refused")
	var broken := ConvexValues.parse_object("{", "body")
	harness.failed(broken, "ProtocolError", "malformed JSON is refused")
	var empty := ConvexValues.parse_object("", "body")
	harness.failed(empty, "ProtocolError", "an empty body is refused")


func _timestamp(value: int) -> String:
	var bytes := PackedByteArray()
	bytes.resize(8)
	var remaining := value
	for index in 8:
		bytes[index] = remaining & 0xFF
		remaining >>= 8
	return Marshalls.raw_to_base64(bytes)
