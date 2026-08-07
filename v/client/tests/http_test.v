module convex

import time
import x.json2

// ScriptedStream replays a response in exactly the chunk boundaries a test
// chooses. Splitting the framing away from dialling is what makes every HTTP
// bound testable without a socket: a header split across two reads, a body that
// stops short of its Content-Length, and a peer that never sends anything are
// all ordinary fixtures here.
struct ScriptedStream {
mut:
	chunks  [][]u8
	index   int
	offset  int
	written []u8
	silent  bool
}

fn (mut stream ScriptedStream) read_some(mut buffer []u8) !int {
	if stream.silent {
		return error('read timed out')
	}
	if stream.index >= stream.chunks.len {
		return error('end of stream')
	}
	chunk := stream.chunks[stream.index]
	mut count := chunk.len - stream.offset
	if count > buffer.len {
		count = buffer.len
	}
	for position in 0 .. count {
		buffer[position] = chunk[stream.offset + position]
	}
	stream.offset += count
	if stream.offset >= chunk.len {
		stream.index++
		stream.offset = 0
	}
	return count
}

fn (mut stream ScriptedStream) write_some(data []u8) !int {
	stream.written << data
	return data.len
}

fn (mut stream ScriptedStream) shutdown() {}

fn scripted(parts []string) Stream {
	mut chunks := [][]u8{cap: parts.len}
	for part in parts {
		chunks << part.bytes()
	}
	return Stream(&ScriptedStream{
		chunks: chunks
	})
}

fn run_exchange(parts []string) !HttpResponse {
	mut stream := scripted(parts)
	return exchange(mut stream, 'POST /api/query HTTP/1.1\r\n\r\n', deadline_in(2 * time.second))
}

fn exchange_failure(parts []string) string {
	run_exchange(parts) or { return (err as ConvexError).message }
	return ''
}

fn test_content_length_body_is_read_exactly() ! {
	response := run_exchange([
		'HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n{}{}',
	])!
	assert response.status_code == 200
	assert response.body == '{}{}'
}

fn test_headers_split_across_reads_are_reassembled() ! {
	// A peer is free to split anywhere, including mid-header-name. Restarting
	// the parse at a false boundary is exactly the bug this covers.
	response := run_exchange([
		'HTTP/1.1 20',
		'0 OK\r\nCont',
		'ent-Length: 2\r',
		'\n\r\n{}',
	])!
	assert response.status_code == 200
	assert response.body == '{}'
}

fn test_chunked_framing_is_decoded_and_bounded() ! {
	response := run_exchange([
		'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n',
		'4\r\n{"a"\r\n3;ext=1\r\n:1}\r\n0\r\n\r\n',
	])!
	assert response.body == '{"a":1}'
}

fn test_connection_close_framing_reads_to_end_of_stream() ! {
	response := run_exchange([
		'HTTP/1.1 500 Internal Server Error\r\n\r\n{"status":"error"',
		'}',
	])!
	assert response.status_code == 500
	assert response.body == '{"status":"error"}'
}

fn test_malformed_status_lines_are_rejected() {
	assert exchange_failure(['nonsense\r\n\r\n']).contains('status line')
	assert exchange_failure(['HTTP/1.X 200 OK\r\n\r\n']).contains('status line')
	assert exchange_failure(['HTTP/1.1 xyz OK\r\n\r\n']).contains('status code')
	assert exchange_failure(['HTTP/1.1 099 Odd\r\n\r\n']).contains('out of range')
	assert exchange_failure(['HTTP/1.1 200 OK\r\nbroken-header\r\n\r\n']).contains('header line')
}

fn test_conflicting_and_repeated_framing_headers_are_rejected() {
	assert exchange_failure([
		'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n{}',
	]).contains('mixed Content-Length')
	assert exchange_failure([
		'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}',
	]).contains('repeated Content-Length')
	assert exchange_failure([
		'HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n{}',
	]).contains('Transfer-Encoding')
}

fn test_header_block_and_header_count_are_bounded() {
	mut many := 'HTTP/1.1 200 OK\r\n'
	for index in 0 .. max_http_headers + 2 {
		many += 'x-mark-${index}: 1\r\n'
	}
	many += '\r\n'
	assert exchange_failure([many]).contains('headers')

	mut huge := 'HTTP/1.1 200 OK\r\nx-large: ' + 'y'.repeat(max_http_header_block_bytes + 16) +
		'\r\n\r\n'
	assert exchange_failure([huge]).contains('exceeds')
}

