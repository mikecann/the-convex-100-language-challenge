module convex

import sync
import time
import x.json2

// The Convex sync profile pinned in manifest.yaml is implemented here in V.
// One worker owns the socket outright: it is the only code that connects,
// reads, writes, changes the query-set version, and retires a connection.
// Public callers and the conformance adapter reach it through a command
// channel, so no second thread can interleave a write with a partially written
// frame or resend an Add against a version the owner has already moved.
pub const sync_endpoint_path = '/api/sync'

// Delivery is bounded twice. Each subscription reserves a count slot and an
// encoded byte charge, and the whole manager reserves a process-wide count and
// byte budget on top. A count-only bound is not a memory bound when a single
// pinned Live message may approach 1 MiB.
pub const max_live_subscriptions = 64
pub const max_relay_updates = 16
pub const max_relay_bytes = 4 * 1024 * 1024
pub const max_live_queue_updates = 16
pub const max_live_queue_bytes = 8 * 1024 * 1024
pub const live_update_overhead_bytes = 512

const live_initial_backoff = 25 * time.millisecond
const live_maximum_backoff = 2 * time.second
const live_command_budget = 8 * time.second
const live_idle_slice = 2 * time.millisecond

// Update is one published Live delivery. A failed query is delivered as an
// error rather than as a missing value so a subscriber can never mistake a
// rejection for an empty result.
pub struct Update {
pub mut:
	value         json2.Any = json2.Any(json2.null)
	logs          []string
	error_kind    string
	error_message string
	error_data    json2.Any = json2.Any(json2.null)
	generation    u64
	charge        int
}

pub fn (update Update) is_error() bool {
	return update.error_kind.len > 0
}

// LiveBudget is the process-wide reservation shared by every subscription.
// See the comment on `LiveStats` above for why this needs `@[heap]` too.
@[heap]
struct LiveBudget {
mut:
	mutex &sync.Mutex = unsafe { nil }
	items int
	bytes int
}

fn new_live_budget() &LiveBudget {
	return &LiveBudget{
		mutex: sync.new_mutex()
	}
}

fn (mut budget LiveBudget) reserve(charge int) bool {
	budget.mutex.@lock()
	defer {
		budget.mutex.unlock()
	}
	if budget.items + 1 > max_live_queue_updates || budget.bytes + charge > max_live_queue_bytes {
		return false
	}
	budget.items++
	budget.bytes += charge
	return true
}

fn (mut budget LiveBudget) release(charge int) {
	budget.mutex.@lock()
	defer {
		budget.mutex.unlock()
	}
	if budget.items > 0 {
		budget.items--
	}
	budget.bytes -= charge
	if budget.bytes < 0 {
		budget.bytes = 0
	}
}

fn (mut budget LiveBudget) reserved() (int, int) {
	budget.mutex.@lock()
	defer {
		budget.mutex.unlock()
	}
	return budget.items, budget.bytes
}

// Relay is the handoff between the one owner worker and one consumer. It fails
// a stopped consumer instead of growing, because the alternative is letting a
// stalled reader convert a bounded stream into unbounded memory.
pub struct Relay {
mut:
	mutex      &sync.Mutex = unsafe { nil }
	budget     &LiveBudget = unsafe { nil }
	items      []Update
	bytes      int
	closed     bool
	overflowed bool
	generation u64
}

fn new_relay(budget &LiveBudget, generation u64) &Relay {
	return &Relay{
		mutex:      sync.new_mutex()
		budget:     budget
		generation: generation
	}
}

fn charge_for(update Update) int {
	mut size := live_update_overhead_bytes
	// The queue retains decoded json2 maps/arrays, not just their wire bytes.
	// Charge both a conservative multiple of the encoding and every structural
	// node so an 8192-node value cannot masquerade as a tiny memory footprint.
	size += encode_json(update.value).len * 2
	size += json_runtime_nodes(update.value) * 128
	size += update.error_message.len
	size += encode_json(update.error_data).len * 2
	size += json_runtime_nodes(update.error_data) * 128
	for line in update.logs {
		size += line.len + 8
	}
	return size
}

