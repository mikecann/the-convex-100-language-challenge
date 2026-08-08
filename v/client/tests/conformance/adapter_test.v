module conformance

import convex
import sync
import time
import x.json2

// CaptureTarget stands in for the terminal stream. `blocked` models the case
// the shared rules care about most: a controller that has stopped reading.
struct CaptureTarget {
mut:
	mutex   &sync.Mutex = unsafe { nil }
	lines   []string
	blocked bool
}

fn new_capture() &CaptureTarget {
	return &CaptureTarget{
		mutex: sync.new_mutex()
	}
}

fn (mut target CaptureTarget) emit(text string) ! {
	for {
		target.mutex.@lock()
		blocked := target.blocked
		target.mutex.unlock()
		if !blocked {
			break
		}
		time.sleep(2 * time.millisecond)
	}
	target.mutex.@lock()
	target.lines << text
	target.mutex.unlock()
}

fn (mut target CaptureTarget) finish() {}

fn (mut target CaptureTarget) captured() []string {
	target.mutex.@lock()
	defer {
		target.mutex.unlock()
	}
	return target.lines.clone()
}

fn (mut target CaptureTarget) set_blocked(value bool) {
	target.mutex.@lock()
	target.blocked = value
	target.mutex.unlock()
}

fn command_failure(line string) string {
	parse_command(line) or { return err.msg() }
	return ''
}

fn test_valid_commands_are_accepted() ! {
	hello := parse_command('{"protocolVersion":1,"id":"h-1","op":"hello"}')!
	assert hello.op == 'hello'
	assert hello.protocol_version == 1

	call := parse_command('{"id":"q-1","op":"query","path":"demo:state","args":{"room":"r"}}')!
	assert call.path == 'demo:state'
	assert (call.args['room'] or { json2.Any(json2.null) }) as string == 'r'

	subscribe := parse_command('{"id":"s-1","op":"subscribe","subscriptionId":"client-initial","path":"demo:state","args":{}}')!
	assert subscribe.subscription_id == 'client-initial'

	unsubscribe := parse_command('{"id":"u-1","op":"unsubscribe","subscriptionId":"client-initial"}')!
	assert unsubscribe.subscription_id == 'client-initial'

	auth := parse_command('{"id":"a-1","op":"setAuth","token":""}')!
	assert auth.token == ''

	control := parse_command('{"id":"d-1","op":"debugDisconnect"}')!
	assert control.op == 'debugDisconnect'
}

fn test_command_shape_is_strictly_validated() {
	assert command_failure('').contains('must not be empty')
	assert command_failure('not json').contains('valid JSON')
	assert command_failure('[1]').contains('must be a JSON object')
	assert command_failure('{"id":1,"op":"hello"}').contains('string id')
	assert command_failure('{"id":"","op":"close"}').contains('1 to 128')
	assert command_failure('{"id":"a","op":7}').contains('string op')
	assert command_failure('{"id":"a","op":"teleport"}').contains('unknown adapter operation')
	// An unknown or repeated field is ambiguous, so it is refused.
	assert command_failure('{"id":"a","op":"close","extra":1}').contains('unknown field')
	assert command_failure('{"id":"a","id":"b","op":"close"}').contains('duplicate field')
	assert command_failure('{"id":"a","\\u0069d":"b","op":"close"}').contains('duplicate field')
	assert command_failure('{"op":"close"}').contains('string id')
	assert command_failure('{"id":"a","op":"query","path":"demo:state"}').contains('missing a required field')
	assert command_failure('{"id":"a","op":"query","path":"ab","args":{}}').contains('three characters')
	assert command_failure('{"id":"a","op":"query","path":"demo:state","args":[]}').contains('args must be a JSON object')
	assert command_failure('{"protocolVersion":2,"id":"a","op":"hello"}').contains('unsupported adapter protocol version')
	assert command_failure('{"id":"a","op":"setAuth","token":1}').contains('token must be a string')
	assert command_failure('{"id":"a","op":"subscribe","subscriptionId":"","path":"demo:state","args":{}}').contains('1 to 128')
	assert command_failure('{"id":"\xff","op":"close"}').contains('valid UTF-8')
}

fn test_identifier_limits_are_measured_in_unicode_scalars() ! {
	long_id := '🟦'.repeat(128)
	accepted := parse_command('{"id":"${long_id}","op":"close"}')!
	assert accepted.id == long_id
	assert command_failure('{"id":"${'🟦'.repeat(129)}","op":"close"}').contains('1 to 128')
}

