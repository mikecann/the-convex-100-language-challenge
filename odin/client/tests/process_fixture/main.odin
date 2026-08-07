package main

import convex "convex:."
import "core:c"
import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

BACKEND_ADDRESS :: "127.0.0.1:19091"
ADAPTER_ADDRESS :: "127.0.0.1:19092"
CONTROLLER_TIMEOUT :: 10 * time.Second

fail :: proc(message: string) -> ! {
	fmt.eprintln(message)
	os.exit(1)
}

send_all :: proc(socket: net.TCP_Socket, data: []u8) -> bool {
	offset := 0
	for offset < len(data) {
		written, err := net.send_tcp(socket, data[offset:])
		if err != nil || written <= 0 { return false }
		offset += written
	}
	return true
}

recv_exact :: proc(socket: net.TCP_Socket, data: []u8) -> bool {
	offset := 0
	for offset < len(data) {
		count, err := net.recv_tcp(socket, data[offset:])
		if err != nil || count <= 0 { return false }
		offset += count
	}
	return true
}

recv_headers :: proc(socket: net.TCP_Socket) -> (string, bool) {
	buffer := make([dynamic]u8, 0, 16*1024)
	defer delete(buffer)
	chunk: [2048]u8
	for len(buffer) < 16*1024 {
		count, err := net.recv_tcp(socket, chunk[:])
		if err != nil || count <= 0 { return "", false }
		append(&buffer, ..chunk[:count])
		if strings.contains(string(buffer[:]), "\r\n\r\n") {
			return strings.clone(string(buffer[:])), true
		}
	}
	return "", false
}

header_value :: proc(headers, name: string) -> string {
	marker := fmt.aprintf("%s: ", name)
	defer delete(marker)
	start := strings.index(headers, marker)
	if start < 0 { return "" }
	start += len(marker)
	end := strings.index(headers[start:], "\r\n")
	if end < 0 { return "" }
	return headers[start:start+end]
}