fn json_runtime_nodes(value json2.Any) int {
	if value is []json2.Any {
		mut count := 1
		for entry in value {
			count += json_runtime_nodes(entry)
		}
		return count
	}
	if value is map[string]json2.Any {
		mut count := 1
		for _, entry in value {
			count += json_runtime_nodes(entry)
		}
		return count
	}
	return 1
}

fn (mut relay Relay) push(update Update) ! {
	charge := charge_for(update)
	stamped := Update{
		value:         update.value
		logs:          update.logs
		error_kind:    update.error_kind
		error_message: update.error_message
		error_data:    update.error_data
		generation:    update.generation
		charge:        charge
	}
	relay.mutex.@lock()
	if relay.closed {
		relay.mutex.unlock()
		return closed_error('live', 'subscription is closed')
	}
	if relay.items.len + 1 > max_relay_updates || relay.bytes + charge > max_relay_bytes {
		relay.overflowed = true
		relay.closed = true
		relay.mutex.unlock()
		relay.drain()
		return transport_error('live', 'subscription consumer is too slow')
	}
	relay.mutex.unlock()
	if !relay.budget.reserve(charge) {
		relay.mutex.@lock()
		relay.overflowed = true
		relay.closed = true
		relay.mutex.unlock()
		relay.drain()
		return transport_error('live', 'Live delivery budget is exhausted')
	}
	relay.mutex.@lock()
	// close() can race the process-wide reservation. Re-check while holding
	// the relay lock before attaching the charged item, otherwise a closed
	// subscription can retain an unreachable update and leak its reservation.
	if relay.closed {
		relay.mutex.unlock()
		relay.budget.release(charge)
		return closed_error('live', 'subscription is closed')
	}
	if relay.items.len + 1 > max_relay_updates || relay.bytes + charge > max_relay_bytes {
		relay.overflowed = true
		relay.closed = true
		relay.mutex.unlock()
		relay.budget.release(charge)
		relay.drain()
		return transport_error('live', 'subscription consumer is too slow')
	}
	relay.items << stamped
	relay.bytes += charge
	relay.mutex.unlock()
}

fn (mut relay Relay) take() ?Update {
	relay.mutex.@lock()
	if relay.items.len == 0 {
		relay.mutex.unlock()
		return none
	}
	update := relay.items[0]
	relay.items.delete(0)
	relay.bytes -= update.charge
	if relay.bytes < 0 {
		relay.bytes = 0
	}
	relay.mutex.unlock()
	relay.budget.release(update.charge)
	return update
}

// next waits up to `budget` for one delivery. Polling keeps the consumer and
// the owner from sharing anything but the mutex, which is what makes the
// deterministic slow-consumer test reproducible.
pub fn (mut relay Relay) next(budget time.Duration) !Update {
	deadline := deadline_in(budget)
	for {
		if update := relay.take() {
			return update
		}
		relay.mutex.@lock()
		closed := relay.closed
		overflowed := relay.overflowed
		relay.mutex.unlock()
		if overflowed {
			return transport_error('live', 'subscription consumer is too slow')
		}
		if closed {
			return closed_error('live', 'subscription is closed')
		}
		if deadline.expired() {
			return transport_error('live', 'no Live update arrived before the deadline')
		}
		time.sleep(live_idle_slice)
	}
	// See the matching comment in `submit` above.
	panic('unreachable: next loop exited without returning')
}

fn (mut relay Relay) drain() {
	relay.mutex.@lock()
	mut released := []int{}
	for update in relay.items {
		released << update.charge
	}
	relay.items = []Update{}
	relay.bytes = 0
	relay.mutex.unlock()
	for charge in released {
		relay.budget.release(charge)
	}
}

// close invalidates the relay before any acknowledgement that depends on it is
// published, so a consumer that has already dequeued an old update cannot
// publish it across the boundary.
pub fn (mut relay Relay) close() {
	relay.mutex.@lock()
	relay.closed = true
	relay.mutex.unlock()
	relay.drain()
}

