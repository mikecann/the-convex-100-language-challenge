package convex

import "base:runtime"
import c "core:c/libc"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:sys/posix"
import "core:thread"
import "core:time"
import "core:unicode/utf8"
import "vendor:curl"

VERSION :: "0.1.0"
CLIENT_VERSION :: "odin-" + VERSION
SYNC_PROFILE :: "convex-rs-0.10.4-unversioned-sync"

MAX_WIRE_BYTES :: 2 * 1024 * 1024
MAX_JSON_DEPTH :: 64
MAX_JSON_NODES :: 65_536
MAX_LOG_LINES :: 256
MAX_LOG_BYTES :: 256 * 1024
MAX_URL_BYTES :: 8192
MAX_PATH_BYTES :: 16 * 1024
MAX_AUTH_BYTES :: 512 * 1024
MAX_ACTIVE_SUBSCRIPTIONS :: 16
MAX_COMMANDS :: 64
HTTP_TIMEOUT :: 30 * time.Second
LIVE_CONNECT_TIMEOUT :: 3 * time.Second
LIVE_IO_TIMEOUT :: 5 * time.Second
LIVE_FRAME_TIMEOUT :: 5 * time.Second
LIVE_INACTIVITY_TIMEOUT :: 30 * time.Second
INITIAL_RECONNECT_BACKOFF :: 100 * time.Millisecond
MAX_RECONNECT_BACKOFF :: 15 * time.Second
INITIAL_TIMESTAMP :: "AAAAAAAAAAA="

curl_once: sync.Once
curl_init_result: curl.code

initialize_curl :: proc() {
	curl_init_result = curl.global_init(curl.GLOBAL_ALL)
}

Error_Kind :: enum {
	None,
	Function,
	Protocol,
	Transport,
	Closed,
	Timeout,
}

// Error keeps Convex function failures separate from protocol and transport
// failures. data_json is absent unless Convex supplied structured error data.
Error :: struct {
	kind:      Error_Kind,
	message:   string,
	data_json: string,
	logs:      []string,
}

Result :: struct {
	value_json: string,
	logs:       []string,
}

Update :: struct {
	value_json: string,
	error:      Error,
	logs:       []string,
	cost:       int,
}

destroy_logs :: proc(logs: []string) {
	for line in logs {
		delete(line)
	}
	delete(logs)
}

destroy_error :: proc(err: ^Error) {
	delete(err.message)
	delete(err.data_json)
	destroy_logs(err.logs)
	err^ = {}
}

destroy_result :: proc(result: ^Result) {
	delete(result.value_json)
	destroy_logs(result.logs)
	result^ = {}
}

destroy_update :: proc(update: ^Update) {
	delete(update.value_json)
	destroy_error(&update.error)
	destroy_logs(update.logs)
	update^ = {}
}

make_error :: proc(kind: Error_Kind, message: string, data_json := "", logs: []string = nil) -> Error {
	return Error{
		kind = kind,
		message = strings.clone(message),
		data_json = strings.clone(data_json),
		logs = logs,
	}
}

error_name :: proc(err: Error) -> string {
	switch err.kind {
	case .None:      return "Error"
	case .Function:  return "FunctionError"
	case .Protocol:  return "ProtocolError"
	case .Transport: return "TransportError"
	case .Closed:    return "ClosedError"
	case .Timeout:   return "TimeoutError"
	}
	return "Error"
}

// check_json_budget runs before Odin's JSON parser allocates a tree. The wire
// limit alone is not a memory limit for documents containing many tiny nodes.
check_json_budget :: proc(source: string, subject: string) -> (err: Error) {
	if len(source) == 0 || len(source) > MAX_WIRE_BYTES {
		return make_error(.Protocol, fmt.tprintf("%s exceeds the bounded wire size", subject))
	}
	depth := 0
	nodes := 1
	in_string := false
	escaped := false
	for byte in transmute([]u8)source {
		if in_string {
			if escaped {
				escaped = false
			} else if byte == '\\' {
				escaped = true
			} else if byte == '"' {
				in_string = false
			}
			continue
		}
		switch byte {
		case '"': in_string = true
		case '[', '{':
			depth += 1
			nodes += 1
			if depth > MAX_JSON_DEPTH {
				return make_error(.Protocol, fmt.tprintf("%s nests deeper than %d", subject, MAX_JSON_DEPTH))
			}
		case ']', '}': depth -= 1
		case ',', ':': nodes += 1
		}
		if nodes > MAX_JSON_NODES {
			return make_error(.Protocol, fmt.tprintf("%s exceeds the bounded JSON node count", subject))
		}
	}
	return {}
}

parse_json :: proc(source: string, subject: string) -> (value: json.Value, err: Error) {
	if budget_err := check_json_budget(source, subject); budget_err.kind != .None {
		return {}, budget_err
	}
	if !utf8.valid_string(source) || !json.is_valid(transmute([]u8)source, .JSON, true) {
		return {}, make_error(.Protocol, fmt.tprintf("%s is not strict JSON", subject))
	}
	parsed, parse_err := json.parse_string(source, .JSON, true)
	if parse_err != nil {
		return {}, make_error(.Protocol, fmt.tprintf("could not parse %s", subject))
	}
	return parsed, {}
}

value_json :: proc(value: json.Value) -> (text: string, err: Error) {
	encoded, marshal_err := json.marshal(value, {spec = .JSON, sort_maps_by_key = true})
	if marshal_err != nil {
		return "", make_error(.Protocol, "could not encode a JSON value")
	}
	defer delete(encoded)
	if len(encoded) > MAX_WIRE_BYTES {
		return "", make_error(.Protocol, "JSON value exceeds the bounded wire size")
	}
	return strings.clone(string(encoded)), {}
}

as_object :: proc(value: json.Value) -> (json.Object, bool) {
	#partial switch v in value {
	case json.Object: return v, true
	case: return {}, false
	}
}

as_array :: proc(value: json.Value) -> (json.Array, bool) {
	#partial switch v in value {
	case json.Array: return v, true
	case: return {}, false
	}
}

as_string :: proc(value: json.Value) -> (string, bool) {
	#partial switch v in value {
	case json.String: return string(v), true
	case: return "", false
	}
}

as_u32 :: proc(value: json.Value) -> (u32, bool) {
	#partial switch v in value {
	case json.Integer:
		if v >= 0 && v <= i64(max(u32)) { return u32(v), true }
	case json.Float:
		if v == v && v >= 0 && v <= f64(max(u32)) && math.trunc(f64(v)) == f64(v) {
			return u32(v), true
		}
	}
	return 0, false
}

member :: proc(object: json.Object, name: string) -> (json.Value, bool) {
	value, ok := object[name]
	return value, ok
}

required_string :: proc(object: json.Object, name: string) -> (string, Error) {
	value, exists := member(object, name)
	if !exists { return "", make_error(.Protocol, fmt.tprintf("missing %s", name)) }
	text, ok := as_string(value)
	if !ok { return "", make_error(.Protocol, fmt.tprintf("%s is not a string", name)) }
	return text, {}
}

required_u32 :: proc(object: json.Object, name: string) -> (u32, Error) {
	value, exists := member(object, name)
	if !exists { return 0, make_error(.Protocol, fmt.tprintf("missing %s", name)) }
	number, ok := as_u32(value)
	if !ok { return 0, make_error(.Protocol, fmt.tprintf("%s is not an unsigned 32-bit integer", name)) }
	return number, {}
}

