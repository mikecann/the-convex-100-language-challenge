module conformance

import convex
import net
import os
import sync
import time
import x.json2

// This adapter is test infrastructure, not public client code. It reserves the
// terminal stream for one ordered NDJSON v1 event stream, sends every
// diagnostic to stderr, and dispatches every operation through the real V
// client. Both transports - stdin/stdout and the ADAPTER_LISTEN TCP socket the
// shared harness uses - carry exactly the same bounded, strict protocol.
pub const adapter_language = 'v'
pub const adapter_implementation = 'native-v-0.1.0'
pub const max_adapter_line_bytes = 2 * 1024 * 1024

const relay_poll_slice = 5 * time.millisecond
const adapter_read_budget = time.hour
const client_close_budget = 4 * time.second

// Holds a pointer field and is copied by value in `retire_relays` below, so
// `@[heap]` is required for the same reason as `OutputSink` in output.v.
@[heap]
struct RelayRecord {
mut:
	relay      &convex.Relay = unsafe { nil }
	generation u64
	active     bool
}

pub struct Adapter {
mut:
	mutex              &sync.Mutex    = unsafe { nil }
	sink               &OutputSink    = unsafe { nil }
	client             &convex.Client = unsafe { nil }
	relays             map[string]&RelayRecord
	counters           map[string]u64
	minimum_generation u64
	greeted            bool
	closing            bool
	finished           bool
}

pub fn new_adapter(sink &OutputSink) &Adapter {
	return &Adapter{
		mutex: sync.new_mutex()
		sink:  sink
	}
}

fn runtime_version() string {
	declared := os.getenv('CONVEX_RUNTIME_VERSION')
	if declared.len > 0 {
		return declared
	}
	return 'V (toolchain version not declared by the image)'
}

fn (mut adapter Adapter) ensure_client() !&convex.Client {
	if adapter.client != unsafe { nil } {
		return adapter.client
	}
	url := os.getenv('CONVEX_URL')
	if url.len == 0 {
		return error('CONVEX_URL is required')
	}
	adapter.client = convex.new_client(url)!
	return adapter.client
}

// ---------------------------------------------------------------------------
// Event encoding. Optional fields are omitted when absent rather than
// serialized as null, because the shared controller validates every emitted
// message against the adapter schema.
// ---------------------------------------------------------------------------

fn encode_event(fields map[string]json2.Any) string {
	return json2.encode(json2.Any(fields)) + '\n'
}

fn error_fields(err IError) map[string]json2.Any {
	mut failure := map[string]json2.Any{}
	if err is convex.ConvexError {
		failure['name'] = json2.Any(err.kind)
		failure['message'] = json2.Any(err.message)
		if err.data !is json2.Null {
			failure['data'] = err.data
		}
	} else {
		failure['name'] = json2.Any('ProtocolError')
		failure['message'] = json2.Any(err.msg())
	}
	return failure
}

fn error_logs(err IError) []string {
	if err is convex.ConvexError {
		return err.logs
	}
	return []string{}
}

fn logs_any(logs []string) json2.Any {
	mut entries := []json2.Any{cap: logs.len}
	for line in logs {
		entries << json2.Any(line)
	}
	return json2.Any(entries)
}

fn (mut adapter Adapter) publish(fields map[string]json2.Any, droppable bool) {
	adapter.sink.publish(encode_event(fields), droppable) or {
		diagnostic('adapter could not publish an event: ${err.msg()}')
	}
}

fn (mut adapter Adapter) publish_error(id string, err IError) {
	mut fields := map[string]json2.Any{}
	if id.len > 0 {
		fields['id'] = json2.Any(id)
	}
	fields['type'] = json2.Any('error')
	fields['error'] = json2.Any(error_fields(err))
	logs := error_logs(err)
	if logs.len > 0 {
		fields['logs'] = logs_any(logs)
	}
	adapter.publish(fields, false)
}

fn (mut adapter Adapter) publish_ack(id string) {
	adapter.publish({
		'id':   json2.Any(id)
		'type': json2.Any('ack')
	}, false)
}

fn subscription_event(subscription_id string, update convex.Update) map[string]json2.Any {
	mut fields := map[string]json2.Any{}
	fields['type'] = json2.Any('subscription')
	fields['subscriptionId'] = json2.Any(subscription_id)
	if update.is_error() {
		mut failure := map[string]json2.Any{}
		failure['name'] = json2.Any(update.error_kind)
		failure['message'] = json2.Any(update.error_message)
		if update.error_data !is json2.Null {
			failure['data'] = update.error_data
		}
		fields['error'] = json2.Any(failure)
	} else {
		fields['value'] = update.value
	}
	if update.logs.len > 0 {
		fields['logs'] = logs_any(update.logs)
	}
	return fields
}

