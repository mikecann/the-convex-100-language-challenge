module convex

fn endpoint_rejected(url string) bool {
	parse_endpoint(url) or { return true }
	return false
}

fn test_plain_and_tls_origins_get_their_default_ports() ! {
	plain := parse_endpoint('http://backend:3210')!
	assert plain.secure == false
	assert plain.host == 'backend'
	assert plain.port == 3210
	assert plain.authority == 'backend:3210'

	implicit := parse_endpoint('http://backend')!
	assert implicit.port == 80

	secure := parse_endpoint('https://example.convex.cloud')!
	assert secure.secure == true
	assert secure.port == 443
}

fn test_trailing_slash_is_the_only_tolerated_path() ! {
	trimmed := parse_endpoint('https://example.convex.cloud/')!
	assert trimmed.authority == 'example.convex.cloud:443'
	assert endpoint_rejected('https://example.convex.cloud/api')
	assert endpoint_rejected('https://example.convex.cloud/?query=1')
	assert endpoint_rejected('https://user:secret@example.convex.cloud')
}

fn test_non_http_schemes_and_malformed_ports_are_rejected() {
	assert endpoint_rejected('ws://example.convex.cloud')
	assert endpoint_rejected('example.convex.cloud')
	assert endpoint_rejected('http://')
	assert endpoint_rejected('http://host:0')
	assert endpoint_rejected('http://host:70000')
	assert endpoint_rejected('http://host:port')
	assert endpoint_rejected('http://ho st')
}

fn test_sync_url_cannot_downgrade_a_tls_deployment() ! {
	// Deriving the Live URL from the parsed origin, rather than by string
	// substitution on the deployment URL, is what makes a wss deployment
	// impossible to turn into a plaintext ws connection.
	secure := parse_endpoint('https://example.convex.cloud')!
	assert secure.sync_url() == 'wss://example.convex.cloud:443/api/sync'
	assert secure.origin() == 'https://example.convex.cloud:443'

	plain := parse_endpoint('http://backend:3210')!
	assert plain.sync_url() == 'ws://backend:3210/api/sync'
}