clone_logs :: proc(object: json.Object) -> (logs: []string, err: Error) {
	value, exists := member(object, "logLines")
	if !exists { return nil, {} }
	array, ok := as_array(value)
	if !ok || len(array) > MAX_LOG_LINES {
		return nil, make_error(.Protocol, "logLines is not a bounded string array")
	}
	result := make([]string, len(array))
	total := 0
	for item, index in array {
		line, string_ok := as_string(item)
		if !string_ok || total + len(line) > MAX_LOG_BYTES {
			for prior in result[:index] { delete(prior) }
			delete(result)
			return nil, make_error(.Protocol, "logLines exceeds its bounded string budget")
		}
		result[index] = strings.clone(line)
		total += len(line)
	}
	return result, {}
}

validate_args :: proc(args_json: string) -> (err: Error) {
	value, parse_err := parse_json(args_json, "Convex arguments")
	if parse_err.kind != .None { return parse_err }
	defer json.destroy_value(value)
	if _, ok := as_object(value); !ok {
		return make_error(.Protocol, "Convex arguments must be a named JSON object")
	}
	return {}
}

quote_json :: proc(text: string) -> string {
	encoded, err := json.marshal(text, {spec = .JSON})
	if err != nil { return strings.clone(`""`) }
	return string(encoded)
}

Response_Buffer :: struct {
	bytes:    [dynamic]u8,
	overflow: bool,
}

http_write_callback :: proc "c" (contents: [^]u8, size, count: c.size_t, userdata: rawptr) -> c.size_t {
	// Foreign callbacks do not inherit an Odin context. libcurl invokes this on
	// the calling thread, but append still needs a valid allocator context.
	context = runtime.default_context()
	buffer := cast(^Response_Buffer)userdata
	amount := int(size * count)
	if amount < 0 || len(buffer.bytes) > MAX_WIRE_BYTES - amount {
		buffer.overflow = true
		return 0
	}
	append(&buffer.bytes, ..contents[:amount])
	return c.size_t(amount)
}

curl_message :: proc(code: curl.code) -> string {
	return string(curl.easy_strerror(code))
}

Client :: struct {
	deployment_url: string,
	auth_token:     string,
	state_mutex:    sync.Mutex,
	closed:         bool,
	owner:          ^Live_Owner,
}

create :: proc(deployment_url: string) -> (client: ^Client, err: Error) {
	sync.once_do(&curl_once, initialize_curl)
	if curl_init_result != .E_OK {
		return nil, make_error(.Transport, fmt.tprintf("libcurl global initialization failed: %s", curl_message(curl_init_result)))
	}
	normalized, url_err := normalize_deployment_url(deployment_url)
	if url_err.kind != .None { return nil, url_err }
	client = new(Client)
	client.deployment_url = normalized
	return client, {}
}

normalize_deployment_url :: proc(url: string) -> (string, Error) {
	if len(url) == 0 || len(url) > MAX_URL_BYTES || !utf8.valid_string(url) {
		return "", make_error(.Protocol, "Convex deployment URL is missing, invalid UTF-8, or too large")
	}
	if !(strings.has_prefix(url, "https://") || strings.has_prefix(url, "http://")) {
		return "", make_error(.Protocol, "Convex deployment URL must use http or https")
	}
	if strings.contains_any(url, " \t\r\n\x00?#") {
		return "", make_error(.Protocol, "Convex deployment URL contains unsupported components")
	}
	authority_start := strings.index(url, "://") + 3
	if authority_start < 3 || authority_start >= len(url) {
		return "", make_error(.Protocol, "Convex deployment URL must include a host")
	}
	trimmed := strings.trim_right(url, "/")
	if slash := strings.index(trimmed[authority_start:], "/"); slash >= 0 {
		return "", make_error(.Protocol, "Convex deployment URL must not include a path")
	}
	if strings.contains(trimmed[authority_start:], "@") {
		return "", make_error(.Protocol, "Convex deployment URL must not include user information")
	}
	return strings.clone(trimmed), {}
}

set_auth :: proc(client: ^Client, token: string) -> (err: Error) {
	if len(token) > MAX_AUTH_BYTES || !utf8.valid_string(token) || strings.contains_any(token, "\r\n\x00") {
		return make_error(.Protocol, "Convex authentication token is invalid or too large")
	}
	sync.mutex_lock(&client.state_mutex)
	defer sync.mutex_unlock(&client.state_mutex)
	if client.closed { return make_error(.Closed, "Convex client is closed") }
	delete(client.auth_token)
	client.auth_token = strings.clone(token)
	return {}
}

query :: proc(client: ^Client, path, args_json: string, timeout := HTTP_TIMEOUT) -> (Result, Error) {
	return call(client, "query", path, args_json, timeout)
}

mutation :: proc(client: ^Client, path, args_json: string, timeout := HTTP_TIMEOUT) -> (Result, Error) {
	return call(client, "mutation", path, args_json, timeout)
}

action :: proc(client: ^Client, path, args_json: string, timeout := HTTP_TIMEOUT) -> (Result, Error) {
	return call(client, "action", path, args_json, timeout)
}

call :: proc(client: ^Client, operation, path, args_json: string, timeout: time.Duration) -> (result: Result, err: Error) {
	if len(path) < 3 || len(path) > MAX_PATH_BYTES || !utf8.valid_string(path) {
		return {}, make_error(.Protocol, "Convex function path is missing, invalid UTF-8, or too large")
	}
	if args_err := validate_args(args_json); args_err.kind != .None { return {}, args_err }
	if timeout <= 0 { return {}, make_error(.Timeout, "Convex HTTP deadline has expired") }

	sync.mutex_lock(&client.state_mutex)
	if client.closed {
		sync.mutex_unlock(&client.state_mutex)
		return {}, make_error(.Closed, "Convex client is closed")
	}
	url := fmt.aprintf("%s/api/%s", client.deployment_url, operation)
	token := strings.clone(client.auth_token)
	sync.mutex_unlock(&client.state_mutex)
	defer delete(url)
	defer delete(token)

	quoted_path := quote_json(path)
	defer delete(quoted_path)
	body := fmt.aprintf(`{{"path":%s,"args":%s,"format":"json"}}`, quoted_path, args_json)
	defer delete(body)
	if len(body) > MAX_WIRE_BYTES {
		return {}, make_error(.Protocol, "Convex HTTP request exceeds the bounded wire size")
	}

	handle := curl.easy_init()
	if handle == nil { return {}, make_error(.Transport, "libcurl could not create an HTTP handle") }
	defer curl.easy_cleanup(handle)
	url_c := strings.clone_to_cstring(url)
	defer delete(url_c)
	body_c := strings.clone_to_cstring(body)
	defer delete(body_c)
	response: Response_Buffer
	defer delete(response.bytes)

	headers: ^curl.slist
	headers = curl.slist_append(headers, cstring("Content-Type: application/json"))
	headers = curl.slist_append(headers, cstring("Accept: application/json"))
	headers = curl.slist_append(headers, cstring("Convex-Client: " + CLIENT_VERSION))
	if token != "" {
		auth_header := fmt.aprintf("Authorization: Bearer %s", token)
		defer delete(auth_header)
		auth_c := strings.clone_to_cstring(auth_header)
		defer delete(auth_c)
		headers = curl.slist_append(headers, auth_c)
	}
	defer curl.slist_free_all(headers)

	timeout_ms := max(c.long(1), c.long(time.duration_milliseconds(timeout)))
	setups := []curl.code{
		curl.easy_setopt(handle, .URL, url_c),
		curl.easy_setopt(handle, .POST, c.long(1)),
		curl.easy_setopt(handle, .POSTFIELDS, body_c),
		curl.easy_setopt(handle, .POSTFIELDSIZE_LARGE, curl.off_t(len(body))),
		curl.easy_setopt(handle, .HTTPHEADER, headers),
		curl.easy_setopt(handle, .WRITEFUNCTION, http_write_callback),
		curl.easy_setopt(handle, .WRITEDATA, &response),
		curl.easy_setopt(handle, .PROTOCOLS_STR, cstring("http,https")),
		curl.easy_setopt(handle, .REDIR_PROTOCOLS_STR, cstring("http,https")),
		curl.easy_setopt(handle, .TIMEOUT_MS, timeout_ms),
		curl.easy_setopt(handle, .CONNECTTIMEOUT_MS, min(timeout_ms, c.long(10_000))),
		curl.easy_setopt(handle, .NOSIGNAL, c.long(1)),
	}
	for setup in setups {
		if setup != .E_OK { return {}, make_error(.Transport, fmt.tprintf("could not configure HTTP transport: %s", curl_message(setup))) }
	}
	perform := curl.easy_perform(handle)
	if perform != .E_OK {
		if response.overflow { return {}, make_error(.Transport, "HTTP response exceeds the bounded wire size") }
		kind: Error_Kind = .Transport
		if perform == .E_OPERATION_TIMEDOUT { kind = .Timeout }
		return {}, make_error(kind, fmt.tprintf("HTTP transport: %s", curl_message(perform)))
	}
	response_code: c.long
	if info_result := curl.easy_getinfo(handle, .RESPONSE_CODE, &response_code); info_result != .E_OK {
		return {}, make_error(.Transport, fmt.tprintf("could not read the HTTP response status: %s", curl_message(info_result)))
	}

	root, parse_err := parse_json(string(response.bytes[:]), "Convex HTTP response")
	if parse_err.kind != .None { return {}, parse_err }
	defer json.destroy_value(root)
	object, ok := as_object(root)
	if !ok { return {}, make_error(.Protocol, "Convex HTTP response is not an object") }
	status, status_err := required_string(object, "status")
	if status_err.kind != .None { return {}, status_err }
	logs, logs_err := clone_logs(object)
	if logs_err.kind != .None { return {}, logs_err }
	if status == "success" {
		if response_code < 200 || response_code >= 300 {
			destroy_logs(logs)
			return {}, make_error(.Transport, fmt.tprintf("Convex HTTP endpoint returned status %d with a success-shaped body", response_code))
		}
		value, exists := member(object, "value")
		if !exists { destroy_logs(logs); return {}, make_error(.Protocol, "success response omitted value") }
		encoded, encode_err := value_json(value)
		if encode_err.kind != .None { destroy_logs(logs); return {}, encode_err }
		return Result{value_json = encoded, logs = logs}, {}
	}
	if status == "error" {
		message, message_err := required_string(object, "errorMessage")
		if message_err.kind != .None { destroy_logs(logs); return {}, message_err }
		data_text := ""
		if data, exists := member(object, "errorData"); exists {
			data_text, err = value_json(data)
			if err.kind != .None { destroy_logs(logs); return {}, err }
		}
		defer delete(data_text)
		return {}, make_error(.Function, message, data_text, logs)
	}
	destroy_logs(logs)
	return {}, make_error(.Protocol, "Convex HTTP response has an unknown status")
}