// ---------------------------------------------------------------------------
// Subscription bookkeeping. Registration, invalidation, and the matching
// acknowledgement are one transaction under the publication lock, so a relay
// that already dequeued an old update cannot publish it across that boundary.
// ---------------------------------------------------------------------------

fn (mut adapter Adapter) next_generation(subscription_id string) u64 {
	generation := (adapter.counters[subscription_id] or { u64(0) }) + 1
	adapter.counters[subscription_id] = generation
	return generation
}

// may_publish is the post-dequeue check. It is separated from the pump so the
// deterministic fixtures can prove a paused relay's update is dropped after an
// unsubscribe, a replacement, or a debugDisconnect acknowledgement.
fn (mut adapter Adapter) may_publish(subscription_id string, generation u64, update_generation u64) bool {
	record := adapter.relays[subscription_id] or { return false }
	if !record.active || record.generation != generation {
		return false
	}
	return update_generation >= adapter.minimum_generation
}

fn (mut adapter Adapter) pump_one(subscription_id string) {
	adapter.mutex.@lock()
	record := adapter.relays[subscription_id] or {
		adapter.mutex.unlock()
		return
	}
	generation := record.generation
	mut relay := record.relay
	adapter.mutex.unlock()

	// The dequeue happens outside the publication lock on purpose: that is the
	// window a paused relay would otherwise use to publish a stale value.
	update := relay.next(relay_poll_slice) or { return }

	adapter.mutex.@lock()
	// close takes this same lock before queueing its terminal event. A relay that
	// dequeued just before close therefore cannot append a subscription value
	// after `closed` in the one ordered output stream.
	if adapter.closing {
		adapter.mutex.unlock()
		return
	}
	if adapter.may_publish(subscription_id, generation, update.generation) {
		fields := subscription_event(subscription_id, update)
		adapter.sink.publish(encode_event(fields), true) or {
			diagnostic('adapter could not publish a subscription event: ${err.msg()}')
		}
	}
	adapter.mutex.unlock()
}

pub fn (mut adapter Adapter) pump_loop() {
	for {
		adapter.mutex.@lock()
		stopping := adapter.closing
		keys := adapter.relays.keys()
		adapter.mutex.unlock()
		if stopping {
			return
		}
		for key in keys {
			adapter.pump_one(key)
		}
		if keys.len == 0 {
			time.sleep(relay_poll_slice)
		}
	}
}

fn (mut adapter Adapter) invalidate(subscription_id string) &RelayRecord {
	// Callers hold the publication lock.
	adapter.next_generation(subscription_id)
	mut record := adapter.relays[subscription_id] or { return unsafe { nil } }
	record.active = false
	adapter.relays.delete(subscription_id)
	return record
}

// ---------------------------------------------------------------------------
// Command dispatch.
// ---------------------------------------------------------------------------

pub fn (mut adapter Adapter) handle_line(line string) {
	command := parse_command(line) or {
		adapter.publish_error('', err)
		return
	}
	if !adapter.greeted && command.op != 'hello' {
		adapter.publish_error(command.id, error('hello must be the first adapter command'))
		return
	}
	adapter.dispatch(command) or { adapter.publish_error(command.id, err) }
}

