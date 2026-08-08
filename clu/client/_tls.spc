_tls = cluster is connect, send, recv, close

rep = any

connect = proc (host: string, port: int) returns (cvt)
					  signals (not_possible(string))
	% resolve host, open a TCP connection, complete a TLS handshake,
	% and verify the peer certificate against host (hostname + chain,
	% via OpenSSL's default trust store). fails if any of that fails.
	end connect

send = proc (t: cvt, s: string) signals (not_possible(string))
	% write all of s over the TLS connection
	end send

recv = proc (t: cvt, maxlen: int, timeout_ms: int) returns (string)
				  signals (not_possible(string), end_of_file,
					   timeout)
	% Waits up to timeout_ms for data with poll(2) on the connection's
	% own file descriptor, then reads up to maxlen bytes (capped
	% internally). Signals timeout (connection still open, nothing
	% arrived in time) if the wait expires, or end_of_file on a clean
	% close. The poll-then-read split (rather than an SSL-level
	% timeout) matters here: OpenSSL's SSL_read cannot itself
	% distinguish "peer is merely idle" from "peer closed", so gating
	% on poll(2) first is what lets a caller tell a live-but-quiet
	% connection apart from one that is actually gone.
	end recv

close = proc (t: cvt) signals (not_possible(string))
	% shut down and free the TLS connection
	end close

end _tls
