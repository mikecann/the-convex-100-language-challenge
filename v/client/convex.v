module convex

import sync
import x.json2

// Convex from V. One `Client` speaks both surfaces this demonstration covers:
// the documented JSON HTTP function API, and the pinned experimental sync
// profile behind `subscribe`. Both are implemented in V in this directory; the
// only borrowed machinery is ordinary sockets, TLS, JSON, and RFC 6455 framing.
pub const client_version = 'v-0.1.0'
pub const max_function_path_bytes = 512

// Result is one successful Convex function outcome.
pub struct Result {
pub:
	value json2.Any = json2.Any(json2.null)
	logs  []string
}

pub struct Client {
pub:
	endpoint Endpoint
mut:
	auth_mutex &sync.Mutex = unsafe { nil }
	auth_token string
	live       &Live = unsafe { nil }
	closed     bool
}

// new_client parses and validates the deployment origin once. Nothing is
// dialled here, so constructing a client cannot block on the network.
pub fn new_client(deployment_url string) !&Client {
	endpoint := parse_endpoint(deployment_url)!
	return &Client{
		endpoint:   endpoint
		auth_mutex: sync.new_mutex()
	}
}

// set_auth replaces the bearer token used by later calls. An empty token clears
// authentication, which is what the shared bearer-token lifecycle test drives.
pub fn (mut client Client) set_auth(token string) ! {
	if client.closed {
		return closed_error('setAuth', 'client is closed')
	}
	if !header_safe(token) {
		return protocol_error('setAuth', 'authentication token contains control characters')
	}
	utf8_scalars(token) or {
		return protocol_error('setAuth', 'authentication token is not valid UTF-8')
	}
	client.auth_mutex.@lock()
	client.auth_token = token
	client.auth_mutex.unlock()
}

fn (mut client Client) token() string {
	client.auth_mutex.@lock()
	defer {
		client.auth_mutex.unlock()
	}
	return client.auth_token
}

// validate_function_path keeps a malformed reference from becoming an opaque
// server error. Convex function references are `module:function`, and the
// shared adapter schema requires at least three characters.
fn validate_function_path(path string, operation string) ! {
	if path.len < 3 || path.len > max_function_path_bytes {
		return protocol_error(operation, 'function path must be 3 to ${max_function_path_bytes} bytes')
	}
	utf8_scalars(path) or { return protocol_error(operation, 'function path is not valid UTF-8') }
	if !header_safe(path) {
		return protocol_error(operation, 'function path contains control characters')
	}
	colon := index_of_byte(path, `:`) or {
		return protocol_error(operation, 'function path must be module:function')
	}
	if colon == 0 || colon == path.len - 1 {
		return protocol_error(operation, 'function path must be module:function')
	}
}

pub fn (mut client Client) query(path string, args map[string]json2.Any) !Result {
	return client.call('query', path, args)
}

pub fn (mut client Client) mutation(path string, args map[string]json2.Any) !Result {
	return client.call('mutation', path, args)
}

pub fn (mut client Client) action(path string, args map[string]json2.Any) !Result {
	return client.call('action', path, args)
}

fn (mut client Client) call(operation string, path string, args map[string]json2.Any) !Result {
	if client.closed {
		return closed_error(operation, 'client is closed')
	}
	validate_function_path(path, operation)!
	mut request := map[string]json2.Any{}
	request['path'] = json2.Any(path)
	request['args'] = json2.Any(args.clone())
	request['format'] = json2.Any('json')
	body := encode_json(json2.Any(request))
	if body.len > max_http_request_bytes {
		return protocol_error(operation, 'request exceeds ${max_http_request_bytes} bytes')
	}
	response := http_post_json(client.endpoint, '/api/${operation}', body, client.token(),
		client_version) or {
		return wrap_error(err, kind_transport_error, operation, '${operation} transport failed')
	}
	return decode_envelope(response, operation)
}

// decode_envelope reads the Convex envelope before deciding what an HTTP status
// means. A real function rejection legitimately arrives with a non-2xx status,
// so the status alone cannot classify the outcome - but a success-shaped body
// still may not arrive with one.
fn decode_envelope(response HttpResponse, operation string) !Result {
	if response.body.len == 0 {
		return transport_error(operation, 'HTTP ${response.status_code} response had an empty body')
	}
	envelope := decode_json_object(response.body, operation) or {
		// A malformed successful response is a protocol violation. For a
		// non-success HTTP response there is no valid Convex envelope to inspect,
		// so keep the failure at the transport boundary instead.
		if response.status_code >= 200 && response.status_code <= 299 {
			return wrap_error(err, kind_protocol_error, operation, 'Convex response envelope was malformed')
		}
		return transport_error(operation, 'HTTP ${response.status_code} response was not a JSON object')
	}
	status := string_field(envelope, 'status') or {
		return protocol_error(operation, 'Convex envelope is missing a string status')
	}
	logs := log_lines(envelope, operation)!
	match status {
		'success' {
			if response.status_code < 200 || response.status_code > 299 {
				return protocol_error(operation, 'HTTP ${response.status_code} cannot carry a successful Convex result')
			}
			value := envelope['value'] or {
				return protocol_error(operation, 'Convex success envelope is missing value')
			}
			return Result{
				value: value
				logs:  logs
			}
		}
		'error' {
			message := string_field(envelope, 'errorMessage') or {
				return protocol_error(operation, 'Convex error envelope is missing errorMessage')
			}
			return function_error(operation, message, envelope['errorData'] or {
				json2.Any(json2.null)
			}, logs)
		}
		else {
			return protocol_error(operation, 'unknown Convex envelope status: ${status}')
		}
	}
}

fn (mut client Client) ensure_live() !&Live {
	if client.closed {
		return closed_error('live', 'client is closed')
	}
	if client.live == unsafe { nil } {
		client.live = new_live(client.endpoint, client_version)!
	}
	return client.live
}

// subscribe starts or replaces a Live subscription and returns its bounded
// relay. The first delivery is the query's current value; later deliveries
// arrive as Convex recomputes it.
pub fn (mut client Client) subscribe(key string, path string, args map[string]json2.Any) !&Relay {
	mut live := client.ensure_live()!
	return live.subscribe(key, path, args)
}

pub fn (mut client Client) unsubscribe(key string) ! {
	if client.live == unsafe { nil } {
		return
	}
	mut live := client.live
	live.unsubscribe(key)!
}

// debug_disconnect_for_adapter is test-only. The shared conformance controller
// uses it to prove five real reconnects; manifest.yaml declares it under
// adapter.adapterOnlyCommands, and no example or README teaches it as part of
// the client API.
pub fn (mut client Client) debug_disconnect_for_adapter() !u64 {
	if client.live == unsafe { nil } {
		return transport_error('debugDisconnect', 'no Live connection is active')
	}
	mut live := client.live
	return live.debug_disconnect()
}

pub fn (mut client Client) live_connection_count() int {
	if client.live == unsafe { nil } {
		return 0
	}
	mut live := client.live
	return live.connection_count()
}

// close retires the Live worker and refuses later calls. It is safe to call
// more than once, which matters because the example and the adapter both defer
// it.
pub fn (mut client Client) close() {
	if client.closed {
		return
	}
	client.closed = true
	if client.live != unsafe { nil } {
		mut live := client.live
		live.close()
	}
}
