package main

import convex "convex:."
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

ADAPTER_PROTOCOL_VERSION :: 1
MAX_ADAPTER_LINE_BYTES :: convex.MAX_WIRE_BYTES
MAX_OUTPUT_RECORDS :: 16
MAX_OUTPUT_BYTES :: 8 * 1024 * 1024
OUTPUT_RECORD_OVERHEAD :: 1024
OUTPUT_CLOSE_TIMEOUT :: 250 * time.Millisecond

Controller_Kind :: enum { Stdio, TCP }

Controller :: struct {
	kind:       Controller_Kind,
	socket:     net.TCP_Socket,
	pending:    [dynamic]u8,
	discarding: bool,
}

controller_read :: proc(controller: ^Controller, buffer: []u8) -> (int, bool) {
	if controller.kind == .TCP {
		count, err := net.recv_tcp(controller.socket, buffer)
		return count, err == nil && count > 0
	}
	count, err := os.read(os.stdin, buffer)
	return count, err == nil && count > 0
}

controller_write :: proc(controller: ^Controller, data: []u8) -> bool {
	offset := 0
	for offset < len(data) {
		if controller.kind == .TCP {
			written, err := net.send_tcp(controller.socket, data[offset:])
			if err != nil || written <= 0 { return false }
			offset += written
		} else {
			written, err := os.write(os.stdout, data[offset:])
			if err != nil || written <= 0 { return false }
			offset += written
		}
	}
	return true
}

// read_line retains unread bytes between calls and discards an oversized line
// through its newline. A hostile controller cannot turn one record into an
// unbounded allocation or desynchronise the next command.
controller_read_line :: proc(controller: ^Controller) -> (line: string, ok, too_long: bool) {
	chunk: [8192]u8
	for {
		for byte, index in controller.pending {
			if byte != '\n' { continue }
			if controller.discarding {
				remove_pending_prefix(controller, index+1)
				controller.discarding = false
				return "", true, true
			}
			end := index
			if end > 0 && controller.pending[end-1] == '\r' { end -= 1 }
			line = strings.clone(string(controller.pending[:end]))
			remove_pending_prefix(controller, index+1)
			return line, true, false
		}
		count, read_ok := controller_read(controller, chunk[:])
		if !read_ok {
			if len(controller.pending) == 0 || controller.discarding { return "", false, controller.discarding }
			line = strings.clone(string(controller.pending[:]))
			resize(&controller.pending, 0)
			return line, true, false
		}
		if !controller.discarding {
			if len(controller.pending) > MAX_ADAPTER_LINE_BYTES - count {
				allowed := MAX_ADAPTER_LINE_BYTES-len(controller.pending)
				newline := -1
				for byte, index in chunk[:count] {
					if byte == '\n' { newline = index; break }
				}
				if newline >= 0 && newline <= allowed {
					append(&controller.pending, ..chunk[:count])
					continue
				}
				resize(&controller.pending, 0)
				if newline >= 0 {
					append(&controller.pending, ..chunk[newline+1:count])
					return "", true, true
				}
				controller.discarding = true
			} else {
				append(&controller.pending, ..chunk[:count])
			}
		} else {
			// Keep only enough bytes to find the delimiter while discarding.
			for byte, index in chunk[:count] {
				if byte == '\n' {
					controller.discarding = false
					append(&controller.pending, ..chunk[index+1:count])
					return "", true, true
				}
			}
		}
	}
}

remove_pending_prefix :: proc(controller: ^Controller, count: int) {
	copy(controller.pending[:], controller.pending[count:])
	resize(&controller.pending, len(controller.pending)-count)
}

Output_Kind :: enum { Event, Activate, Invalidate }

Output_Item :: struct {
	kind:            Output_Kind,
	encoded:         string,
	subscription_id: string,
	generation:      u64,
	cost:            int,
}

Output :: struct {
	controller: ^Controller,
	mutex:      sync.Mutex,
	cond:       sync.Cond,
	queue:      [dynamic]^Output_Item,
	records:    int,
	bytes:      int,
	accepting:  bool,
	closing:    bool,
	done:       bool,
	failed:     bool,
	thread:     ^thread.Thread,
}

output_create :: proc(controller: ^Controller) -> ^Output {
	output := new(Output)
	output.controller = controller
	output.accepting = true
	output.thread = thread.create_and_start_with_data(output, output_thread, context)
	return output
}

