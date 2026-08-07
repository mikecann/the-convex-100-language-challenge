// Deterministic hostile HTTP fixtures.
//
// A real deployment always answers correctly, which is exactly why it is a poor
// test subject: the interesting behaviour is what this client does when the
// peer is wrong. Each test here drives a raw TCP peer that speaks one specific
// malformed or oversized response and asserts that the client reports the right
// failure family instead of guessing.

///|
/// UTF-8 encode a body. `String::to_bytes` produces UTF-16 code units, which is
/// not what an HTTP peer puts on the wire.
fn utf8_bytes(text : String) -> Bytes {
  @utf8.encode(text)
}

///|
/// Read one HTTP request off a raw connection and return its head.
///
/// The peer has to consume the request body before answering, otherwise a
/// client that is still writing can block against an unread socket buffer and
/// the test would hang rather than fail.
async fn take_http_request(connection : @socket.Tcp) -> String {
  guard connection.read_until("\r\n\r\n") is Some(head) else { return "" }
  let lower = head.to_lower()
  guard lower.find("content-length:") is Some(start) else { return head }
  let rest = lower.substring(start=start + 15)
  let end = match rest.find("\r\n") {
    Some(index) => index
    None => rest.length()
  }
  let digits = rest.substring(start=0, end~)
  let length = @string.parse_int(digits.trim_space()) catch { _ => 0 }
  if length > 0 {
    connection.read_exactly(length) |> ignore
  }
  head
}

///|
async fn consume_http_request(connection : @socket.Tcp) -> Unit {
  take_http_request(connection) |> ignore
}

///|
/// The value of the request's `Authorization` header, or the empty string when
/// the request carried none. Absent and empty are different answers here: the
/// point of the test below is that clearing a token removes the header rather
/// than sending a blank one.
fn authorization_header(head : String) -> String {
  let lower = head.to_lower()
  guard lower.find("authorization:") is Some(start) else { return "" }
  let rest = head.substring(start=start + 14)
  let end = match rest.find("\r\n") {
    Some(index) => index
    None => rest.length()
  }
  rest.substring(start=0, end~).trim_space().to_owned()
}

///|
/// Frame a body as a complete HTTP/1.1 response the peer then closes.
fn http_response(status : Int, reason : String, body : Bytes) -> Bytes {
  framed_response(status, reason, body, body.length(), keep_alive=false)
}

///|
/// Frame a response with an arbitrary declared length and connection
/// disposition.
///
/// `declared` is written into `Content-Length` while `body` is what actually
/// goes out, so a peer can under-declare, over-declare, or truncate. With
/// `keep_alive` the peer promises to hold the connection open, which is the
/// case that separates a client that honours the framing from one that just
/// reads until the socket dies: the second kind hangs here until its own
/// deadline expires.
fn framed_response(
  status : Int,
  reason : String,
  body : Bytes,
  declared : Int,
  keep_alive~ : Bool,
) -> Bytes {
  let disposition = if keep_alive { "keep-alive" } else { "close" }
  let head = "HTTP/1.1 " +
    status.to_string() +
    " " +
    reason +
    "\r\nContent-Type: application/json\r\nContent-Length: " +
    declared.to_string() +
    "\r\nConnection: " +
    disposition +
    "\r\n\r\n"
  let framed = @buffer.Buffer(size_hint=head.length() + body.length())
  framed.write_bytes(utf8_bytes(head)[:])
  framed.write_bytes(body[:])
  framed.to_bytes()
}

///|
/// Run `body` against a raw peer that answers exactly one request.
async fn with_raw_http_peer(
  respond : async (@socket.Tcp) -> Unit,
  body : async (String) -> Unit,
) -> Unit {
  @async.with_task_group(group => {
    let server = @socket.TcpServer::TcpServer(
      @socket.Addr::parse("127.0.0.1:0"),
      reuse_addr=true,
    )
    let port = server.addr.port()
    group.spawn_bg(
      () => {
        defer server.close()
        let (connection, _) = server.accept()
        defer connection.close()
        consume_http_request(connection)
        respond(connection)
      },
      no_wait=true,
      // A client that refuses an oversized body stops reading, so the peer's
      // write can legitimately fail with a broken pipe.
      allow_failure=true,
    )
    body("http://127.0.0.1:" + port.to_string())
  })
}