fn test_path_minimum_is_measured_in_unicode_scalars() {
	// Two astral scalars occupy eight UTF-8 bytes but still do not satisfy the
	// schema's three-character minimum.
	assert command_failure('{"id":"a","op":"query","path":"🟦🟩","args":{}}').contains('three characters')
}

fn test_over_long_commands_are_refused() {
	line := '{"id":"a","op":"query","path":"demo:echo","args":{"value":"' +
		'x'.repeat(max_command_bytes) + '"}}'
	assert command_failure(line).contains('exceeds')
}

fn test_ready_and_error_events_match_the_shared_schema_shape() ! {
	mut capture := new_capture()
	mut sink := new_output_sink(OutputTarget(capture))
	spawn sink.writer_loop()
	mut adapter := new_adapter(sink)
	adapter.handle_line('{"protocolVersion":1,"id":"h-1","op":"hello"}')
	// A second hello, and any command with an unknown operation, must produce a
	// structured error rather than a silent success.
	adapter.handle_line('{"protocolVersion":1,"id":"h-2","op":"hello"}')
	sink.close(false)

	lines := capture.captured()
	assert lines.len == 2
	for line in lines {
		assert line.ends_with('\n')
	}
	ready := json2.raw_decode(lines[0])! as map[string]json2.Any
	assert (ready['type'] or { json2.Any('') }) as string == 'ready'
	assert (ready['id'] or { json2.Any('') }) as string == 'h-1'
	assert (ready['language'] or { json2.Any('') }) as string == 'v'
	assert ((ready['implementation'] or { json2.Any('') }) as string).len > 0
	assert ((ready['runtime'] or { json2.Any('') }) as string).len > 0
	assert (convex.integral_number(ready['protocolVersion'] or { json2.Any(json2.null) }) or { -1 }) == 1

	failure := json2.raw_decode(lines[1])! as map[string]json2.Any
	assert (failure['type'] or { json2.Any('') }) as string == 'error'
	assert (failure['id'] or { json2.Any('') }) as string == 'h-2'
	// An `as map[string]json2.Any` applied directly to a `map[key] or {}`
	// expression confuses this V version's type checker; splitting the `or`
	// fallback into its own statement first is what keeps it type-checking
	// the fallback against `json2.Any`, not the later cast's target type.
	raw_details := failure['error'] or { json2.Any(json2.null) }
	details := raw_details as map[string]json2.Any
	// Same reasoning again: a cast chained straight into a method call - not
	// just an intermediate variable of a map type - also needs its `or {}`
	// broken out on its own line.
	raw_message := details['message'] or { json2.Any('') }
	message := raw_message as string
	assert message.contains('only be sent once')
	// Absent optional fields are omitted, never serialized as null.
	assert 'data' !in details
	assert 'value' !in failure
	assert 'subscriptionId' !in failure
}

fn test_hello_must_come_first() ! {
	mut capture := new_capture()
	mut sink := new_output_sink(OutputTarget(capture))
	spawn sink.writer_loop()
	mut adapter := new_adapter(sink)
	adapter.handle_line('{"id":"q-1","op":"query","path":"demo:state","args":{}}')
	sink.close(false)
	lines := capture.captured()
	assert lines.len == 1
	assert lines[0].contains('hello must be the first adapter command')
}

fn test_subscription_events_carry_value_or_error_but_never_both() {
	value_event := subscription_event('client-initial', convex.Update{
		value: json2.Any({
			'count': json2.Any(i64(1))
		})
		logs:  ['ran']
	})
	assert (value_event['type'] or { json2.Any('') }) as string == 'subscription'
	assert (value_event['subscriptionId'] or { json2.Any('') }) as string == 'client-initial'
	assert 'value' in value_event
	assert 'error' !in value_event
	assert 'id' !in value_event

	error_event := subscription_event('client-repair', convex.Update{
		error_kind:    'FunctionError'
		error_message: 'room is empty'
		error_data:    json2.Any({
			'code': json2.Any('ROOM_EMPTY')
		})
	})
	assert 'error' in error_event
	assert 'value' !in error_event
	assert 'logs' !in error_event
	// See the comment above `raw_details` earlier in this file.
	raw_error_details := error_event['error'] or { json2.Any(json2.null) }
	details := raw_error_details as map[string]json2.Any
	assert (details['name'] or { json2.Any('') }) as string == 'FunctionError'
	raw_data := details['data'] or { json2.Any(json2.null) }
	data := raw_data as map[string]json2.Any
	assert (data['code'] or { json2.Any('') }) as string == 'ROOM_EMPTY'
}

