package convex

import "core:encoding/base64"
import "core:crypto/legacy/sha1"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:testing"
import "core:thread"
import "core:time"

@test
json_budget_rejects_hostile_shapes :: proc(t: ^testing.T) {
	deep: strings.Builder
	strings.builder_init(&deep)
	defer strings.builder_destroy(&deep)
	for _ in 0..<MAX_JSON_DEPTH+1 { strings.write_byte(&deep, '[') }
	strings.write_byte(&deep, '0')
	for _ in 0..<MAX_JSON_DEPTH+1 { strings.write_byte(&deep, ']') }
	err := check_json_budget(strings.to_string(deep), "hostile JSON")
	testing.expect_value(t, err.kind, Error_Kind.Protocol)
	destroy_error(&err)

	dense: strings.Builder
	strings.builder_init(&dense)
	defer strings.builder_destroy(&dense)
	strings.write_byte(&dense, '[')
	for index in 0..<MAX_JSON_NODES+1 {
		if index > 0 { strings.write_byte(&dense, ',') }
		strings.write_byte(&dense, '0')
	}
	strings.write_byte(&dense, ']')
	err = check_json_budget(strings.to_string(dense), "hostile JSON")
	testing.expect_value(t, err.kind, Error_Kind.Protocol)
	destroy_error(&err)
}

@test
timestamp_order_is_little_endian :: proc(t: ^testing.T) {
	before, ok_before := decode_timestamp("/wAAAAAAAAA=") // 255
	after, ok_after := decode_timestamp("AAEAAAAAAAA=")  // 256
	testing.expect(t, ok_before && ok_after)
	testing.expect_value(t, before, u64(255))
	testing.expect_value(t, after, u64(256))
	testing.expect(t, after > before)
}

make_test_subscription :: proc(owner: ^Live_Owner, id: u32) -> ^Subscription {
	sub := new(Subscription)
	sub.query_id = id
	// These direct publication tests do not run an owner thread. Leaving owner
	// nil lets teardown destroy the fixture instead of queuing an impossible
	// Remove command against the stack-only owner.
	sub.owner = nil
	sub.active = true
	sub.path = strings.clone("demo:state")
	sub.args_json = strings.clone(`{"room":"test"}`)
	updates, allocation_err := chan.create_buffered(chan.Chan(Update), 1, context.allocator)
	assert(allocation_err == nil)
	sub.updates = updates
	owner.active[id] = sub
	owner.remote_active[id] = true
	return sub
}

@test
transition_is_atomic_and_query_failure_recovers :: proc(t: ^testing.T) {
	owner: Live_Owner
	owner.active = make(map[u32]^Subscription)
	defer delete_map(owner.active)
	owner.remote_active = make(map[u32]bool)
	defer delete_map(owner.remote_active)
	owner.remote_version = {0, 0, strings.clone(INITIAL_TIMESTAMP)}
	defer delete(owner.remote_version.timestamp)
	defer delete(owner.max_observed_timestamp)
	sub := make_test_subscription(&owner, 1)
	defer subscription_destroy(sub)

	failed := `{"type":"Transition","startVersion":{"querySet":0,"identity":0,"ts":"AAAAAAAAAAA="},"endVersion":{"querySet":1,"identity":0,"ts":"AQAAAAAAAAA="},"modifications":[{"type":"QueryFailed","queryId":1,"errorMessage":"empty","errorData":{"code":"ROOM_EMPTY"},"logLines":["failed"]}]}`
	err := process_server_message(&owner, failed)
	testing.expect_value(t, err.kind, Error_Kind.None)
	update, ok := subscription_recv(sub, time.Second)
	testing.expect(t, ok)
	testing.expect_value(t, update.error.kind, Error_Kind.Function)
	testing.expect(t, strings.contains(update.error.data_json, "ROOM_EMPTY"))
	destroy_update(&update)

	recovered := `{"type":"Transition","startVersion":{"querySet":1,"identity":0,"ts":"AQAAAAAAAAA="},"endVersion":{"querySet":1,"identity":0,"ts":"AgAAAAAAAAA="},"modifications":[{"type":"QueryUpdated","queryId":1,"value":{"count":1},"logLines":["recovered"]}]}`
	err = process_server_message(&owner, recovered)
	testing.expect_value(t, err.kind, Error_Kind.None)
	update, ok = subscription_recv(sub, time.Second)
	testing.expect(t, ok)
	testing.expect_value(t, update.error.kind, Error_Kind.None)
	testing.expect(t, strings.contains(update.value_json, `"count":1`))
	destroy_update(&update)

	// A mismatched transition fails before any new update crosses the commit.
	mismatched := `{"type":"Transition","startVersion":{"querySet":99,"identity":0,"ts":"AgAAAAAAAAA="},"endVersion":{"querySet":100,"identity":0,"ts":"AwAAAAAAAAA="},"modifications":[{"type":"QueryUpdated","queryId":1,"value":{"count":99}}]}`
	err = process_server_message(&owner, mismatched)
	testing.expect_value(t, err.kind, Error_Kind.Protocol)
	destroy_error(&err)
	_, unexpected := chan.try_recv(sub.updates)
	testing.expect(t, !unexpected)
}

