module convex

import time
import x.json2

// The Live owner is exercised here without a socket. Every rule these fixtures
// cover - version continuity, coalescing, rehydration suppression, bounded
// delivery, and recovery after a failure - is a rule a happy-path integration
// test would never fail on.
fn new_test_owner() !&LiveOwner {
	return &LiveOwner{
		endpoint:       parse_endpoint('http://backend:3210')!
		client_version: client_version
		session_id:     'fixture-session'
		budget:         new_live_budget()
		stats:          new_live_stats()
		remote_version: zero_version()
		backoff:        live_initial_backoff
	}
}

fn version_json(version Version) string {
	return '{"querySet":${version.query_set},"identity":${version.identity},"ts":"${version.ts}"}'
}

fn transition_json(start Version, end Version, modifications string) string {
	return '{"type":"Transition","startVersion":${version_json(start)},"endVersion":${version_json(end)},"modifications":[${modifications}]}'
}

fn next_version(current Version, timestamp u64) Version {
	return Version{
		query_set: current.query_set
		identity:  current.identity
		ts:        encode_timestamp(timestamp)
	}
}

fn count_of(update Update) i64 {
	state := update.value as map[string]json2.Any
	return integral_number(state['count'] or { json2.Any(json2.null) }) or { -1 }
}

fn test_initial_transition_delivers_the_current_value() ! {
	mut owner := new_test_owner()!
	mut relay := owner.add_query('counter', 'demo:state', {
		'room': json2.Any('r')
	})!
	start := zero_version()
	end := next_version(start, 100)
	owner.apply_message(transition_json(start, end, '{"type":"QueryUpdated","queryId":1,"value":{"count":0},"logLines":["ran"]}'))!

	update := relay.next(100 * time.millisecond)!
	assert !update.is_error()
	assert count_of(update) == 0
	assert update.logs[0] == 'ran'
	assert owner.remote_version.equals(end)
	_, _, observed, _ := owner.stats.snapshot()
	assert observed == 100
}

fn test_transition_must_continue_from_the_local_version() ! {
	mut owner := new_test_owner()!
	mut relay := owner.add_query('counter', 'demo:state', map[string]json2.Any{})!
	stale := Version{
		query_set: 9
		identity:  0
		ts:        encode_timestamp(5)
	}
	owner.apply_message(transition_json(stale, next_version(stale, 6), '{"type":"QueryUpdated","queryId":1,"value":{"count":1}}')) or {
		assert (err as ConvexError).message.contains('startVersion')
		// Nothing may be published from a transition that was not applied.
		update := relay.next(20 * time.millisecond) or { return }
		assert false, 'a rejected transition published ${update.value}'
	}
	assert false, 'a discontinuous transition must be rejected'
}

fn test_transition_timestamp_may_not_move_backwards() ! {
	mut owner := new_test_owner()!
	owner.add_query('counter', 'demo:state', map[string]json2.Any{})!
	start := zero_version()
	forward := next_version(start, 500)
	owner.apply_message(transition_json(start, forward, ''))!
	backward := next_version(forward, 400)
	owner.apply_message(transition_json(forward, backward, '')) or {
		assert (err as ConvexError).message.contains('backwards')
		return
	}
	assert false, 'a backwards timestamp must be rejected'
}

fn test_repeated_modifications_are_coalesced_to_the_final_state() ! {
	mut owner := new_test_owner()!
	mut relay := owner.add_query('counter', 'demo:state', map[string]json2.Any{})!
	start := zero_version()
	end := next_version(start, 10)
	owner.apply_message(transition_json(start, end, '{"type":"QueryUpdated","queryId":1,"value":{"count":1}},{"type":"QueryUpdated","queryId":1,"value":{"count":2}}'))!
	update := relay.next(100 * time.millisecond)!
	assert count_of(update) == 2
	extra := relay.next(20 * time.millisecond) or { return }
	assert false, 'one transition must publish one value per query: ${extra.value}'
}