output_enqueue :: proc(output: ^Output, item: ^Output_Item) -> bool {
	sync.mutex_lock(&output.mutex)
	defer sync.mutex_unlock(&output.mutex)
	if !output.accepting || output.failed || output.records >= MAX_OUTPUT_RECORDS || output.bytes > MAX_OUTPUT_BYTES-item.cost {
		return false
	}
	output.records += 1
	output.bytes += item.cost
	append(&output.queue, item)
	sync.cond_signal(&output.cond)
	return true
}

output_event :: proc(output: ^Output, encoded: string, subscription_id := "", generation: u64 = 0) -> bool {
	item := new(Output_Item)
	item.kind = .Event
	item.encoded = encoded
	item.subscription_id = strings.clone(subscription_id)
	item.generation = generation
	item.cost = len(encoded) + OUTPUT_RECORD_OVERHEAD
	if !output_enqueue(output, item) { destroy_output_item(item); return false }
	return true
}

output_control :: proc(output: ^Output, kind: Output_Kind, subscription_id: string, generation: u64) -> bool {
	item := new(Output_Item)
	item.kind = kind
	item.subscription_id = strings.clone(subscription_id)
	item.generation = generation
	item.cost = OUTPUT_RECORD_OVERHEAD
	if !output_enqueue(output, item) { destroy_output_item(item); return false }
	return true
}

output_pop :: proc(output: ^Output) -> ^Output_Item {
	sync.mutex_lock(&output.mutex)
	defer sync.mutex_unlock(&output.mutex)
	for len(output.queue) == 0 && !output.closing {
		sync.cond_wait(&output.cond, &output.mutex)
	}
	if len(output.queue) == 0 { return nil }
	item := output.queue[0]
	copy(output.queue[:], output.queue[1:])
	resize(&output.queue, len(output.queue)-1)
	return item
}

output_release :: proc(output: ^Output, cost: int) {
	sync.mutex_lock(&output.mutex)
	output.records -= 1
	output.bytes -= cost
	sync.mutex_unlock(&output.mutex)
}

output_thread :: proc(data: rawptr) {
	output := cast(^Output)data
	active := make(map[string]u64)
	defer {
		for key in active { delete(key) }
		delete_map(active)
		sync.mutex_lock(&output.mutex)
		output.done = true
		sync.cond_broadcast(&output.cond)
		sync.mutex_unlock(&output.mutex)
	}
	for {
		item := output_pop(output)
		if item == nil { return }
		switch item.kind {
		case .Activate:
			if old_key, exists := find_owned_key(active, item.subscription_id); exists {
				delete_key(&active, item.subscription_id)
				delete(old_key)
			}
			active[strings.clone(item.subscription_id)] = item.generation
		case .Invalidate:
			if generation, exists := active[item.subscription_id]; exists && generation == item.generation {
				owned_key, _ := find_owned_key(active, item.subscription_id)
				delete_key(&active, item.subscription_id)
				delete(owned_key)
			}
		case .Event:
			valid := relay_is_current(active, item^)
			if valid && !controller_write(output.controller, transmute([]u8)item.encoded) {
				sync.mutex_lock(&output.mutex)
				output.failed = true
				output.accepting = false
				output.closing = true
				sync.mutex_unlock(&output.mutex)
			}
		}
		cost := item.cost
		destroy_output_item(item)
		output_release(output, cost)
	}
}

relay_is_current :: proc(active: map[string]u64, item: Output_Item) -> bool {
	if item.generation == 0 { return true }
	generation, exists := active[item.subscription_id]
	return exists && generation == item.generation
}

find_owned_key :: proc(values: map[string]u64, wanted: string) -> (string, bool) {
	for key in values { if key == wanted { return key, true } }
	return "", false
}

destroy_output_item :: proc(item: ^Output_Item) {
	delete(item.encoded)
	delete(item.subscription_id)
	free(item)
}

output_close :: proc(output: ^Output, timeout := OUTPUT_CLOSE_TIMEOUT) -> bool {
	sync.mutex_lock(&output.mutex)
	output.accepting = false
	output.closing = true
	sync.cond_broadcast(&output.cond)
	sync.mutex_unlock(&output.mutex)
	deadline := time.tick_add(time.tick_now(), timeout)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		sync.mutex_lock(&output.mutex)
		done := output.done
		sync.mutex_unlock(&output.mutex)
		if done { thread.destroy(output.thread); delete(output.queue); free(output); return true }
		time.sleep(time.Millisecond)
	}
	return false
}