pub fn (mut relay Relay) is_closed() bool {
	relay.mutex.@lock()
	defer {
		relay.mutex.unlock()
	}
	return relay.closed
}

pub fn (mut relay Relay) generation_now() u64 {
	relay.mutex.@lock()
	defer {
		relay.mutex.unlock()
	}
	return relay.generation
}

// LiveStats carries the reconnect evidence the shared harness inspects. It is
// the only owner state readable from another thread, and it is mutex-guarded.
// Every instance is created through `new_live_stats`, which already returns
// a heap pointer, but the compiler cannot prove that from a `&LiveStats`
// parameter alone; `@[heap]` makes that guarantee part of the type instead.
@[heap]
struct LiveStats {
mut:
	mutex                  &sync.Mutex = unsafe { nil }
	connection_count       int
	last_close_reason      string
	max_observed_timestamp u64
	generation             u64
}

fn new_live_stats() &LiveStats {
	return &LiveStats{
		mutex:             sync.new_mutex()
		last_close_reason: 'InitialConnect'
	}
}

fn (mut stats LiveStats) connection_metadata() int {
	stats.mutex.@lock()
	defer {
		stats.mutex.unlock()
	}
	return stats.connection_count
}

fn (mut stats LiveStats) note_connected() {
	stats.mutex.@lock()
	stats.connection_count++
	stats.mutex.unlock()
}

fn (mut stats LiveStats) note_retired(reason string) u64 {
	stats.mutex.@lock()
	defer {
		stats.mutex.unlock()
	}
	stats.last_close_reason = reason
	stats.generation++
	return stats.generation
}

fn (mut stats LiveStats) note_timestamp(value u64) {
	stats.mutex.@lock()
	defer {
		stats.mutex.unlock()
	}
	if value > stats.max_observed_timestamp {
		stats.max_observed_timestamp = value
	}
}

fn (mut stats LiveStats) snapshot() (int, string, u64, u64) {
	stats.mutex.@lock()
	defer {
		stats.mutex.unlock()
	}
	return stats.connection_count, stats.last_close_reason, stats.max_observed_timestamp, stats.generation
}

struct ActiveQuery {
	query_id u32
	key      string
	path     string
	args     map[string]json2.Any
mut:
	relay        &Relay = unsafe { nil }
	last_encoded string
	has_last     bool
	rehydrating  bool
}

enum OwnerOp {
	subscribe
	unsubscribe
	disconnect
	close
}

struct OwnerRequest {
	op    OwnerOp
	key   string
	path  string
	args  map[string]json2.Any
	reply chan OwnerReply = chan OwnerReply{cap: 1}
}

struct OwnerReply {
	ok         bool
	relay      &Relay = unsafe { nil }
	generation u64
	failure    ConvexError
}

// LiveOwner holds the state only the worker touches. Nothing outside the worker
// may read or write these fields; that restriction is the whole point of the
// command channel.
struct LiveOwner {
mut:
	endpoint          Endpoint
	client_version    string
	session_id        string
	budget            &LiveBudget = unsafe { nil }
	stats             &LiveStats  = unsafe { nil }
	socket            &LiveSocket = unsafe { nil }
	queries           map[u32]&ActiveQuery
	keys              map[string]u32
	next_query_id     u32 = 1
	query_set_version u32
	remote_version    Version
	backoff           time.Duration
	next_connect_at   u64
	connected         bool
	stopping          bool
}

// Live is the handle callers hold. It owns no socket state at all.
pub struct Live {
pub:
	sync_url string
mut:
	commands chan OwnerRequest
	budget   &LiveBudget = unsafe { nil }
	stats    &LiveStats  = unsafe { nil }
	closed   bool
}