fn test_query_failure_is_delivered_and_then_recovers() ! {
	mut owner := new_test_owner()!
	mut relay := owner.add_query('repair', 'demo:requiresNonzero', map[string]json2.Any{})!
	start := zero_version()
	failed_at := next_version(start, 10)
	owner.apply_message(transition_json(start, failed_at, '{"type":"QueryFailed","queryId":1,"errorMessage":"room is empty","errorData":{"code":"ROOM_EMPTY"}}'))!
	failure := relay.next(100 * time.millisecond)!
	assert failure.is_error()
	assert failure.error_kind == kind_function_error
	assert failure.error_message == 'room is empty'
	data := failure.error_data as map[string]json2.Any
	assert (string_field(data, 'code') or { '' }) == 'ROOM_EMPTY'

	// A failed query must not be stranded: the same subscription still
	// delivers a later valid value.
	repaired_at := next_version(failed_at, 20)
	owner.apply_message(transition_json(failed_at, repaired_at, '{"type":"QueryUpdated","queryId":1,"value":{"count":1}}'))!
	repaired := relay.next(100 * time.millisecond)!
	assert !repaired.is_error()
	assert count_of(repaired) == 1
}

fn test_query_removed_publishes_nothing() ! {
	mut owner := new_test_owner()!
	mut relay := owner.add_query('counter', 'demo:state', map[string]json2.Any{})!
	start := zero_version()
	owner.apply_message(transition_json(start, next_version(start, 3), '{"type":"QueryRemoved","queryId":1}'))!
	update := relay.next(20 * time.millisecond) or { return }
	assert false, 'QueryRemoved must publish nothing: ${update.value}'
}

fn test_unsupported_messages_and_modifications_are_rejected() ! {
	mut owner := new_test_owner()!
	owner.add_query('counter', 'demo:state', map[string]json2.Any{})!
	start := zero_version()
	for payload in [
		'{"type":"Unknown"}',
		'{"type":"FatalError","error":"backend restarted"}',
		'{"type":"AuthError","error":"identity rejected"}',
		'not json at all',
		'[]',
		transition_json(start, next_version(start, 1), '{"type":"QuerySomething","queryId":1}'),
		transition_json(start, next_version(start, 1), '{"type":"QueryUpdated","queryId":1}'),
		transition_json(start, next_version(start, 1), '{"type":"QueryFailed","queryId":1}'),
		transition_json(start, next_version(start, 1), '{"type":"QueryUpdated","queryId":-1,"value":1}'),
		transition_json(start, next_version(start, 1), '"not an object"'),
	] {
		owner.apply_message(payload) or { continue }
		assert false, 'unsupported Live payload was accepted: ${payload}'
	}
	// Messages the profile defines but this client ignores must not fail.
	owner.apply_message('{"type":"Ping"}')!
	owner.apply_message('{"type":"MutationResponse"}')!
	owner.apply_message('{"type":"ActionResponse"}')!
}

fn test_unchanged_rehydration_is_suppressed_but_a_change_is_not() ! {
	mut owner := new_test_owner()!
	mut relay := owner.add_query('counter', 'demo:state', map[string]json2.Any{})!
	start := zero_version()
	first := next_version(start, 10)
	owner.apply_message(transition_json(start, first, '{"type":"QueryUpdated","queryId":1,"value":{"count":0}}'))!
	assert count_of(relay.next(100 * time.millisecond)!) == 0

	// A reconnect replays the query set, so the server resends the value the
	// subscriber already has. Republishing it would turn one reconnect into a
	// duplicate delivery.
	mut query := owner.queries[1] or { return error('query 1 disappeared') }
	query.rehydrating = true
	second := next_version(first, 20)
	owner.apply_message(transition_json(first, second, '{"type":"QueryUpdated","queryId":1,"value":{"count":0}}'))!
	duplicate := relay.next(20 * time.millisecond) or {
		// Suppressed as intended; a real change still comes through.
		third := next_version(second, 30)
		owner.apply_message(transition_json(second, third, '{"type":"QueryUpdated","queryId":1,"value":{"count":1}}'))!
		assert count_of(relay.next(100 * time.millisecond)!) == 1
		return
	}
	assert false, 'an unchanged rehydration must be suppressed: ${duplicate.value}'
}

fn test_relay_count_bound_fails_a_stopped_consumer() ! {
	mut budget := new_live_budget()
	mut relay := new_relay(budget, 0)
	for index in 0 .. max_relay_updates {
		relay.push(Update{
			value: json2.Any(i64(index))
		})!
	}
	relay.push(Update{
		value: json2.Any(i64(999))
	}) or {
		assert (err as ConvexError).message.contains('too slow')
		// Overflow closes the subscription instead of accumulating, and the
		// shared byte budget is released rather than leaked.
		assert relay.is_closed()
		items, bytes := budget.reserved()
		assert items == 0
		assert bytes == 0
		return
	}
	assert false, 'a stopped consumer must not grow the queue past ${max_relay_updates}'
}

