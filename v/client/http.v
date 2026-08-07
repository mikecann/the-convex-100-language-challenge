module convex

import time

// Convex's documented JSON HTTP API is framed here in V rather than handed to a
// general-purpose fetch helper. Owning the framing is what makes the response
// bounds real: a status line, a header block, and a body all have explicit
// ceilings, so a hostile or broken peer cannot stream unbounded bytes into a
// 128 MiB container before the client notices.
pub const max_http_request_bytes = 2 * 1024 * 1024
pub const max_http_response_bytes = 2 * 1024 * 1024
pub const max_http_status_line_bytes = 1024
pub const max_http_header_block_bytes = 16 * 1024
pub const max_http_headers = 64
pub const max_http_chunk_line_bytes = 64
pub const http_call_budget = 20 * time.second

struct HttpResponse {
	status_code int
	body        string
}

// HttpReader buffers exactly as much as the bounds allow. `taken` is the
// running total of body-eligible bytes so the ceiling covers the whole
// exchange rather than each individual read. Named in PascalCase rather than
// the all-lowercase `reader` its role would suggest, because V reserves
// all-lowercase single-word type names for its own builtins.

struct HttpReader {
mut:
	stream   Stream
	pending  []u8
	position int
	taken    int
	deadline Deadline
	eof      bool
}

fn (mut r HttpReader) fill() ! {
	if r.eof {
		return
	}
	if r.deadline.expired() {
		return transport_error('http', 'response deadline elapsed')
	}
	set_stream_timeout(mut r.stream, r.deadline)
	mut chunk := []u8{len: 16 * 1024}
	count := r.stream.read_some(mut chunk) or {
		// A closed connection is a legitimate end of a `Connection: close`
		// response body, so it is reported as EOF and validated by the framing
		// rules above. A read that failed because the budget ran out is not:
		// treating that as EOF would silently accept a truncated body.
		if r.deadline.expired() {
			return transport_error('http', 'response deadline elapsed mid-body')
		}
		r.eof = true
		return
	}
	if count <= 0 {
		r.eof = true
		return
	}
	r.taken += count
	if r.taken > max_http_response_bytes {
		return transport_error('http', 'response exceeds ${max_http_response_bytes} bytes')
	}
	// Compact the buffer before growing it so a long response cannot retain
	// every byte already consumed.
	if r.position > 0 {
		r.pending = r.pending[r.position..].clone()
		r.position = 0
	}
	r.pending << chunk[..count]
}

fn (mut r HttpReader) read_line(limit int) !string {
	for {
		mut index := r.position
		for index < r.pending.len {
			if r.pending[index] == `\n` {
				mut end := index
				if end > r.position && r.pending[end - 1] == `\r` {
					end--
				}
				line := r.pending[r.position..end].bytestr()
				r.position = index + 1
				if line.len > limit {
					return protocol_error('http', 'HTTP line exceeds ${limit} bytes')
				}
				return line
			}
			index++
		}
		if r.pending.len - r.position > limit {
			return protocol_error('http', 'HTTP line exceeds ${limit} bytes')
		}
		if r.eof {
			return protocol_error('http', 'HTTP response ended mid-line')
		}
		r.fill()!
	}
	// See the matching comment on `Live.submit` in live.v.
	panic('unreachable: read_line loop exited without returning')
}

fn (mut r HttpReader) read_exact(count int) !string {
	if count > max_http_response_bytes {
		return transport_error('http', 'response exceeds ${max_http_response_bytes} bytes')
	}
	for r.pending.len - r.position < count {
		if r.eof {
			return transport_error('http', 'HTTP body ended before Content-Length')
		}
		r.fill()!
	}
	text := r.pending[r.position..r.position + count].bytestr()
	r.position += count
	return text
}

fn (mut r HttpReader) read_to_eof() !string {
	for !r.eof {
		r.fill()!
	}
	text := r.pending[r.position..].bytestr()
	r.position = r.pending.len
	if text.len > max_http_response_bytes {
		return transport_error('http', 'response exceeds ${max_http_response_bytes} bytes')
	}
	return text
}

// read_chunked decodes RFC 7230 chunked framing with the same total ceiling as
// a Content-Length body. Chunk extensions are ignored, but a malformed size, a
// missing terminator, or a total over the limit fails the call.
fn (mut r HttpReader) read_chunked() !string {
	mut body := []u8{}
	for {
		line := r.read_line(max_http_chunk_line_bytes)!
		mut size_text := line
		if semicolon := index_of_byte(line, `;`) {
			size_text = line[..semicolon]
		}
		size_text = size_text.trim_space()
		if size_text.len == 0 || size_text.len > 8 {
			return protocol_error('http', 'chunk size is malformed')
		}
		mut size := 0
		for character in size_text {
			digit := hex_digit_value(character) or {
				return protocol_error('http', 'chunk size is malformed')
			}
			size = size * 16 + digit
		}
		if size == 0 {
			// Consume the trailer section, bounded by the header block limit.
			mut trailer_bytes := 0
			for {
				trailer := r.read_line(max_http_header_block_bytes)!
				if trailer.len == 0 {
					break
				}
				trailer_bytes += trailer.len
				if trailer_bytes > max_http_header_block_bytes {
					return protocol_error('http', 'chunked trailer exceeds the header limit')
				}
			}
			break
		}
		if body.len + size > max_http_response_bytes {
			return transport_error('http', 'chunked response exceeds ${max_http_response_bytes} bytes')
		}
		body << r.read_exact(size)!.bytes()
		terminator := r.read_line(max_http_chunk_line_bytes)!
		if terminator.len != 0 {
			return protocol_error('http', 'chunk did not end with CRLF')
		}
	}
	return body.bytestr()
}