@test
slow_consumer_keeps_only_newest_bounded_update :: proc(t: ^testing.T) {
	owner: Live_Owner
	owner.active = make(map[u32]^Subscription)
	defer delete_map(owner.active)
	owner.remote_active = make(map[u32]bool)
	defer delete_map(owner.remote_active)
	sub := make_test_subscription(&owner, 1)
	defer subscription_destroy(sub)
	for count in 0..<20 {
		publish(sub, Update{value_json = fmt.aprintf(`{{"count":%d}}`, count)})
	}
	testing.expect_value(t, chan.len(sub.updates), 1)
	update, ok := subscription_recv(sub, time.Second)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(update.value_json, `"count":19`))
	testing.expect(t, update.cost <= MAX_WIRE_BYTES+4096)
	destroy_update(&update)
}

@test
timed_out_add_is_rolled_back_without_an_orphan :: proc(t: ^testing.T) {
	client, create_err := create("http://127.0.0.1:1")
	testing.expect_value(t, create_err.kind, Error_Kind.None)
	defer destroy(client)
	sub, subscribe_err := subscribe_with_completion_delay_for_test(
		client,
		"demo:state",
		`{"room":"abandoned"}`,
		150*time.Millisecond,
		20*time.Millisecond,
	)
	testing.expect(t, sub == nil)
	testing.expect_value(t, subscribe_err.kind, Error_Kind.Timeout)
	destroy_error(&subscribe_err)

	// This inspection command is an owner-thread barrier. It cannot run until
	// the delayed Add has observed abandonment and completed its rollback.
	active_count, connected, inspect_err := owner_state_for_test(client)
	testing.expect_value(t, inspect_err.kind, Error_Kind.None)
	testing.expect_value(t, active_count, 0)
	testing.expect(t, !connected)
	destroy_error(&inspect_err)
}

Raw_HTTP_Mode :: enum { Malformed, Oversized, Stalled, Success_4xx, Success_5xx }

Raw_HTTP_Peer :: struct {
	listener: net.TCP_Socket,
	mode:     Raw_HTTP_Mode,
}

