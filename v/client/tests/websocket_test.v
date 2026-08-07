module convex

import crypto.sha1
import encoding.base64
import net
import time

// These fixtures speak raw RFC 6455 on a loopback socket. They exist because
// the Live acceptance rules are about frames, not about Convex: a fragmented
// UTF-8 message, a control frame, an over-sized message, a peer close, and a
// peer that stops halfway through a frame are all things a happy-path Convex
// test would never produce.
//
// `ws_guid` comes from websocket.v: this file shares the `convex` module with
// it, and a second top-level const of the same name here is a duplicate
// declaration, not a shadow.

fn ws_frame(fin bool, opcode u8, payload []u8) []u8 {
	mut frame := []u8{}
	first := if fin { u8(0x80) | opcode } else { opcode }
	frame << first
	// Server frames are never masked, which is also what LiveSocket requires of
	// the real Convex backend.
	if payload.len < 126 {
		frame << u8(payload.len)
	} else if payload.len <= 0xffff {
		frame << u8(126)
		frame << u8((payload.len >> 8) & 0xff)
		frame << u8(payload.len & 0xff)
	} else {
		frame << u8(127)
		for shift := 56; shift >= 0; shift -= 8 {
			frame << u8((u64(payload.len) >> shift) & 0xff)
		}
	}
	frame << payload
	return frame
}

fn accept_key(request string) string {
	for line in request.split('\r\n') {
		lowered := line.to_lower()
		if lowered.starts_with('sec-websocket-key:') {
			key := line.all_after(':').trim_space()
			return base64.encode(sha1.sum('${key}${ws_guid}'.bytes()))
		}
	}
	return ''
}

// serve_ws_fixture completes one upgrade, writes a scripted byte script, then
// holds the connection open for `linger` milliseconds so a stalled read is a
// genuine half-frame rather than an end of stream.
fn serve_ws_fixture(port int, script [][]u8, linger time.Duration) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:${port}') or { return }
	mut conn := listener.accept() or {
		listener.close() or {}
		return
	}
	conn.set_read_timeout(5 * time.second)
	conn.set_write_timeout(5 * time.second)
	mut request := []u8{}
	for request.len < 8192 {
		mut chunk := []u8{len: 1024}
		count := conn.read(mut chunk) or { break }
		if count <= 0 {
			break
		}
		request << chunk[..count]
		if request.bytestr().contains('\r\n\r\n') {
			break
		}
	}
	key := accept_key(request.bytestr())
	response := 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${key}\r\n\r\n'
	conn.write(response.bytes()) or {}
	for part in script {
		conn.write(part) or { break }
	}
	time.sleep(linger)
	conn.close() or {}
	listener.close() or {}
}

// This peer sends one byte at a time slowly enough that a relative timeout
// would be refreshed forever. The client must instead keep one absolute frame
// deadline from the first header byte to the last payload byte.
fn serve_ws_dribble(port int, frame []u8, delay time.Duration) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:${port}') or { return }
	mut conn := listener.accept() or {
		listener.close() or {}
		return
	}
	conn.set_read_timeout(5 * time.second)
	conn.set_write_timeout(5 * time.second)
	mut request := []u8{}
	for request.len < 8192 {
		mut chunk := []u8{len: 1024}
		count := conn.read(mut chunk) or { break }
		if count <= 0 {
			break
		}
		request << chunk[..count]
		if request.bytestr().contains('\r\n\r\n') {
			break
		}
	}
	key := accept_key(request.bytestr())
	response := 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: WebSocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: ${key}\r\n\r\n'
	conn.write(response.bytes()) or {}
	for octet in frame {
		conn.write([octet]) or { break }
		time.sleep(delay)
	}
	conn.close() or {}
	listener.close() or {}
}

fn connect_fixture(port int) !&LiveSocket {
	for _ in 0 .. 60 {
		socket := connect_live_socket('ws://127.0.0.1:${port}/api/sync', client_version,
			deadline_in(2 * time.second)) or {
			time.sleep(50 * time.millisecond)
			continue
		}
		return socket
	}
	return transport_error('live', 'the WebSocket fixture never accepted a connection')
}

fn read_text_frame(mut socket LiveSocket) !string {
	for _ in 0 .. 20 {
		frame := socket.read_frame()!
		if frame.kind == frame_text {
			return frame.text
		}
		if frame.kind == frame_peer_closed {
			return transport_error('live', 'peer closed before a text frame arrived')
		}
	}
	return transport_error('live', 'no text frame arrived')
}

fn test_fragmented_utf8_message_is_reassembled() ! {
	port := 39871
	// "世" is split across the two fragments, so a reader that decoded each
	// fragment on its own would produce mojibake or fail.
	payload := '{"type":"Ping","note":"世界"}'.bytes()
	// Byte 24 is the second byte of "世", so the split lands inside one scalar.
	spawn serve_ws_fixture(port, [
		ws_frame(false, 0x01, payload[..24]),
		ws_frame(true, 0x00, payload[24..]),
	], 400 * time.millisecond)
	mut socket := connect_fixture(port)!
	text := read_text_frame(mut socket)!
	assert text == '{"type":"Ping","note":"世界"}'
	assert (utf8_scalars(text) or { -1 }) > 0
	socket.abandon()
}

fn test_ping_is_answered_and_does_not_surface_as_a_message() ! {
	port := 39872
	spawn serve_ws_fixture(port, [
		ws_frame(true, 0x09, 'keepalive'.bytes()),
		ws_frame(true, 0x01, '{"type":"Ping"}'.bytes()),
	], 400 * time.millisecond)
	mut socket := connect_fixture(port)!
	first := socket.read_frame()!
	// A control frame is handled, not published.
	assert first.kind == frame_none
	assert !socket.abandoned
	text := read_text_frame(mut socket)!
	assert text == '{"type":"Ping"}'
	socket.abandon()
}