Subscription :: struct {
	query_id:       u32,
	updates:        chan.Chan(Update),
	owner:          ^Live_Owner,
	active_mutex:   sync.Mutex,
	active:         bool,
	last_signature: string,
	suppress_once:  bool,
	path:           string,
	args_json:      string,
}

subscription_recv :: proc(subscription: ^Subscription, timeout: time.Duration) -> (update: Update, ok: bool) {
	deadline := time.tick_add(time.tick_now(), timeout)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if received, received_ok := chan.try_recv(subscription.updates); received_ok {
			return received, true
		} else if chan.is_closed(subscription.updates) {
			return {}, false
		}
		time.sleep(time.Millisecond)
	}
	return {}, false
}

subscription_is_active :: proc(subscription: ^Subscription) -> bool {
	if subscription == nil { return false }
	sync.mutex_lock(&subscription.active_mutex)
	defer sync.mutex_unlock(&subscription.active_mutex)
	return subscription.active
}

subscription_close :: proc(subscription: ^Subscription, timeout := LIVE_IO_TIMEOUT) -> (err: Error) {
	if subscription == nil { return {} }
	sync.mutex_lock(&subscription.active_mutex)
	owner := subscription.owner
	active := subscription.active
	sync.mutex_unlock(&subscription.active_mutex)
	if owner == nil || !active { return {} }
	return owner_remove(owner, subscription, timeout)
}

subscription_destroy :: proc(subscription: ^Subscription) {
	if subscription == nil { return }
	close_err := subscription_close(subscription)
	if close_err.kind != .None {
		// The owner can still hold this pointer after a timed-out acknowledgement.
		// Leak the terminal subscription instead of freeing live memory underneath it.
		destroy_error(&close_err)
		return
	}
	for {
		update, received_ok := chan.try_recv(subscription.updates)
		if !received_ok { break }
		destroy_update(&update)
	}
	chan.destroy(subscription.updates)
	delete(subscription.last_signature)
	delete(subscription.path)
	delete(subscription.args_json)
	free(subscription)
}

Command_Kind :: enum { Add, Remove, Debug_Disconnect, Inspect_Test, Close }

Owner_Response :: struct {
	mutex:            sync.Mutex,
	cond:             sync.Cond,
	done:             bool,
	abandoned:        bool,
	error:            Error,
	sub:              ^Subscription,
	active_count:     int,
	socket_connected: bool,
	test_forced_drains: int,
}

Owner_Command :: struct {
	kind:                  Command_Kind,
	path:                  string,
	args_json:             string,
	sub:                   ^Subscription,
	response:              ^Owner_Response,
	test_completion_delay: time.Duration,
}

Receive_Watchdog :: struct {
	mutex:    sync.Mutex,
	cond:     sync.Cond,
	done:     bool,
	fd:       posix.FD,
	deadline: time.Tick,
}

receive_watchdog_thread :: proc(data: rawptr) {
	watchdog := cast(^Receive_Watchdog)data
	sync.mutex_lock(&watchdog.mutex)
	for !watchdog.done {
		remaining := time.tick_diff(time.tick_now(), watchdog.deadline)
		if remaining <= 0 { break }
		_ = sync.cond_wait_with_timeout(&watchdog.cond, &watchdog.mutex, remaining)
	}
	if !watchdog.done {
		// curl_ws_recv may keep polling internally after a short read. Interrupt
		// that syscall at the absolute frame deadline so the owner regains control.
		_ = posix.shutdown(watchdog.fd, .RDWR)
	}
	sync.mutex_unlock(&watchdog.mutex)
}

Remote_Version :: struct { query_set, identity: u32, timestamp: string }

Live_Owner :: struct {
	client:                 ^Client,
	thread:                 ^thread.Thread,
	queue_mutex:            sync.Mutex,
	commands:               [dynamic]^Owner_Command,
	accepting:              bool,
	active:                 map[u32]^Subscription,
	// Only subscriptions whose Add crossed the current socket are eligible for
	// transport/protocol publications. A failed pending Add stays silent.
	remote_active:          map[u32]bool,
	next_query_id:          u32,
	query_set_version:      u32,
	remote_version:         Remote_Version,
	connection_count:       u32,
	last_close_reason:      string,
	max_observed_timestamp: string,
	max_observed_number:    u64,
	have_timestamp:         bool,
	reconnect_backoff:      time.Duration,
	reconnect_at:           time.Tick,
	last_server_response:   time.Tick,
	message_started:        time.Tick,
	receive_pending:        bool,
	test_forced_drains:     int,
	fragmented:             bool,
	incoming:               [dynamic]u8,
	socket:                 ^curl.CURL,
	closing:                bool,
}