fn test_relay_byte_bound_trips_before_the_count_bound() ! {
	mut budget := new_live_budget()
	mut relay := new_relay(budget, 0)
	// One near-maximum value proves a count-only bound is not a memory bound.
	large := json2.Any('x'.repeat(384 * 1024))
	mut accepted := 0
	for _ in 0 .. max_relay_updates {
		relay.push(Update{
			value: large
		}) or { break }
		accepted++
	}
	assert accepted < max_relay_updates
	assert accepted * 384 * 1024 <= max_relay_bytes
	assert relay.is_closed()
}

fn test_process_wide_budget_is_shared_by_every_subscription() ! {
	mut budget := new_live_budget()
	mut first := new_relay(budget, 0)
	mut second := new_relay(budget, 0)
	mut accepted := 0
	for index in 0 .. max_live_queue_updates {
		if index % 2 == 0 {
			first.push(Update{
				value: json2.Any(i64(index))
			}) or { break }
		} else {
			second.push(Update{
				value: json2.Any(i64(index))
			}) or { break }
		}
		accepted++
	}
	assert accepted == max_live_queue_updates
	items, _ := budget.reserved()
	assert items == max_live_queue_updates
	// The manager-wide reservation is exhausted even though neither relay has
	// reached its own count bound.
	first.push(Update{
		value: json2.Any(i64(99))
	}) or {
		assert (err as ConvexError).message.contains('budget')
		return
	}
	assert false, 'the process-wide budget must bound every subscription together'
}

fn test_taking_updates_returns_the_shared_budget() ! {
	mut budget := new_live_budget()
	mut relay := new_relay(budget, 0)
	relay.push(Update{
		value: json2.Any('value')
	})!
	before, _ := budget.reserved()
	assert before == 1
	relay.next(100 * time.millisecond)!
	after, bytes := budget.reserved()
	assert after == 0
	assert bytes == 0
}

fn test_retire_publishes_a_transport_failure_without_stranding_subscriptions() ! {
	mut owner := new_test_owner()!
	mut relay := owner.add_query('counter', 'demo:state', map[string]json2.Any{})!
	generation := owner.retire('ServerClosed', true)
	assert generation > 0
	failure := relay.next(100 * time.millisecond)!
	assert failure.is_error()
	assert failure.error_kind == kind_transport_error

	// The subscription survives the failure and is replayed on the next
	// connection, so a later transition still delivers.
	mut query := owner.queries[1] or { return error('query 1 disappeared') }
	assert query.rehydrating
	assert owner.remote_version.equals(zero_version())
	start := zero_version()
	owner.apply_message(transition_json(start, next_version(start, 7), '{"type":"QueryUpdated","queryId":1,"value":{"count":4}}'))!
	assert count_of(relay.next(100 * time.millisecond)!) == 4
}

fn test_adapter_disconnect_does_not_publish_an_error() ! {
	mut owner := new_test_owner()!
	mut relay := owner.add_query('counter', 'demo:state', map[string]json2.Any{})!
	owner.retire('adapter debugDisconnect', false)
	update := relay.next(20 * time.millisecond) or {
		_, reason, _, _ := owner.stats.snapshot()
		assert reason == 'adapter debugDisconnect'
		return
	}
	assert false, 'a requested disconnect is not a subscriber-visible error: ${update.value}'
}

fn test_five_disconnect_generations_drop_rehydration_and_deliver_new_values() ! {
	mut owner := new_test_owner()!
	mut relay := owner.add_query('counter', 'demo:state', map[string]json2.Any{})!
	mut expected_generation := u64(0)
	for value in 1 .. 6 {
		expected_generation++
		generation := owner.retire('fixture reconnect ${value}', false)
		assert generation == expected_generation
		// A real reconnect starts its remote version again, resends the active
		// Add set, and receives the old snapshot before the external mutation.
		// The old snapshot must stay behind the generation barrier.
		mut active := owner.queries[1] or { return error('subscription disappeared') }
		assert active.rehydrating
		start := zero_version()
		rehydrated := next_version(start, u64(value * 10))
		owner.apply_message(transition_json(start, rehydrated, '{"type":"QueryUpdated","queryId":1,"value":{"count":0}}'))!
		updated := next_version(rehydrated, u64(value * 10 + 1))
		owner.apply_message(transition_json(rehydrated, updated, '{"type":"QueryUpdated","queryId":1,"value":{"count":${value}}}'))!
		delivery := relay.next(100 * time.millisecond)!
		assert count_of(delivery) == i64(value)
		assert delivery.generation == generation
	}
}