///|
/// Run `body` against a peer that answers each connection it accepts with the
/// next scripted response and then holds the socket open for `hold_ms`.
///
/// Holding is the point. A client that ignored `Content-Length` and simply read
/// until the peer hung up would pass every fixture whose peer closes straight
/// away, so the framing would never actually be under test. A peer that keeps
/// its promise to stay open separates the two: a client that honours the
/// declared length returns immediately, and one that does not sits there until
/// its own deadline.
///
/// Successive connections get successive responses because this client opens a
/// fresh connection per call, which is what makes "and then it recovers"
/// expressible.
async fn with_scripted_http_peer(
  responses : Array[Bytes],
  hold_ms : Int,
  body : async (String) -> Unit,
) -> Unit {
  @async.with_task_group(group => {
    let server = @socket.TcpServer::TcpServer(
      @socket.Addr::parse("127.0.0.1:0"),
      reuse_addr=true,
    )
    let port = server.addr.port()
    let served = Counter::{ value: 0 }
    group.spawn_bg(
      () => {
        defer server.close()
        for ;; {
          let (connection, _) = server.accept()
          let index = served.value
          served.value = served.value + 1
          group.spawn_bg(
            () => {
              defer connection.close()
              consume_http_request(connection)
              if index < responses.length() {
                connection.write(responses[index])
              }
              if hold_ms > 0 {
                @async.sleep(hold_ms)
              }
            },
            no_wait=true,
            allow_failure=true,
          )
        }
      },
      no_wait=true,
      allow_failure=true,
    )
    body("http://127.0.0.1:" + port.to_string())
  })
}

///|
/// Run `body` against a peer that answers every connection it accepts and
/// records the `Authorization` header each request carried.
///
/// This client opens a fresh connection per call, so proving that a credential
/// change takes effect immediately needs a peer that survives more than one
/// request. Ordering is deterministic because the client's calls are
/// sequential: the next one is not made until the previous response is read.
async fn with_recording_http_peer(
  observed : Array[String],
  body : async (String) -> Unit,
) -> Unit {
  @async.with_task_group(group => {
    let server = @socket.TcpServer::TcpServer(
      @socket.Addr::parse("127.0.0.1:0"),
      reuse_addr=true,
    )
    let port = server.addr.port()
    group.spawn_bg(
      () => {
        defer server.close()
        for ;; {
          let (connection, _) = server.accept()
          group.spawn_bg(
            () => {
              defer connection.close()
              observed.push(authorization_header(take_http_request(connection)))
              connection.write(
                http_response(
                  200,
                  "OK",
                  utf8_bytes("{\"status\":\"success\",\"value\":{\"count\":0}}"),
                ),
              )
            },
            no_wait=true,
            allow_failure=true,
          )
        }
      },
      no_wait=true,
      allow_failure=true,
    )
    body("http://127.0.0.1:" + port.to_string())
  })
}

///|
/// Drive one credential lifecycle: absent, set, replaced, cleared.
async fn exercise_tokens(
  origin : String,
  token : String,
  replacement : String,
) -> Unit {
  @convex.with_client(origin, client => {
    let args = @json.parse("{\"room\":\"r\"}")
    // No credential configured: the header must be absent, not blank.
    client.query("demo:state", args) |> ignore
    client.set_auth(Some(token))
    client.query("demo:state", args) |> ignore
    // The token is attached per request rather than per connection, so a
    // replacement takes effect on the very next call.
    client.set_auth(Some(replacement))
    client.query("demo:state", args) |> ignore
    // An empty string clears the credential. This is the case the shared suite
    // uses to prove a replaced token is really forgotten rather than cached.
    client.set_auth(Some(""))
    client.query("demo:state", args) |> ignore
  })
}

