module convex

import crypto.sha1
import encoding.base64
import os
import time

// This is the deliberately small RFC 6455 subset Convex Live needs. Owning
// the frame parser is important: V 0.4.9's net.websocket allocates the
// peer-declared payload before callers can enforce a limit and retries timed
// out writes internally. Neither behaviour is safe inside a 128 MiB adapter.
pub const max_live_message_bytes = 1024 * 1024
pub const live_connect_budget = 10 * time.second
pub const live_write_budget = 5 * time.second
pub const live_close_budget = 2 * time.second
// Keep every owner-held operation below live_command_budget (8 seconds). That
// lets unsubscribe and close reach the sole socket owner even when a peer has
// stopped halfway through a frame instead of leaving callers behind a longer
// in-flight read.
pub const live_frame_budget = 5 * time.second
pub const live_read_slice = 25 * time.millisecond

const max_ws_status_line_bytes = 1024
const max_ws_header_block_bytes = 16 * 1024
const max_ws_headers = 64
const ws_guid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

struct LiveFrame {
	kind string
	text string
}

const frame_none = 'none'
const frame_text = 'text'
const frame_peer_closed = 'peer-closed'

struct LiveSocket {
mut:
	stream          Stream
	fragment        []u8
	fragment_opcode u8
	message_expires u64
	frame_budget    time.Duration = live_frame_budget
	write_budget    time.Duration = live_write_budget
	abandoned       bool
}

fn random_bytes(count int) ![]u8 {
	mut file := os.open('/dev/urandom') or {
		return transport_error('live', 'could not open the kernel entropy source')
	}
	bytes := file.read_bytes(count)
	file.close()
	if bytes.len != count {
		return transport_error('live', 'kernel entropy source returned too few bytes')
	}
	return bytes
}

fn live_endpoint(url string) !Endpoint {
	if !url.ends_with(sync_endpoint_path) {
		return protocol_error('live', 'Live URL does not use the pinned sync endpoint')
	}
	origin := url[..url.len - sync_endpoint_path.len]
	if origin.starts_with('wss://') {
		return parse_endpoint('https://' + origin[6..])
	}
	if origin.starts_with('ws://') {
		return parse_endpoint('http://' + origin[5..])
	}
	return protocol_error('live', 'Live URL must start with ws:// or wss://')
}

fn read_ws_byte(mut stream Stream, deadline Deadline) !u8 {
	if deadline.expired() {
		return transport_error('live', 'WebSocket read deadline elapsed')
	}
	set_stream_timeout(mut stream, deadline)
	mut buf := []u8{len: 1}
	count := stream.read_some(mut buf) or {
		return transport_error('live', 'WebSocket read failed: ${err.msg()}')
	}
	if count != 1 {
		return transport_error('live', 'WebSocket peer closed mid-frame')
	}
	return buf[0]
}

fn read_ws_exact(mut stream Stream, count int, deadline Deadline) ![]u8 {
	mut result := []u8{len: count}
	mut position := 0
	for position < count {
		if deadline.expired() {
			return transport_error('live', 'WebSocket read deadline elapsed mid-frame')
		}
		set_stream_timeout(mut stream, deadline)
		// A plain `result[position..]` clones: V slices copy the backing
		// array by default, so a read into that copy would never reach
		// `result` and every frame would decode as zero bytes. `unsafe`
		// here is only opting into the shared, no-copy view instead.
		mut remaining := unsafe { result[position..] }
		read := stream.read_some(mut remaining) or {
			return transport_error('live', 'WebSocket read failed mid-frame: ${err.msg()}')
		}
		if read <= 0 {
			return transport_error('live', 'WebSocket peer closed mid-frame')
		}
		position += read
	}
	return result
}

fn read_ws_line(mut stream Stream, limit int, deadline Deadline) !string {
	mut bytes := []u8{cap: if limit < 256 { limit } else { 256 }}
	for bytes.len <= limit {
		next_byte := read_ws_byte(mut stream, deadline)!
		bytes << next_byte
		if bytes.len > limit {
			return protocol_error('live', 'WebSocket handshake line exceeds ${limit} bytes')
		}
		if next_byte == `\n` {
			mut end := bytes.len - 1
			if end > 0 && bytes[end - 1] == `\r` {
				end--
			}
			return bytes[..end].bytestr()
		}
	}
	return protocol_error('live', 'WebSocket handshake line exceeds ${limit} bytes')
}

fn header_has_token(value string, expected string) bool {
	for token in value.split(',') {
		if token.trim_space().to_lower() == expected {
			return true
		}
	}
	return false
}