fn test_oversized_bodies_are_refused_by_declaration_and_by_arrival() {
	declared := 'HTTP/1.1 200 OK\r\nContent-Length: ${max_http_response_bytes + 1}\r\n\r\n'
	assert exchange_failure([declared]).contains('exceeds')

	// A peer that lies about Content-Length, or omits it entirely, must still be
	// stopped by the running total rather than by trusting the header.
	mut parts := ['HTTP/1.1 200 OK\r\n\r\n']
	for _ in 0 .. 40 {
		parts << 'z'.repeat(64 * 1024)
	}
	assert exchange_failure(parts).contains('exceeds')
}

fn test_truncated_and_silent_responses_fail_rather_than_hang() {
	assert exchange_failure([
		'HTTP/1.1 200 OK\r\nContent-Length: 16\r\n\r\nshort',
	]).contains('ended before Content-Length')

	mut stream := Stream(&ScriptedStream{
		silent: true
	})
	// A silent peer must be bounded by the absolute deadline, not by patience.
	response := exchange(mut stream, 'POST /api/query HTTP/1.1\r\n\r\n', deadline_in(50 * time.millisecond)) or {
		assert (err as ConvexError).kind in [kind_transport_error, kind_protocol_error]
		return
	}
	assert false, 'a silent peer must not produce a response: ${response.status_code}'
}

fn test_request_rejects_header_injection() {
	endpoint := parse_endpoint('http://backend:3210') or { panic(err) }
	build_request(endpoint, '/api/query', '{}', 'token\r\nX-Injected: 1', client_version) or {
		assert (err as ConvexError).message.contains('control characters')
		return
	}
	assert false, 'a token containing CRLF must be rejected'
}

fn test_request_carries_the_documented_convex_headers() ! {
	endpoint := parse_endpoint('https://example.convex.cloud')!
	request := build_request(endpoint, '/api/mutation', '{"a":1}', 'secret', client_version)!
	assert request.starts_with('POST /api/mutation HTTP/1.1\r\n')
	assert request.contains('Host: example.convex.cloud:443\r\n')
	assert request.contains('Content-Type: application/json\r\n')
	assert request.contains('Convex-Client: ${client_version}\r\n')
	assert request.contains('Authorization: Bearer secret\r\n')
	assert request.contains('Content-Length: 7\r\n')
	assert request.ends_with('\r\n\r\n{"a":1}')

	anonymous := build_request(endpoint, '/api/query', '{}', '', client_version)!
	assert !anonymous.contains('Authorization')
}

fn envelope_failure(status_code int, body string) ConvexError {
	decode_envelope(HttpResponse{
		status_code: status_code
		body:        body
	}, 'query') or { return err as ConvexError }
	return ConvexError{
		kind:    'None'
		message: 'no error'
	}
}

fn test_success_envelope_decodes_value_and_logs() ! {
	result := decode_envelope(HttpResponse{
		status_code: 200
		body:        '{"status":"success","value":{"count":1.0},"logLines":["demo:echo ran"]}'
	}, 'query')!
	state := result.value as map[string]json2.Any
	assert (integral_number(state['count'] or { json2.Any(json2.null) }) or { -1 }) == 1
	assert result.logs[0] == 'demo:echo ran'
}

fn test_structured_function_error_keeps_its_data() {
	failure := envelope_failure(400, '{"status":"error","errorMessage":"boom","errorData":{"code":"CLIENT_EXPECTED"},"logLines":["log"]}')
	assert failure.kind == kind_function_error
	assert failure.message == 'boom'
	data := failure.data as map[string]json2.Any
	assert (string_field(data, 'code') or { '' }) == 'CLIENT_EXPECTED'
	assert failure.logs[0] == 'log'
}

fn test_envelope_strictness() {
	// A non-2xx status may carry a real function error, but never a success.
	assert envelope_failure(503, '{"status":"success","value":0}').kind == kind_protocol_error
	assert envelope_failure(500, '{"status":"error"}').message.contains('errorMessage')
	assert envelope_failure(200, '{"status":"success"}').message.contains('missing value')
	assert envelope_failure(200, '{"status":"weird","value":0}').message.contains('unknown Convex envelope status')
	assert envelope_failure(200, '{"value":0}').message.contains('string status')
	// A proxy error page is a transport failure, not a Convex protocol fault.
	assert envelope_failure(502, '<html>bad gateway</html>').kind == kind_transport_error
	assert envelope_failure(200, '').kind == kind_transport_error
	assert envelope_failure(200, '[1]').kind == kind_protocol_error
}

fn test_function_paths_are_validated_before_any_request() {
	for path in ['', 'ab', ':state', 'demo:', 'demo state', 'de\nmo:state'] {
		validate_function_path(path, 'query') or { continue }
		assert false, 'invalid function path was accepted: ${path}'
	}
	validate_function_path('demo:state', 'query') or { assert false, 'demo:state must be accepted' }
}