ensure_owner :: proc(client: ^Client) -> (owner: ^Live_Owner, err: Error) {
	sync.mutex_lock(&client.state_mutex)
	defer sync.mutex_unlock(&client.state_mutex)
	if client.closed { return nil, make_error(.Closed, "Convex client is closed") }
	if client.owner != nil { return client.owner, {} }
	owner = new(Live_Owner)
	owner.client = client
	owner.accepting = true
	owner.active = make(map[u32]^Subscription)
	owner.remote_active = make(map[u32]bool)
	owner.remote_version = {0, 0, strings.clone(INITIAL_TIMESTAMP)}
	owner.last_close_reason = strings.clone("InitialConnect")
	owner.reconnect_backoff = INITIAL_RECONNECT_BACKOFF
	// Commands are allocated by the caller and consumed by the owner thread.
	// Give the owner the same allocator context so ownership can cross that
	// boundary safely.
	owner.thread = thread.create_and_start_with_data(owner, live_owner_thread, context)
	client.owner = owner
	return owner, {}
}

subscribe_internal :: proc(client: ^Client, path, args_json: string, timeout, test_completion_delay: time.Duration) -> (sub: ^Subscription, err: Error) {
	if len(path) < 3 || len(path) > MAX_PATH_BYTES || !utf8.valid_string(path) {
		return nil, make_error(.Protocol, "Convex function path is missing, invalid UTF-8, or too large")
	}
	if args_err := validate_args(args_json); args_err.kind != .None { return nil, args_err }
	owner, owner_err := ensure_owner(client)
	if owner_err.kind != .None { return nil, owner_err }
	response := new(Owner_Response)
	command := new(Owner_Command)
	command.kind = .Add
	command.path = strings.clone(path)
	command.args_json = strings.clone(args_json)
	command.response = response
	command.test_completion_delay = test_completion_delay
	if queue_err := enqueue_command(owner, command); queue_err.kind != .None {
		delete(command.path); delete(command.args_json); free(command); free(response)
		return nil, queue_err
	}
	if !wait_response(response, timeout) {
		return nil, make_error(.Timeout, "Live subscribe acknowledgement timed out")
	}
	sub = response.sub
	err = response.error
	free(response)
	return
}

subscribe :: proc(client: ^Client, path, args_json: string, timeout := LIVE_IO_TIMEOUT) -> (sub: ^Subscription, err: Error) {
	return subscribe_internal(client, path, args_json, timeout, 0)
}

subscribe_with_completion_delay_for_test :: proc(client: ^Client, path, args_json: string, delay, timeout: time.Duration) -> (sub: ^Subscription, err: Error) {
	return subscribe_internal(client, path, args_json, timeout, delay)
}

owner_remove :: proc(owner: ^Live_Owner, sub: ^Subscription, timeout: time.Duration) -> (err: Error) {
	sync.mutex_lock(&sub.active_mutex)
	active := sub.active
	sync.mutex_unlock(&sub.active_mutex)
	if !active { return {} }
	response := new(Owner_Response)
	command := new(Owner_Command)
	command.kind = .Remove
	command.sub = sub
	command.response = response
	if queue_err := enqueue_command(owner, command); queue_err.kind != .None {
		free(command); free(response); return queue_err
	}
	if !wait_response(response, timeout) { return make_error(.Timeout, "Live unsubscribe acknowledgement timed out") }
	err = response.error
	free(response)
	return
}

debug_disconnect_for_adapter :: proc(client: ^Client, timeout := LIVE_IO_TIMEOUT) -> (err: Error) {
	owner, owner_err := ensure_owner(client)
	if owner_err.kind != .None { return owner_err }
	response := new(Owner_Response)
	command := new(Owner_Command)
	command.kind = .Debug_Disconnect
	command.response = response
	if queue_err := enqueue_command(owner, command); queue_err.kind != .None { free(command); free(response); return queue_err }
	if !wait_response(response, timeout) { return make_error(.Timeout, "debug disconnect acknowledgement timed out") }
	err = response.error
	free(response)
	return
}

close :: proc(client: ^Client, timeout := LIVE_IO_TIMEOUT) -> (err: Error) {
	if client == nil { return {} }
	sync.mutex_lock(&client.state_mutex)
	if client.closed {
		sync.mutex_unlock(&client.state_mutex)
		return {}
	}
	client.closed = true
	owner := client.owner
	sync.mutex_unlock(&client.state_mutex)
	if owner == nil { return {} }
	response := new(Owner_Response)
	command := new(Owner_Command)
	command.kind = .Close
	command.response = response
	if queue_err := enqueue_command(owner, command); queue_err.kind != .None { free(command); free(response); return queue_err }
	if !wait_response(response, timeout) { return make_error(.Timeout, "Live close acknowledgement timed out") }
	err = response.error
	free(response)
	return
}

destroy :: proc(client: ^Client) {
	if client == nil { return }
	close_err := close(client)
	destroy_error(&close_err)
	if client.owner != nil {
		deadline := time.tick_add(time.tick_now(), LIVE_IO_TIMEOUT)
		for !thread.is_done(client.owner.thread) && time.tick_diff(time.tick_now(), deadline) > 0 {
			time.sleep(time.Millisecond)
		}
		// The owner may still have pointers into Client after an abnormal close
		// timeout. Leaking that rare terminal object is safer than a use-after-free.
		if !thread.is_done(client.owner.thread) { return }
		thread.destroy(client.owner.thread)
		destroy_owner(client.owner)
	}
	delete(client.deployment_url)
	delete(client.auth_token)
	free(client)
}

enqueue_command :: proc(owner: ^Live_Owner, command: ^Owner_Command) -> (err: Error) {
	sync.mutex_lock(&owner.queue_mutex)
	defer sync.mutex_unlock(&owner.queue_mutex)
	if !owner.accepting { return make_error(.Closed, "Live owner is closed") }
	if len(owner.commands) >= MAX_COMMANDS { return make_error(.Transport, "Live command queue is full") }
	append(&owner.commands, command)
	return {}
}

wait_response :: proc(response: ^Owner_Response, timeout: time.Duration) -> bool {
	deadline := time.tick_add(time.tick_now(), timeout)
	sync.mutex_lock(&response.mutex)
	defer sync.mutex_unlock(&response.mutex)
	for !response.done {
		remaining := time.tick_diff(time.tick_now(), deadline)
		if remaining <= 0 {
			response.abandoned = true
			return false
		}
		_ = sync.cond_wait_with_timeout(&response.cond, &response.mutex, remaining)
	}
	return true
}

response_is_abandoned :: proc(response: ^Owner_Response) -> bool {
	sync.mutex_lock(&response.mutex)
	defer sync.mutex_unlock(&response.mutex)
	return response.abandoned
}

complete_response :: proc(response: ^Owner_Response, sub: ^Subscription = nil, err: Error = {}, active_count := 0, socket_connected := false, test_forced_drains := 0) -> bool {
	response_error := err
	sync.mutex_lock(&response.mutex)
	if response.abandoned {
		sync.mutex_unlock(&response.mutex)
		destroy_error(&response_error)
		free(response)
		return false
	}
	response.sub = sub
	response.error = response_error
	response.active_count = active_count
	response.socket_connected = socket_connected
	response.test_forced_drains = test_forced_drains
	response.done = true
	sync.cond_signal(&response.cond)
	sync.mutex_unlock(&response.mutex)
	return true
}

take_command :: proc(owner: ^Live_Owner) -> ^Owner_Command {
	sync.mutex_lock(&owner.queue_mutex)
	defer sync.mutex_unlock(&owner.queue_mutex)
	if len(owner.commands) == 0 { return nil }
	command := owner.commands[0]
	copy(owner.commands[:], owner.commands[1:])
	resize(&owner.commands, len(owner.commands)-1)
	return command
}

