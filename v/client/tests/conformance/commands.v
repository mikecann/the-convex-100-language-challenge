module conformance

import convex
import x.json2

// The shared controller validates everything this adapter emits against
// _shared/schemas/adapter.schema.json. Validating what arrives just as
// strictly is the other half of that contract: an unknown field, a duplicate
// field, a wrong type, or an over-long identifier is a protocol error here,
// not something to quietly ignore and answer anyway.
pub const max_command_bytes = 2 * 1024 * 1024

pub struct Command {
pub:
	id               string
	op               string
	path             string
	args             map[string]json2.Any
	token            string
	subscription_id  string
	protocol_version int
}

fn allowed_fields(op string) ![]string {
	return match op {
		'hello' { ['protocolVersion', 'id', 'op'] }
		'query', 'mutation', 'action' { ['id', 'op', 'path', 'args'] }
		'subscribe', 'unsubscribe' { ['id', 'op', 'subscriptionId', 'path', 'args'] }
		'setAuth' { ['id', 'op', 'token'] }
		'close', 'debugDisconnect' { ['id', 'op'] }
		else { error('unknown adapter operation: ${op}') }
	}
}

fn required_fields(op string) []string {
	return match op {
		'hello' { ['protocolVersion', 'id', 'op'] }
		'query', 'mutation', 'action' { ['id', 'op', 'path', 'args'] }
		'subscribe' { ['id', 'op', 'subscriptionId', 'path', 'args'] }
		'unsubscribe' { ['id', 'op', 'subscriptionId'] }
		'setAuth' { ['id', 'op', 'token'] }
		else { ['id', 'op'] }
	}
}

// duplicate_top_level_key inspects the raw line because a decoded JSON map has
// already collapsed a repeated field to one entry. `{"id":"a","id":"b"}` is
// ambiguous, so it is refused rather than silently resolved.
fn duplicate_top_level_key(text string) ?string {
	mut seen := map[string]bool{}
	mut depth := 0
	mut expect_key := false
	mut index := 0
	for index < text.len {
		character := text[index]
		if character == `{` {
			depth++
			expect_key = depth == 1
			index++
			continue
		}
		if character == `[` {
			depth++
			index++
			continue
		}
		if character == `}` || character == `]` {
			depth--
			index++
			continue
		}
		if character == `,` {
			if depth == 1 {
				expect_key = true
			}
			index++
			continue
		}
		if character == `"` {
			start := index + 1
			mut end := start
			for end < text.len {
				if text[end] == `\\` {
					end += 2
					continue
				}
				if text[end] == `"` {
					break
				}
				end++
			}
			if end >= text.len {
				return none
			}
			if depth == 1 && expect_key {
				raw_key := text[start..end]
				decoded_key := json2.raw_decode('"${raw_key}"') or { json2.Any(raw_key) }
				key := if decoded_key is string { decoded_key } else { raw_key }
				if key in seen {
					return key
				}
				seen[key] = true
				expect_key = false
			}
			index = end + 1
			continue
		}
		index++
	}
	return none
}

// parse_command turns one NDJSON line into a validated command.
pub fn parse_command(line string) !Command {
	if line.len == 0 {
		return error('adapter command line must not be empty')
	}
	if line.len > max_command_bytes {
		return error('adapter command exceeds ${max_command_bytes} bytes')
	}
	convex.utf8_scalars(line) or { return error('adapter command is not valid UTF-8') }
	if key := duplicate_top_level_key(line) {
		return error('adapter command contains a duplicate field: ${key}')
	}
	command := convex.decode_bounded_json_object(line, 'adapter') or { return error(err.msg()) }

	id := as_string(command, 'id') or { return error('adapter command requires a string id') }
	if !bounded_identifier(id) {
		return error('id must be 1 to 128 Unicode scalars')
	}
	op := as_string(command, 'op') or { return error('adapter command requires a string op') }

	allowed := allowed_fields(op)!
	for key in command.keys() {
		if key !in allowed {
			return error('adapter command contains an unknown field: ${key}')
		}
	}
	for key in required_fields(op) {
		if key !in command {
			return error('adapter command is missing a required field: ${key}')
		}
	}

	mut protocol_version := 0
	if op == 'hello' {
		value := convex.integral_number(command['protocolVersion'] or { json2.Any(json2.null) }) or {
			return error('protocolVersion must be an integer')
		}
		if value != 1 {
			return error('unsupported adapter protocol version: ${value}')
		}
		protocol_version = 1
	}

	mut path := ''
	if 'path' in command {
		path = as_string(command, 'path') or { return error('path must be a string') }
		path_scalars := convex.utf8_scalars(path) or { return error('path is not valid UTF-8') }
		if op in ['query', 'mutation', 'action'] && path_scalars < 3 {
			return error('path must contain at least three characters')
		}
	}

	mut args := map[string]json2.Any{}
	if 'args' in command {
		value := command['args'] or { json2.Any(json2.null) }
		if value !is map[string]json2.Any {
			return error('args must be a JSON object')
		}
		args = value as map[string]json2.Any
	}

	mut token := ''
	if op == 'setAuth' {
		token = as_string(command, 'token') or { return error('token must be a string') }
	}

	mut subscription_id := ''
	if 'subscriptionId' in command {
		subscription_id = as_string(command, 'subscriptionId') or {
			return error('subscriptionId must be a string')
		}
		if !bounded_identifier(subscription_id) {
			return error('subscriptionId must be 1 to 128 Unicode scalars')
		}
	}

	return Command{
		id:               id
		op:               op
		path:             path
		args:             args
		token:            token
		subscription_id:  subscription_id
		protocol_version: protocol_version
	}
}

fn as_string(object map[string]json2.Any, key string) ?string {
	value := object[key] or { return none }
	if value is string {
		return value
	}
	return none
}

fn bounded_identifier(text string) bool {
	scalars := convex.utf8_scalars(text) or { return false }
	return scalars >= 1 && scalars <= 128
}