fn (mut adapter Adapter) dispatch(command Command) ! {
	match command.op {
		'hello' {
			if adapter.greeted {
				return error('hello may only be sent once')
			}
			adapter.greeted = true
			adapter.publish({
				'protocolVersion': json2.Any(1)
				'id':              json2.Any(command.id)
				'type':            json2.Any('ready')
				'language':        json2.Any(adapter_language)
				'implementation':  json2.Any(adapter_implementation)
				'runtime':         json2.Any(runtime_version())
			}, false)
		}
		'query', 'mutation', 'action' {
			mut client := adapter.ensure_client()!
			result := match command.op {
				'query' { client.query(command.path, command.args)! }
				'mutation' { client.mutation(command.path, command.args)! }
				else { client.action(command.path, command.args)! }
			}
			mut fields := map[string]json2.Any{}
			fields['id'] = json2.Any(command.id)
			fields['type'] = json2.Any('result')
			fields['value'] = result.value
			if result.logs.len > 0 {
				fields['logs'] = logs_any(result.logs)
			}
			adapter.publish(fields, false)
		}
		'setAuth' {
			mut client := adapter.ensure_client()!
			client.set_auth(command.token)!
			adapter.publish_ack(command.id)
		}
		'subscribe' {
			mut client := adapter.ensure_client()!
			adapter.mutex.@lock()
			mut previous := adapter.invalidate(command.subscription_id)
			adapter.mutex.unlock()
			if previous != unsafe { nil } {
				mut relay := previous.relay
				relay.close()
			}
			relay := client.subscribe(command.subscription_id, command.path, command.args)!
			// Registration and the acknowledgement are published together, so a
			// value that is already hydrated cannot overtake the ack.
			adapter.mutex.@lock()
			generation := adapter.next_generation(command.subscription_id)
			adapter.relays[command.subscription_id] = &RelayRecord{
				relay:      relay
				generation: generation
				active:     true
			}
			adapter.sink.publish(encode_event({
				'id':   json2.Any(command.id)
				'type': json2.Any('ack')
			}), false) or { diagnostic('adapter could not publish an ack: ${err.msg()}') }
			adapter.mutex.unlock()
		}
		'unsubscribe' {
			mut client := adapter.ensure_client()!
			adapter.mutex.@lock()
			mut previous := adapter.invalidate(command.subscription_id)
			adapter.mutex.unlock()
			if previous != unsafe { nil } {
				mut relay := previous.relay
				relay.close()
			}
			client.unsubscribe(command.subscription_id)!
			adapter.publish_ack(command.id)
		}
		'debugDisconnect' {
			mut client := adapter.ensure_client()!
			generation := client.debug_disconnect_for_adapter()!
			// Hold the publication lock across the new minimum generation and
			// the acknowledgement. A relay that dequeued an older update can
			// only resume afterwards, at which point it drops it.
			adapter.mutex.@lock()
			adapter.minimum_generation = generation
			adapter.sink.publish(encode_event({
				'id':   json2.Any(command.id)
				'type': json2.Any('ack')
			}), false) or { diagnostic('adapter could not publish an ack: ${err.msg()}') }
			adapter.mutex.unlock()
		}
		'close' {
			// The terminal event is ordered behind every earlier event, and no
			// later relay event may cross it. Hold the publication lock while it is
			// queued so the pump's post-dequeue check observes `closing` first.
			adapter.mutex.@lock()
			adapter.closing = true
			adapter.sink.publish(encode_event({
				'id':   json2.Any(command.id)
				'type': json2.Any('closed')
			}), false) or { diagnostic('adapter could not publish close: ${err.msg()}') }
			adapter.finished = true
			adapter.mutex.unlock()
		}
		else {
			return error('unknown adapter operation: ${command.op}')
		}
	}
}

pub fn (mut adapter Adapter) is_finished() bool {
	adapter.mutex.@lock()
	defer {
		adapter.mutex.unlock()
	}
	return adapter.finished
}

// cleanup retires every subscription and the one client in a bounded way, then
// lets the terminal writer drain what is already queued.
pub fn (mut adapter Adapter) cleanup() {
	adapter.mutex.@lock()
	adapter.closing = true
	mut records := []&RelayRecord{}
	for key in adapter.relays.keys() {
		if record := adapter.relays[key] {
			records << record
		}
	}
	adapter.relays = map[string]&RelayRecord{}
	adapter.mutex.unlock()
	for record in records {
		mut entry := record
		entry.active = false
		mut relay := entry.relay
		relay.close()
	}
	if adapter.client != unsafe { nil } {
		mut client := adapter.client
		client.close()
	}
}

// ---------------------------------------------------------------------------
// Transports.
// ---------------------------------------------------------------------------

// TcpLines is the bounded NDJSON reader for ADAPTER_LISTEN mode. An over-long
// line is reported and discarded up to its terminator instead of being
// buffered, so a broken controller cannot grow the adapter's memory.
struct TcpLines {
mut:
	conn       &net.TcpConn = unsafe { nil }
	pending    []u8
	position   int
	eof        bool
	discarding bool
	overlong   bool
}

// discard_buffered_line consumes an already-buffered over-long line without
// throwing away the first byte of the next command. The old implementation
// cleared an entire chunk once it crossed the limit, which could accidentally
// discard a newline and the command after it.
fn (mut lines TcpLines) discard_buffered_line() bool {
	mut index := lines.position
	for index < lines.pending.len {
		if lines.pending[index] == `\n` {
			lines.pending = lines.pending[index + 1..].clone()
			lines.position = 0
			lines.discarding = false
			return true
		}
		index++
	}
	lines.pending = []u8{}
	lines.position = 0
	return false
}

