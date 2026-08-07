// Adapter serialisation and framing regressions.
//
// The shared controller validates every emitted line against
// `_shared/schemas/adapter.schema.json` and rejects the run on the first
// mismatch, which is a slow and expensive way to discover that an optional
// member was serialised as null. These tests pin the shapes locally instead.

///|
test "a ready event reports the protocol, language, and provenance" {
  let line = ready_event("hello-1", "moonbit", "impl", "runtime")
  let event = @json.parse(line)
  @test.assert_eq(
    @convex.json_field(event, "type") is Some(String("ready")),
    true,
  )
  @test.assert_eq(
    @convex.json_field(event, "protocolVersion") is Some(Number(1.0, ..)),
    true,
  )
  @test.assert_eq(
    @convex.json_field(event, "language") is Some(String("moonbit")),
    true,
  )
  @test.assert_eq(
    @convex.json_field(event, "implementation") is Some(String("impl")),
    true,
  )
  @test.assert_eq(
    @convex.json_field(event, "runtime") is Some(String("runtime")),
    true,
  )
}

///|
test "a result event carries the value and its log lines" {
  let line = result_event("q-1", @json.parse("{\"count\":0}"), ["[LOG] hi"])
  let event = @json.parse(line)
  @test.assert_eq(
    @convex.json_field(event, "type") is Some(String("result")),
    true,
  )
  @test.assert_eq(@convex.json_has_field(event, "value"), true)
  guard @convex.json_field(event, "logs") is Some(Array(logs)) else {
    fail("logs must be an array")
  }
  @test.assert_eq(logs.length(), 1)
}

///|
test "a result event preserves a legitimately null value" {
  // Convex returns JSON null for a function that returns null. Dropping the
  // member would make that indistinguishable from a truncated event.
  let line = result_event("q-1", Json::null(), [])
  let event = @json.parse(line)
  @test.assert_eq(@convex.json_has_field(event, "value"), true)
  @test.assert_eq(@convex.json_field(event, "value") is Some(Null), true)
}

///|
test "an error event omits id and data rather than serialising them as null" {
  let anonymous = @json.parse(
    error_event(None, "ProtocolError", "no id here", None),
  )
  @test.assert_eq(@convex.json_has_field(anonymous, "id"), false)
  guard @convex.json_field(anonymous, "error") is Some(error) else {
    fail("expected an error member")
  }
  @test.assert_eq(@convex.json_has_field(error, "data"), false)
  @test.assert_eq(
    @convex.json_field(error, "name") is Some(String("ProtocolError")),
    true,
  )
  let structured = @json.parse(
    error_event(
      Some("q-1"),
      "FunctionError",
      "boom",
      Some(@json.parse("{\"code\":\"ROOM_EMPTY\"}")),
    ),
  )
  @test.assert_eq(
    @convex.json_field(structured, "id") is Some(String("q-1")),
    true,
  )
  guard @convex.json_field(structured, "error") is Some(payload) else {
    fail("expected an error member")
  }
  guard @convex.json_field(payload, "data") is Some(data) else {
    fail("expected structured error data")
  }
  @test.assert_eq(
    @convex.json_field(data, "code") is Some(String("ROOM_EMPTY")),
    true,
  )
}

///|
test "a subscription error event never carries an id" {
  let event = @json.parse(
    subscription_error_event("sub-1", "FunctionError", "boom", None),
  )
  @test.assert_eq(@convex.json_has_field(event, "id"), false)
  @test.assert_eq(
    @convex.json_field(event, "subscriptionId") is Some(String("sub-1")),
    true,
  )
}

///|
test "ack and closed events are minimal" {
  let ack = @json.parse(ack_event("s-1"))
  @test.assert_eq(@convex.json_field(ack, "type") is Some(String("ack")), true)
  @test.assert_eq(@convex.json_has_field(ack, "value"), false)
  let closed = @json.parse(closed_event("c-1"))
  @test.assert_eq(
    @convex.json_field(closed, "type") is Some(String("closed")),
    true,
  )
}

///|
async test "the writer keeps order and drops events from a retired generation" {
  @async.with_task_group(group => {
    let (source, sink) = @io.pipe()
    let writer = EventWriter::new()
    // Queue everything before the writer starts, so the outcome is decided by
    // the generation check rather than by which task ran first.
    writer.register("sub-1", 1)
    writer.emit(
      subscription_value_event("sub-1", Json::number(1.0), []),
      guard_subscription="sub-1",
      guard_generation=1,
    )
    writer.retire("sub-1")
    writer.emit(ack_event("unsub-1"))
    writer.emit(ack_event("unsub-2"))
    writer.stop()
    // The read half has to be pending before the writer touches the pipe: a
    // write issued while nothing has yet asked to read blocks forever on this
    // async runtime's pipe implementation, deadlocking the test rather than
    // completing (verified directly against `moonbitlang/async` 0.20.3's own
    // `PipeWrite::write_once`, independent of this file's write path). The
    // real adapter never hits this: its sink is the controller's socket or
    // stdout, both continuously drained, not a pipe this same test also holds
    // the only reader for.
    let reading = group.spawn(() => source.read_all().text(), no_wait=true)
    writer.run(sink)
    sink.close()
    let written = reading.wait()
    source.close()
    let lines = written.split("\n").to_array()
    // The stale subscription value never reached the stream, and the two
    // acknowledgements kept their order.
    @test.assert_eq(written.contains("subscription"), false)
    @test.assert_eq(lines.length() >= 2, true)
    @test.assert_eq(lines[0].contains("unsub-1"), true)
    @test.assert_eq(lines[1].contains("unsub-2"), true)
  })
}

///|
async test "the reader splits NDJSON incrementally and tolerates CRLF" {
  let source = @io.MemoryReader(sink => {
    sink.write(@utf8.encode("{\"a\":1}\r\n{\"b\":2}\n"))
  })
  let reader = LineReader::new(source)
  guard reader.next_line() is Line(first) else { fail("expected a line") }
  @test.assert_eq(first, "{\"a\":1}")
  guard reader.next_line() is Line(second) else { fail("expected a line") }
  @test.assert_eq(second, "{\"b\":2}")
  @test.assert_eq(reader.next_line() is Eof, true)
  source.close()
}

///|
async test "an over-long command line is refused and the stream resynchronises" {
  // The oversized line is never retained: the reader keeps scanning for its
  // terminating newline and then carries on with the next command.
  let flood = "x".repeat(MAX_COMMAND_BYTES + 1024)
  let source = @io.MemoryReader(sink => {
    sink.write(@utf8.encode(flood + "\n{\"ok\":true}\n"))
  })
  let reader = LineReader::new(source)
  guard reader.next_line() is Rejected(reason) else {
    fail("expected the flood to be refused")
  }
  @test.assert_eq(reason.contains("line limit"), true)
  guard reader.next_line() is Line(recovered) else {
    fail("expected the stream to resynchronise")
  }
  @test.assert_eq(recovered, "{\"ok\":true}")
  source.close()
}
