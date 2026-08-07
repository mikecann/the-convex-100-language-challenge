use "pony_test"
use "../../../../client"

// Tests for the conformance adapter itself.
//
// The shared controller validates every emitted line against the adapter
// schema, and the failure it is easiest to ship is an optional field written
// as null instead of being omitted. These tests assert the exact serialised
// text, so a shape mismatch is caught here rather than in a shared run.

actor Main is TestList
  new create(env: Env) =>
    PonyTest(env, this)

  new make() =>
    None

  fun tag tests(test: PonyTest) =>
    test(_TestAdapterEvents)
    test(_TestAdapterCommands)
    test(_TestAdapterLines)
    test(_TestAdapterOutputOrdering)

class iso _TestAdapterEvents is UnitTest
  fun name(): String => "adapter/events"

  fun apply(h: TestHelper) ? =>
    h.assert_eq[String](
      "{\"protocolVersion\":1,\"id\":\"h1\",\"type\":\"ready\"," +
      "\"language\":\"pony\",\"implementation\":\"native-pony-0.1.0\"," +
      "\"runtime\":\"0.58.0\"}",
      AdapterEvents.ready("h1", "pony", "native-pony-0.1.0", "0.58.0")?)

    h.assert_eq[String](
      "{\"id\":\"q1\",\"type\":\"result\",\"value\":{\"count\":0.0}," +
      "\"logs\":[\"line\"]}",
      AdapterEvents.result(
        "q1",
        JsonDecode("{\"count\":0.0}")?,
        recover val
          let logs = Array[String](1)
          logs.push("line")
          logs
        end)?)

    h.assert_eq[String]("{\"id\":\"a1\",\"type\":\"ack\"}",
      AdapterEvents.ack("a1")?)
    h.assert_eq[String]("{\"id\":\"c1\",\"type\":\"closed\"}",
      AdapterEvents.closed("c1")?)

    // A function error carries its structured payload as `data`.
    h.assert_eq[String](
      "{\"id\":\"f1\",\"type\":\"error\",\"error\":{" +
      "\"name\":\"FunctionError\",\"message\":\"boom\"," +
      "\"data\":{\"code\":\"PONY_EXPECTED\"}}}",
      AdapterEvents.failure("f1", ConvexError.function(
        "boom", JsonDecode("{\"code\":\"PONY_EXPECTED\"}")?, true))?)

    // Without a payload the field is omitted, never written as null.
    let protocol_failure =
      AdapterEvents.failure("f2", ConvexError.protocol("bad envelope"))?
    h.assert_eq[String](
      "{\"id\":\"f2\",\"type\":\"error\",\"error\":{" +
      "\"name\":\"ProtocolError\",\"message\":\"bad envelope\"}}",
      protocol_failure)
    h.assert_false(protocol_failure.contains("null"))

    // A line with no usable identifier omits `id` entirely, because the schema
    // requires a non-empty string when it is present.
    let anonymous =
      AdapterEvents.failure("", ConvexError.protocol("unparseable"))?
    h.assert_false(anonymous.contains("\"id\""))

    h.assert_eq[String](
      "{\"type\":\"subscription\",\"subscriptionId\":\"s1\"," +
      "\"value\":{\"count\":1.0},\"logs\":[]}",
      AdapterEvents.subscription_value(
        "s1", JsonDecode("{\"count\":1.0}")?, NoLogs())?)

    // A subscription failure is not the answer to a command, so it has no id.
    let subscription_failure = AdapterEvents.subscription_failure(
      "s1",
      ConvexError.function(
        "boom", JsonDecode("{\"code\":\"ROOM_EMPTY\"}")?, true))?
    h.assert_eq[String](
      "{\"type\":\"subscription\",\"subscriptionId\":\"s1\",\"error\":{" +
      "\"name\":\"FunctionError\",\"message\":\"boom\"," +
      "\"data\":{\"code\":\"ROOM_EMPTY\"}}}",
      subscription_failure)
    h.assert_false(subscription_failure.contains("\"id\""))