raw_http_peer :: proc(data: rawptr) {
	peer := cast(^Raw_HTTP_Peer)data
	socket, _, err := net.accept_tcp(peer.listener)
	if err != nil { return }
	defer net.close(socket)
	request: [8192]u8
	_, _ = net.recv_tcp(socket, request[:])
	switch peer.mode {
	case .Malformed:
		response := "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\n{"
		_, _ = net.send_tcp(socket, transmute([]u8)response)
	case .Oversized:
		header := fmt.aprintf("HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", MAX_WIRE_BYTES+1)
		_, _ = net.send_tcp(socket, transmute([]u8)header)
		delete(header)
		chunk: [8192]u8
		for &byte in chunk { byte = 'x' }
		remaining := MAX_WIRE_BYTES+1
		for remaining > 0 {
			amount := min(remaining, len(chunk))
			if _, send_err := net.send_tcp(socket, chunk[:amount]); send_err != nil { break }
			remaining -= amount
		}
	case .Stalled:
		response := "HTTP/1.1 200 OK\r\nContent-Length: 10\r\nConnection: close\r\n\r\n{"
		_, _ = net.send_tcp(socket, transmute([]u8)response)
		time.sleep(200 * time.Millisecond)
	case .Success_4xx:
		body := `{"status":"success","value":{"count":4},"logLines":[]}`
		response := fmt.aprintf("HTTP/1.1 400 Bad Request\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body)
		_, _ = net.send_tcp(socket, transmute([]u8)response)
		delete(response)
	case .Success_5xx:
		body := `{"status":"success","value":{"count":5},"logLines":[]}`
		response := fmt.aprintf("HTTP/1.1 503 Service Unavailable\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body)
		_, _ = net.send_tcp(socket, transmute([]u8)response)
		delete(response)
	}
}

run_http_peer :: proc(t: ^testing.T, mode: Raw_HTTP_Mode, timeout: time.Duration) -> Error {
	listener, listen_err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	testing.expect_value(t, listen_err, nil)
	defer net.close(listener)
	endpoint, endpoint_err := net.bound_endpoint(listener)
	testing.expect_value(t, endpoint_err, nil)
	peer := Raw_HTTP_Peer{listener = listener, mode = mode}
	peer_thread := thread.create_and_start_with_data(&peer, raw_http_peer, context)
	defer thread.destroy(peer_thread)
	url := fmt.aprintf("http://127.0.0.1:%d", endpoint.port)
	defer delete(url)
	client, create_err := create(url)
	testing.expect_value(t, create_err.kind, Error_Kind.None)
	defer destroy(client)
	_, err := query(client, "demo:state", `{}`, timeout)
	return err
}

@test
hostile_http_peer_is_bounded_and_classified :: proc(t: ^testing.T) {
	modes := [?]Raw_HTTP_Mode{
		Raw_HTTP_Mode.Malformed,
		Raw_HTTP_Mode.Oversized,
		Raw_HTTP_Mode.Stalled,
		Raw_HTTP_Mode.Success_4xx,
		Raw_HTTP_Mode.Success_5xx,
	}
	for mode in modes {
		timeout := time.Second
		if mode == .Stalled { timeout = 50 * time.Millisecond }
		started := time.tick_now()
		err := run_http_peer(t, mode, timeout)
		elapsed := time.tick_since(started)
		testing.expect(t, err.kind == .Protocol || err.kind == .Transport || err.kind == .Timeout)
		if mode == .Success_4xx || mode == .Success_5xx {
			testing.expect_value(t, err.kind, Error_Kind.Transport)
		}
		if mode == .Stalled {
			testing.expect_value(t, err.kind, Error_Kind.Timeout)
			testing.expect(t, elapsed < 500*time.Millisecond)
		}
		destroy_error(&err)
	}
}

Raw_HTTP_Recovery_Peer :: struct { listener: net.TCP_Socket, first_status: string }

raw_http_recovery_peer :: proc(data: rawptr) {
	peer := cast(^Raw_HTTP_Recovery_Peer)data
	for attempt in 0..<2 {
		socket, _, err := net.accept_tcp(peer.listener)
		if err != nil { return }
		request: [8192]u8
		_, _ = net.recv_tcp(socket, request[:])
		body := `{"status":"success","value":{"count":7},"logLines":[]}`
		status := peer.first_status if attempt == 0 else "200 OK"
		response := fmt.aprintf("HTTP/1.1 %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", status, len(body), body)
		_, _ = net.send_tcp(socket, transmute([]u8)response)
		delete(response)
		net.close(socket)
	}
}

run_non_2xx_recovery :: proc(t: ^testing.T, first_status: string) {
	listener, listen_err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	testing.expect_value(t, listen_err, nil)
	defer net.close(listener)
	endpoint, endpoint_err := net.bound_endpoint(listener)
	testing.expect_value(t, endpoint_err, nil)
	peer := Raw_HTTP_Recovery_Peer{listener = listener, first_status = first_status}
	peer_thread := thread.create_and_start_with_data(&peer, raw_http_recovery_peer, context)
	defer thread.destroy(peer_thread)
	url := fmt.aprintf("http://127.0.0.1:%d", endpoint.port)
	defer delete(url)
	client, create_err := create(url)
	testing.expect_value(t, create_err.kind, Error_Kind.None)
	defer destroy(client)

	_, first_err := query(client, "demo:state", `{}`)
	testing.expect_value(t, first_err.kind, Error_Kind.Transport)
	testing.expect(t, strings.contains(first_err.message, first_status[:3]))
	destroy_error(&first_err)
	result, second_err := query(client, "demo:state", `{}`)
	testing.expect_value(t, second_err.kind, Error_Kind.None)
	testing.expect(t, strings.contains(result.value_json, `"count":7`))
	destroy_result(&result)
}

@test
non_2xx_success_body_is_transport_and_the_client_recovers :: proc(t: ^testing.T) {
	run_non_2xx_recovery(t, "400 Bad Request")
	run_non_2xx_recovery(t, "503 Service Unavailable")
}

Raw_Live_Peer :: struct {
	listener:              net.TCP_Socket,
	observed_client_close: bool,
	large_fragment:        bool,
	partial_mutex:         sync.Mutex,
	partial_cond:          sync.Cond,
	partial_sent:          bool,
}

mark_partial_sent :: proc(peer: ^Raw_Live_Peer) {
	sync.mutex_lock(&peer.partial_mutex)
	peer.partial_sent = true
	sync.cond_signal(&peer.partial_cond)
	sync.mutex_unlock(&peer.partial_mutex)
}

wait_partial_sent :: proc(peer: ^Raw_Live_Peer, timeout: time.Duration) -> bool {
	deadline := time.tick_add(time.tick_now(), timeout)
	sync.mutex_lock(&peer.partial_mutex)
	defer sync.mutex_unlock(&peer.partial_mutex)
	for !peer.partial_sent {
		remaining := time.tick_diff(time.tick_now(), deadline)
		if remaining <= 0 { return false }
		_ = sync.cond_wait_with_timeout(&peer.partial_cond, &peer.partial_mutex, remaining)
	}
	return true
}

websocket_key :: proc(request: string) -> string {
	marker := "Sec-WebSocket-Key: "
	start := strings.index(request, marker)
	if start < 0 { return "" }
	start += len(marker)
	end_relative := strings.index(request[start:], "\r\n")
	if end_relative < 0 { return "" }
	return request[start:start+end_relative]
}

websocket_accept :: proc(key: string) -> string {
	magic := fmt.aprintf("%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11", key)
	defer delete(magic)
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]u8)magic)
	digest: [sha1.DIGEST_SIZE]u8
	sha1.final(&ctx, digest[:])
	return base64.encode(digest[:])
}

recv_tcp_exact :: proc(socket: net.TCP_Socket, destination: []u8) -> bool {
	used := 0
	for used < len(destination) {
		count, recv_err := net.recv_tcp(socket, destination[used:])
		if recv_err != nil || count == 0 { return false }
		used += count
	}
	return true
}