fn perform_upgrade(mut stream Stream, endpoint Endpoint, client_version string, deadline Deadline) ! {
	nonce := random_bytes(16)!
	key := base64.encode(nonce)
	request := 'GET ${sync_endpoint_path} HTTP/1.1\r\n' + 'Host: ${endpoint.authority}\r\n' +
		'Upgrade: websocket\r\n' + 'Connection: Upgrade\r\n' + 'Sec-WebSocket-Key: ${key}\r\n' +
		'Sec-WebSocket-Version: 13\r\n' + 'Convex-Client: ${client_version}\r\n\r\n'
	write_stream_all(mut stream, request.bytes(), deadline, 'live')!

	status := read_ws_line(mut stream, max_ws_status_line_bytes, deadline)!
	if !(status.starts_with('HTTP/1.1 101 ') || status.starts_with('HTTP/1.0 101 ')) {
		return transport_error('live', 'WebSocket upgrade did not return HTTP 101')
	}
	mut header_bytes := 0
	mut header_count := 0
	mut upgrade := ''
	mut connection := ''
	mut accept := ''
	for {
		line := read_ws_line(mut stream, max_ws_header_block_bytes, deadline)!
		if line.len == 0 {
			break
		}
		header_bytes += line.len + 2
		header_count++
		if header_bytes > max_ws_header_block_bytes || header_count > max_ws_headers {
			return protocol_error('live', 'WebSocket upgrade headers exceed their bound')
		}
		colon := index_of_byte(line, `:`) or {
			return protocol_error('live', 'WebSocket upgrade header is malformed')
		}
		if colon == 0 {
			return protocol_error('live', 'WebSocket upgrade header name is empty')
		}
		name := line[..colon].trim_space().to_lower()
		value := line[colon + 1..].trim_space()
		if !header_safe(name) || !header_safe(value) {
			return protocol_error('live', 'WebSocket upgrade header contains controls')
		}
		match name {
			'upgrade' {
				upgrade += if upgrade.len > 0 { ',' + value } else { value }
			}
			'connection' {
				connection += if connection.len > 0 { ',' + value } else { value }
			}
			'sec-websocket-accept' {
				if accept.len > 0 {
					return protocol_error('live', 'WebSocket upgrade repeated Sec-WebSocket-Accept')
				}
				accept = value
			}
			else {}
		}
	}
	expected := base64.encode(sha1.sum('${key}${ws_guid}'.bytes()))
	if !header_has_token(upgrade, 'websocket') || !header_has_token(connection, 'upgrade') {
		return protocol_error('live', 'WebSocket upgrade omitted required token headers')
	}
	if accept != expected {
		return protocol_error('live', 'WebSocket upgrade accept challenge did not match')
	}
}

fn connect_live_socket(url string, client_version string, deadline Deadline) !&LiveSocket {
	endpoint := live_endpoint(url)!
	mut stream := dial_stream(endpoint, deadline)!
	perform_upgrade(mut stream, endpoint, client_version, deadline) or {
		stream.shutdown()
		return err
	}
	return &LiveSocket{
		stream: stream
	}
}

fn (mut socket LiveSocket) wait_readable(slice time.Duration) bool {
	if socket.abandoned {
		return false
	}
	return stream_is_readable(mut socket.stream, slice)
}

fn (mut socket LiveSocket) read_one_frame(deadline Deadline) !(u8, bool, []u8) {
	first := read_ws_byte(mut socket.stream, deadline)!
	second := read_ws_byte(mut socket.stream, deadline)!
	fin := first & 0x80 != 0
	if first & 0x70 != 0 {
		return protocol_error('live', 'WebSocket reserved bits were set')
	}
	opcode := first & 0x0f
	if opcode in [u8(3), 4, 5, 6, 7, 11, 12, 13, 14, 15] {
		return protocol_error('live', 'WebSocket used a reserved opcode')
	}
	if second & 0x80 != 0 {
		return protocol_error('live', 'server WebSocket frames must not be masked')
	}
	mut length := u64(second & 0x7f)
	if length == 126 {
		extended := read_ws_exact(mut socket.stream, 2, deadline)!
		length = (u64(extended[0]) << 8) | u64(extended[1])
		if length < 126 {
			return protocol_error('live', 'WebSocket length was not minimally encoded')
		}
	} else if length == 127 {
		extended := read_ws_exact(mut socket.stream, 8, deadline)!
		if extended[0] & 0x80 != 0 {
			return protocol_error('live', 'WebSocket length exceeds signed 63-bit range')
		}
		length = 0
		for octet in extended {
			length = (length << 8) | u64(octet)
		}
		if length <= 0xffff {
			return protocol_error('live', 'WebSocket length was not minimally encoded')
		}
	}
	control := opcode >= 8
	if control && (!fin || length > 125) {
		return protocol_error('live', 'WebSocket control frame is malformed')
	}
	// Check the peer declaration before converting to int or allocating.
	if !control && length > u64(max_live_message_bytes - socket.fragment.len) {
		return protocol_error('live', 'Live message exceeds ${max_live_message_bytes} bytes')
	}
	payload := read_ws_exact(mut socket.stream, int(length), deadline)!
	return opcode, fin, payload
}