///|
async test "a configured token reaches the wire as a verbatim bearer header" {
  // An opaque token shaped like the JWT a Convex deployment would be given.
  // Convex validates it server side, so anything this client rewrites - case,
  // padding, the `-` and `_` of base64url - turns into an authentication
  // failure that looks like a deployment problem instead of a client bug.
  let token = "eyJhbGciOiJIUzI1NiJ9.e30.-Zm9v_YmFyIQ"
  let replacement = "eyJhbGciOiJIUzI1NiJ9.e31.-YmF6_cXV4IQ"
  let observed : Array[String] = []
  with_recording_http_peer(observed, origin => {
    exercise_tokens(origin, token, replacement)
  })
  @test.assert_eq(observed.length(), 4)
  @test.assert_eq(observed[0], "")
  @test.assert_eq(observed[1], "Bearer " + token)
  @test.assert_eq(observed[2], "Bearer " + replacement)
  @test.assert_eq(observed[3], "")
}

///|
/// Run one query and report either the decoded count or the failure family and
/// message, so each test can assert on a single string.
async fn probe_query(origin : String) -> String {
  @convex.with_client(origin, client => {
    let outcome = try {
      let result = client.query("demo:state", @json.parse("{\"room\":\"r\"}"))
      let count = @convex.integer_value(
        @convex.required_field(result.value, "count", "state"),
        "count",
      )
      "count=" + count.to_string() + " logs=" + result.logs.length().to_string()
    } catch {
      @convex.ConvexError(info) => info.kind.to_string() + ": " + info.message
      _ => "unexpected error"
    }
    outcome
  })
}

///|
async test "a success envelope yields the value and its log lines" {
  with_raw_http_peer(
    connection => {
      connection.write(
        http_response(
          200,
          "OK",
          utf8_bytes(
            "{\"status\":\"success\",\"value\":{\"count\":0},\"logLines\":[\"[LOG] demo:echo\"]}",
          ),
        ),
      )
    },
    origin => @test.assert_eq(probe_query(origin), "count=0 logs=1"),
  )
}

///|
async test "an error envelope becomes a FunctionError carrying errorData" {
  with_raw_http_peer(
    connection => {
      connection.write(
        http_response(
          200,
          "OK",
          utf8_bytes(
            "{\"status\":\"error\",\"errorMessage\":\"boom\",\"errorData\":{\"code\":\"ROOM_EMPTY\"}}",
          ),
        ),
      )
    },
    origin => {
      let outcome = @convex.with_client(origin, client => {
        try {
          client.query("demo:fail", @json.parse("{\"code\":\"x\"}")) |> ignore
          "accepted"
        } catch {
          @convex.ConvexError(info) => {
            let code = match info.data {
              Some(data) =>
                match @convex.json_field(data, "code") {
                  Some(String(code)) => code
                  _ => "no-code"
                }
              None => "no-data"
            }
            info.kind.to_string() + "/" + code
          }
          _ => "unexpected error"
        }
      })
      @test.assert_eq(outcome, "FunctionError/ROOM_EMPTY")
    },
  )
}

///|
async test "a non-2xx status is protocol drift, not a function failure" {
  with_raw_http_peer(
    connection => {
      connection.write(
        http_response(500, "Internal Server Error", utf8_bytes("{}")),
      )
    },
    origin => {
      @test.assert_eq(probe_query(origin).has_prefix("ProtocolError"), true)
    },
  )
}