recv_masked_client_text :: proc(socket: net.TCP_Socket, payload: []u8) -> (size: int, ok: bool) {
	header: [2]u8
	if !recv_tcp_exact(socket, header[:]) { return }
	// Client messages in this fixture are complete text frames and RFC 6455
	// requires every client-to-server frame to carry a masking key.
	if header[0] != 0x81 || header[1] & 0x80 == 0 { return }
	payload_size := u64(header[1] & 0x7f)
	if payload_size == 126 {
		extended: [2]u8
		if !recv_tcp_exact(socket, extended[:]) { return }
		payload_size = u64(extended[0]) << 8 | u64(extended[1])
	} else if payload_size == 127 {
		extended: [8]u8
		if !recv_tcp_exact(socket, extended[:]) { return }
		payload_size = 0
		for byte in extended { payload_size = payload_size << 8 | u64(byte) }
	}
	if payload_size > u64(len(payload)) { return }
	mask: [4]u8
	if !recv_tcp_exact(socket, mask[:]) { return }
	size = int(payload_size)
	if !recv_tcp_exact(socket, payload[:size]) { return }
	for index in 0..<size { payload[index] = payload[index] ~ mask[index % len(mask)] }
	return size, true
}

raw_live_partial_frame_peer :: proc(data: rawptr) {
	peer := cast(^Raw_Live_Peer)data
	socket, _, err := net.accept_tcp(peer.listener)
	if err != nil { return }
	defer net.close(socket)
	request: [16*1024]u8
	used := 0
	for used < len(request) {
		count, recv_err := net.recv_tcp(socket, request[used:])
		if recv_err != nil || count == 0 { return }
		used += count
		if strings.contains(string(request[:used]), "\r\n\r\n") { break }
	}
	key := websocket_key(string(request[:used]))
	if key == "" { return }
	accept := websocket_accept(key)
	defer delete(accept)
	response := fmt.aprintf("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept)
	_, send_err := net.send_tcp(socket, transmute([]u8)response)
	delete(response)
	if send_err != nil { return }

	// Do not inject the hostile server frame until the subscription really is
	// active on this socket. Otherwise Connect itself can fail and the timeout
	// never reaches the subscription the test is meant to observe.
	client_message: [64*1024]u8
	connect_size, connect_ok := recv_masked_client_text(socket, client_message[:])
	connect_matches := strings.contains(string(client_message[:connect_size]), `"type":"Connect"`)
	if !connect_ok || !connect_matches { return }
	modify_size, modify_ok := recv_masked_client_text(socket, client_message[:])
	modify := string(client_message[:modify_size])
	if !modify_ok ||
	   !strings.contains(modify, `"type":"ModifyQuerySet"`) ||
	   !strings.contains(modify, `"queryId":0`) { return }

	if peer.large_fragment {
		// Also exercise a fragment large enough for libcurl to yield buffered data.
		partial: [4 + 8192]u8
		partial[0] = 0x81
		partial[1] = 126
		partial[2] = 0x23
		partial[3] = 0x28 // 9000 bytes, encoded in network byte order.
		for index in 4..<len(partial) { partial[index] = 'x' }
		sent := 0
		for sent < len(partial) {
			count, partial_err := net.send_tcp(socket, partial[sent:])
			if partial_err != nil || count == 0 { return }
			sent += count
		}
		mark_partial_sent(peer)
	} else {
		// The acceptance case stalls after a single payload byte. libcurl must not
		// monopolize the owner while waiting for the rest of this frame.
		partial := []u8{0x81, 10, '{'}
		_, partial_err := net.send_tcp(socket, partial)
		if partial_err != nil { return }
		mark_partial_sent(peer)
	}
	// Stay open until the client enforces its own deadline. Closing on a sleep
	// races the assertion under emulation and can turn the intended timeout into
	// an ordinary peer-close error.
	closed: [1]u8
	close_count, close_err := net.recv_tcp(socket, closed[:])
	peer.observed_client_close = close_count == 0 || close_err != nil
}

run_partial_frame_deadline :: proc(t: ^testing.T, large_fragment: bool) {
	listener, listen_err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	testing.expect_value(t, listen_err, nil)
	defer net.close(listener)
	endpoint, endpoint_err := net.bound_endpoint(listener)
	testing.expect_value(t, endpoint_err, nil)
	peer := Raw_Live_Peer{listener = listener, large_fragment = large_fragment}
	peer_thread := thread.create_and_start_with_data(&peer, raw_live_partial_frame_peer, context)
	url := fmt.aprintf("http://127.0.0.1:%d", endpoint.port)
	defer delete(url)
	client, create_err := create(url)
	testing.expect_value(t, create_err.kind, Error_Kind.None)
	defer destroy(client)
	sub, subscribe_err := subscribe(client, "demo:state", `{}`)
	testing.expect_value(t, subscribe_err.kind, Error_Kind.None)
	defer subscription_destroy(sub)
	started := time.tick_now()
	update, received := subscription_recv(sub, LIVE_FRAME_TIMEOUT+2*time.Second)
	testing.expect(t, received)
	testing.expect_value(t, update.error.kind, Error_Kind.Transport)
	testing.expect(t, strings.contains(update.error.message, "frame deadline"))
	testing.expect(t, time.tick_since(started) < LIVE_FRAME_TIMEOUT+time.Second)
	destroy_update(&update)
	thread.destroy(peer_thread)
	testing.expect(t, peer.observed_client_close)
}

@test
hostile_live_peer_partial_frame_has_absolute_deadline :: proc(t: ^testing.T) {
	run_partial_frame_deadline(t, false)
}

@test
hostile_live_peer_large_partial_frame_has_absolute_deadline :: proc(t: ^testing.T) {
	run_partial_frame_deadline(t, true)
}

@test
close_during_blocked_live_receive_has_bounded_teardown :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	testing.expect_value(t, listen_err, nil)
	defer net.close(listener)
	endpoint, endpoint_err := net.bound_endpoint(listener)
	testing.expect_value(t, endpoint_err, nil)
	peer := Raw_Live_Peer{listener = listener}
	peer_thread := thread.create_and_start_with_data(&peer, raw_live_partial_frame_peer, context)
	url := fmt.aprintf("http://127.0.0.1:%d", endpoint.port)
	defer delete(url)
	client, create_err := create(url)
	testing.expect_value(t, create_err.kind, Error_Kind.None)
	sub, subscribe_err := subscribe(client, "demo:state", `{}`)
	testing.expect_value(t, subscribe_err.kind, Error_Kind.None)
	testing.expect(t, wait_partial_sent(&peer, time.Second))
	// Let the owner enter curl_ws_recv before Close is queued.
	time.sleep(50 * time.Millisecond)
	started := time.tick_now()
	destroy(client)
	testing.expect(t, time.tick_since(started) < LIVE_FRAME_TIMEOUT+time.Second)
	subscription_destroy(sub)
	thread.destroy(peer_thread)
	testing.expect(t, peer.observed_client_close)
}

