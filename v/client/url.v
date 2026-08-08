module convex

// Endpoint is the parsed deployment URL. Parsing it once, strictly, keeps the
// HTTP and Live paths from disagreeing about the host, the port, or whether TLS
// is required, which is exactly the sort of drift that produces a plaintext
// request to a TLS deployment.
pub struct Endpoint {
pub:
	secure    bool
	host      string
	port      int
	authority string
}

// parse_endpoint accepts only an absolute http or https origin. A path, query,
// fragment, or embedded credential is rejected instead of being silently
// dropped, because the caller would otherwise believe it was honoured.
pub fn parse_endpoint(deployment_url string) !Endpoint {
	mut rest := ''
	mut secure := false
	if deployment_url.starts_with('https://') {
		secure = true
		rest = deployment_url[8..]
	} else if deployment_url.starts_with('http://') {
		rest = deployment_url[7..]
	} else {
		return protocol_error('config', 'deployment URL must start with http:// or https://')
	}
	// A trailing slash is the one path component a deployment URL may carry.
	if rest.ends_with('/') {
		rest = rest[..rest.len - 1]
	}
	if rest.contains('/') || rest.contains('?') || rest.contains('#') || rest.contains('@') {
		return protocol_error('config', 'deployment URL must be a bare origin')
	}
	if rest.len == 0 {
		return protocol_error('config', 'deployment URL is missing a host')
	}
	mut host := rest
	mut port := if secure { 443 } else { 80 }
	colon := rest.last_index_u8(`:`)
	if colon >= 0 {
		host = rest[..colon]
		port_text := rest[colon + 1..]
		if port_text.len == 0 || port_text.len > 5 {
			return protocol_error('config', 'deployment URL port is invalid')
		}
		mut value := 0
		for character in port_text {
			if character < `0` || character > `9` {
				return protocol_error('config', 'deployment URL port is invalid')
			}
			value = value * 10 + int(character - `0`)
		}
		if value < 1 || value > 65535 {
			return protocol_error('config', 'deployment URL port is out of range')
		}
		port = value
	}
	if host.len == 0 || host.len > 255 {
		return protocol_error('config', 'deployment URL host is invalid')
	}
	for character in host {
		is_allowed := (character >= `a` && character <= `z`)
			|| (character >= `A` && character <= `Z`)
			|| (character >= `0` && character <= `9`) || character == `.`
			|| character == `-`
		if !is_allowed {
			return protocol_error('config', 'deployment URL host contains an unsupported character')
		}
	}
	return Endpoint{
		secure:    secure
		host:      host
		port:      port
		authority: '${host}:${port}'
	}
}

// origin rebuilds the canonical origin so evidence and headers show the same
// text the client actually dialled.
pub fn (endpoint Endpoint) origin() string {
	scheme := if endpoint.secure { 'https' } else { 'http' }
	return '${scheme}://${endpoint.authority}'
}

// sync_url derives the pinned Live endpoint from the same parsed origin, so a
// TLS deployment can never be downgraded to a plaintext WebSocket.
pub fn (endpoint Endpoint) sync_url() string {
	scheme := if endpoint.secure { 'wss' } else { 'ws' }
	return '${scheme}://${endpoint.authority}${sync_endpoint_path}'
}