// new_live starts the one owner worker for a deployment. The owner struct is
// deliberately constructed inside the worker thread, so no other thread ever
// holds a reference to the socket state at all.
pub fn new_live(endpoint Endpoint, client_version string) !&Live {
	budget := new_live_budget()
	stats := new_live_stats()
	commands := chan OwnerRequest{cap: 32}
	session_id := new_session_id()!
	spawn live_worker(endpoint, client_version, session_id, commands, budget, stats)
	return &Live{
		sync_url: endpoint.sync_url()
		commands: commands
		budget:   budget
		stats:    stats
	}
}

// new_session_id reads the kernel entropy source directly. The pinned profile
// wants a per-connection-family session identifier, and a seeded PRNG would
// hand two containers started in the same millisecond the same identity.
fn new_session_id() !string {
	mut bytes := random_bytes(16)!
	// Convex expects the session identifier to be a UUID. Set the RFC 4122
	// version and variant bits explicitly instead of sending an ungrouped hex
	// string, and never fall back to a shared all-zero identity.
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	hex := bytes.hex()
	return '${hex[..8]}-${hex[8..12]}-${hex[12..16]}-${hex[16..20]}-${hex[20..]}'
}

fn (mut live Live) submit(request OwnerRequest) !OwnerReply {
	if live.closed {
		return closed_error('live', 'Live client is closed')
	}
	deadline := deadline_in(live_command_budget)
	for {
		if live.commands.try_push(request) == .success {
			break
		}
		if deadline.expired() {
			return transport_error('live', 'Live worker command queue is full')
		}
		time.sleep(live_idle_slice)
	}
	for {
		mut reply := OwnerReply{}
		if request.reply.try_pop(mut reply) == .success {
			if !reply.ok {
				return reply.failure
			}
			return reply
		}
		if deadline.expired() {
			return transport_error('live', 'Live worker did not answer before the deadline')
		}
		time.sleep(live_idle_slice)
	}
	// Every branch of the loop above returns; this is unreachable, but V's
	// exhaustiveness check does not infer that a bare `for {}` never falls
	// through on its own.
	panic('unreachable: submit loop exited without returning')
}

// subscribe registers or replaces a subscription. The reply is only produced
// after the owner has invalidated any previous relay for the same key, so a
// stale update cannot cross the acknowledgement.
pub fn (mut live Live) subscribe(key string, path string, args map[string]json2.Any) !&Relay {
	if !is_bounded_identifier(key) {
		return protocol_error('live', 'subscription id must be 1 to ${max_identifier_scalars} Unicode scalars')
	}
	validate_function_path(path, 'live')!
	reply := live.submit(OwnerRequest{
		op:    .subscribe
		key:   key
		path:  path
		args:  args
		reply: chan OwnerReply{cap: 1}
	})!
	return reply.relay
}

pub fn (mut live Live) unsubscribe(key string) ! {
	live.submit(OwnerRequest{
		op:    .unsubscribe
		key:   key
		reply: chan OwnerReply{cap: 1}
	})!
}

// debug_disconnect exists only for the shared conformance adapter. It is not
// part of the educational client API and manifest.yaml declares it under
// adapter.adapterOnlyCommands. The reply carries the new generation, and it is
// produced only after the old connection has been retired and reconnect work
// scheduled.
pub fn (mut live Live) debug_disconnect() !u64 {
	reply := live.submit(OwnerRequest{
		op:    .disconnect
		reply: chan OwnerReply{cap: 1}
	})!
	return reply.generation
}

pub fn (mut live Live) close() {
	if live.closed {
		return
	}
	live.submit(OwnerRequest{
		op:    .close
		reply: chan OwnerReply{cap: 1}
	}) or {}
	live.closed = true
}

pub fn (mut live Live) connection_count() int {
	count, _, _, _ := live.stats.snapshot()
	return count
}

pub fn (mut live Live) last_close_reason() string {
	_, reason, _, _ := live.stats.snapshot()
	return reason
}

pub fn (mut live Live) max_observed_timestamp() u64 {
	_, _, timestamp, _ := live.stats.snapshot()
	return timestamp
}

pub fn (mut live Live) generation() u64 {
	_, _, _, generation := live.stats.snapshot()
	return generation
}

