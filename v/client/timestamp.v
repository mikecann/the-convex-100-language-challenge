module convex

import x.json2

// The pinned sync profile encodes its logical timestamp as a little-endian
// unsigned 64-bit integer in base64. It is decoded here rather than treated as
// an opaque token so a server transition that moves the timestamp backwards can
// be rejected, and so `maxObservedTimestamp` can be resent on reconnect.
const base64_alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
const initial_timestamp = 'AAAAAAAAAAA='

fn base64_value(character u8) ?int {
	if character >= `A` && character <= `Z` {
		return int(character - `A`)
	}
	if character >= `a` && character <= `z` {
		return int(character - `a`) + 26
	}
	if character >= `0` && character <= `9` {
		return int(character - `0`) + 52
	}
	if character == `+` {
		return 62
	}
	if character == `/` {
		return 63
	}
	return none
}

fn encode_timestamp(value u64) string {
	mut bytes := []u8{len: 8}
	mut remaining := value
	for index in 0 .. 8 {
		bytes[index] = u8(remaining & 0xff)
		remaining >>= 8
	}
	mut output := []u8{len: 12, init: `=`}
	mut character := 0
	mut position := 0
	for position + 3 <= 8 {
		a := int(bytes[position])
		b := int(bytes[position + 1])
		c := int(bytes[position + 2])
		output[character] = base64_alphabet[a >> 2]
		output[character + 1] = base64_alphabet[((a & 0x03) << 4) | (b >> 4)]
		output[character + 2] = base64_alphabet[((b & 0x0f) << 2) | (c >> 6)]
		output[character + 3] = base64_alphabet[c & 0x3f]
		position += 3
		character += 4
	}
	a := int(bytes[6])
	b := int(bytes[7])
	output[8] = base64_alphabet[a >> 2]
	output[9] = base64_alphabet[((a & 0x03) << 4) | (b >> 4)]
	output[10] = base64_alphabet[(b & 0x0f) << 2]
	return output.bytestr()
}

// decode_timestamp insists on the exact canonical encoding. Accepting a
// non-canonical variant would let two different strings mean the same instant,
// which would break the start/end version equality the transition check relies
// on.
fn decode_timestamp(text string) !u64 {
	if text.len != 12 || text[11] != `=` {
		return protocol_error('live', 'timestamp is not a canonical base64 uint64')
	}
	mut values := []int{len: 11}
	for index in 0 .. 11 {
		values[index] = base64_value(text[index]) or {
			return protocol_error('live', 'timestamp contains invalid base64')
		}
	}
	if values[10] % 4 != 0 {
		return protocol_error('live', 'timestamp base64 has non-zero padding bits')
	}
	mut bytes := []u8{len: 8}
	mut character := 0
	mut position := 0
	for position < 8 {
		v0 := values[character]
		v1 := values[character + 1]
		v2 := values[character + 2]
		bytes[position] = u8((v0 << 2) | (v1 >> 4))
		bytes[position + 1] = u8(((v1 & 0x0f) << 4) | (v2 >> 2))
		if position + 2 < 8 {
			bytes[position + 2] = u8(((v2 & 0x03) << 6) | values[character + 3])
		}
		character += 4
		position += 3
	}
	mut value := u64(0)
	for index := 7; index >= 0; index-- {
		value = (value << 8) | u64(bytes[index])
	}
	if encode_timestamp(value) != text {
		return protocol_error('live', 'timestamp is not canonical')
	}
	return value
}

// Version is the sync profile's (querySet, identity, ts) triple. The client
// tracks the server's version so a transition whose start version disagrees is
// rejected instead of applied on top of state it was not computed from.
struct Version {
	query_set u32
	identity  u32
	ts        string
}

fn zero_version() Version {
	return Version{
		query_set: 0
		identity:  0
		ts:        initial_timestamp
	}
}

fn (left Version) equals(right Version) bool {
	return left.query_set == right.query_set && left.identity == right.identity
		&& left.ts == right.ts
}

fn parse_version(object map[string]json2.Any, key string) !Version {
	fields := object_field(object, key) or {
		return protocol_error('live', '${key} must be an object')
	}
	query_set := uint32_field(fields, 'querySet') or {
		return protocol_error('live', '${key}.querySet must be a uint32')
	}
	identity := uint32_field(fields, 'identity') or {
		return protocol_error('live', '${key}.identity must be a uint32')
	}
	ts := string_field(fields, 'ts') or {
		return protocol_error('live', '${key}.ts must be a string')
	}
	decode_timestamp(ts)!
	return Version{
		query_set: query_set
		identity:  identity
		ts:        ts
	}
}