send_tcp_all :: proc(socket: net.TCP_Socket, bytes: []u8) -> bool {
	sent := 0
	for sent < len(bytes) {
		count, send_err := net.send_tcp(socket, bytes[sent:])
		if send_err != nil || count == 0 { return false }
		sent += count
	}
	return true
}

wait_for_tcp_close :: proc(socket: net.TCP_Socket) -> bool {
	buffer: [4096]u8
	for {
		count, recv_err := net.recv_tcp(socket, buffer[:])
		if count == 0 || recv_err != nil { return true }
	}
}

server_text_frame :: proc(payload: string) -> [dynamic]u8 {
	frame := make([dynamic]u8, 0, len(payload)+10)
	append(&frame, u8(0x81))
	if len(payload) < 126 {
		append(&frame, u8(len(payload)))
	} else if len(payload) <= 0xffff {
		append(&frame, u8(126), u8(len(payload) >> 8), u8(len(payload)))
	} else {
		append(&frame, u8(127))
		length := u64(len(payload))
		append(
			&frame,
			u8(length >> u64(56)), u8(length >> u64(48)),
			u8(length >> u64(40)), u8(length >> u64(32)),
			u8(length >> u64(24)), u8(length >> u64(16)),
			u8(length >> u64(8)), u8(length),
		)
	}
	append(&frame, ..transmute([]u8)payload)
	return frame
}

recv_upgrade_request :: proc(socket: net.TCP_Socket, request: []u8) -> (string, bool) {
	used := 0
	for used < len(request) {
		count, recv_err := net.recv_tcp(socket, request[used:])
		if recv_err != nil || count == 0 { return "", false }
		used += count
		text := string(request[:used])
		if strings.contains(text, "\r\n\r\n") {
			key := websocket_key(text)
			return key, key != ""
		}
	}
	return "", false
}

validate_live_client_start :: proc(socket: net.TCP_Socket) -> bool {
	message: [64*1024]u8
	connect_size, connect_ok := recv_masked_client_text(socket, message[:])
	if !connect_ok || !strings.contains(string(message[:connect_size]), `"type":"Connect"`) { return false }
	modify_size, modify_ok := recv_masked_client_text(socket, message[:])
	modify := string(message[:modify_size])
	return modify_ok &&
	       strings.contains(modify, `"type":"ModifyQuerySet"`) &&
	       strings.contains(modify, `"type":"Add"`) &&
	       strings.contains(modify, `"queryId":0`)
}

Coalesced_Mode :: enum { Upgrade_And_Frame, Two_Complete, Complete_Then_Partial, Idle_After_Complete }

Coalesced_Live_Peer :: struct {
	listener:              net.TCP_Socket,
	mode:                  Coalesced_Mode,
	validated_client:      bool,
	observed_client_close: bool,
	partial_duration:      time.Duration,
}