fn (mut socket LiveSocket) read_frame() !LiveFrame {
	if socket.abandoned {
		return transport_error('live', 'Live socket has been retired')
	}
	deadline := if socket.message_expires > time.sys_mono_now() {
		Deadline{
			expires_at: socket.message_expires
		}
	} else {
		deadline_in(socket.frame_budget)
	}
	for {
		opcode, fin, payload := socket.read_one_frame(deadline) or {
			socket.abandon()
			return err
		}
		match opcode {
			0 {
				if socket.fragment_opcode == 0 {
					socket.abandon()
					return protocol_error('live', 'unexpected WebSocket continuation')
				}
				socket.fragment << payload
				if !fin {
					continue
				}
				message := socket.fragment.clone()
				op := socket.fragment_opcode
				socket.fragment = []u8{}
				socket.fragment_opcode = 0
				socket.message_expires = 0
				return socket.finish_message(op, message)
			}
			1, 2 {
				if socket.fragment_opcode != 0 {
					socket.abandon()
					return protocol_error('live', 'new WebSocket data frame interrupted fragments')
				}
				if !fin {
					socket.fragment_opcode = opcode
					socket.fragment = payload.clone()
					socket.message_expires = deadline.expires_at
					continue
				}
				return socket.finish_message(opcode, payload)
			}
			8 {
				if payload.len == 1 {
					socket.abandon()
					return protocol_error('live', 'WebSocket close payload may not be one byte')
				}
				if payload.len > 2 {
					reason := payload[2..].bytestr()
					utf8_scalars(reason) or {
						socket.abandon()
						return protocol_error('live', 'WebSocket close reason is not valid UTF-8')
					}
				}
				socket.abandon()
				return LiveFrame{
					kind: frame_peer_closed
				}
			}
			9 {
				socket.write_control(10, payload, deadline) or {
					socket.abandon()
					return err
				}
				return LiveFrame{
					kind: frame_none
				}
			}
			10 {
				return LiveFrame{
					kind: frame_none
				}
			}
			else {
				socket.abandon()
				return protocol_error('live', 'unsupported WebSocket opcode')
			}
		}
	}
}

fn (mut socket LiveSocket) finish_message(opcode u8, payload []u8) !LiveFrame {
	if opcode == 2 {
		socket.abandon()
		return protocol_error('live', 'the pinned Live profile has no binary messages')
	}
	text := payload.bytestr()
	utf8_scalars(text) or {
		socket.abandon()
		return protocol_error('live', 'Live text message is not valid UTF-8')
	}
	return LiveFrame{
		kind: frame_text
		text: text
	}
}

fn (mut socket LiveSocket) write_control(opcode u8, payload []u8, deadline Deadline) ! {
	if payload.len > 125 {
		return protocol_error('live', 'WebSocket control payload exceeds 125 bytes')
	}
	socket.write_frame(opcode, payload, deadline)!
}

fn (mut socket LiveSocket) write_frame(opcode u8, payload []u8, deadline Deadline) ! {
	if deadline.expired() {
		return transport_error('live', 'WebSocket write deadline elapsed')
	}
	mask := random_bytes(4)!
	mut header := []u8{cap: 14}
	header << (u8(0x80) | opcode)
	if payload.len < 126 {
		header << (u8(0x80) | u8(payload.len))
	} else if payload.len <= 0xffff {
		header << u8(0xfe)
		header << u8((payload.len >> 8) & 0xff)
		header << u8(payload.len & 0xff)
	} else {
		header << u8(0xff)
		for shift := 56; shift >= 0; shift -= 8 {
			header << u8((u64(payload.len) >> shift) & 0xff)
		}
	}
	header << mask
	mut frame := []u8{cap: header.len + payload.len}
	frame << header
	for index, octet in payload {
		frame << (octet ^ mask[index % 4])
	}
	write_stream_all(mut socket.stream, frame, deadline, 'live')!
}

fn (mut socket LiveSocket) write_text(text string) ! {
	if socket.abandoned {
		return transport_error('live', 'Live socket has been retired')
	}
	if text.len > max_live_message_bytes {
		return protocol_error('live', 'outgoing Live message exceeds ${max_live_message_bytes} bytes')
	}
	socket.write_frame(1, text.bytes(), deadline_in(socket.write_budget)) or {
		socket.abandon()
		return err
	}
}

fn (mut socket LiveSocket) close(reason string) {
	if socket.abandoned {
		return
	}
	mut payload := [u8(0x03), 0xe8]
	reason_bytes := reason.bytes()
	mut maximum := if reason_bytes.len > 123 { 123 } else { reason_bytes.len }
	// RFC 6455 requires the close reason to remain valid UTF-8. Truncating a
	// multibyte scalar at byte 123 would manufacture an invalid control frame.
	for maximum > 0 {
		utf8_scalars(reason_bytes[..maximum].bytestr()) or {
			maximum--
			continue
		}
		break
	}
	payload << reason_bytes[..maximum]
	socket.write_control(8, payload, deadline_in(live_close_budget)) or {}
	socket.abandon()
}

fn (mut socket LiveSocket) abandon() {
	if socket.abandoned {
		return
	}
	socket.abandoned = true
	socket.fragment = []u8{}
	socket.fragment_opcode = 0
	socket.message_expires = 0
	socket.stream.shutdown()
}