quote :: proc(text: string) -> string {
	encoded, err := json.marshal(text, {spec = .JSON})
	if err != nil { return strings.clone(`""`) }
	return string(encoded)
}

logs_json :: proc(logs: []string) -> string {
	builder: strings.Builder
	strings.builder_init(&builder)
	strings.write_byte(&builder, '[')
	for line, index in logs {
		if index > 0 { strings.write_byte(&builder, ',') }
		encoded := quote(line)
		strings.write_string(&builder, encoded)
		delete(encoded)
	}
	strings.write_byte(&builder, ']')
	return strings.to_string(builder)
}

error_object_json :: proc(err: convex.Error) -> string {
	name := quote(convex.error_name(err))
	message := quote(err.message)
	defer delete(name)
	defer delete(message)
	if err.data_json != "" {
		return fmt.aprintf(`{{"name":%s,"message":%s,"data":%s}}`, name, message, err.data_json)
	}
	return fmt.aprintf(`{{"name":%s,"message":%s}}`, name, message)
}

failure_event :: proc(id: string, err: convex.Error) -> string {
	id_json := quote(id)
	error_json := error_object_json(err)
	defer delete(id_json)
	defer delete(error_json)
	logs := logs_json(err.logs)
	defer delete(logs)
	if len(err.logs) > 0 {
		return fmt.aprintf(`{{"id":%s,"type":"error","logs":%s,"error":%s}}
`, id_json, logs, error_json)
	}
	return fmt.aprintf(`{{"id":%s,"type":"error","error":%s}}
`, id_json, error_json)
}

protocol_failure_event :: proc(id, message: string) -> string {
	err := convex.make_error(.Protocol, message)
	defer convex.destroy_error(&err)
	if id == "" {
		error_json := error_object_json(err)
		defer delete(error_json)
		return fmt.aprintf(`{{"type":"error","error":%s}}
`, error_json)
	}
	return failure_event(id, err)
}

result_event :: proc(id: string, result: convex.Result) -> string {
	id_json := quote(id)
	logs := logs_json(result.logs)
	defer delete(id_json)
	defer delete(logs)
	return fmt.aprintf(`{{"id":%s,"type":"result","value":%s,"logs":%s}}
`, id_json, result.value_json, logs)
}

subscription_event :: proc(subscription_id: string, update: convex.Update) -> string {
	sub_json := quote(subscription_id)
	defer delete(sub_json)
	if update.error.kind != .None {
		error_json := error_object_json(update.error)
		defer delete(error_json)
		logs := logs_json(update.error.logs)
		defer delete(logs)
		if len(update.error.logs) > 0 {
			return fmt.aprintf(`{{"type":"subscription","subscriptionId":%s,"logs":%s,"error":%s}}
`, sub_json, logs, error_json)
		}
		return fmt.aprintf(`{{"type":"subscription","subscriptionId":%s,"error":%s}}
`, sub_json, error_json)
	}
	logs := logs_json(update.logs)
	defer delete(logs)
	return fmt.aprintf(`{{"type":"subscription","subscriptionId":%s,"value":%s,"logs":%s}}
`, sub_json, update.value_json, logs)
}

simple_event :: proc(id, kind: string) -> string {
	id_json := quote(id)
	defer delete(id_json)
	return fmt.aprintf(`{{"id":%s,"type":"%s"}}
`, id_json, kind)
}

ready_event :: proc(id: string) -> string {
	id_json := quote(id)
	defer delete(id_json)
	return fmt.aprintf(`{{"protocolVersion":1,"id":%s,"type":"ready","language":"odin","implementation":"native-odin-%s","runtime":"odin-dev-2026-05"}}
`, id_json, convex.VERSION)
}

Command :: struct {
	id:              string,
	op:              string,
	path:            string,
	args_json:       string,
	subscription_id: string,
	token:           string,
	protocol_version: u32,
}

destroy_command :: proc(command: ^Command) {
	delete(command.id); delete(command.op); delete(command.path)
	delete(command.args_json); delete(command.subscription_id); delete(command.token)
	command^ = {}
}

valid_id :: proc(id: string) -> bool {
	if !utf8.valid_string(id) { return false }
	count := utf8.rune_count_in_string(id)
	return count >= 1 && count <= 128
}