fn live_worker(endpoint Endpoint, client_version string, session_id string, commands chan OwnerRequest, budget &LiveBudget, stats &LiveStats) {
	mut owner := LiveOwner{
		endpoint:       endpoint
		client_version: client_version
		session_id:     session_id
		budget:         budget
		stats:          stats
		remote_version: zero_version()
		backoff:        live_initial_backoff
	}
	for !owner.stopping {
		owner.service_commands(commands)
		if owner.stopping {
			break
		}
		owner.maintain_connection()
		owner.pump()
	}
	owner.shutdown()
}

fn (mut owner LiveOwner) service_commands(commands chan OwnerRequest) {
	mut request := OwnerRequest{}
	for _ in 0 .. 16 {
		if commands.try_pop(mut request) != .success {
			return
		}
		owner.handle(request)
		if owner.stopping {
			return
		}
	}
}

fn (mut owner LiveOwner) handle(request OwnerRequest) {
	match request.op {
		.subscribe {
			relay := owner.add_query(request.key, request.path, request.args) or {
				owner.answer_failure(request, err)
				return
			}
			request.reply.try_push(OwnerReply{
				ok:         true
				relay:      relay
				generation: owner.current_generation()
			})
		}
		.unsubscribe {
			owner.remove_query(request.key) or {
				owner.answer_failure(request, err)
				return
			}
			request.reply.try_push(OwnerReply{
				ok:         true
				generation: owner.current_generation()
			})
		}
		.disconnect {
			// Retire first, then schedule the reconnect, and only then answer.
			// The acknowledgement therefore proves the old connection is gone.
			generation := owner.retire('adapter debugDisconnect', false)
			owner.next_connect_at = time.sys_mono_now()
			request.reply.try_push(OwnerReply{
				ok:         true
				generation: generation
			})
		}
		.close {
			owner.stopping = true
			request.reply.try_push(OwnerReply{
				ok: true
			})
		}
	}
}

fn (mut owner LiveOwner) answer_failure(request OwnerRequest, err IError) {
	request.reply.try_push(OwnerReply{
		ok:      false
		failure: wrap_error(err, kind_protocol_error, 'live', 'Live command failed')
	})
}

fn (mut owner LiveOwner) current_generation() u64 {
	_, _, _, generation := owner.stats.snapshot()
	return generation
}

fn (mut owner LiveOwner) add_query(key string, path string, args map[string]json2.Any) !&Relay {
	// Replacement invalidates the previous relay first. Nothing dequeued from
	// the old relay can be published after this point.
	if key in owner.keys {
		owner.remove_query(key)!
	}
	if owner.queries.len >= max_live_subscriptions {
		return protocol_error('live', 'more than ${max_live_subscriptions} Live subscriptions')
	}
	if owner.next_query_id == 4294967295 {
		return protocol_error('live', 'Live query identifiers are exhausted')
	}
	query_id := owner.next_query_id
	owner.next_query_id++
	relay := new_relay(owner.budget, owner.current_generation())
	mut query := &ActiveQuery{
		query_id:    query_id
		key:         key
		path:        path
		args:        args.clone()
		relay:       relay
		rehydrating: false
	}
	owner.queries[query_id] = query
	owner.keys[key] = query_id
	if owner.connected {
		owner.send_modification('Add', query) or { owner.retire('AddFailed: ${err.msg()}', true) }
	}
	return relay
}

fn (mut owner LiveOwner) remove_query(key string) ! {
	query_id := owner.keys[key] or { return }
	mut query := owner.queries[query_id] or { return }
	owner.keys.delete(key)
	owner.queries.delete(query_id)
	query.relay.close()
	if owner.connected {
		owner.send_modification('Remove', query) or {
			owner.retire('RemoveFailed: ${err.msg()}', true)
		}
	}
}

fn (mut owner LiveOwner) maintain_connection() {
	if owner.connected || owner.stopping {
		return
	}
	if time.sys_mono_now() < owner.next_connect_at {
		time.sleep(live_idle_slice)
		return
	}
	owner.connect()
}