live_owner_thread :: proc(thread_data: rawptr) {
	owner := cast(^Live_Owner)thread_data
	for !owner.closing {
		for command := take_command(owner); command != nil; command = take_command(owner) {
			handle_command(owner, command)
			delete(command.path)
			delete(command.args_json)
			free(command)
			if owner.closing { break }
		}
		if owner.closing { break }
		if len(owner.active) > 0 && owner.socket == nil && tick_due(owner.reconnect_at) {
			if connect_err := connect_live(owner); connect_err.kind != .None {
				retire_socket(owner, connect_err.message, false, false)
				owner.connection_count += 1
				destroy_error(&connect_err)
				schedule_reconnect(owner)
			}
		} else {
		}
		if owner.socket != nil {
			pump_live(owner)
		} else {
			time.sleep(10 * time.Millisecond)
		}
	}
	retire_socket(owner, "ClientClosed", false, false)
	for _, sub in owner.active {
		invalidate_subscription(sub)
	}
	clear(&owner.active)
}

tick_due :: proc(tick: time.Tick) -> bool {
	return tick == {} || time.tick_diff(tick, time.tick_now()) >= 0
}

handle_command :: proc(owner: ^Live_Owner, command: ^Owner_Command) {
	switch command.kind {
	case .Add:
		if response_is_abandoned(command.response) {
			_ = complete_response(command.response)
			return
		}
		if len(owner.active) >= MAX_ACTIVE_SUBSCRIPTIONS || owner.next_query_id == max(u32) {
			complete_response(command.response, err = make_error(.Protocol, "Live subscription limit reached"))
			return
		}
		sub := new(Subscription)
		sub.query_id = owner.next_query_id
		owner.next_query_id += 1
		sub.owner = owner
		sub.active = true
		sub.path = strings.clone(command.path)
		sub.args_json = strings.clone(command.args_json)
		updates, allocation_err := chan.create_buffered(chan.Chan(Update), 1, context.allocator)
		if allocation_err != nil {
			delete(sub.path); delete(sub.args_json); free(sub)
			complete_response(command.response, err = make_error(.Transport, "could not allocate the bounded Live update channel"))
			return
		}
		sub.updates = updates
		owner.active[sub.query_id] = sub
		if owner.socket == nil {
			owner.reconnect_at = time.tick_now()
		} else if send_err := send_modify(owner, []^Subscription{sub}, nil); send_err.kind != .None {
			publish_transport_error(owner, send_err.message)
			retire_socket(owner, send_err.message, true, true)
				destroy_error(&send_err)
			}
		if command.test_completion_delay > 0 { time.sleep(command.test_completion_delay) }
		if !complete_response(command.response, sub = sub) {
			rollback_abandoned_add(owner, sub)
		}
	case .Remove:
		sub := command.sub
		if sub != nil {
			if _, exists := owner.active[sub.query_id]; exists {
				invalidate_subscription(sub)
				delete_key(&owner.active, sub.query_id)
				if owner.socket != nil {
					if send_err := send_modify(owner, nil, []u32{sub.query_id}); send_err.kind != .None {
						retire_socket(owner, send_err.message, len(owner.active) > 0, true)
						destroy_error(&send_err)
					}
				}
			}
		}
		complete_response(command.response)
	case .Debug_Disconnect:
		if owner.socket == nil {
			complete_response(command.response, err = make_error(.Transport, "Live WebSocket is not connected"))
			return
		}
		// Retire and schedule the replacement before publishing the barrier.
		retire_socket(owner, "DebugDisconnect", true, true)
		complete_response(command.response)
	case .Inspect_Test:
		complete_response(
			command.response,
			active_count = len(owner.active),
			socket_connected = owner.socket != nil,
			test_forced_drains = owner.test_forced_drains,
		)
	case .Close:
		sync.mutex_lock(&owner.queue_mutex)
		owner.accepting = false
		sync.mutex_unlock(&owner.queue_mutex)
		owner.closing = true
		complete_response(command.response)
	}
}

rollback_abandoned_add :: proc(owner: ^Live_Owner, sub: ^Subscription) {
	if _, exists := owner.active[sub.query_id]; !exists { return }
	delete_key(&owner.active, sub.query_id)
	if owner.socket != nil && owner.remote_active[sub.query_id] {
		if remove_err := send_modify(owner, nil, []u32{sub.query_id}); remove_err.kind != .None {
			retire_socket(owner, remove_err.message, len(owner.active) > 0, true)
			destroy_error(&remove_err)
		}
	}
	invalidate_subscription(sub)
	subscription_destroy(sub)
}

owner_state_for_test :: proc(client: ^Client, timeout := LIVE_IO_TIMEOUT) -> (active_count: int, socket_connected: bool, err: Error) {
	owner, owner_err := ensure_owner(client)
	if owner_err.kind != .None { return 0, false, owner_err }
	response := new(Owner_Response)
	command := new(Owner_Command)
	command.kind = .Inspect_Test
	command.response = response
	if queue_err := enqueue_command(owner, command); queue_err.kind != .None {
		free(command); free(response); return 0, false, queue_err
	}
	if !wait_response(response, timeout) { return 0, false, make_error(.Timeout, "Live owner inspection timed out") }
	active_count = response.active_count
	socket_connected = response.socket_connected
	err = response.error
	free(response)
	return
}

owner_forced_drains_for_test :: proc(client: ^Client, timeout := LIVE_IO_TIMEOUT) -> (count: int, err: Error) {
	owner, owner_err := ensure_owner(client)
	if owner_err.kind != .None { return 0, owner_err }
	response := new(Owner_Response)
	command := new(Owner_Command)
	command.kind = .Inspect_Test
	command.response = response
	if queue_err := enqueue_command(owner, command); queue_err.kind != .None {
		free(command); free(response); return 0, queue_err
	}
	if !wait_response(response, timeout) { return 0, make_error(.Timeout, "Live owner drain inspection timed out") }
	count = response.test_forced_drains
	err = response.error
	free(response)
	return
}

invalidate_subscription :: proc(sub: ^Subscription) {
	sync.mutex_lock(&sub.active_mutex)
	if sub.active {
		sub.active = false
		chan.close(sub.updates)
	}
	sub.owner = nil
	sync.mutex_unlock(&sub.active_mutex)
}

destroy_owner :: proc(owner: ^Live_Owner) {
	delete(owner.commands)
	delete_map(owner.active)
	delete_map(owner.remote_active)
	delete(owner.remote_version.timestamp)
	delete(owner.last_close_reason)
	delete(owner.max_observed_timestamp)
	delete(owner.incoming)
	free(owner)
}

schedule_reconnect :: proc(owner: ^Live_Owner) {
	if len(owner.active) == 0 { return }
	owner.reconnect_at = time.tick_add(time.tick_now(), owner.reconnect_backoff)
	owner.reconnect_backoff = min(owner.reconnect_backoff * 2, MAX_RECONNECT_BACKOFF)
}

live_url :: proc(deployment_url: string) -> string {
	if strings.has_prefix(deployment_url, "https://") {
		return fmt.aprintf("wss://%s/api/sync", deployment_url[len("https://"):])
	}
	return fmt.aprintf("ws://%s/api/sync", deployment_url[len("http://"):])
}