///|
async test "an oversized body is refused instead of being buffered" {
  let padding = "x".repeat(@convex.HTTP_MAX_RESPONSE_BYTES + 64)
  with_raw_http_peer(
    connection => {
      connection.write(
        http_response(
          200,
          "OK",
          utf8_bytes("{\"status\":\"success\",\"value\":\"" + padding + "\"}"),
        ),
      )
    },
    origin => {
      let outcome = probe_query(origin)
      @test.assert_eq(outcome.has_prefix("ProtocolError"), true)
      @test.assert_eq(outcome.contains("exceeded"), true)
    },
  )
}

///|
async test "a body that is not valid UTF-8 is protocol drift" {
  with_raw_http_peer(
    connection => connection.write(http_response(200, "OK", b"\xff\xfe\xfd")),
    origin => {
      let outcome = probe_query(origin)
      @test.assert_eq(outcome.has_prefix("ProtocolError"), true)
      @test.assert_eq(outcome.contains("UTF-8"), true)
    },
  )
}

///|
async test "a body that is not JSON is protocol drift" {
  with_raw_http_peer(
    connection => {
      connection.write(http_response(200, "OK", utf8_bytes("not json at all")))
    },
    origin => {
      @test.assert_eq(probe_query(origin).has_prefix("ProtocolError"), true)
    },
  )
}

///|
async test "a success envelope with no value member is refused" {
  // A truncated envelope must not be reported as a successful null result.
  with_raw_http_peer(
    connection => {
      connection.write(
        http_response(200, "OK", utf8_bytes("{\"status\":\"success\"}")),
      )
    },
    origin => {
      let outcome = probe_query(origin)
      @test.assert_eq(outcome.has_prefix("ProtocolError"), true)
      @test.assert_eq(outcome.contains("value"), true)
    },
  )
}

///|
async test "an unknown envelope status is refused" {
  with_raw_http_peer(
    connection => {
      connection.write(
        http_response(200, "OK", utf8_bytes("{\"status\":\"maybe\"}")),
      )
    },
    origin => {
      @test.assert_eq(probe_query(origin).has_prefix("ProtocolError"), true)
    },
  )
}

///|
/// A success envelope of a given body, used by the framing fixtures below.
fn success_body(count : Int) -> Bytes {
  utf8_bytes(
    "{\"status\":\"success\",\"value\":{\"count\":" +
    count.to_string() +
    "},\"logLines\":[]}",
  )
}

///|
async test "a keep-alive response is framed by Content-Length, not by EOF" {
  let body = success_body(0)
  with_scripted_http_peer(
    [framed_response(200, "OK", body, body.length(), keep_alive=true)],
    // Far longer than the call should take, and shorter than the client's own
    // thirty second deadline, so waiting for the socket to die is measurable as
    // a failure rather than as a slow pass.
    20000,
    origin => {
      let started = @async.now()
      @test.assert_eq(probe_query(origin), "count=0 logs=0")
      // The peer is still holding the connection open at this point, so the
      // call can only have returned by trusting the declared length.
      @test.assert_eq(@async.now() - started < 10000L, true)
    },
  )
}

///|
async test "a body shorter than its Content-Length never becomes a value" {
  let body = success_body(0)
  // Promise sixteen more bytes than are sent and then hang up. A client that
  // treated whatever arrived before EOF as the whole body would decode a
  // truncated envelope, and a truncated envelope is exactly what a permissive
  // parser turns into a plausible wrong answer.
  let truncated = framed_response(
    200,
    "OK",
    body,
    body.length() + 16,
    keep_alive=false,
  )
  with_scripted_http_peer([truncated], 0, origin => {
    let outcome = probe_query(origin)
    @test.assert_eq(outcome.has_prefix("count="), false)
    // Either family is honest here: the transport lost the rest of the body, or
    // what arrived was not a Convex envelope. What it must not be is a value.
    @test.assert_eq(
      outcome.has_prefix("ProtocolError") ||
      outcome.has_prefix("TransportError"),
      true,
    )
  })
}

