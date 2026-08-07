module: convex

// -------------------------------------------------------------------------
// Proof that TLS verification is really on.
//
// Certificate checking is the one thing a client can get wrong while
// every happy-path test still passes, so it needs a real peer rather than
// a loopback fixture this process writes to itself. The Docker test stage
// starts a local TLS server with a private CA and runs this program three
// times, once per TLS_MODE (selecting both the trust store via
// SSL_CERT_FILE and, for wronghost, the address dialled):
//   trusted   - the CA is trusted and the name matches: the handshake,
//               and a real request over the encrypted stream, succeed.
//   untrusted - a different CA is trusted: the handshake must fail.
//   wronghost - the right CA is trusted but the connection is made by
//               address rather than by the name on the certificate: the
//               handshake must still fail.
// Only "trusted" would pass on a client that quietly skipped
// verification, which is exactly why the other two matter.
// -------------------------------------------------------------------------

define function run-trusted () => (exit-code :: <integer>)
  let conn = cx-connect-tls("localhost", 44300, cx-now-ms() + 5000);
  if (~conn)
    format-err("trusted handshake unexpectedly failed\n");
    1
  else
    let sent? = cx-write(conn, string-to-bytes("GET / HTTP/1.0\r\n\r\n"), cx-now-ms() + 5000);
    let response = if (sent?) cx-read(conn, 64, cx-now-ms() + 5000) else #f end if;
    cx-close(conn);
    if (response & response.size >= 12 & bytes-to-string(response, start: 0, end: 12) = "HTTP/1.0 200")
      0
    else
      format-err("trusted response was not HTTP/1.0 200\n");
      1
    end if;
  end if
end function;

define function run-untrusted () => (exit-code :: <integer>)
  let conn = cx-connect-tls("localhost", 44300, cx-now-ms() + 5000);
  if (conn)
    cx-close(conn);
    format-err("untrusted handshake unexpectedly succeeded\n");
    1
  else
    0
  end if
end function;

define function run-wronghost () => (exit-code :: <integer>)
  let conn = cx-connect-tls("127.0.0.1", 44300, cx-now-ms() + 5000);
  if (conn)
    cx-close(conn);
    format-err("wronghost handshake unexpectedly succeeded\n");
    1
  else
    0
  end if
end function;

define function main () => ()
  let mode = cx-getenv("TLS_MODE");
  let code =
    if (mode = "trusted")
      run-trusted()
    elseif (mode = "untrusted")
      run-untrusted()
    elseif (mode = "wronghost")
      run-wronghost()
    else
      format-err("TLS_MODE must be trusted, untrusted or wronghost\n");
      1
    end if;
  force-err();
  c-exit(code);
end function;

main();