has_field :: proc(fields: []string, wanted: string) -> bool {
	for field in fields { if field == wanted { return true } }
	return false
}

reject_extra_fields :: proc(object: json.Object, allowed: []string) -> (err: convex.Error) {
	for field in object {
		if !has_field(allowed, field) {
			message := fmt.aprintf("adapter command contains unsupported field %s", field)
			defer delete(message)
			return convex.make_error(.Protocol, message)
		}
	}
	return {}
}

parse_command :: proc(line: string) -> (command: Command, err: convex.Error) {
	root, parse_err := convex.parse_json(line, "adapter command")
	if parse_err.kind != .None { return {}, parse_err }
	defer json.destroy_value(root)
	object, ok := convex.as_object(root)
	if !ok { return {}, convex.make_error(.Protocol, "adapter command is not an object") }
	if id_value, exists := convex.member(object, "id"); exists {
		if id, id_ok := convex.as_string(id_value); id_ok && valid_id(id) { command.id = strings.clone(id) }
	}
	op, op_err := convex.required_string(object, "op")
	if op_err.kind != .None { return command, op_err }
	command.op = strings.clone(op)
	if !valid_id(command.id) { return command, convex.make_error(.Protocol, "adapter command id is missing or invalid") }

	switch op {
	case "hello":
		if field_err := reject_extra_fields(object, []string{"protocolVersion", "id", "op"}); field_err.kind != .None { return command, field_err }
		version, version_err := convex.required_u32(object, "protocolVersion")
		if version_err.kind != .None { return command, version_err }
		command.protocol_version = version
	case "query", "mutation", "action", "subscribe":
		allowed := []string{"id", "op", "path", "args"}
		if op == "subscribe" { allowed = []string{"id", "op", "subscriptionId", "path", "args"} }
		if field_err := reject_extra_fields(object, allowed); field_err.kind != .None { return command, field_err }
		path, path_err := convex.required_string(object, "path")
		if path_err.kind != .None || len(path) < 3 {
			convex.destroy_error(&path_err)
			return command, convex.make_error(.Protocol, "path is missing or invalid")
		}
		command.path = strings.clone(path)
		args, exists := convex.member(object, "args")
		if !exists { return command, convex.make_error(.Protocol, "args is required") }
		if _, object_ok := convex.as_object(args); !object_ok { return command, convex.make_error(.Protocol, "args is not an object") }
		command.args_json, err = convex.value_json(args)
		if err.kind != .None { return }
		if op == "subscribe" {
			subscription_id, sub_err := convex.required_string(object, "subscriptionId")
			if sub_err.kind != .None || !valid_id(subscription_id) {
				convex.destroy_error(&sub_err)
				return command, convex.make_error(.Protocol, "subscriptionId is missing or invalid")
			}
			command.subscription_id = strings.clone(subscription_id)
		}
	case "unsubscribe":
		if field_err := reject_extra_fields(object, []string{"id", "op", "subscriptionId", "path", "args"}); field_err.kind != .None { return command, field_err }
		subscription_id, sub_err := convex.required_string(object, "subscriptionId")
		if sub_err.kind != .None || !valid_id(subscription_id) {
			convex.destroy_error(&sub_err)
			return command, convex.make_error(.Protocol, "subscriptionId is missing or invalid")
		}
		command.subscription_id = strings.clone(subscription_id)
		if path_value, exists := convex.member(object, "path"); exists {
			if _, valid := convex.as_string(path_value); !valid { return command, convex.make_error(.Protocol, "optional unsubscribe path is not a string") }
		}
		if args_value, exists := convex.member(object, "args"); exists {
			if _, valid := convex.as_object(args_value); !valid { return command, convex.make_error(.Protocol, "optional unsubscribe args is not an object") }
		}
	case "setAuth":
		if field_err := reject_extra_fields(object, []string{"id", "op", "token"}); field_err.kind != .None { return command, field_err }
		token, token_err := convex.required_string(object, "token")
		if token_err.kind != .None || len(token) > MAX_ADAPTER_LINE_BYTES {
			convex.destroy_error(&token_err)
			return command, convex.make_error(.Protocol, "token is missing or too large")
		}
		command.token = strings.clone(token)
	case "close", "debugDisconnect":
		if field_err := reject_extra_fields(object, []string{"id", "op"}); field_err.kind != .None { return command, field_err }
	case: return command, convex.make_error(.Protocol, "unknown adapter operation")
	}
	return command, {}
}