fn index_of_byte(text string, needle u8) ?int {
	for index, character in text {
		if character == needle {
			return index
		}
	}
	return none
}

fn hex_digit_value(character u8) ?int {
	if character >= `0` && character <= `9` {
		return int(character - `0`)
	}
	if character >= `a` && character <= `f` {
		return int(character - `a`) + 10
	}
	if character >= `A` && character <= `F` {
		return int(character - `A`) + 10
	}
	return none
}

// header_safe rejects the control characters that would let a token or a
// function path split the request into two. The client never trusts caller
// input to be header-safe just because it came from its own API.
fn header_safe(value string) bool {
	for character in value {
		if character < 0x20 || character == 0x7f {
			return false
		}
	}
	return true
}

fn build_request(endpoint Endpoint, path string, body string, token string, client_version string) !string {
	if !header_safe(token) {
		return protocol_error('http', 'authentication token contains control characters')
	}
	mut request := 'POST ${path} HTTP/1.1\r\n'
	request += 'Host: ${endpoint.authority}\r\n'
	request += 'Accept: application/json\r\n'
	request += 'Content-Type: application/json\r\n'
	request += 'Convex-Client: ${client_version}\r\n'
	// One request per connection keeps response framing unambiguous: there is
	// no pipelined second response to mis-attribute if a peer lies about its
	// Content-Length.
	request += 'Connection: close\r\n'
	if token.len > 0 {
		request += 'Authorization: Bearer ${token}\r\n'
	}
	request += 'Content-Length: ${body.len}\r\n\r\n'
	request += body
	return request
}

fn parse_status_code(line string) !int {
	if line.len < 12 || !(line.starts_with('HTTP/1.0 ') || line.starts_with('HTTP/1.1 ')) {
		return protocol_error('http', 'HTTP status line is malformed')
	}
	digits := line[9..12]
	mut code := 0
	for character in digits {
		if character < `0` || character > `9` {
			return protocol_error('http', 'HTTP status code is malformed')
		}
		code = code * 10 + int(character - `0`)
	}
	if code < 100 || code > 599 {
		return protocol_error('http', 'HTTP status code is out of range')
	}
	return code
}

// http_post_json performs one bounded request/response exchange on its own
// connection. Everything above it treats a non-2xx status as data, because a
// real Convex function error legitimately arrives with one.
fn http_post_json(endpoint Endpoint, path string, body string, token string, client_version string) !HttpResponse {
	if body.len > max_http_request_bytes {
		return protocol_error('http', 'request body exceeds ${max_http_request_bytes} bytes')
	}
	deadline := deadline_in(http_call_budget)
	request := build_request(endpoint, path, body, token, client_version)!
	mut stream := dial_stream(endpoint, deadline)!
	defer {
		stream.shutdown()
	}
	return exchange(mut stream, request, deadline)
}

// exchange is the framing itself, separated from dialling so the deterministic
// fixtures can drive every bound - status line, header block, Content-Length,
// chunked framing, and a truncated body - without a socket.
fn exchange(mut stream Stream, request string, deadline Deadline) !HttpResponse {
	write_stream_all(mut stream, request.bytes(), deadline, 'http')!

	mut response := HttpReader{
		stream:   stream
		pending:  []u8{}
		deadline: deadline
	}
	status_code := parse_status_code(response.read_line(max_http_status_line_bytes)!)!

	mut header_bytes := 0
	mut header_count := 0
	mut content_length := -1
	mut chunked := false
	for {
		line := response.read_line(max_http_header_block_bytes)!
		if line.len == 0 {
			break
		}
		header_bytes += line.len + 2
		header_count++
		if header_bytes > max_http_header_block_bytes {
			return protocol_error('http', 'header block exceeds ${max_http_header_block_bytes} bytes')
		}
		if header_count > max_http_headers {
			return protocol_error('http', 'response has more than ${max_http_headers} headers')
		}
		colon := index_of_byte(line, `:`) or {
			return protocol_error('http', 'header line is malformed')
		}
		name := line[..colon].to_lower()
		value := line[colon + 1..].trim_space()
		if name == 'content-length' {
			if content_length >= 0 {
				return protocol_error('http', 'response repeated Content-Length')
			}
			if value.len == 0 || value.len > 8 {
				return protocol_error('http', 'Content-Length is malformed')
			}
			mut length := 0
			for character in value {
				if character < `0` || character > `9` {
					return protocol_error('http', 'Content-Length is malformed')
				}
				length = length * 10 + int(character - `0`)
			}
			if length > max_http_response_bytes {
				return transport_error('http', 'response exceeds ${max_http_response_bytes} bytes')
			}
			content_length = length
		} else if name == 'transfer-encoding' {
			if value.to_lower() != 'chunked' {
				return protocol_error('http', 'unsupported Transfer-Encoding: ${value}')
			}
			chunked = true
		}
	}
	if chunked && content_length >= 0 {
		return protocol_error('http', 'response mixed Content-Length with chunked framing')
	}

	payload := if chunked {
		response.read_chunked()!
	} else if content_length >= 0 {
		response.read_exact(content_length)!
	} else {
		response.read_to_eof()!
	}
	return HttpResponse{
		status_code: status_code
		body:        payload
	}
}