fn (mut owner LiveOwner) connect() {
	deadline := deadline_in(live_connect_budget)
	socket := connect_live_socket(owner.endpoint.sync_url(), owner.client_version, deadline) or {
		owner.schedule_reconnect('ConnectFailed: ${err.msg()}')
		return
	}
	owner.socket = socket
	owner.connected = true
	// A completed handshake is a healthy connection, so the next failure starts
	// from the initial delay again instead of inheriting an old maximum.
	owner.backoff = live_initial_backoff
	owner.remote_version = zero_version()
	owner.query_set_version = 0
	_, reason, timestamp, _ := owner.stats.snapshot()
	// connectionCount is the number of earlier successful connections. The
	// initial Connect therefore carries zero, matching the pinned sync client.
	count := owner.stats.connection_metadata()
	owner.send_connect(count, reason, timestamp) or {
		owner.retire('ConnectMessageFailed: ${err.msg()}', true)
		return
	}
	owner.stats.note_connected()
	// Every connection resends the full active query set. A reconnect that
	// forgot one Add would leave that subscription silently dead.
	mut replay := []&ActiveQuery{}
	mut query_ids := owner.queries.keys()
	query_ids.sort()
	for query_id in query_ids {
		mut active := owner.queries[query_id] or { continue }
		active.rehydrating = true
		replay << active
	}
	if replay.len > 0 {
		owner.send_modify_set(0, 1, replay, 'Add') or {
			owner.retire('ReplayFailed: ${err.msg()}', true)
			return
		}
		owner.query_set_version = 1
	}
}

fn (mut owner LiveOwner) send_connect(connection_count int, close_reason string, timestamp u64) ! {
	message := connect_message(owner.session_id, connection_count, close_reason, timestamp)
	owner.socket.write_text(encode_json(json2.Any(message)))!
}

// connect_message is kept pure so the reconnect metadata can be reviewed and
// fixture-tested without a socket. In particular, maxObservedTimestamp is
// carried as the profile's canonical little-endian/base64 timestamp, not as a
// decimal number that another client would interpret differently.
fn connect_message(session_id string, connection_count int, close_reason string, timestamp u64) map[string]json2.Any {
	mut message := map[string]json2.Any{}
	message['type'] = json2.Any('Connect')
	message['sessionId'] = json2.Any(session_id)
	message['connectionCount'] = json2.Any(i64(connection_count))
	message['lastCloseReason'] = json2.Any(close_reason)
	message['clientTs'] = json2.Any(i64(0))
	if timestamp > 0 {
		message['maxObservedTimestamp'] = json2.Any(encode_timestamp(timestamp))
	}
	return message
}

fn modification_for(kind string, query &ActiveQuery) json2.Any {
	mut modification := map[string]json2.Any{}
	modification['type'] = json2.Any(kind)
	modification['queryId'] = json2.Any(i64(query.query_id))
	if kind == 'Add' {
		modification['udfPath'] = json2.Any(query.path)
		modification['args'] = json2.Any([json2.Any(query.args.clone())])
	}
	return json2.Any(modification)
}

fn (mut owner LiveOwner) send_modify_set(base u32, next u32, queries []&ActiveQuery, kind string) ! {
	mut modifications := []json2.Any{cap: queries.len}
	for query in queries {
		modifications << modification_for(kind, query)
	}
	mut message := map[string]json2.Any{}
	message['type'] = json2.Any('ModifyQuerySet')
	message['baseVersion'] = json2.Any(i64(base))
	message['newVersion'] = json2.Any(i64(next))
	message['modifications'] = json2.Any(modifications)
	owner.socket.write_text(encode_json(json2.Any(message)))!
}

fn (mut owner LiveOwner) send_modification(kind string, query &ActiveQuery) ! {
	if owner.query_set_version == 4294967295 {
		return protocol_error('live', 'Live query-set version is exhausted')
	}
	base := owner.query_set_version
	owner.send_modify_set(base, base + 1, [query], kind)!
	owner.query_set_version = base + 1
}