fn test_output_is_ordered_and_whole() ! {
	mut capture := new_capture()
	mut sink := new_output_sink(OutputTarget(capture))
	spawn sink.writer_loop()
	for index in 0 .. 8 {
		sink.publish('{"seq":${index}}\n', false)!
	}
	sink.close(false)
	lines := capture.captured()
	assert lines.len == 8
	for index in 0 .. 8 {
		assert lines[index] == '{"seq":${index}}\n'
	}
}

fn test_a_stopped_reader_is_bounded_by_count_and_by_bytes() ! {
	mut capture := new_capture()
	capture.set_blocked(true)
	mut sink := new_output_sink(OutputTarget(capture))
	spawn sink.writer_loop()
	// Each event is close to the largest one subscription value can be, so a
	// count-only bound would be worth many times the container's memory.
	large := 'x'.repeat(384 * 1024)
	mut published := 0
	for _ in 0 .. 64 {
		sink.publish('{"value":"${large}"}\n', true) or { break }
		published++
		count, bytes := sink.reserved()
		assert count <= max_output_items
		assert bytes <= max_output_bytes
	}
	assert published > 0
	count, bytes := sink.reserved()
	assert count <= max_output_items
	assert bytes <= max_output_bytes
	capture.set_blocked(false)
	sink.close(false)
}

fn test_a_congested_non_droppable_event_fails_instead_of_growing() ! {
	mut capture := new_capture()
	capture.set_blocked(true)
	mut sink := new_output_sink(OutputTarget(capture))
	spawn sink.writer_loop()
	mut failure := ''
	for _ in 0 .. max_output_items + 4 {
		sink.publish('{"type":"ack"}\n', false) or {
			failure = err.msg()
			break
		}
	}
	assert failure.contains('congested')
	capture.set_blocked(false)
	sink.close(false)
}

fn test_invalidation_drops_a_paused_relays_update() {
	mut adapter := new_adapter(new_output_sink(OutputTarget(new_capture())))
	generation := adapter.next_generation('client-initial')
	adapter.relays['client-initial'] = &RelayRecord{
		generation: generation
		active:     true
	}
	// A relay that dequeued an update while it was still registered may publish.
	assert adapter.may_publish('client-initial', generation, 0)

	// Unsubscribe or same-id replacement invalidates it first, so the update it
	// is still holding can no longer cross the acknowledgement.
	adapter.invalidate('client-initial')
	assert !adapter.may_publish('client-initial', generation, 0)

	replacement := adapter.next_generation('client-initial')
	adapter.relays['client-initial'] = &RelayRecord{
		generation: replacement
		active:     true
	}
	assert replacement > generation
	assert !adapter.may_publish('client-initial', generation, 0)
	assert adapter.may_publish('client-initial', replacement, 0)
}

fn test_debug_disconnect_minimum_generation_drops_older_updates() {
	mut adapter := new_adapter(new_output_sink(OutputTarget(new_capture())))
	generation := adapter.next_generation('client-reconnect')
	adapter.relays['client-reconnect'] = &RelayRecord{
		generation: generation
		active:     true
	}
	assert adapter.may_publish('client-reconnect', generation, 4)
	// The acknowledgement publishes a new minimum, so an update produced by the
	// retired connection is dropped even though its relay is still current.
	adapter.minimum_generation = 5
	assert !adapter.may_publish('client-reconnect', generation, 4)
	assert adapter.may_publish('client-reconnect', generation, 5)
}

fn test_listen_address_parsing_is_strict() {
	valid_host, valid_port := parse_listen_address('0.0.0.0:8080') or {
		assert false, 'a valid ADAPTER_LISTEN must parse'
		return
	}
	assert valid_host == '0.0.0.0'
	assert valid_port == 8080
	for bad in ['', '8080', '0.0.0.0:', ':8080', '0.0.0.0:0', '0.0.0.0:70000', 'host:port'] {
		parse_listen_address(bad) or { continue }
		assert false, 'invalid ADAPTER_LISTEN was accepted: ${bad}'
	}
}

fn test_overlong_tcp_line_preserves_the_next_controller_command() {
	// The over-long command and the valid close command arrive in one chunk.
	// Discarding the whole chunk would lose the close and leave the controller
	// waiting forever, so the reader keeps bytes after the first newline.
	mut lines := TcpLines{
		pending:    ('x'.repeat(max_adapter_line_bytes + 1) + '\n{"id":"close","op":"close"}\n').bytes()
		discarding: true
	}
	assert lines.discard_buffered_line()
	assert lines.overlong == false
	line := lines.next() or {
		assert false, 'the valid command after an overlong line disappeared'
		return
	}
	assert line == '{"id":"close","op":"close"}'
}