fn test_binary_messages_are_refused_by_the_pinned_profile() ! {
	port := 39873
	spawn serve_ws_fixture(port, [
		ws_frame(true, 0x02, [u8(1), 2, 3]),
	], 400 * time.millisecond)
	mut socket := connect_fixture(port)!
	frame := socket.read_frame() or {
		assert (err as ConvexError).kind == kind_protocol_error
		assert socket.abandoned
		return
	}
	assert false, 'a binary frame must be refused: ${frame.kind}'
}

fn test_oversized_messages_are_refused_and_the_connection_is_abandoned() ! {
	port := 39874
	spawn serve_ws_fixture(port, [
		ws_frame(true, 0x01, []u8{len: max_live_message_bytes + 64, init: `x`}),
	], 400 * time.millisecond)
	mut socket := connect_fixture(port)!
	frame := socket.read_frame() or {
		assert (err as ConvexError).message.contains('exceeds')
		assert socket.abandoned
		return
	}
	assert false, 'an over-sized message must be refused: ${frame.kind}'
}

fn test_a_peer_close_is_reported_rather_than_treated_as_data() ! {
	port := 39875
	spawn serve_ws_fixture(port, [
		ws_frame(true, 0x08, [u8(0x03), 0xe8]),
	], 400 * time.millisecond)
	mut socket := connect_fixture(port)!
	frame := socket.read_frame()!
	assert frame.kind == frame_peer_closed
	assert socket.abandoned
}

fn test_a_half_frame_is_bounded_and_abandons_the_connection() ! {
	port := 39876
	// Announce 200 payload bytes and send eight. The peer then holds the
	// connection open, so only the deadline can end this read.
	mut truncated := ws_frame(true, 0x01, []u8{len: 200, init: `y`})
	truncated = truncated[..10]
	spawn serve_ws_fixture(port, [truncated], 3 * time.second)
	mut socket := connect_fixture(port)!
	socket.frame_budget = 300 * time.millisecond
	started := time.sys_mono_now()
	frame := socket.read_frame() or {
		elapsed := time.Duration(i64(time.sys_mono_now() - started))
		// Bounded by the deadline, and never resumed: a partially consumed
		// frame cannot be restarted at a guessed boundary.
		assert elapsed < 3 * time.second
		assert socket.abandoned
		assert (err as ConvexError).kind == kind_transport_error
		return
	}
	assert false, 'a half-frame read must not succeed: ${frame.kind}'
}

fn test_declared_oversize_is_rejected_before_payload_allocation() ! {
	port := 39878
	// Advertise 1 GiB but send no body. A post-allocation limit would OOM the
	// 128 MiB adapter before this assertion could run.
	header := [u8(0x81), 0x7f, 0, 0, 0, 0, 0x40, 0, 0, 0]
	spawn serve_ws_fixture(port, [header], 2 * time.second)
	mut socket := connect_fixture(port)!
	frame := socket.read_frame() or {
		assert (err as ConvexError).kind == kind_protocol_error
		assert err.msg().contains('exceeds')
		assert socket.abandoned
		return
	}
	assert false, 'an oversized declared frame must fail before allocation: ${frame.kind}'
}

fn test_continuous_dribble_cannot_refresh_the_frame_deadline() ! {
	port := 39879
	frame := ws_frame(true, 0x01, 'a modest payload that arrives much too slowly'.bytes())
	spawn serve_ws_dribble(port, frame, 60 * time.millisecond)
	mut socket := connect_fixture(port)!
	socket.frame_budget = 250 * time.millisecond
	started := time.sys_mono_now()
	result := socket.read_frame() or {
		elapsed := time.Duration(i64(time.sys_mono_now() - started))
		assert elapsed < time.second
		assert (err as ConvexError).kind == kind_transport_error
		assert socket.abandoned
		return
	}
	assert false, 'a continuous dribble must not complete: ${result.kind}'
}

fn test_stopped_reader_cannot_extend_the_write_deadline() ! {
	port := 39880
	// The raw peer upgrades and then deliberately never reads WebSocket data.
	spawn serve_ws_fixture(port, [][]u8{}, 3 * time.second)
	mut socket := connect_fixture(port)!
	socket.write_budget = 250 * time.millisecond
	payload := 'x'.repeat(max_live_message_bytes)
	started := time.sys_mono_now()
	for _ in 0 .. 8 {
		socket.write_text(payload) or {
			elapsed := time.Duration(i64(time.sys_mono_now() - started))
			assert elapsed < 3 * time.second
			assert (err as ConvexError).kind == kind_transport_error
			assert socket.abandoned
			return
		}
	}
	assert false, 'a stopped reader accepted 8 MiB without reaching the deadline'
}

fn test_a_retired_socket_refuses_further_use() ! {
	port := 39877
	spawn serve_ws_fixture(port, [
		ws_frame(true, 0x01, '{"type":"Ping"}'.bytes()),
	], 400 * time.millisecond)
	mut socket := connect_fixture(port)!
	assert read_text_frame(mut socket)! == '{"type":"Ping"}'
	socket.abandon()
	socket.write_text('{"type":"Ping"}') or {
		assert (err as ConvexError).message.contains('retired')
		frame := socket.read_frame() or {
			assert (err as ConvexError).message.contains('retired')
			return
		}
		assert false, 'a retired socket must not read: ${frame.kind}'
	}
	assert false, 'a retired socket must not write'
}