Adapter_Subscription :: struct {
	subscription: ^convex.Subscription,
	generation:   u64,
	relay_thread: ^thread.Thread,
}

Relay_Data :: struct {
	output:          ^Output,
	subscription:    ^convex.Subscription,
	subscription_id: string,
	generation:      u64,
}

relay_thread :: proc(data_raw: rawptr) {
	data := cast(^Relay_Data)data_raw
	defer { delete(data.subscription_id); free(data) }
	for {
		update, ok := convex.subscription_recv(data.subscription, 50 * time.Millisecond)
		if !ok {
			if convex.subscription_is_active(data.subscription) { continue }
			return
		}
		encoded := subscription_event(data.subscription_id, update)
		convex.destroy_update(&update)
		if !output_event(data.output, encoded, data.subscription_id, data.generation) { return }
	}
}

ensure_client :: proc(current: ^^convex.Client) -> (client: ^convex.Client, err: convex.Error) {
	if current^ != nil { return current^, {} }
	url := os.get_env_alloc("CONVEX_URL", context.allocator)
	defer delete(url)
	if url == "" { return nil, convex.make_error(.Protocol, "CONVEX_URL is required") }
	client, err = convex.create(url)
	if err.kind != .None { return }
	token := os.get_env_alloc("CONVEX_AUTH_TOKEN", context.allocator)
	defer delete(token)
	if token != "" {
		if auth_err := convex.set_auth(client, token); auth_err.kind != .None {
			convex.destroy(client)
			return nil, auth_err
		}
	}
	current^ = client
	return client, {}
}

stop_adapter_subscription :: proc(output: ^Output, state: Adapter_Subscription, subscription_id: string) {
	_ = output_control(output, .Invalidate, subscription_id, state.generation)
	_ = convex.subscription_close(state.subscription)
	thread.destroy(state.relay_thread)
	convex.subscription_destroy(state.subscription)
}