connect_live :: proc(owner: ^Live_Owner) -> (err: Error) {
	url := live_url(owner.client.deployment_url)
	defer delete(url)
	url_c := strings.clone_to_cstring(url)
	defer delete(url_c)
	handle := curl.easy_init()
	if handle == nil { return make_error(.Transport, "libcurl could not create a Live handle") }
	headers: ^curl.slist
	headers = curl.slist_append(headers, cstring("Convex-Client: " + CLIENT_VERSION))
	defer curl.slist_free_all(headers)
	setups := []curl.code{
		curl.easy_setopt(handle, .URL, url_c),
		curl.easy_setopt(handle, .CONNECT_ONLY, c.long(2)),
		curl.easy_setopt(handle, .HTTPHEADER, headers),
		curl.easy_setopt(handle, .PROTOCOLS_STR, cstring("ws,wss")),
		curl.easy_setopt(handle, .CONNECTTIMEOUT_MS, c.long(time.duration_milliseconds(LIVE_CONNECT_TIMEOUT))),
		curl.easy_setopt(handle, .TIMEOUT_MS, c.long(time.duration_milliseconds(LIVE_CONNECT_TIMEOUT))),
		curl.easy_setopt(handle, .NOSIGNAL, c.long(1)),
	}
	for setup in setups {
		if setup != .E_OK { curl.easy_cleanup(handle); return make_error(.Transport, fmt.tprintf("could not configure Live transport: %s", curl_message(setup))) }
	}
	if result := curl.easy_perform(handle); result != .E_OK {
		curl.easy_cleanup(handle)
		return make_error(.Transport, fmt.tprintf("Live dial: %s", curl_message(result)))
	}
	fd, socket_ok := active_socket(handle)
	if !socket_ok {
		curl.easy_cleanup(handle)
		return make_error(.Transport, "Live dial did not expose its active socket")
	}
	flags := posix.fcntl(fd, .GETFL)
	if flags < 0 || posix.fcntl(fd, .SETFL, flags | posix.O_NONBLOCK) < 0 {
		curl.easy_cleanup(handle)
		return make_error(.Transport, "Live dial could not make its socket nonblocking")
	}
	confirmed_flags := posix.fcntl(fd, .GETFL)
	if confirmed_flags < 0 || (confirmed_flags & posix.O_NONBLOCK) == 0 {
		curl.easy_cleanup(handle)
		return make_error(.Transport, "Live dial did not retain nonblocking socket mode")
	}
	owner.socket = handle
	owner.query_set_version = 0
	delete(owner.remote_version.timestamp)
	owner.remote_version = {0, 0, strings.clone(INITIAL_TIMESTAMP)}
	owner.last_server_response = time.tick_now()
	owner.fragmented = false
	// The 101 response can arrive in the same read as initial WebSocket bytes.
	// Those bytes live in libcurl even when the OS socket is no longer readable.
	owner.receive_pending = true
	resize(&owner.incoming, 0)

	connect_message := build_connect(owner)
	defer delete(connect_message)
	if send_err := send_text(owner, connect_message, LIVE_IO_TIMEOUT); send_err.kind != .None {
		retire_socket(owner, send_err.message, false, false)
		return send_err
	}
	adds := make([dynamic]^Subscription, 0, len(owner.active))
	defer delete(adds)
	for _, sub in owner.active {
		sub.suppress_once = sub.last_signature != ""
		append(&adds, sub)
	}
	sort_subscriptions_by_id(adds[:])
	if len(adds) > 0 {
		if modify_err := send_modify(owner, adds[:], nil); modify_err.kind != .None {
			retire_socket(owner, modify_err.message, false, false)
			return modify_err
		}
	}
	owner.reconnect_backoff = INITIAL_RECONNECT_BACKOFF
	return {}
}

build_connect :: proc(owner: ^Live_Owner) -> string {
	session := fmt.tprintf("00000000-0000-4000-8000-%012x", u64(time.tick_now()._nsec) & 0xffffffffffff)
	reason := quote_json(owner.last_close_reason)
	defer delete(reason)
	if owner.have_timestamp {
		timestamp := quote_json(owner.max_observed_timestamp)
		defer delete(timestamp)
		return fmt.aprintf(`{{"type":"Connect","sessionId":"%s","connectionCount":%d,"lastCloseReason":%s,"maxObservedTimestamp":%s,"clientTs":0}}`, session, owner.connection_count, reason, timestamp)
	}
	return fmt.aprintf(`{{"type":"Connect","sessionId":"%s","connectionCount":%d,"lastCloseReason":%s,"clientTs":0}}`, session, owner.connection_count, reason)
}

send_modify :: proc(owner: ^Live_Owner, adds: []^Subscription, removes: []u32) -> (err: Error) {
	if owner.query_set_version == max(u32) {
		return make_error(.Protocol, "Live query-set version exhausted its unsigned 32-bit range")
	}
	new_version := owner.query_set_version + 1
	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)
	fmt.sbprintf(&builder, `{{"type":"ModifyQuerySet","baseVersion":%d,"newVersion":%d,"modifications":[`, owner.query_set_version, new_version)
	first := true
	for sub in adds {
		if !first { strings.write_byte(&builder, ',') }
		first = false
		path := quote_json(sub.path)
		fmt.sbprintf(&builder, `{{"type":"Add","queryId":%d,"udfPath":%s,"args":[%s]}}`, sub.query_id, path, sub.args_json)
		delete(path)
	}
	for id in removes {
		if !first { strings.write_byte(&builder, ',') }
		first = false
		fmt.sbprintf(&builder, `{{"type":"Remove","queryId":%d}}`, id)
	}
	strings.write_string(&builder, "]}")
	message := strings.to_string(builder)
	if len(message) > MAX_WIRE_BYTES { return make_error(.Protocol, "ModifyQuerySet exceeds the bounded wire size") }
	if send_err := send_text(owner, message, LIVE_IO_TIMEOUT); send_err.kind != .None { return send_err }
	owner.query_set_version = new_version
	for sub in adds { owner.remote_active[sub.query_id] = true }
	for id in removes { delete_key(&owner.remote_active, id) }
	return {}
}

active_socket :: proc(handle: ^curl.CURL) -> (posix.FD, bool) {
	socket: curl.socket_t
	if curl.easy_getinfo(handle, .ACTIVESOCKET, &socket) != .E_OK || socket == curl.SOCKET_BAD { return {}, false }
	return posix.FD(socket), true
}

wait_socket :: proc(handle: ^curl.CURL, writable: bool, deadline: time.Tick) -> bool {
	fd, ok := active_socket(handle)
	if !ok { return false }
	remaining := time.tick_diff(time.tick_now(), deadline)
	if remaining <= 0 { return false }
	timeout_ms := c.int(max(1, min(i64(50), i64(time.duration_milliseconds(remaining)))))
	events: posix.Poll_Event = {.OUT} if writable else {.IN}
	poll_fd := posix.pollfd{fd = fd, events = events}
	return posix.poll(&poll_fd, 1, timeout_ms) > 0
}

send_text :: proc(owner: ^Live_Owner, text: string, timeout: time.Duration) -> (err: Error) {
	if owner.socket == nil { return make_error(.Transport, "Live WebSocket is not connected") }
	deadline := time.tick_add(time.tick_now(), timeout)
	offset := 0
	for offset < len(text) {
		sent: c.size_t
		result := curl.ws_send(owner.socket, raw_data(transmute([]u8)text[offset:]), c.size_t(len(text[offset:])), &sent, 0, curl.WS_TEXT)
		offset += int(sent)
		if result == .E_OK { continue }
		if result == .E_AGAIN && wait_socket(owner.socket, true, deadline) { continue }
		if result == .E_AGAIN { return make_error(.Timeout, "Live write exceeded its absolute deadline") }
		return make_error(.Transport, fmt.tprintf("Live write: %s", curl_message(result)))
	}
	return {}
}

