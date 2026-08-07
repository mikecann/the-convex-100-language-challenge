class_name ConvexTestHarness
extends RefCounted

# A very small assertion helper.
#
# GDScript's assert() is compiled out of release builds, so the tests use
# explicit checks instead: the same code has to behave identically whether it
# runs under the editor binary in the test image or inside an exported release
# pack. Every check is counted, every failure is reported, and the suite's
# exit status is what the Docker build gates on.

var _suite: String
var _failures: Array = []
var _checks: int = 0


func _init(suite: String) -> void:
	_suite = suite


func check(condition: bool, message: String) -> bool:
	_checks += 1
	if not condition:
		_failures.append(message)
	return condition


func equal(actual: Variant, expected: Variant, message: String) -> bool:
	if ConvexValues.equal_values(actual, expected):
		return check(true, message)
	return check(false, "%s (expected %s, got %s)" % [message, expected, actual])


func failed(result: Dictionary, expected_name: String, message: String) -> bool:
	if not ConvexResult.is_failure(result):
		return check(false, "%s (expected %s, got a value)" % [message, expected_name])
	var actual := ConvexResult.error_name(result)
	if actual == expected_name:
		return check(true, message)
	var detail := "%s: %s" % [actual, ConvexResult.error_message(result)]
	return check(false, "%s (expected %s, got %s)" % [message, expected_name, detail])


func succeeded(result: Dictionary, message: String) -> bool:
	if ConvexResult.is_failure(result):
		var detail := ConvexResult.error_message(result)
		return check(false, "%s (failed with %s)" % [message, detail])
	return check(true, message)


func report() -> int:
	for failure in _failures:
		printerr("FAIL %s: %s" % [_suite, failure])
	if _failures.is_empty():
		print("PASS %s (%d checks)" % [_suite, _checks])
		return 0
	printerr("FAIL %s: %d of %d checks failed" % [_suite, _failures.size(), _checks])
	return 1