decimal :: proc(text: string) -> (int, bool) {
	if len(text) == 0 { return 0, false }
	value := 0
	for byte in transmute([]u8)text {
		if byte < '0' || byte > '9' || value > convex.MAX_WIRE_BYTES { return 0, false }
		value = value*10 + int(byte-'0')
	}
	return value, true
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

websocket_read_text :: proc(socket: net.TCP_Socket) -> (string, bool) {
	header: [2]u8
	if !recv_exact(socket, header[:]) { return "", false }
	if header[0] & 0x0f == 8 { return "", false }
	if header[0] & 0x0f != 1 || header[1] & 0x80 == 0 { return "", false }
	length := u64(header[1] & 0x7f)
	if length == 126 {
		extended: [2]u8
		if !recv_exact(socket, extended[:]) { return "", false }
		length = u64(extended[0])<<8 | u64(extended[1])
	} else if length == 127 {
		extended: [8]u8
		if !recv_exact(socket, extended[:]) { return "", false }
		length = 0
		for byte in extended { length = length<<8 | u64(byte) }
	}
	if length > u64(convex.MAX_WIRE_BYTES) { return "", false }
	mask: [4]u8
	if !recv_exact(socket, mask[:]) { return "", false }
	payload := make([]u8, int(length))
	if !recv_exact(socket, payload) { delete(payload); return "", false }
	for &byte, index in payload { byte ~= mask[index%4] }
	return string(payload), true
}

websocket_send_text :: proc(socket: net.TCP_Socket, text: string) -> bool {
	frame := make([dynamic]u8, 0, len(text)+10)
	defer delete(frame)
	append(&frame, 0x81)
	if len(text) < 126 {
		append(&frame, u8(len(text)))
	} else {
		append(&frame, 126, u8(len(text)>>8), u8(len(text)))
	}
	append(&frame, ..transmute([]u8)text)
	return send_all(socket, frame[:])
}

state_version_json :: proc(query_set: u32, timestamp: u64) -> string {
	bytes: [8]u8
	for index in 0..<8 { bytes[index] = u8(timestamp >> u64(8*index)) }
	encoded := base64.encode(bytes[:])
	defer delete(encoded)
	return fmt.aprintf(`{{"querySet":%d,"identity":0,"ts":"%s"}}`, query_set, encoded)
}

transition :: proc(start_query_set, end_query_set: u32, start_ts, end_ts: u64, modifications: string) -> string {
	start := state_version_json(start_query_set, start_ts)
	end := state_version_json(end_query_set, end_ts)
	defer delete(start)
	defer delete(end)
	return fmt.aprintf(`{{"type":"Transition","startVersion":%s,"endVersion":%s,"modifications":[%s]}}`, start, end, modifications)
}

serve_http :: proc(socket: net.TCP_Socket, headers: string, request_number: int, large: bool) {
	// Consume the request body before closing so the fixture does not inject a
	// TCP reset after writing an otherwise valid response.
	content_length, length_ok := decimal(header_value(headers, "Content-Length"))
	separator := strings.index(headers, "\r\n\r\n")
	if !length_ok || separator < 0 { return }
	if strings.contains(headers, "Expect: 100-continue") {
		interim := "HTTP/1.1 100 Continue\r\n\r\n"
		if !send_all(socket, transmute([]u8)interim) { return }
	}
	already := len(headers)-(separator+4)
	remaining := content_length-already
	chunk: [8192]u8
	for remaining > 0 {
		amount := min(remaining, len(chunk))
		if !recv_exact(socket, chunk[:amount]) { return }
		remaining -= amount
	}
	body := ""
	status := "200 OK"
	if large {
		value := strings.repeat("x", 1800*1024)
		body = fmt.aprintf(`{{"status":"success","value":"%s","logLines":[]}}`, value)
		delete(value)
	} else if request_number == 1 {
		status = "560 Convex Function Error"
		body = strings.clone(`{"status":"error","errorMessage":"fixture boom","errorData":{"code":"PROCESS_EXPECTED"},"logLines":["fixture log"]}`)
	} else {
		body = strings.clone(`{"status":"success","value":7,"logLines":[]}`)
	}
	defer delete(body)
	response := fmt.aprintf("HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", status, len(body), body)
	defer delete(response)
	_ = send_all(socket, transmute([]u8)response)
}

serve_websocket :: proc(socket: net.TCP_Socket, headers: string, connection_number: int) {
	key := header_value(headers, "Sec-WebSocket-Key")
	if key == "" { return }
	accept := websocket_accept(key)
	defer delete(accept)
	response := fmt.aprintf("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept)
	if !send_all(socket, transmute([]u8)response) { delete(response); return }
	delete(response)
	query_set: u32
	timestamp: u64
	for {
		message, ok := websocket_read_text(socket)
		if !ok { return }
		root, parse_err := convex.parse_json(message, "fixture client message")
		delete(message)
		if parse_err.kind != .None { convex.destroy_error(&parse_err); return }
		object, object_ok := convex.as_object(root)
		if !object_ok { json.destroy_value(root); return }
		type_name, type_err := convex.required_string(object, "type")
		if type_err.kind != .None { convex.destroy_error(&type_err); json.destroy_value(root); return }
		if type_name == "Connect" { json.destroy_value(root); continue }
		if type_name != "ModifyQuerySet" { json.destroy_value(root); return }
		base, base_err := convex.required_u32(object, "baseVersion")
		new_version, version_err := convex.required_u32(object, "newVersion")
		mods_value, exists := convex.member(object, "modifications")
		mods, mods_ok := convex.as_array(mods_value)
		if base_err.kind != .None || version_err.kind != .None || !exists || !mods_ok || base != query_set {
			convex.destroy_error(&base_err); convex.destroy_error(&version_err); json.destroy_value(root); return
		}
		parts: strings.Builder
		strings.builder_init(&parts)
		first_is_add := false
		first_id: u32
		for mod_value, index in mods {
			mod, valid := convex.as_object(mod_value)
			if !valid { continue }
			kind, _ := convex.required_string(mod, "type")
			id, _ := convex.required_u32(mod, "queryId")
			if index == 0 { first_is_add, first_id = kind == "Add", id }
			if index > 0 { strings.write_byte(&parts, ',') }
			if kind == "Add" {
				fmt.sbprintf(&parts, `{{"type":"QueryUpdated","queryId":%d,"value":{{"count":0}},"logLines":[]}}`, id)
			} else {
				fmt.sbprintf(&parts, `{{"type":"QueryRemoved","queryId":%d}}`, id)
			}
		}
		timestamp += 1
		encoded := transition(query_set, new_version, timestamp-1, timestamp, strings.to_string(parts))
		strings.builder_destroy(&parts)
		json.destroy_value(root)
		if !websocket_send_text(socket, encoded) { delete(encoded); return }
		delete(encoded)
		query_set = new_version
		if connection_number > 1 && first_is_add {
			timestamp += 1
			modification := fmt.aprintf(`{{"type":"QueryUpdated","queryId":%d,"value":{{"count":1}},"logLines":[]}}`, first_id)
			updated := transition(query_set, query_set, timestamp-1, timestamp, modification)
			delete(modification)
			_ = websocket_send_text(socket, updated)
			delete(updated)
		}
	}
}

backend_peer :: proc(large: bool) {
	endpoint, valid := net.parse_endpoint(BACKEND_ADDRESS)
	if !valid { fail("invalid backend fixture endpoint") }
	listener, err := net.listen_tcp(endpoint)
	if err != nil { fail("could not listen for backend fixture") }
	defer net.close(listener)
	http_count := 0
	websocket_count := 0
	for {
		socket, _, accept_err := net.accept_tcp(listener)
		if accept_err != nil { fail("backend fixture accept failed") }
		headers, ok := recv_headers(socket)
		if !ok { net.close(socket); continue }
		if strings.has_prefix(headers, "GET /api/sync ") {
			websocket_count += 1
			serve_websocket(socket, headers, websocket_count)
		} else {
			http_count += 1
			serve_http(socket, headers, http_count, large)
		}
		delete(headers)
		net.close(socket)
	}
}

Controller :: struct { socket: net.TCP_Socket, pending: [dynamic]u8 }

controller_send :: proc(controller: ^Controller, line: string) {
	if !send_all(controller.socket, transmute([]u8)line) { fail("controller write failed") }
	newline := "\n"
	if !send_all(controller.socket, transmute([]u8)newline) { fail("controller write failed") }
}

controller_line :: proc(controller: ^Controller) -> string {
	chunk: [4096]u8
	deadline := time.tick_add(time.tick_now(), CONTROLLER_TIMEOUT)
	for {
		for byte, index in controller.pending {
			if byte == '\n' {
				line := strings.clone(string(controller.pending[:index]))
				copy(controller.pending[:], controller.pending[index+1:])
				resize(&controller.pending, len(controller.pending)-index-1)
				return line
			}
		}
		remaining := time.tick_diff(time.tick_now(), deadline)
		if remaining <= 0 { fail("controller read deadline expired") }
		poll_fd := posix.pollfd{fd = posix.FD(controller.socket), events = {.IN}}
		timeout_ms := c.int(max(1, time.duration_milliseconds(remaining)))
		if posix.poll(&poll_fd, 1, timeout_ms) <= 0 { fail("controller read deadline expired") }
		count, err := net.recv_tcp(controller.socket, chunk[:])
		if err != nil || count <= 0 { fail("controller read failed") }
		append(&controller.pending, ..chunk[:count])
	}
}

expect_event :: proc(controller: ^Controller, expected_type: string, id: string = "") -> json.Object {
	line := controller_line(controller)
	root, err := convex.parse_json(line, "adapter process event")
	delete(line)
	if err.kind != .None { fail(err.message) }
	object, ok := convex.as_object(root)
	if !ok { fail("adapter process event is not an object") }
	type_name, _ := convex.required_string(object, "type")
	if type_name != expected_type { fail("adapter process event has the wrong type") }
	if id != "" {
		actual, _ := convex.required_string(object, "id")
		if actual != id { fail("adapter process event has the wrong id") }
	}
	return object
}

adapter_controller :: proc(stopped_reader: bool) {
	socket: net.TCP_Socket
	err: net.Network_Error
	// Treat a successful loopback connection as the listener-ready barrier. The
	// amd64 binary may need a moment to start under emulation, independently of
	// the per-command controller deadline below.
	for _ in 0..<1000 {
		socket, err = net.dial_tcp(ADAPTER_ADDRESS)
		if err == nil { break }
		time.sleep(10*time.Millisecond)
	}
	if err != nil { fail("could not connect to adapter TCP controller") }
	defer net.close(socket)
	controller := Controller{socket = socket}
	defer delete(controller.pending)
	if stopped_reader {
		near_limit := strings.repeat("x", 1800*1024)
		defer delete(near_limit)
		for index in 0..<20 {
			command := fmt.aprintf(`{{"id":"large-%d","op":"query","path":"demo:echo","args":{{"value":"%s"}}}}`, index, near_limit)
			written := send_all(controller.socket, transmute([]u8)command)
			newline := "\n"
			if written { written = send_all(controller.socket, transmute([]u8)newline) }
			delete(command)
			if !written { break }
		}
		time.sleep(2*time.Second)
		return
	}

	controller_send(&controller, `{"protocolVersion":1,"id":"bad","op":"hello","extra":true}`)
	_ = expect_event(&controller, "error")
	controller_send(&controller, `{"id":"failure","op":"query","path":"demo:state","args":{}}`)
	failure := expect_event(&controller, "error", "failure")
	error_value, _ := convex.member(failure, "error")
	error_object, _ := convex.as_object(error_value)
	name, _ := convex.required_string(error_object, "name")
	if name != "FunctionError" { fail("structured function error was lost") }
	data_value, data_exists := convex.member(error_object, "data")
	data_object, data_ok := convex.as_object(data_value)
	if !data_exists || !data_ok { fail("structured function error data was lost") }
	code, _ := convex.required_string(data_object, "code")
	if code != "PROCESS_EXPECTED" { fail("structured function error code changed") }
	logs_value, logs_exist := convex.member(failure, "logs")
	logs, logs_ok := convex.as_array(logs_value)
	if !logs_exist || !logs_ok || len(logs) != 1 { fail("structured function error logs were lost") }
	controller_send(&controller, `{"id":"recovery","op":"query","path":"demo:state","args":{}}`)
	_ = expect_event(&controller, "result", "recovery")

	controller_send(&controller, `{"id":"old","op":"subscribe","subscriptionId":"same","path":"demo:state","args":{}}`)
	_ = expect_event(&controller, "ack", "old")
	_ = expect_event(&controller, "subscription")
	controller_send(&controller, `{"id":"replacement","op":"subscribe","subscriptionId":"same","path":"demo:state","args":{}}`)
	_ = expect_event(&controller, "ack", "replacement")
	_ = expect_event(&controller, "subscription")
	controller_send(&controller, `{"id":"unsubscribe","op":"unsubscribe","subscriptionId":"same"}`)
	_ = expect_event(&controller, "ack", "unsubscribe")

	controller_send(&controller, `{"id":"live","op":"subscribe","subscriptionId":"reconnect","path":"demo:state","args":{}}`)
	_ = expect_event(&controller, "ack", "live")
	_ = expect_event(&controller, "subscription")
	controller_send(&controller, `{"id":"disconnect","op":"debugDisconnect"}`)
	_ = expect_event(&controller, "ack", "disconnect")
	_ = expect_event(&controller, "subscription")
	controller_send(&controller, `{"id":"stop-live","op":"unsubscribe","subscriptionId":"reconnect"}`)
	_ = expect_event(&controller, "ack", "stop-live")
	controller_send(&controller, `{"id":"close","op":"close"}`)
	_ = expect_event(&controller, "closed", "close")
}

main :: proc() {
	if len(os.args) != 2 { fail("usage: process-fixture backend|large-backend|controller|stopped-controller") }
	switch os.args[1] {
	case "backend": backend_peer(false)
	case "large-backend": backend_peer(true)
	case "controller": adapter_controller(false)
	case "stopped-controller": adapter_controller(true)
	case: fail("unknown process fixture mode")
	}
}
