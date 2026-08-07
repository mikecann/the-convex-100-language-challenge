use "pony_test"

// The HTTP request writer and the bounded response reader.

class iso _TestHttpRequest is UnitTest
  fun name(): String => "http/request"

  fun apply(h: TestHelper) ? =>
    let endpoint = ConvexEndpoint("http://127.0.0.1:3210")?
    let request = Bytes.to_string(HttpRequest.post_json(
      endpoint,
      endpoint.function_path("query"),
      "{\"a\":1}",
      "pony-0.1.0",
      "")?)

    h.assert_true(Bytes.starts_with(request, "POST /api/query HTTP/1.1\r\n"))
    h.assert_true(request.contains("Host: 127.0.0.1:3210\r\n"))
    h.assert_true(request.contains("Content-Type: application/json\r\n"))
    h.assert_true(request.contains("Convex-Client: pony-0.1.0\r\n"))
    h.assert_true(request.contains("Content-Length: 7\r\n"))
    h.assert_true(request.contains("Connection: close\r\n"))
    // No token means no Authorization header at all, not an empty one.
    h.assert_false(request.contains("Authorization"))
    h.assert_true(request.contains("\r\n\r\n{\"a\":1}"))

    let authorised = Bytes.to_string(HttpRequest.post_json(
      endpoint,
      endpoint.function_path("mutation"),
      "{}",
      "pony-0.1.0",
      "token-value")?)
    h.assert_true(authorised.contains("Authorization: Bearer token-value\r\n"))

    // A token carrying a header terminator must be refused, not written.
    h.assert_error({()? =>
      HttpRequest.post_json(
        ConvexEndpoint("http://127.0.0.1:3210")?,
        "/api/query",
        "{}",
        "pony-0.1.0",
        "bad\r\nX-Injected: 1")?
    })

class iso _TestHttpResponse is UnitTest
  fun name(): String => "http/response"

  fun apply(h: TestHelper) ? =>
    // Content-Length framing, delivered in two pieces to prove the reader is
    // incremental rather than whole-message.
    let parser = HttpResponseParser
    parser.push(Bytes.of_string(
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" +
      "Content-Length: 10\r\n\r\n{\"a\":"))?
    h.assert_false(parser.ready())
    parser.push(Bytes.of_string("\"bc\"}"))?
    h.assert_true(parser.ready())
    let response = parser.response()?
    h.assert_eq[U16](200, response.status)
    h.assert_eq[String]("{\"a\":\"bc\"}", response.body)

class iso _TestHttpChunked is UnitTest
  fun name(): String => "http/chunked"

  fun apply(h: TestHelper) ? =>
    let parser = HttpResponseParser
    parser.push(Bytes.of_string(
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\n{\"a\":\r\n"))?
    h.assert_false(parser.ready())
    parser.push(Bytes.of_string("5\r\n\"bc\"}\r\n0\r\n\r\n"))?
    h.assert_true(parser.ready())
    h.assert_eq[String]("{\"a\":\"bc\"}", parser.response()?.body)

class iso _TestHttpStrict is UnitTest
  fun name(): String => "http/strict"

  fun apply(h: TestHelper) =>
    // A response that claims both Content-Length and chunked framing is
    // ambiguous about where the message ends, so it is refused.
    h.assert_error({()? =>
      let parser = HttpResponseParser
      parser.push(Bytes.of_string(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n" +
        "Transfer-Encoding: chunked\r\n\r\n{}"))?
    })

    // Two Content-Length headers are equally ambiguous.
    h.assert_error({()? =>
      let parser = HttpResponseParser
      parser.push(Bytes.of_string(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}"))?
    })

    // Obsolete header line folding is not accepted.
    h.assert_error({()? =>
      let parser = HttpResponseParser
      parser.push(Bytes.of_string(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n  folded\r\n\r\n{}"))?
    })

    // A body larger than the response budget fails before it is buffered.
    h.assert_error({()? =>
      let parser = HttpResponseParser
      parser.push(Bytes.of_string(
        "HTTP/1.1 200 OK\r\nContent-Length: 99999999\r\n\r\n"))?
    })

    // A header block that never terminates cannot grow without limit.
    h.assert_error({()? =>
      let parser = HttpResponseParser
      var filler: String iso = String(20_000)
      var index: USize = 0
      while index < 20_000 do
        filler.push('x')
        index = index + 1
      end
      parser.push(Bytes.of_string("HTTP/1.1 200 OK\r\nX-Long: "))?
      parser.push(Bytes.of_string(consume filler))?
    })

    // A close-delimited body only completes when the peer actually closes.
    h.assert_error({()? =>
      let parser = HttpResponseParser
      parser.push(Bytes.of_string(
        "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n{}"))?
      parser.finish()?
    })

    // The status line is exact. Prefixes such as 1010 and unknown HTTP/1.x
    // versions must not be accepted as valid HTTP/1.1 responses.
    h.assert_error({()? =>
      let parser = HttpResponseParser
      parser.push(Bytes.of_string(
        "HTTP/1.9 200 OK\r\nContent-Length: 0\r\n\r\n"))?
    })

    h.assert_error({()? =>
      let parser = HttpResponseParser
      parser.push(Bytes.of_string(
        "HTTP/1.1 700 Nope\r\nContent-Length: 0\r\n\r\n"))?
    })

    // A zero chunk is incomplete until its final empty trailer line arrives.
    h.assert_error({()? =>
      let parser = HttpResponseParser
      parser.push(Bytes.of_string(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n"))?
      parser.finish()?
    })

class iso _TestHttpCloseDelimited is UnitTest
  fun name(): String => "http/close-delimited"

  fun apply(h: TestHelper) ? =>
    let parser = HttpResponseParser
    parser.push(Bytes.of_string("HTTP/1.1 500 Server Error\r\n\r\nboom"))?
    h.assert_false(parser.ready())
    let response = parser.finish()?
    h.assert_eq[U16](500, response.status)
    h.assert_eq[String]("boom", response.body)
