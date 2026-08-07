module: convex

// -------------------------------------------------------------------------
// Language-local unit coverage for the transport, JSON, and HTTP layers.
// Exercises real network round trips (against example.com) for the parts
// that only a real peer can prove -- a real TLS handshake, a real
// chunked-transfer-encoding response -- rather than only loopback
// fixtures, the same tradeoff convex-buffer/convex-http.alg documents for
// the ALGOL 60 client. The Live/WebSocket/sync layers have their own
// suite in live-test.dylan.
// -------------------------------------------------------------------------

define variable *failures* :: <integer> = 0;

define function check (label :: <byte-string>, ok? :: <boolean>) => ()
  if (ok?)
    format-out("ok - %s\n", label);
  else
    *failures* := *failures* + 1;
    format-out("FAIL - %s\n", label);
  end if;
end function;

define function test-json () => ()
  let obj = make-json-object();
  json-object-set!(obj, "path", "demo:echo");
  let args = make-json-object();
  json-object-set!(args, "room", "abc");
  json-object-set!(args, "count", 0);
  json-object-set!(obj, "args", args);
  json-object-set!(obj, "format", "json");
  let text = json-encode(obj);
  check("json encode preserves insertion order",
        text = "{\"path\":\"demo:echo\",\"args\":{\"room\":\"abc\",\"count\":0},\"format\":\"json\"}");

  let (decoded, ok1) = json-parse(text);
  check("json decode succeeds", ok1);
  check("json decode round-trips a string field", json-object-ref(decoded, "path") = "demo:echo");
  let decoded-args = json-object-ref(decoded, "args");
  check("json decode round-trips a nested string", json-object-ref(decoded-args, "room") = "abc");
  check("json decode round-trips a nested integer", json-object-ref(decoded-args, "count") = 0);

  let (null-v, ok2) = json-parse("null");
  check("json null decodes to the null singleton", ok2 & json-null?(null-v));

  let (bad, ok3) = json-parse("{not json");
  check("malformed json is rejected, not signalled out", ~ok3);

  let (float-v, ok4) = json-parse("1.0");
  check("an integral-looking float still decodes as a float", ok4 & instance?(float-v, <float>));

  let (int-v, ok5) = json-parse("42");
  check("a bare integer decodes as an integer", ok5 & instance?(int-v, <integer>) & int-v = 42);

  let (str-v, ok6) = json-parse("\"caf\\u00e9 \\\"quoted\\\" \\n end\"");
  check("string escapes and \\u sequences decode", ok6);

  let (arr, ok7) = json-parse("[1, 2, 3]");
  check("arrays decode with correct element order", ok7 & arr.size = 3 & arr[1] = 2);

  check("an integral float re-encodes with an explicit .0", json-encode(1.0d0) = "1.0");

  // Convex's "json" format may render a whole count as either an integer
  // or a float (e.g. 0 or 0.0); decoding must accept both without
  // silently truncating a genuinely fractional value.
  let (zero-int, _a) = json-parse("0");
  let (zero-float, _b) = json-parse("0.0");
  check("integral 0 and 0.0 both decode, as distinct Dylan types",
        instance?(zero-int, <integer>) & instance?(zero-float, <float>));
end function;

define function test-native () => ()
  check("cx-now-ms returns a positive monotonic reading", cx-now-ms() > 0);
  let bytes = cx-random-bytes(16);
  check("cx-random-bytes returns the requested length", bytes.size = 16);
  let bytes2 = cx-random-bytes(16);
  check("two random-byte draws are not identical", bytes ~= bytes2);

  let conn = cx-connect-tls("example.com", 443, cx-now-ms() + 8000);
  check("cx-connect-tls reaches a real TLS host", conn & #t);
  if (conn)
    let request = "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n";
    let wrote? = cx-write(conn, string-to-bytes(request), cx-now-ms() + 5000);
    check("cx-write succeeds", wrote?);
    let data = cx-read(conn, 200, cx-now-ms() + 5000);
    check("cx-read returns response bytes", data & data.size > 0);
    cx-close(conn);
  end if;
end function;

define function find-substring (haystack :: <byte-string>, needle :: <byte-string>) => (idx :: false-or(<integer>))
  let hn = haystack.size;
  let nn = needle.size;
  block (done)
    for (i from 0 to hn - nn)
      if (copy-sequence(haystack, start: i, end: i + nn) = needle)
        done(i);
      end if;
    end for;
    #f
  end block
end function;

define function test-http () => ()
  let url = parse-convex-url("https://example.com");
  check("parse-convex-url detects https", url & url.url-tls?);
  check("parse-convex-url extracts host", url & url.url-host = "example.com");
  check("parse-convex-url defaults the https port to 443", url & url.url-port = 443);

  let url2 = parse-convex-url("http://backend:3210/base");
  check("parse-convex-url extracts an explicit port", url2 & url2.url-port = 3210);
  check("parse-convex-url extracts a path prefix", url2 & url2.url-path = "/base");

  // example.com serves a real chunked response -- exactly the framing
  // edge case worth proving before ever pointing this at Convex.
  let conn = cx-connect-tls("example.com", 443, cx-now-ms() + 8000);
  if (conn)
    let request = "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n";
    cx-write(conn, string-to-bytes(request), cx-now-ms() + 5000);
    let (status, body) = http-read-response(conn, cx-now-ms() + 5000);
    cx-close(conn);
    check("http-read-response parses a 200 status line", status = 200);
    check("http-read-response decodes a non-empty chunked body", body & body.size > 100);
    if (body)
      check("the decoded body contains the expected page content",
            find-substring(body, "Example Domain") & #t);
    end if;
  else
    check("could reach example.com for the chunked-body test", #f);
  end if;
end function;

define function main () => ()
  test-json();
  test-native();
  test-http();
  force-out();
  if (*failures* > 0)
    format-err(concatenate(integer-to-string(*failures*), " client-test check(s) failed\n"));
    force-err();
    c-exit(1);
  end if;
end function;

main();
