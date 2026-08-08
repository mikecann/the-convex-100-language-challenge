package main

import convex "convex:."
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

@test
adapter_serialization_omits_absent_optional_fields :: proc(t: ^testing.T) {
	ready := ready_event("hello")
	defer delete(ready)
	testing.expect(t, strings.contains(ready, `"protocolVersion":1`))
	testing.expect(t, !strings.contains(ready, `:null`))

	err := convex.make_error(.Transport, "socket stopped")
	failure := failure_event("call", err)
	convex.destroy_error(&err)
	defer delete(failure)
	testing.expect(t, strings.contains(failure, `"name":"TransportError"`))
	testing.expect(t, !strings.contains(failure, `"data":null`))

	result := convex.Result{value_json = strings.clone(`{"ok":true}`)}
	event := result_event("call", result)
	convex.destroy_result(&result)
	defer delete(event)
	testing.expect(t, strings.contains(event, `"value":{"ok":true}`))
	testing.expect(t, strings.contains(event, `"logs":[]`))
}

@test
adapter_rejects_malformed_and_incomplete_commands :: proc(t: ^testing.T) {
	sources := [?]string{
		`{malformed`,
		`{"id":"x","op":"query","path":"demo:state"}`,
		`{"id":"x","op":"subscribe","path":"demo:state","args":{}}`,
		`{"id":"x","op":"unknown"}`,
		`{"id":"x","op":"close","surprise":true}`,
		`{"protocolVersion":1,"id":"x","op":"hello","extra":0}`,
		`{"id":"x","op":"unsubscribe","subscriptionId":"s","args":[]}`,
	}
	for source in sources {
		command, err := parse_command(source)
		testing.expect_value(t, err.kind, convex.Error_Kind.Protocol)
		convex.destroy_error(&err)
		destroy_command(&command)
	}
}

@test
adapter_parses_all_protocol_v1_command_shapes :: proc(t: ^testing.T) {
	sources := [?]string{
		`{"protocolVersion":1,"id":"h","op":"hello"}`,
		`{"id":"q","op":"query","path":"demo:state","args":{}}`,
		`{"id":"m","op":"mutation","path":"demo:increment","args":{}}`,
		`{"id":"a","op":"action","path":"demo:greet","args":{}}`,
		`{"id":"s","op":"subscribe","subscriptionId":"sub","path":"demo:state","args":{}}`,
		`{"id":"u","op":"unsubscribe","subscriptionId":"sub"}`,
		`{"id":"t","op":"setAuth","token":""}`,
		`{"id":"d","op":"debugDisconnect"}`,
		`{"id":"c","op":"close"}`,
	}
	for source in sources {
		command, err := parse_command(source)
		testing.expect_value(t, err.kind, convex.Error_Kind.None)
		convex.destroy_error(&err)
		destroy_command(&command)
	}
}

@test
relay_generation_barrier_rejects_stale_events :: proc(t: ^testing.T) {
	active := make(map[string]u64)
	defer delete_map(active)
	active["same-id"] = 2
	stale := Output_Item{kind = .Event, subscription_id = "same-id", generation = 1}
	current := Output_Item{kind = .Event, subscription_id = "same-id", generation = 2}
	testing.expect(t, !relay_is_current(active, stale))
	testing.expect(t, relay_is_current(active, current))
	delete_key(&active, "same-id")
	testing.expect(t, !relay_is_current(active, current))
}

@test
adapter_ids_use_unicode_scalar_count_and_omit_invalid_ids :: proc(t: ^testing.T) {
	maximum := strings.repeat("😀", 128)
	defer delete(maximum)
	maximum_json := quote(maximum)
	defer delete(maximum_json)
	line := fmt.aprintf(`{{"protocolVersion":1,"id":%s,"op":"hello"}}`, maximum_json)
	command, err := parse_command(line)
	delete(line)
	testing.expect_value(t, err.kind, convex.Error_Kind.None)
	testing.expect(t, command.id == maximum)
	convex.destroy_error(&err)
	destroy_command(&command)

	too_large := strings.repeat("😀", 129)
	defer delete(too_large)
	too_large_json := quote(too_large)
	defer delete(too_large_json)
	line = fmt.aprintf(`{{"protocolVersion":1,"id":%s,"op":"hello"}}`, too_large_json)
	command, err = parse_command(line)
	delete(line)
	testing.expect_value(t, err.kind, convex.Error_Kind.Protocol)
	testing.expect_value(t, command.id, "")
	event := protocol_failure_event(command.id, err.message)
	testing.expect(t, !strings.contains(event, `"id":`))
	delete(event)
	convex.destroy_error(&err)
	destroy_command(&command)

	subscription_line := fmt.aprintf(`{{"id":"s","op":"subscribe","subscriptionId":%s,"path":"demo:state","args":{{}}}}`, maximum_json)
	command, err = parse_command(subscription_line)
	delete(subscription_line)
	testing.expect_value(t, err.kind, convex.Error_Kind.None)
	convex.destroy_error(&err)
	destroy_command(&command)

	subscription_line = fmt.aprintf(`{{"id":"s","op":"subscribe","subscriptionId":%s,"path":"demo:state","args":{{}}}}`, too_large_json)
	command, err = parse_command(subscription_line)
	delete(subscription_line)
	testing.expect_value(t, err.kind, convex.Error_Kind.Protocol)
	convex.destroy_error(&err)
	destroy_command(&command)

	// Confirm the test strings themselves are valid JSON scalars, not malformed
	// byte sequences accidentally taking the protocol-error path.
	value, parse_error := json.parse_string(maximum_json, .JSON, true)
	testing.expect_value(t, parse_error, nil)
	json.destroy_value(value)
}