pump_live :: proc(owner: ^Live_Owner) {
	if owner.socket == nil { return }
	// libcurl may already own bytes read alongside the HTTP Upgrade, so an OS
	// poll alone is not sufficient. A successful receive can also leave the next
	// complete frame in libcurl's private buffer, so drain once more before
	// returning to the socket poll.
	forced_drain := owner.receive_pending
	if forced_drain { owner.test_forced_drains += 1 }
	readable := forced_drain || wait_socket(owner.socket, false, time.tick_add(time.tick_now(), 10*time.Millisecond))
	if !readable {
		if owner.message_started != {} && time.tick_diff(owner.message_started, time.tick_now()) >= LIVE_FRAME_TIMEOUT {
			publish_transport_error(owner, "Live message exceeded its absolute frame deadline")
			retire_socket(owner, "FrameTimeout", true, true)
			return
		}
		if time.tick_diff(owner.last_server_response, time.tick_now()) >= LIVE_INACTIVITY_TIMEOUT {
			publish_transport_error(owner, "Live server became inactive")
			retire_socket(owner, "InactiveServer", true, true)
		}
		return
	}
	started_here := owner.message_started == {}
	if started_here { owner.message_started = time.tick_now() }
	frame_deadline := time.tick_add(owner.message_started, LIVE_FRAME_TIMEOUT)
	fd, socket_ok := active_socket(owner.socket)
	if !socket_ok {
		publish_transport_error(owner, "Live receive lost its active socket")
		retire_socket(owner, "MissingSocket", true, true)
		return
	}
	watchdog := Receive_Watchdog{fd = fd, deadline = frame_deadline}
	watchdog_thread := thread.create_and_start_with_data(&watchdog, receive_watchdog_thread, context)
	buffer: [8192]u8
	received: c.size_t
	meta: ^curl.ws_frame
	result := curl.ws_recv(owner.socket, &buffer[0], len(buffer), &received, &meta)
	sync.mutex_lock(&watchdog.mutex)
	watchdog.done = true
	sync.cond_signal(&watchdog.cond)
	sync.mutex_unlock(&watchdog.mutex)
	thread.destroy(watchdog_thread)
	if time.tick_diff(owner.message_started, time.tick_now()) >= LIVE_FRAME_TIMEOUT {
		publish_transport_error(owner, "Live message exceeded its absolute frame deadline")
		retire_socket(owner, "FrameTimeout", true, true)
		return
	}
	if result == .E_AGAIN {
		owner.receive_pending = false
		// This build's private libcurl patch makes ws_meta non-nil here only
		// when CONNECT_ONLY has consumed part of a successor frame internally.
		pending_decoder_input := forced_drain && curl.ws_meta(owner.socket) != nil
		if forced_drain && started_here && !pending_decoder_input {
			// The extra read after a complete frame found no buffered successor.
			// Do not turn that ordinary idle state into a false frame deadline.
			owner.message_started = {}
			return
		}
		// Readability followed by E_AGAIN means libcurl consumed an incomplete
		// frame into its private decoder buffer. Start the absolute frame clock
		// even though it cannot return those bytes to us yet.
		if owner.message_started == {} { owner.message_started = time.tick_now() }
		if owner.message_started != {} && time.tick_diff(owner.message_started, time.tick_now()) >= LIVE_FRAME_TIMEOUT {
			publish_transport_error(owner, "Live message exceeded its absolute frame deadline")
			retire_socket(owner, "FrameTimeout", true, true)
			return
		}
		if time.tick_diff(owner.last_server_response, time.tick_now()) >= LIVE_INACTIVITY_TIMEOUT {
			publish_transport_error(owner, "Live server became inactive")
			retire_socket(owner, "InactiveServer", true, true)
			return
		}
		return
	}
	if result != .E_OK {
		publish_transport_error(owner, fmt.tprintf("Live receive: %s", curl_message(result)))
		retire_socket(owner, curl_message(result), true, true)
		return
	}
	owner.last_server_response = time.tick_now()
	// Drain once after every successful receive. libcurl can read multiple TCP
	// frames at once even when this frame's bytesleft is zero.
	owner.receive_pending = true
	if meta == nil { return }
	if .PING in meta.flags || .PONG in meta.flags {
		if started_here { owner.message_started = {} }
		return
	}
	if .CLOSE in meta.flags {
		publish_transport_error(owner, "Live peer closed the WebSocket")
		retire_socket(owner, "PeerClosed", true, true)
		return
	}
	if .BINARY in meta.flags || !(.TEXT in meta.flags) {
		publish_protocol_error(owner, "Live server sent an unsupported binary message")
		retire_socket(owner, "ProtocolError", true, true)
		return
	}
	if int(received) > MAX_WIRE_BYTES - len(owner.incoming) {
		publish_protocol_error(owner, "Live message exceeds the bounded wire size")
		retire_socket(owner, "ProtocolError", true, true)
		return
	}
	append(&owner.incoming, ..buffer[:int(received)])
	if meta.bytesleft != 0 { return }
	if .CONT in meta.flags {
		owner.fragmented = true
		return
	}
	message := strings.clone(string(owner.incoming[:]))
	resize(&owner.incoming, 0)
	owner.fragmented = false
	owner.message_started = {}
	defer delete(message)
	if !utf8.valid_string(message) {
		publish_protocol_error(owner, "Live text message is not valid UTF-8")
		retire_socket(owner, "ProtocolError", true, true)
		return
	}
	if transition_err := process_server_message(owner, message); transition_err.kind != .None {
		publish_protocol_error(owner, transition_err.message)
		retire_socket(owner, transition_err.message, true, true)
		destroy_error(&transition_err)
	}
}

retire_socket :: proc(owner: ^Live_Owner, reason: string, reconnect, count_connection: bool) {
	if owner.socket != nil {
		curl.easy_cleanup(owner.socket)
		owner.socket = nil
		if count_connection { owner.connection_count += 1 }
	}
	delete(owner.last_close_reason)
	owner.last_close_reason = strings.clone(reason)
	owner.query_set_version = 0
	delete(owner.remote_version.timestamp)
	owner.remote_version = {0, 0, strings.clone(INITIAL_TIMESTAMP)}
	clear(&owner.remote_active)
	resize(&owner.incoming, 0)
	owner.message_started = {}
	owner.receive_pending = false
	owner.fragmented = false
	if reconnect { schedule_reconnect(owner) }
}

publish_transport_error :: proc(owner: ^Live_Owner, message: string) {
	for id, sub in owner.active {
		if owner.remote_active[id] { publish(sub, Update{error = make_error(.Transport, message)}) }
	}
}

publish_protocol_error :: proc(owner: ^Live_Owner, message: string) {
	for id, sub in owner.active {
		if owner.remote_active[id] { publish(sub, Update{error = make_error(.Protocol, message)}) }
	}
}

publish :: proc(sub: ^Subscription, update: Update) {
	next := update
	sync.mutex_lock(&sub.active_mutex)
	defer sync.mutex_unlock(&sub.active_mutex)
	if !sub.active { destroy_update(&next); return }
	signature := update_signature(next)
	if sub.suppress_once && signature == sub.last_signature {
		sub.suppress_once = false
		delete(signature)
		destroy_update(&next)
		return
	}
	sub.suppress_once = false
	delete(sub.last_signature)
	sub.last_signature = signature
	next.cost = len(next.value_json) + len(next.error.message) + len(next.error.data_json) + 1024
	for line in next.logs { next.cost += len(line) + 64 }
	if next.cost > MAX_WIRE_BYTES + 4096 {
		destroy_update(&next)
		next = Update{error = make_error(.Protocol, "Live update exceeds the bounded delivery budget"), cost = 2048}
	}
	if !chan.try_send(sub.updates, next) {
		if previous, received_ok := chan.try_recv(sub.updates); received_ok { destroy_update(&previous) }
		if !chan.try_send(sub.updates, next) { destroy_update(&next) }
	}
}

update_signature :: proc(update: Update) -> string {
	if update.error.kind == .None { return fmt.aprintf("V:%s", update.value_json) }
	return fmt.aprintf("E:%s:%s:%s", error_name(update.error), update.error.message, update.error.data_json)
}

base64_sextet :: proc(byte: u8) -> (u8, bool) {
	switch {
	case byte >= 'A' && byte <= 'Z': return byte-'A', true
	case byte >= 'a' && byte <= 'z': return byte-'a'+26, true
	case byte >= '0' && byte <= '9': return byte-'0'+52, true
	case byte == '+': return 62, true
	case byte == '/': return 63, true
	}
	return 0, false
}

