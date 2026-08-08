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

recv = proc (t: cvt, maxlen: int) returns (string)
				  signals (not_possible(string), end_of_file)
	% read up to maxlen bytes (capped internally) from the TLS
	% connection; signals end_of_file on a clean close
	end recv

close = proc (t: cvt) signals (not_possible(string))
	% shut down and free the TLS connection
	end close

end _tls