fn test_unsubscribe_and_replacement_invalidate_the_old_relay_first() ! {
	mut owner := new_test_owner()!
	mut original := owner.add_query('counter', 'demo:state', map[string]json2.Any{})!
	mut replacement := owner.add_query('counter', 'demo:state', {
		'room': json2.Any('other')
	})!
	// The replacement is a different relay, and the old one is already closed
	// before this call returns - before any acknowledgement could be published.
	assert original.is_closed()
	assert !replacement.is_closed()
	assert owner.queries.len == 1

	owner.remove_query('counter')!
	assert replacement.is_closed()
	assert owner.queries.len == 0
	assert owner.keys.len == 0
}

fn test_backoff_grows_then_resets_after_a_valid_transition() ! {
	mut owner := new_test_owner()!
	owner.add_query('counter', 'demo:state', map[string]json2.Any{})!
	owner.schedule_backoff()
	first := owner.backoff
	owner.schedule_backoff()
	assert owner.backoff > first
	// A healthy connection must not inherit an old maximum delay.
	start := zero_version()
	owner.apply_message(transition_json(start, next_version(start, 11), ''))!
	assert owner.backoff == live_initial_backoff
}

fn test_subscription_capacity_is_bounded() ! {
	mut owner := new_test_owner()!
	for index in 0 .. max_live_subscriptions {
		owner.add_query('key-${index}', 'demo:state', map[string]json2.Any{})!
	}
	owner.add_query('one-too-many', 'demo:state', map[string]json2.Any{}) or {
		assert (err as ConvexError).message.contains('Live subscriptions')
		return
	}
	assert false, 'the active subscription set must be bounded'
}

fn test_modify_query_set_uses_the_pinned_shape() ! {
	query := &ActiveQuery{
		query_id: 7
		key:      'counter'
		path:     'demo:state'
		args:     {
			'room': json2.Any('lobby')
		}
	}
	add := decode_json_object(encode_json(modification_for('Add', query)), 'test')!
	assert (string_field(add, 'type') or { '' }) == 'Add'
	assert (uint32_field(add, 'queryId') or { 0 }) == 7
	assert (string_field(add, 'udfPath') or { '' }) == 'demo:state'
	// The pinned profile carries a query's arguments as a one-element array.
	args := array_field(add, 'args') or { []json2.Any{} }
	assert args.len == 1
	first := args[0] as map[string]json2.Any
	assert (string_field(first, 'room') or { '' }) == 'lobby'

	remove := decode_json_object(encode_json(modification_for('Remove', query)), 'test')!
	assert (string_field(remove, 'type') or { '' }) == 'Remove'
	assert (uint32_field(remove, 'queryId') or { 0 }) == 7
	assert 'udfPath' !in remove
	assert 'args' !in remove
}

fn test_session_id_is_an_rfc4122_v4_uuid() ! {
	id := new_session_id()!
	assert id.len == 36
	assert id[8] == `-` && id[13] == `-` && id[18] == `-` && id[23] == `-`
	assert id[14] == `4`
	assert id[19] in [`8`, `9`, `a`, `b`]
}

fn test_connection_metadata_counts_only_earlier_successes() {
	mut stats := new_live_stats()
	assert stats.connection_metadata() == 0
	stats.note_connected()
	assert stats.connection_metadata() == 1
}

fn test_connect_metadata_carries_last_close_and_canonical_timestamp() ! {
	message := connect_message('fixture-session', 4, 'ServerClosed', 256)
	assert (string_field(message, 'type') or { '' }) == 'Connect'
	assert (string_field(message, 'sessionId') or { '' }) == 'fixture-session'
	assert (integral_number(message['connectionCount'] or { json2.Any(json2.null) }) or { -1 }) == 4
	assert (string_field(message, 'lastCloseReason') or { '' }) == 'ServerClosed'
	assert (string_field(message, 'maxObservedTimestamp') or { '' }) == encode_timestamp(256)
	without_timestamp := connect_message('fixture-session', 0, 'InitialConnect', 0)
	assert 'maxObservedTimestamp' !in without_timestamp
}