coalesced_live_peer :: proc(data: rawptr) {
	peer := cast(^Coalesced_Live_Peer)data
	socket, _, accept_err := net.accept_tcp(peer.listener)
	if accept_err != nil { return }
	defer net.close(socket)
	request: [16*1024]u8
	key, request_ok := recv_upgrade_request(socket, request[:])
	if !request_ok { return }
	accept := websocket_accept(key)
	defer delete(accept)
	response := fmt.aprintf("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept)
	defer delete(response)
	first_transition := `{"type":"Transition","startVersion":{"querySet":0,"identity":0,"ts":"AAAAAAAAAAA="},"endVersion":{"querySet":1,"identity":0,"ts":"AQAAAAAAAAA="},"modifications":[{"type":"QueryUpdated","queryId":0,"value":{"count":9},"logLines":[]}]}`
	first_frame := server_text_frame(first_transition)
	defer delete(first_frame)
	if peer.mode == .Upgrade_And_Frame {
		packet := make([dynamic]u8, 0, len(response)+len(first_frame))
		defer delete(packet)
		append(&packet, ..transmute([]u8)response)
		append(&packet, ..first_frame[:])
		if !send_tcp_all(socket, packet[:]) { return }
	} else if !send_tcp_all(socket, transmute([]u8)response) {
		return
	}
	peer.validated_client = validate_live_client_start(socket)
	if !peer.validated_client { return }
	if peer.mode != .Upgrade_And_Frame {
		second_transition := `{"type":"Transition","startVersion":{"querySet":1,"identity":0,"ts":"AQAAAAAAAAA="},"endVersion":{"querySet":1,"identity":0,"ts":"AgAAAAAAAAA="},"modifications":[{"type":"QueryUpdated","queryId":0,"value":{"count":10},"logLines":[]}]}`
		second_frame := server_text_frame(second_transition)
		defer delete(second_frame)
		packet := make([dynamic]u8, 0, len(first_frame)+len(second_frame))
		defer delete(packet)
		append(&packet, ..first_frame[:])
		switch peer.mode {
		case .Two_Complete:
			append(&packet, ..second_frame[:])
		case .Complete_Then_Partial:
			// One TCP write leaves a complete frame followed by a permanently
			// incomplete successor in libcurl's private receive buffer.
			append(&packet, ..second_frame[:3])
		case .Idle_After_Complete:
		case .Upgrade_And_Frame:
		}
		started := time.tick_now()
		if !send_tcp_all(socket, packet[:]) { return }
		peer.observed_client_close = wait_for_tcp_close(socket)
		if peer.mode == .Complete_Then_Partial { peer.partial_duration = time.tick_since(started) }
		return
	}
	peer.observed_client_close = wait_for_tcp_close(socket)
}

@test
upgrade_and_complete_frame_in_one_tcp_write_is_delivered :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	testing.expect_value(t, listen_err, nil)
	defer net.close(listener)
	endpoint, endpoint_err := net.bound_endpoint(listener)
	testing.expect_value(t, endpoint_err, nil)
	peer := Coalesced_Live_Peer{listener = listener, mode = .Upgrade_And_Frame}
	peer_thread := thread.create_and_start_with_data(&peer, coalesced_live_peer, context)
	url := fmt.aprintf("http://127.0.0.1:%d", endpoint.port)
	defer delete(url)
	client, create_err := create(url)
	testing.expect_value(t, create_err.kind, Error_Kind.None)
	sub, subscribe_err := subscribe(client, "demo:state", `{}`)
	testing.expect_value(t, subscribe_err.kind, Error_Kind.None)
	update, received := subscription_recv(sub, time.Second)
	testing.expect(t, received)
	testing.expect_value(t, update.error.kind, Error_Kind.None)
	testing.expect(t, strings.contains(update.value_json, `"count":9`))
	destroy_update(&update)
	subscription_destroy(sub)
	destroy(client)
	thread.destroy(peer_thread)
	testing.expect(t, peer.validated_client)
	testing.expect(t, peer.observed_client_close)
}

@test
two_complete_frames_in_one_tcp_write_are_both_drained :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	testing.expect_value(t, listen_err, nil)
	defer net.close(listener)
	endpoint, endpoint_err := net.bound_endpoint(listener)
	testing.expect_value(t, endpoint_err, nil)
	peer := Coalesced_Live_Peer{listener = listener, mode = .Two_Complete}
	peer_thread := thread.create_and_start_with_data(&peer, coalesced_live_peer, context)
	url := fmt.aprintf("http://127.0.0.1:%d", endpoint.port)
	defer delete(url)
	client, create_err := create(url)
	testing.expect_value(t, create_err.kind, Error_Kind.None)
	sub, subscribe_err := subscribe(client, "demo:state", `{}`)
	testing.expect_value(t, subscribe_err.kind, Error_Kind.None)
	latest := ""
	for _ in 0..<2 {
		update, received := subscription_recv(sub, time.Second)
		if !received { break }
		testing.expect_value(t, update.error.kind, Error_Kind.None)
		delete(latest)
		latest = strings.clone(update.value_json)
		destroy_update(&update)
		if strings.contains(latest, `"count":10`) { break }
	}
	testing.expect(t, strings.contains(latest, `"count":10`))
	delete(latest)
	subscription_destroy(sub)
	destroy(client)
	thread.destroy(peer_thread)
	testing.expect(t, peer.validated_client)
	testing.expect(t, peer.observed_client_close)
}