fn (mut owner LiveOwner) pump() {
	if !owner.connected {
		return
	}
	if !owner.socket.wait_readable(live_read_slice) {
		return
	}
	frame := owner.socket.read_frame() or {
		owner.retire('ReadFailed: ${err.msg()}', true)
		return
	}
	if frame.kind == frame_peer_closed {
		owner.retire('ServerClosed', true)
		return
	}
	if frame.kind != frame_text {
		return
	}
	owner.apply_message(frame.text) or { owner.retire('ProtocolFailed: ${err.msg()}', true) }
}

// apply_message is the pinned profile's server-message handler. It is written
// as a pure function of owner state and message text so the deterministic
// fixtures can drive it without a socket.
fn (mut owner LiveOwner) apply_message(text string) ! {
	if text.len > max_live_message_bytes {
		return protocol_error('live', 'Live message exceeds ${max_live_message_bytes} bytes')
	}
	event := decode_json_object(text, 'live')!
	kind := string_field(event, 'type') or {
		return protocol_error('live', 'Live message is missing a string type')
	}
	match kind {
		'Transition' {
			return owner.apply_transition(event)
		}
		'Ping', 'MutationResponse', 'ActionResponse' {
			return
		}
		'FatalError' {
			message := string_field(event, 'error') or { 'server reported a fatal error' }
			return protocol_error('live', 'Live server sent FatalError: ${message}')
		}
		'AuthError' {
			message := string_field(event, 'error') or { 'server rejected the identity' }
			return protocol_error('live', 'Live server sent AuthError: ${message}')
		}
		else {
			return protocol_error('live', 'unsupported pinned Live server message: ${kind}')
		}
	}
}

struct PendingDelivery {
	query_id u32
	deliver  bool
	update   Update
}

// apply_transition validates the whole transition before publishing anything.
// A transition that fails halfway must not leave half of its modifications
// visible, and it must not advance the version it was not applied against.
fn (mut owner LiveOwner) apply_transition(event map[string]json2.Any) ! {
	start := parse_version(event, 'startVersion')!
	end := parse_version(event, 'endVersion')!
	if !start.equals(owner.remote_version) {
		return protocol_error('live', 'Transition startVersion does not match local state')
	}
	start_timestamp := decode_timestamp(start.ts)!
	end_timestamp := decode_timestamp(end.ts)!
	if end_timestamp < start_timestamp {
		return protocol_error('live', 'Transition timestamp moved backwards')
	}
	modifications := array_field(event, 'modifications') or {
		return protocol_error('live', 'Transition modifications must be an array')
	}
	if modifications.len > max_live_subscriptions * 4 {
		return protocol_error('live', 'Transition carries an implausible number of modifications')
	}

	// Coalesce first so a transition that mentions one query twice publishes
	// only its final state.
	mut ordered := []u32{}
	mut pending := map[u32]PendingDelivery{}
	for entry in modifications {
		delivery := owner.parse_modification(entry)!
		if delivery.query_id !in pending {
			ordered << delivery.query_id
		}
		pending[delivery.query_id] = delivery
	}

	owner.remote_version = end
	owner.stats.note_timestamp(end_timestamp)
	// A valid server transition proves the connection is healthy, so transport
	// backoff restarts from its initial delay.
	owner.backoff = live_initial_backoff

	generation := owner.current_generation()
	for query_id in ordered {
		delivery := pending[query_id] or { continue }
		if !delivery.deliver {
			continue
		}
		mut query := owner.queries[query_id] or { continue }
		encoded := encode_json(delivery.update.value)
		// Suppress an unchanged rehydration so a reconnect does not republish a
		// value the subscriber has already seen.
		suppressed := query.rehydrating && query.has_last && !delivery.update.is_error()
			&& query.last_encoded == encoded
		query.rehydrating = false
		if !delivery.update.is_error() {
			query.last_encoded = encoded
			query.has_last = true
		}
		if suppressed {
			continue
		}
		mut relay := query.relay
		// A reactive query is current state, not an event log: if the consumer
		// has not caught up to the previous delivery yet, that delivery is
		// superseded, not queued behind. This is what lets a rehydration
		// snapshot and the real update that follows moments later - two
		// separate transitions, so `parse_modification`'s own coalescing does
		// not see them together - collapse to the one value a caller polling
		// `relay.next()` once actually observes.
		relay.drain()
		relay.push(Update{
			value:         delivery.update.value
			logs:          delivery.update.logs
			error_kind:    delivery.update.error_kind
			error_message: delivery.update.error_message
			error_data:    delivery.update.error_data
			generation:    generation
		}) or {
			// A stopped consumer closes its own subscription; it must not stall
			// the owner or any other subscription.
			continue
		}
	}
}