class iso _TestAdapterCommands is UnitTest
  fun name(): String => "adapter/commands"

  fun apply(h: TestHelper) =>
    match AdapterCommandParser.parse(
      "{\"protocolVersion\":1,\"id\":\"h1\",\"op\":\"hello\"}")
    | let command: AdapterCommand => h.assert_eq[String]("hello", command.op)
    | (let id: String, let reason: String) =>
      h.fail("valid hello was refused: " + reason)
    end

    match AdapterCommandParser.parse(
      "{\"id\":\"q1\",\"op\":\"query\",\"path\":\"demo:state\"," +
      "\"args\":{\"room\":\"r\"}}")
    | let command: AdapterCommand =>
      h.assert_eq[String]("demo:state", command.path)
    | (let id: String, let reason: String) =>
      h.fail("valid query was refused: " + reason)
    end

    // Every one of these must be refused with a reason rather than guessed at.
    _refuse(h, "not json")
    _refuse(h, "{\"protocolVersion\":1,\"op\":\"hello\"}")
    _refuse(h, "{\"id\":\"\",\"op\":\"query\",\"path\":\"demo:x\",\"args\":{}}")
    _refuse(h, "{\"id\":\"q\",\"op\":\"query\",\"path\":\"demo:x\"}")
    _refuse(h, "{\"id\":\"q\",\"op\":\"query\",\"path\":\"demo:x\",\"args\":1}")
    _refuse(h, "{\"id\":\"s\",\"op\":\"subscribe\",\"path\":\"demo:x\"," +
      "\"args\":{}}")

    // A command that names itself but fails later validation still gets its
    // `id` echoed back, so the controller can match the refusal to the
    // command that caused it instead of receiving an anonymous error.
    _refuse_with_id(h, "{\"id\":\"h\",\"op\":\"hello\",\"protocolVersion\":2}",
      "h")
    _refuse_with_id(h, "{\"id\":\"u\",\"op\":\"nope\"}", "u")
    // An unexpected field is a refusal: the schema forbids extras, and a
    // controller that sends one is not speaking this protocol.
    _refuse_with_id(h, "{\"id\":\"c\",\"op\":\"close\",\"extra\":1}", "c")

    // The schema counts Unicode characters rather than UTF-8 bytes.
    let long_id = _repeat("x", 128)
    match AdapterCommandParser.parse(
      "{\"id\":\"" + long_id + "\",\"op\":\"close\"}")
    | let command: AdapterCommand => h.assert_eq[USize](128, command.id.size())
    | (let id: String, let reason: String) =>
      h.fail("a 128 character id was refused: " + reason)
    end
    _refuse(h, "{\"id\":\"" + _repeat("x", 129) + "\",\"op\":\"close\"}")

    let emoji_id = _repeat("😀", 128)
    match AdapterCommandParser.parse(
      "{\"id\":\"" + emoji_id + "\",\"op\":\"close\"}")
    | let command: AdapterCommand =>
      h.assert_eq[USize](128 * 4, command.id.size())
    | (let id: String, let reason: String) =>
      h.fail("a 128 character Unicode id was refused: " + reason)
    end
    _refuse(h,
      "{\"id\":\"" + _repeat("😀", 129) + "\",\"op\":\"close\"}")

  fun _refuse(h: TestHelper, line: String) =>
    match AdapterCommandParser.parse(line)
    | let command: AdapterCommand => h.fail("accepted a bad command: " + line)
    | (let id: String, let reason: String) => None
    end

  fun _refuse_with_id(h: TestHelper, line: String, expected_id: String) =>
    match AdapterCommandParser.parse(line)
    | let command: AdapterCommand => h.fail("accepted a bad command: " + line)
    | (let id: String, let reason: String) =>
      h.assert_eq[String](expected_id, id)
    end

  fun _repeat(unit: String, count: USize): String =>
    var out: String iso = String(count * unit.size())
    var index: USize = 0
    while index < count do
      out.append(unit)
      index = index + 1
    end
    consume out

class iso _TestAdapterLines is UnitTest
  fun name(): String => "adapter/lines"

  fun apply(h: TestHelper) ? =>
    let buffer = AdapterLineBuffer

    // Two lines arriving in three reads, one of them splitting a line.
    h.assert_eq[USize](0, buffer.push(Bytes.of_string("{\"a\":")).size())
    let first = buffer.push(Bytes.of_string("1}\n{\"b\":2}\r\n"))
    h.assert_eq[USize](2, first.size())
    h.assert_eq[String]("{\"a\":1}", first(0)?._2)
    // A trailing carriage return belongs to the framing, not to the command.
    h.assert_eq[String]("{\"b\":2}", first(1)?._2)

    // A line beyond the bound is reported once and then skipped to the next
    // terminator, so the stream stays in step.
    var oversized: String iso = String(AdapterLimits.max_line_bytes() + 16)
    var index: USize = 0
    while index < (AdapterLimits.max_line_bytes() + 8) do
      oversized.push('x')
      index = index + 1
    end
    oversized.append("\n{\"c\":3}\n")
    let after = buffer.push(Bytes.of_string(consume oversized))
    h.assert_eq[USize](2, after.size())
    h.assert_false(after(0)?._1)
    h.assert_true(after(1)?._1)
    h.assert_eq[String]("{\"c\":3}", after(1)?._2)

class iso _CollectingWriter is OutputWriter
  let _collector: _OutputScenario

  new iso create(collector: _OutputScenario) =>
    _collector = collector

  fun ref write(text: String): Bool =>
    _collector.wrote(text)
    true

  fun ref dispose() =>
    None

actor _OutputScenario is AdapterExit
  """
  Proves the ordering guarantee the shared controller depends on: an event from
  a retired relay generation can never appear after the acknowledgement that
  retired it, even when the relay produces it late.
  """

  let _h: TestHelper
  let _lines: Array[String] = Array[String]

  new create(h: TestHelper) =>
    _h = h

  be start() =>
    let output = AdapterOutput(_CollectingWriter(this), this)
    let relay = AdapterRelay(output, "s1", 1)

    output.activate_relay("s1", 1)
    output.emit_relay("s1", 1, "first-update", relay)
    // Unsubscribe: the relay is retired, and only then is the command
    // acknowledged.
    output.invalidate_relay("s1", 1)
    output.emit("unsubscribe-ack")
    // A late event from the retired generation, exactly as a paused relay
    // resuming after its dequeue would produce. It must be discarded.
    output.emit_relay("s1", 1, "stale-update", relay)
    output.emit("finished")

  be wrote(text: String) =>
    if text == "finished\n" then
      _h.assert_eq[USize](2, _lines.size())
      try
        _h.assert_eq[String]("first-update\n", _lines(0)?)
        _h.assert_eq[String]("unsubscribe-ack\n", _lines(1)?)
      end
      _h.complete(true)
    else
      _lines.push(text)
    end

  be adapter_finished(code: I32) =>
    _h.fail("the collecting output unexpectedly failed")
    _h.complete(false)

class iso _TestAdapterOutputOrdering is UnitTest
  fun name(): String => "adapter/output-ordering"

  fun apply(h: TestHelper) =>
    h.long_test(20_000_000_000)
    _OutputScenario(h).start()