@test
partial_frame_coalesced_after_complete_frame_keeps_absolute_deadline :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	testing.expect_value(t, listen_err, nil)
	defer net.close(listener)
	endpoint, endpoint_err := net.bound_endpoint(listener)
	testing.expect_value(t, endpoint_err, nil)
	peer := Coalesced_Live_Peer{listener = listener, mode = .Complete_Then_Partial}
	peer_thread := thread.create_and_start_with_data(&peer, coalesced_live_peer, context)
	url := fmt.aprintf("http://127.0.0.1:%d", endpoint.port)
	defer delete(url)
	client, create_err := create(url)
	testing.expect_value(t, create_err.kind, Error_Kind.None)
	defer destroy(client)
	sub, subscribe_err := subscribe(client, "demo:state", `{}`)
	testing.expect_value(t, subscribe_err.kind, Error_Kind.None)
	defer subscription_destroy(sub)
	first, first_received := subscription_recv(sub, time.Second)
	testing.expect(t, first_received)
	testing.expect_value(t, first.error.kind, Error_Kind.None)
	destroy_update(&first)
	timed_out, timeout_received := subscription_recv(sub, LIVE_FRAME_TIMEOUT+2*time.Second)
	testing.expect(t, timeout_received)
	testing.expect_value(t, timed_out.error.kind, Error_Kind.Transport)
	testing.expect(t, strings.contains(timed_out.error.message, "frame deadline"))
	destroy_update(&timed_out)
	thread.destroy(peer_thread)
	testing.expect(t, peer.validated_client)
	testing.expect(t, peer.observed_client_close)
	testing.expect(t, peer.partial_duration >= LIVE_FRAME_TIMEOUT)
	testing.expect(t, peer.partial_duration < LIVE_FRAME_TIMEOUT+time.Second)
}

@test
speculative_drain_stops_after_e_again_without_busy_spin :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	testing.expect_value(t, listen_err, nil)
	defer net.close(listener)
	endpoint, endpoint_err := net.bound_endpoint(listener)
	testing.expect_value(t, endpoint_err, nil)
	peer := Coalesced_Live_Peer{listener = listener, mode = .Idle_After_Complete}
	peer_thread := thread.create_and_start_with_data(&peer, coalesced_live_peer, context)
	url := fmt.aprintf("http://127.0.0.1:%d", endpoint.port)
	defer delete(url)
	client, create_err := create(url)
	testing.expect_value(t, create_err.kind, Error_Kind.None)
	sub, subscribe_err := subscribe(client, "demo:state", `{}`)
	testing.expect_value(t, subscribe_err.kind, Error_Kind.None)
	update, received := subscription_recv(sub, time.Second)
	testing.expect(t, received)
	testing.expect_value(t, update.error.kind, Error_Kind.None)
	destroy_update(&update)
	time.sleep(100 * time.Millisecond)
	first_count, first_err := owner_forced_drains_for_test(client)
	testing.expect_value(t, first_err.kind, Error_Kind.None)
	destroy_error(&first_err)
	time.sleep(100 * time.Millisecond)
	second_count, second_err := owner_forced_drains_for_test(client)
	testing.expect_value(t, second_err.kind, Error_Kind.None)
	destroy_error(&second_err)
	testing.expect(t, first_count > 0)
	testing.expect_value(t, second_count, first_count)
	subscription_destroy(sub)
	destroy(client)
	thread.destroy(peer_thread)
	testing.expect(t, peer.validated_client)
	testing.expect(t, peer.observed_client_close)
}

Recovery_Live_Peer :: struct {
	listener:              net.TCP_Socket,
	validated_connections: int,
	observed_closes:        int,
	timeout_durations:      [2]time.Duration,
}