run_adapter :: proc(controller: ^Controller) {
	output := output_create(controller)
	client: ^convex.Client
	subscriptions := make(map[string]Adapter_Subscription)
	next_generation: u64
	defer {
		for id, state in subscriptions {
			stop_adapter_subscription(output, state, id)
			delete(id)
		}
		delete_map(subscriptions)
		if client != nil { convex.destroy(client) }
		_ = output_close(output)
	}

	for {
		line, read_ok, too_long := controller_read_line(controller)
		if !read_ok { return }
		if too_long {
			if !output_event(output, protocol_failure_event("", "adapter command exceeds the bounded line size")) { return }
			continue
		}
		command, command_err := parse_command(line)
		delete(line)
		if command_err.kind != .None {
			encoded := protocol_failure_event(command.id, command_err.message)
			convex.destroy_error(&command_err)
			if !output_event(output, encoded) { destroy_command(&command); return }
			destroy_command(&command)
			continue
		}

		switch command.op {
		case "hello":
			if command.protocol_version != ADAPTER_PROTOCOL_VERSION {
				if !output_event(output, protocol_failure_event(command.id, "unsupported adapter protocol version")) { destroy_command(&command); return }
			} else if !output_event(output, ready_event(command.id)) { destroy_command(&command); return }
		case "query", "mutation", "action":
			active_client, client_err := ensure_client(&client)
			if client_err.kind != .None {
				if !output_event(output, failure_event(command.id, client_err)) { convex.destroy_error(&client_err); destroy_command(&command); return }
				convex.destroy_error(&client_err)
				break
			}
			result: convex.Result
			call_err: convex.Error
			switch command.op {
			case "query": result, call_err = convex.query(active_client, command.path, command.args_json)
			case "mutation": result, call_err = convex.mutation(active_client, command.path, command.args_json)
			case "action": result, call_err = convex.action(active_client, command.path, command.args_json)
			}
			if call_err.kind != .None {
				encoded := failure_event(command.id, call_err)
				convex.destroy_error(&call_err)
				if !output_event(output, encoded) { destroy_command(&command); return }
			} else {
				encoded := result_event(command.id, result)
				convex.destroy_result(&result)
				if !output_event(output, encoded) { destroy_command(&command); return }
			}
		case "setAuth":
			active_client, client_err := ensure_client(&client)
			if client_err.kind == .None { client_err = convex.set_auth(active_client, command.token) }
			if client_err.kind != .None {
				encoded := failure_event(command.id, client_err)
				convex.destroy_error(&client_err)
				if !output_event(output, encoded) { destroy_command(&command); return }
			} else if !output_event(output, simple_event(command.id, "ack")) { destroy_command(&command); return }
		case "subscribe":
			active_client, client_err := ensure_client(&client)
			if client_err.kind != .None {
				encoded := failure_event(command.id, client_err)
				convex.destroy_error(&client_err)
				if !output_event(output, encoded) { destroy_command(&command); return }
				break
			}
			if previous, exists := subscriptions[command.subscription_id]; exists {
				owned_key, _ := find_subscription_key(subscriptions, command.subscription_id)
				stop_adapter_subscription(output, previous, command.subscription_id)
				delete_key(&subscriptions, command.subscription_id)
				delete(owned_key)
			}
			sub, subscribe_err := convex.subscribe(active_client, command.path, command.args_json)
			if subscribe_err.kind != .None {
				encoded := failure_event(command.id, subscribe_err)
				convex.destroy_error(&subscribe_err)
				if !output_event(output, encoded) { destroy_command(&command); return }
				break
			}
			next_generation += 1
			generation := next_generation
			if !output_control(output, .Activate, command.subscription_id, generation) {
				convex.subscription_destroy(sub); destroy_command(&command); return
			}
			// Publish the command acknowledgement before the relay can enqueue its
			// first value. Activate still precedes both, so the generation is live.
			if !output_event(output, simple_event(command.id, "ack")) {
				convex.subscription_destroy(sub); destroy_command(&command); return
			}
			data := new(Relay_Data)
			data.output = output
			data.subscription = sub
			data.subscription_id = strings.clone(command.subscription_id)
			data.generation = generation
			state := Adapter_Subscription{sub, generation, thread.create_and_start_with_data(data, relay_thread, context)}
			subscriptions[strings.clone(command.subscription_id)] = state
		case "unsubscribe":
			if state, exists := subscriptions[command.subscription_id]; exists {
				owned_key, _ := find_subscription_key(subscriptions, command.subscription_id)
				stop_adapter_subscription(output, state, command.subscription_id)
				delete_key(&subscriptions, command.subscription_id)
				delete(owned_key)
			}
			if !output_event(output, simple_event(command.id, "ack")) { destroy_command(&command); return }
		case "debugDisconnect":
			active_client, client_err := ensure_client(&client)
			if client_err.kind == .None { client_err = convex.debug_disconnect_for_adapter(active_client) }
			if client_err.kind != .None {
				encoded := failure_event(command.id, client_err)
				convex.destroy_error(&client_err)
				if !output_event(output, encoded) { destroy_command(&command); return }
			} else if !output_event(output, simple_event(command.id, "ack")) { destroy_command(&command); return }
		case "close":
			for id, state in subscriptions {
				stop_adapter_subscription(output, state, id)
				delete(id)
			}
			clear(&subscriptions)
			if client != nil { _ = convex.close(client) }
			_ = output_event(output, simple_event(command.id, "closed"))
			destroy_command(&command)
			return
		}
		destroy_command(&command)
	}
}

find_subscription_key :: proc(values: map[string]Adapter_Subscription, wanted: string) -> (string, bool) {
	for key in values { if key == wanted { return key, true } }
	return "", false
}

main :: proc() {
	controller := Controller{kind = .Stdio}
	defer delete(controller.pending)
	address := os.get_env_alloc("ADAPTER_LISTEN", context.allocator)
	defer delete(address)
	if address != "" {
		if !(strings.has_prefix(address, "127.0.0.1:") || strings.has_prefix(address, "[::1]:")) {
			fmt.eprintln("ADAPTER_LISTEN must be loopback")
			os.exit(1)
		}
		endpoint, valid := net.parse_endpoint(address)
		if !valid { fmt.eprintln("invalid ADAPTER_LISTEN address"); os.exit(1) }
		listener, listen_err := net.listen_tcp(endpoint)
		if listen_err != nil { fmt.eprintln("could not listen for controller"); os.exit(1) }
		defer net.close(listener)
		socket, _, accept_err := net.accept_tcp(listener)
		if accept_err != nil { fmt.eprintln("could not accept controller"); os.exit(1) }
		controller.kind = .TCP
		controller.socket = socket
		defer net.close(socket)
		run_adapter(&controller)
		return
	}
	run_adapter(&controller)
}