fn (mut owner LiveOwner) parse_modification(entry json2.Any) !PendingDelivery {
	if entry !is map[string]json2.Any {
		return protocol_error('live', 'Live modification must be an object')
	}
	change := entry as map[string]json2.Any
	kind := string_field(change, 'type') or {
		return protocol_error('live', 'Live modification type must be a string')
	}
	query_id := uint32_field(change, 'queryId') or {
		return protocol_error('live', 'Live modification queryId must be a uint32')
	}
	match kind {
		'QueryUpdated' {
			value := change['value'] or {
				return protocol_error('live', 'QueryUpdated is missing value')
			}
			return PendingDelivery{
				query_id: query_id
				deliver:  true
				update:   Update{
					value: value
					logs:  log_lines(change, 'live')!
				}
			}
		}
		'QueryFailed' {
			message := string_field(change, 'errorMessage') or {
				return protocol_error('live', 'QueryFailed errorMessage must be a string')
			}
			return PendingDelivery{
				query_id: query_id
				deliver:  true
				update:   Update{
					logs:          log_lines(change, 'live')!
					error_kind:    kind_function_error
					error_message: message
					error_data:    change['errorData'] or { json2.Any(json2.null) }
				}
			}
		}
		'QueryRemoved' {
			return PendingDelivery{
				query_id: query_id
				deliver:  false
			}
		}
		else {
			return protocol_error('live', 'unsupported Live modification: ${kind}')
		}
	}
}

// retire drops the current connection and bumps the generation. Publishing the
// failure is optional because an adapter-requested disconnect is not an error
// the subscriber should see, while an unexpected transport or protocol fault
// is.
fn (mut owner LiveOwner) retire(reason string, publish bool) u64 {
	if owner.socket != unsafe { nil } {
		owner.socket.abandon()
		owner.socket = unsafe { nil }
	}
	owner.connected = false
	owner.remote_version = zero_version()
	owner.query_set_version = 0
	generation := owner.stats.note_retired(reason)
	for query_id in owner.queries.keys() {
		mut active := owner.queries[query_id] or { continue }
		active.rehydrating = true
		if publish {
			mut relay := active.relay
			// A failure is delivered, not fatal: the subscription stays
			// registered and is replayed on the next connection.
			relay.push(Update{
				error_kind:    kind_transport_error
				error_message: reason
				generation:    generation
			}) or {}
		}
	}
	owner.schedule_backoff()
	return generation
}

fn (mut owner LiveOwner) schedule_reconnect(reason string) {
	owner.stats.note_retired(reason)
	owner.connected = false
	owner.schedule_backoff()
}

fn (mut owner LiveOwner) schedule_backoff() {
	owner.next_connect_at = time.sys_mono_now() + u64(owner.backoff)
	mut next := time.Duration(i64(owner.backoff) * 2)
	if next > live_maximum_backoff {
		next = live_maximum_backoff
	}
	owner.backoff = next
}

fn (mut owner LiveOwner) shutdown() {
	for query_id in owner.queries.keys() {
		mut active := owner.queries[query_id] or { continue }
		mut relay := active.relay
		relay.close()
	}
	owner.queries = map[u32]&ActiveQuery{}
	owner.keys = map[string]u32{}
	if owner.socket != unsafe { nil } {
		owner.socket.close('client close')
		owner.socket = unsafe { nil }
	}
	owner.connected = false
}