recovery_live_peer :: proc(data: rawptr) {
	peer := cast(^Recovery_Live_Peer)data
	for attempt in 0..<3 {
		socket, _, accept_err := net.accept_tcp(peer.listener)
		if accept_err != nil { return }
		request: [16*1024]u8
		key, request_ok := recv_upgrade_request(socket, request[:])
		if !request_ok { net.close(socket); return }
		accept := websocket_accept(key)
		response := fmt.aprintf("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept)
		delete(accept)
		if !send_tcp_all(socket, transmute([]u8)response) {
			delete(response); net.close(socket); return
		}
		delete(response)
		if !validate_live_client_start(socket) { net.close(socket); return }
		peer.validated_connections += 1
		if attempt < 2 {
			partial := []u8{0x81, 10, '{'}
			started := time.tick_now()
			if !send_tcp_all(socket, partial) { net.close(socket); return }
			closed: [1]u8
			count, close_err := net.recv_tcp(socket, closed[:])
			peer.timeout_durations[attempt] = time.tick_since(started)
			if count == 0 || close_err != nil { peer.observed_closes += 1 }
			net.close(socket)
			continue
		}
		transition := `{"type":"Transition","startVersion":{"querySet":0,"identity":0,"ts":"AAAAAAAAAAA="},"endVersion":{"querySet":1,"identity":0,"ts":"AgAAAAAAAAA="},"modifications":[{"type":"QueryUpdated","queryId":0,"value":{"recovered":true},"logLines":[]}]}`
		// Give the subscriber time to consume the second bounded error before the
		// healthy value arrives and intentionally replaces an unread update.
		time.sleep(500 * time.Millisecond)
		frame := server_text_frame(transition)
		_ = send_tcp_all(socket, frame[:])
		delete(frame)
		_ = wait_for_tcp_close(socket)
		net.close(socket)
	}
}

@test
repeated_frame_timeouts_recover_without_a_stale_watchdog :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	testing.expect_value(t, listen_err, nil)
	defer net.close(listener)
	endpoint, endpoint_err := net.bound_endpoint(listener)
	testing.expect_value(t, endpoint_err, nil)
	peer := Recovery_Live_Peer{listener = listener}
	peer_thread := thread.create_and_start_with_data(&peer, recovery_live_peer, context)
	url := fmt.aprintf("http://127.0.0.1:%d", endpoint.port)
	defer delete(url)
	client, create_err := create(url)
	testing.expect_value(t, create_err.kind, Error_Kind.None)
	sub, subscribe_err := subscribe(client, "demo:state", `{}`)
	testing.expect_value(t, subscribe_err.kind, Error_Kind.None)
	transport_errors := 0
	recovered := false
	for _ in 0..<3 {
		update, received := subscription_recv(sub, LIVE_FRAME_TIMEOUT+2*time.Second)
		testing.expect(t, received)
		if !received { break }
		if update.error.kind == .Transport {
			transport_errors += 1
			testing.expect(t, strings.contains(update.error.message, "frame deadline"))
		} else {
			testing.expect_value(t, update.error.kind, Error_Kind.None)
			recovered = strings.contains(update.value_json, `"recovered":true`)
		}
		destroy_update(&update)
		if recovered { break }
	}
	testing.expect(t, transport_errors >= 1)
	testing.expect(t, recovered)
	// Every receive watchdog is joined before socket retirement. Waiting beyond
	// the old deadline proves neither timed-out watchdog can later close the
	// healthy replacement socket, even if the OS reuses its descriptor number.
	_, unexpected := subscription_recv(sub, LIVE_FRAME_TIMEOUT+500*time.Millisecond)
	testing.expect(t, !unexpected)
	_, connected, inspect_err := owner_state_for_test(client)
	testing.expect_value(t, inspect_err.kind, Error_Kind.None)
	testing.expect(t, connected)
	destroy_error(&inspect_err)
	subscription_destroy(sub)
	destroy(client)
	thread.destroy(peer_thread)
	testing.expect_value(t, peer.validated_connections, 3)
	testing.expect_value(t, peer.observed_closes, 2)
	for duration in peer.timeout_durations {
		testing.expect(t, duration >= LIVE_FRAME_TIMEOUT)
		testing.expect(t, duration < LIVE_FRAME_TIMEOUT+2*time.Second)
	}
}

Control_Frame_Peer :: struct {
	listener:              net.TCP_Socket,
	validated_client:      bool,
	observed_client_close: bool,
	duration:              time.Duration,
}

control_frame_live_peer :: proc(data: rawptr) {
	peer := cast(^Control_Frame_Peer)data
	socket, _, accept_err := net.accept_tcp(peer.listener)
	if accept_err != nil { return }
	defer net.close(socket)
	request: [16*1024]u8
	key, request_ok := recv_upgrade_request(socket, request[:])
	if !request_ok { return }
	accept := websocket_accept(key)
	response := fmt.aprintf("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept)
	delete(accept)
	if !send_tcp_all(socket, transmute([]u8)response) { delete(response); return }
	delete(response)
	peer.validated_client = validate_live_client_start(socket)
	if !peer.validated_client { return }
	started := time.tick_now()
	// Start a fragmented text message, then keep sending valid control frames.
	// None of those pings may renew the data message's absolute deadline.
	fragment := []u8{0x01, 1, '{'}
	if !send_tcp_all(socket, fragment) { return }
	for _ in 0..<4 {
		time.sleep(800 * time.Millisecond)
		ping := []u8{0x89, 0}
		if !send_tcp_all(socket, ping) { return }
	}
	peer.observed_client_close = wait_for_tcp_close(socket)
	peer.duration = time.tick_since(started)
}

@test
control_frames_do_not_renew_a_fragmented_message_deadline :: proc(t: ^testing.T) {
	listener, listen_err := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	testing.expect_value(t, listen_err, nil)
	defer net.close(listener)
	endpoint, endpoint_err := net.bound_endpoint(listener)
	testing.expect_value(t, endpoint_err, nil)
	peer := Control_Frame_Peer{listener = listener}
	peer_thread := thread.create_and_start_with_data(&peer, control_frame_live_peer, context)
	url := fmt.aprintf("http://127.0.0.1:%d", endpoint.port)
	defer delete(url)
	client, create_err := create(url)
	testing.expect_value(t, create_err.kind, Error_Kind.None)
	defer destroy(client)
	sub, subscribe_err := subscribe(client, "demo:state", `{}`)
	testing.expect_value(t, subscribe_err.kind, Error_Kind.None)
	defer subscription_destroy(sub)
	update, received := subscription_recv(sub, LIVE_FRAME_TIMEOUT+2*time.Second)
	testing.expect(t, received)
	testing.expect_value(t, update.error.kind, Error_Kind.Transport)
	testing.expect(t, strings.contains(update.error.message, "frame deadline"))
	destroy_update(&update)
	thread.destroy(peer_thread)
	testing.expect(t, peer.validated_client)
	testing.expect(t, peer.observed_client_close)
	testing.expect(t, peer.duration >= LIVE_FRAME_TIMEOUT)
	testing.expect(t, peer.duration < LIVE_FRAME_TIMEOUT+time.Second)
}