decode_timestamp :: proc(encoded: string) -> (u64, bool) {
	// An eight-byte Convex timestamp has exactly eleven base64 digits plus one
	// padding byte. The low two bits of digit eleven must be zero canonically.
	if len(encoded) != 12 || encoded[11] != '=' { return 0, false }
	bytes: [8]u8
	buffer: u32
	bits := 0
	byte_index := 0
	for index in 0..<11 {
		value, ok := base64_sextet(encoded[index])
		if !ok { return 0, false }
		if index == 10 && value & 0x03 != 0 { return 0, false }
		buffer = (buffer << 6) | u32(value)
		bits += 6
		if bits >= 8 {
			bits -= 8
			if byte_index >= len(bytes) { return 0, false }
			bytes[byte_index] = u8((buffer >> u32(bits)) & 0xff)
			byte_index += 1
			if bits == 0 { buffer = 0 } else { buffer &= (u32(1) << u32(bits))-1 }
		}
	}
	if byte_index != len(bytes) || bits != 2 || buffer != 0 { return 0, false }
	answer: u64
	for index in 0..<8 { answer |= u64(bytes[index]) << u64(8*index) }
	return answer, true
}

state_version :: proc(value: json.Value, label: string) -> (version: Remote_Version, err: Error) {
	object, ok := as_object(value)
	if !ok { return {}, make_error(.Protocol, fmt.tprintf("%s is not an object", label)) }
	version.query_set, err = required_u32(object, "querySet")
	if err.kind != .None { return }
	version.identity, err = required_u32(object, "identity")
	if err.kind != .None { return }
	timestamp, timestamp_err := required_string(object, "ts")
	if timestamp_err.kind != .None { return {}, timestamp_err }
	if _, valid := decode_timestamp(timestamp); !valid { return {}, make_error(.Protocol, fmt.tprintf("%s timestamp is not canonical", label)) }
	version.timestamp = strings.clone(timestamp)
	return version, {}
}

versions_equal :: proc(left, right: Remote_Version) -> bool {
	return left.query_set == right.query_set && left.identity == right.identity && left.timestamp == right.timestamp
}

Pending_Update :: struct { query_id: u32, update: Update, removed: bool }

process_server_message :: proc(owner: ^Live_Owner, source: string) -> (err: Error) {
	root, parse_err := parse_json(source, "Live server message")
	if parse_err.kind != .None { return parse_err }
	defer json.destroy_value(root)
	object, ok := as_object(root)
	if !ok { return make_error(.Protocol, "Live server message is not an object") }
	type_name, type_err := required_string(object, "type")
	if type_err.kind != .None { return type_err }
	if type_name == "Ping" || type_name == "MutationResponse" || type_name == "ActionResponse" {
		owner.reconnect_backoff = INITIAL_RECONNECT_BACKOFF
		return {}
	}
	if type_name == "TransitionChunk" { return make_error(.Protocol, "TransitionChunk assembly is not implemented") }
	if type_name == "FatalError" || type_name == "AuthError" {
		message, message_err := required_string(object, "error")
		if message_err.kind != .None { return message_err }
		return make_error(.Protocol, fmt.tprintf("%s: %s", type_name, message))
	}
	if type_name != "Transition" { return make_error(.Protocol, fmt.tprintf("unknown Live server message %s", type_name)) }
	start_value, exists := member(object, "startVersion")
	if !exists { return make_error(.Protocol, "Transition omitted startVersion") }
	start, start_err := state_version(start_value, "Transition startVersion")
	if start_err.kind != .None { return start_err }
	defer delete(start.timestamp)
	if !versions_equal(start, owner.remote_version) { return make_error(.Protocol, "Transition startVersion does not match local state") }
	end_value, end_exists := member(object, "endVersion")
	if !end_exists { return make_error(.Protocol, "Transition omitted endVersion") }
	end, end_err := state_version(end_value, "Transition endVersion")
	if end_err.kind != .None { return end_err }
	defer delete(end.timestamp)
	mods_value, mods_exists := member(object, "modifications")
	if !mods_exists { return make_error(.Protocol, "Transition omitted modifications") }
	mods, mods_ok := as_array(mods_value)
	if !mods_ok || len(mods) > 1024 { return make_error(.Protocol, "Transition modifications is not a bounded array") }
	pending := make([dynamic]Pending_Update, 0, len(mods))
	defer {
		for &item in pending { destroy_update(&item.update) }
		delete(pending)
	}
	seen := make(map[u32]bool)
	defer delete_map(seen)
	for mod_value in mods {
		mod, object_ok := as_object(mod_value)
		if !object_ok { return make_error(.Protocol, "Transition modification is not an object") }
		kind, kind_err := required_string(mod, "type")
		if kind_err.kind != .None { return kind_err }
		query_id, id_err := required_u32(mod, "queryId")
		if id_err.kind != .None { return id_err }
		if seen[query_id] { return make_error(.Protocol, "Transition modified one query more than once") }
		seen[query_id] = true
		item := Pending_Update{query_id = query_id}
		switch kind {
		case "QueryUpdated":
			if !owner.remote_active[query_id] { return make_error(.Protocol, "QueryUpdated refers to an inactive query") }
			value, value_exists := member(mod, "value")
			if !value_exists { return make_error(.Protocol, "QueryUpdated omitted value") }
			item.update.value_json, err = value_json(value)
			if err.kind != .None { return }
			item.update.logs, err = clone_logs(mod)
			if err.kind != .None { destroy_update(&item.update); return }
		case "QueryFailed":
			if !owner.remote_active[query_id] { return make_error(.Protocol, "QueryFailed refers to an inactive query") }
			message, message_err := required_string(mod, "errorMessage")
			if message_err.kind != .None { return message_err }
			data_text := ""
			if data, data_exists := member(mod, "errorData"); data_exists {
				data_text, err = value_json(data)
				if err.kind != .None { return }
			}
			logs, logs_err := clone_logs(mod)
			if logs_err.kind != .None { delete(data_text); return logs_err }
			item.update.error = make_error(.Function, message, data_text, logs)
			delete(data_text)
		case "QueryRemoved": item.removed = true
		case: return make_error(.Protocol, fmt.tprintf("unknown Transition modification %s", kind))
		}
		append(&pending, item)
	}

	// Commit the complete transition before any subscriber observes it.
	delete(owner.remote_version.timestamp)
	owner.remote_version = {end.query_set, end.identity, strings.clone(end.timestamp)}
	if timestamp, valid := decode_timestamp(end.timestamp); valid && (!owner.have_timestamp || timestamp > owner.max_observed_number) {
		owner.have_timestamp = true
		owner.max_observed_number = timestamp
		delete(owner.max_observed_timestamp)
		owner.max_observed_timestamp = strings.clone(end.timestamp)
	}
	sort_pending_by_id(pending[:])
	for &item in pending {
		if item.removed { continue }
		if sub, active := owner.active[item.query_id]; active {
			publish(sub, item.update)
			item.update = {}
		}
	}
	owner.reconnect_backoff = INITIAL_RECONNECT_BACKOFF
	return {}
}

// The bounded collections are tiny. These explicit insertion sorts avoid a
// comparator closure carrying owner state and keep publication deterministic.
sort_subscriptions_by_id :: proc(items: []^Subscription) {
	for index in 1..<len(items) {
		cursor := index
		for cursor > 0 && items[cursor].query_id < items[cursor-1].query_id {
			items[cursor], items[cursor-1] = items[cursor-1], items[cursor]
			cursor -= 1
		}
	}
}

sort_pending_by_id :: proc(items: []Pending_Update) {
	for index in 1..<len(items) {
		cursor := index
		for cursor > 0 && items[cursor].query_id < items[cursor-1].query_id {
			items[cursor], items[cursor-1] = items[cursor-1], items[cursor]
			cursor -= 1
		}
	}
}