///|
async test "an over-limit body is refused and the next call still succeeds" {
  let padding = "x".repeat(@convex.HTTP_MAX_RESPONSE_BYTES + 64)
  let oversized = utf8_bytes(
    "{\"status\":\"success\",\"value\":\"" + padding + "\"}",
  )
  let ok = success_body(0)
  with_scripted_http_peer(
    [
      framed_response(200, "OK", oversized, oversized.length(), keep_alive=true),
      framed_response(200, "OK", ok, ok.length(), keep_alive=true),
    ],
    20000,
    origin => {
      @convex.with_client(origin, client => {
        let args = @json.parse("{\"room\":\"r\"}")
        let refused = try {
          client.query("demo:state", args) |> ignore
          "accepted"
        } catch {
          @convex.ConvexError(info) =>
            info.kind.to_string() + ": " + info.message
          _ => "unexpected error"
        }
        @test.assert_eq(refused.has_prefix("ProtocolError"), true)
        @test.assert_eq(refused.contains("exceeded"), true)
        // Refusing a body must not poison the client. Each call opens its own
        // connection, so the next one is unaffected by the one that was refused.
        let recovered = client.query("demo:state", args)
        @test.assert_eq(
          @convex.integer_value(
            @convex.required_field(recovered.value, "count", "state"),
            "count",
          ),
          0L,
        )
      })
    },
  )
}

///|
async test "an error envelope under a failing status keeps its errorData" {
  // Convex answers a thrown function with 200, but a deployment behind a proxy
  // may deliver the same envelope as 5xx. Dropping `errorData` because of the
  // status line would flatten an application error the caller is expected to
  // branch on into "the server said 500".
  let envelope = utf8_bytes(
    "{\"status\":\"error\",\"errorMessage\":\"boom\"," +
    "\"errorData\":{\"code\":\"ROOM_EMPTY\"},\"logLines\":[\"[LOG] a\"]}",
  )
  with_scripted_http_peer(
    [
      framed_response(
        500,
        "Internal Server Error",
        envelope,
        envelope.length(),
        keep_alive=true,
      ),
    ],
    20000,
    origin => {
      let outcome = @convex.with_client(origin, client => {
        try {
          client.query("demo:fail", @json.parse("{\"room\":\"r\"}")) |> ignore
          "accepted"
        } catch {
          @convex.ConvexError(info) => {
            let code = match info.data {
              Some(data) =>
                match @convex.json_field(data, "code") {
                  Some(String(code)) => code
                  _ => "no-code"
                }
              None => "no-data"
            }
            info.kind.to_string() +
            "/" +
            code +
            "/" +
            info.logs.length().to_string()
          }
          _ => "unexpected error"
        }
      })
      @test.assert_eq(outcome, "FunctionError/ROOM_EMPTY/1")
    },
  )
}

///|
async test "a success envelope under a failing status is refused" {
  // The body claims the function returned a value and the status says the call
  // did not succeed. Believing the body here would report a proxy's cached or
  // synthesised page as a Convex result.
  let body = success_body(7)
  with_scripted_http_peer(
    [framed_response(502, "Bad Gateway", body, body.length(), keep_alive=true)],
    20000,
    origin => {
      let outcome = probe_query(origin)
      @test.assert_eq(outcome.has_prefix("ProtocolError"), true)
      @test.assert_eq(outcome.contains("502"), true)
      @test.assert_eq(outcome.contains("count=7"), false)
    },
  )
}

///|
async test "a failing status with no envelope is reported as the status" {
  let page = utf8_bytes("<html><body>gateway timeout</body></html>")
  with_scripted_http_peer(
    [
      framed_response(
        504,
        "Gateway Timeout",
        page,
        page.length(),
        keep_alive=true,
      ),
    ],
    20000,
    origin => {
      let outcome = probe_query(origin)
      @test.assert_eq(outcome.has_prefix("ProtocolError"), true)
      // The status is the only fact in the response, so it is the whole report
      // rather than a complaint about the punctuation of an error page.
      @test.assert_eq(outcome.contains("504"), true)
    },
  )
}
