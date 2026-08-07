module convex

import x.json2

// These helpers keep each assertion about *rejection* readable. Every one of
// them is a case where a lenient decoder would turn malformed input into a
// value the rest of the client would then trust.
fn utf8_rejected(text string) bool {
	utf8_scalars(text) or { return true }
	return false
}

fn decode_rejected(text string) bool {
	decode_json_object(text, 'test') or { return true }
	return false
}

fn decode_failure(text string) string {
	decode_json_object(text, 'test') or { return (err as ConvexError).message }
	return ''
}

fn integral_rejected(value json2.Any) bool {
	integral_number(value) or { return true }
	return false
}

fn test_utf8_scalars_counts_real_scalars() {
	assert (utf8_scalars('kia ora') or { -1 }) == 7
	assert (utf8_scalars('Καλημέρα') or { -1 }) == 8
	assert (utf8_scalars('🟨🟩🟦') or { -1 }) == 3
	assert (utf8_scalars('Hello, 世界 👋') or { -1 }) == 11
}

fn test_utf8_scalars_rejects_malformed_bytes() {
	// A lone continuation byte, a truncated sequence, an overlong encoding, a
	// UTF-16 surrogate half, and a value past U+10FFFF must all be rejected.
	assert utf8_rejected('\x80')
	assert utf8_rejected('\xe4\xb8')
	assert utf8_rejected('\xc0\xaf')
	assert utf8_rejected('\xed\xa0\x80')
	assert utf8_rejected('\xf5\x80\x80\x80')
}

fn test_identifier_bound_is_measured_in_scalars() {
	assert is_bounded_identifier('client-initial')
	assert !is_bounded_identifier('')
	// 128 emoji are 512 bytes but exactly 128 scalars, so the shared adapter
	// schema's limit accepts them and 129 must not be accepted.
	assert is_bounded_identifier('🟦'.repeat(128))
	assert !is_bounded_identifier('🟦'.repeat(129))
	assert !is_bounded_identifier('\xff')
}

fn test_json_root_must_be_an_object() {
	assert decode_rejected('[1,2]')
	assert decode_rejected('"text"')
	assert decode_rejected('7')
}

fn test_json_depth_is_bounded() {
	deep := '['.repeat(max_json_depth + 1) + ']'.repeat(max_json_depth + 1)
	assert decode_failure('{"a":${deep}}').contains('nests deeper')
}

fn test_json_node_count_is_bounded() {
	mut parts := []string{cap: max_json_nodes + 2}
	for index in 0 .. max_json_nodes + 2 {
		parts << '${index}'
	}
	payload := '{"a":[' + parts.join(',') + ']}'
	assert decode_failure(payload).contains('structural nodes')
}

fn test_json_byte_limit_is_enforced_before_decoding() {
	payload := '{"a":"' + 'x'.repeat(max_json_bytes) + '"}'
	assert decode_failure(payload).contains('bytes')
}

fn test_json_scan_rejects_unbalanced_and_unterminated_text() {
	assert decode_rejected('{"a":[1}')
	assert decode_rejected('{"a":"unterminated}')
	assert decode_rejected('{"a":1}}')
}

fn test_integral_number_accepts_convex_decimal_integers() {
	// Convex may encode 1 as 1.0. Both forms mean one.
	assert (integral_number(json2.Any(i64(0))) or { -1 }) == 0
	assert (integral_number(json2.Any(f64(0.0))) or { -1 }) == 0
	assert (integral_number(json2.Any(f64(1.0))) or { -1 }) == 1
	assert (integral_number(json2.Any(f64(-7.0))) or { 0 }) == -7
}

fn test_integral_number_rejects_fractional_and_quoted_values() {
	assert integral_rejected(json2.Any(f64(1.5)))
	assert integral_rejected(json2.Any('1'))
	assert integral_rejected(json2.Any(true))
	assert integral_rejected(json2.Any(json2.null))
	assert integral_rejected(json2.Any(f64(1.0e300)))
}

fn test_strict_field_accessors_do_not_coerce() {
	object := {
		'text':   json2.Any('value')
		'number': json2.Any(i64(7))
		'nested': json2.Any(map[string]json2.Any{})
		'list':   json2.Any([json2.Any(i64(1))])
	}
	assert (string_field(object, 'text') or { '' }) == 'value'
	// json2 would happily render 7 as "7"; the protocol layer must not.
	assert (string_field(object, 'number') or { 'rejected' }) == 'rejected'
	assert (object_field(object, 'nested') or {
		{
			'fallback': json2.Any(true)
		}
	}).len == 0
	assert (object_field(object, 'list') or {
		{
			'fallback': json2.Any(true)
		}
	}).len == 1
	assert (array_field(object, 'list') or { []json2.Any{} }).len == 1
	assert (array_field(object, 'nested') or { []json2.Any{} }).len == 0
}

fn test_log_lines_requires_an_array_of_strings() ! {
	assert log_lines(map[string]json2.Any{}, 'test')!.len == 0
	present := log_lines({
		'logLines': json2.Any([json2.Any('one')])
	}, 'test')!
	assert present[0] == 'one'
	lines := log_lines({
		'logLines': json2.Any([json2.Any(i64(1))])
	}, 'test') or {
		assert (err as ConvexError).kind == kind_protocol_error
		return
	}
	assert false, 'non-string log lines must be rejected: ${lines}'
}