fn (mut lines TcpLines) fill() bool {
	mut chunk := []u8{len: 16 * 1024}
	count := lines.conn.read(mut chunk) or {
		lines.eof = true
		return false
	}
	if count <= 0 {
		lines.eof = true
		return false
	}
	if lines.position > 0 {
		lines.pending = lines.pending[lines.position..].clone()
		lines.position = 0
	}
	lines.pending << chunk[..count]
	return true
}

fn (mut lines TcpLines) next() ?string {
	for {
		if lines.discarding {
			if lines.discard_buffered_line() {
				lines.overlong = true
				return ''
			}
			if lines.eof {
				lines.discarding = false
				lines.overlong = true
				return ''
			}
			lines.fill()
			continue
		}
		mut index := lines.position
		for index < lines.pending.len {
			if lines.pending[index] == `\n` {
				mut end := index
				if end > lines.position && lines.pending[end - 1] == `\r` {
					end--
				}
				text := lines.pending[lines.position..end].bytestr()
				lines.position = index + 1
				if lines.discarding {
					lines.discarding = false
					lines.overlong = true
					return ''
				}
				return text
			}
			index++
		}
		if lines.pending.len - lines.position > max_adapter_line_bytes {
			lines.discarding = true
			continue
		}
		if lines.eof {
			if lines.discarding {
				lines.discarding = false
				lines.overlong = true
				return ''
			}
			return none
		}
		if !lines.fill() {
			if lines.pending.len - lines.position > 0 {
				text := lines.pending[lines.position..].bytestr()
				lines.position = lines.pending.len
				return text
			}
			return none
		}
	}
	// Every branch of the loop above returns; see the matching comment on
	// `Live.submit` in live.v.
	panic('unreachable: TcpLines.next loop exited without returning')
}

fn parse_listen_address(text string) !(string, int) {
	colon := text.last_index_u8(`:`)
	if colon < 1 || colon == text.len - 1 {
		return error('ADAPTER_LISTEN must be host:port')
	}
	host := text[..colon]
	mut port := 0
	for character in text[colon + 1..] {
		if character < `0` || character > `9` {
			return error('ADAPTER_LISTEN port must be numeric')
		}
		port = port * 10 + int(character - `0`)
	}
	if port < 1 || port > 65535 {
		return error('ADAPTER_LISTEN port is out of range')
	}
	return host, port
}

fn run_stdio() int {
	mut sink := new_output_sink(stdout_target())
	spawn sink.writer_loop()
	mut adapter := new_adapter(sink)
	spawn adapter.pump_loop()
	for {
		raw := os.get_raw_line()
		if raw.len == 0 {
			break
		}
		line := raw.trim_right('\r\n')
		if line.len > max_adapter_line_bytes {
			adapter.publish_error('', error('adapter command exceeds ${max_adapter_line_bytes} bytes'))
			continue
		}
		if line.len == 0 {
			adapter.publish_error('', error('adapter command line must not be empty'))
			continue
		}
		adapter.handle_line(line)
		if adapter.is_finished() {
			break
		}
	}
	adapter.cleanup()
	sink.close(true)
	return 0
}

fn run_tcp(address string) int {
	host, port := parse_listen_address(address) or {
		diagnostic('adapter could not use ADAPTER_LISTEN: ${err.msg()}')
		return 2
	}
	mut listener := net.listen_tcp(.ip, '${host}:${port}') or {
		diagnostic('adapter could not listen on ${address}: ${err.msg()}')
		return 2
	}
	diagnostic('adapter listening on ${address}')
	mut conn := listener.accept() or {
		diagnostic('adapter could not accept a controller: ${err.msg()}')
		listener.close() or {}
		return 2
	}
	// Exactly one controller connection carries the stream.
	listener.close() or {}
	conn.set_read_timeout(adapter_read_budget)
	conn.set_write_timeout(client_close_budget)

	mut sink := new_output_sink(tcp_target(conn))
	spawn sink.writer_loop()
	mut adapter := new_adapter(sink)
	spawn adapter.pump_loop()
	mut lines := TcpLines{
		conn: conn
	}
	for {
		line := lines.next() or { break }
		if lines.overlong {
			lines.overlong = false
			adapter.publish_error('', error('adapter command exceeds ${max_adapter_line_bytes} bytes'))
			continue
		}
		if line.len == 0 {
			adapter.publish_error('', error('adapter command line must not be empty'))
			continue
		}
		adapter.handle_line(line)
		if adapter.is_finished() {
			break
		}
	}
	adapter.cleanup()
	sink.close(true)
	return 0
}

// run_adapter is the conformance executable's whole behaviour.
pub fn run_adapter() {
	listen := os.getenv('ADAPTER_LISTEN')
	status := if listen.len == 0 { run_stdio() } else { run_tcp(listen) }
	exit(status)
}
