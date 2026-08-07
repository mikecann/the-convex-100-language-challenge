module convex

import x.json2

fn timestamp_rejected(text string) bool {
	decode_timestamp(text) or { return true }
	return false
}

fn test_timestamp_round_trips_the_pinned_encoding() ! {
	assert encode_timestamp(0) == initial_timestamp
	assert decode_timestamp(initial_timestamp)! == 0
	for value in [u64(1), 255, 256, 1_700_000_000_000_000_000, u64(18446744073709551615)] {
		encoded := encode_timestamp(value)
		assert encoded.len == 12
		assert decode_timestamp(encoded)! == value
	}
}

fn test_non_canonical_timestamps_are_rejected() {
	// Two spellings of one instant would break the start/end version equality
	// the transition check depends on, so only the canonical form is accepted.
	assert timestamp_rejected('')
	assert timestamp_rejected('AAAAAAAAAAA')
	assert timestamp_rejected('AAAAAAAAAAAA')
	assert timestamp_rejected('AAAAAAAAAA!=')
	// The final base64 character carries two padding bits that must be zero.
	assert timestamp_rejected('AAAAAAAAAAB=')
}

fn test_version_parsing_requires_every_field() ! {
	object := {
		'startVersion': json2.Any({
			'querySet': json2.Any(i64(3))
			'identity': json2.Any(i64(1))
			'ts':       json2.Any(encode_timestamp(42))
		})
	}
	version := parse_version(object, 'startVersion')!
	assert version.query_set == 3
	assert version.identity == 1
	assert decode_timestamp(version.ts)! == 42
	assert version.equals(Version{
		query_set: 3
		identity:  1
		ts:        encode_timestamp(42)
	})
	assert !version.equals(zero_version())
}

fn test_version_parsing_rejects_wrong_types_and_ranges() {
	bad_versions := [
		json2.Any('not an object'),
		json2.Any({
			'querySet': json2.Any(i64(-1))
			'identity': json2.Any(i64(0))
			'ts':       json2.Any(initial_timestamp)
		}),
		json2.Any({
			'querySet': json2.Any(i64(0))
			'identity': json2.Any(i64(4294967296))
			'ts':       json2.Any(initial_timestamp)
		}),
		json2.Any({
			'querySet': json2.Any(i64(0))
			'identity': json2.Any(i64(0))
			'ts':       json2.Any(i64(0))
		}),
	]
	for candidate in bad_versions {
		object := {
			'endVersion': candidate
		}
		parse_version(object, 'endVersion') or { continue }
		assert false, 'invalid version was accepted: ${candidate}'
	}
}
