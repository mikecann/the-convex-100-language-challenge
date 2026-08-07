// Sync protocol encoding and decoding, including the hostile inputs a drifting
// or malicious server could send.
//
// These are white-box tests: the encoders and the decoder are internal, and the
// point of the exercise is that drift is rejected before it can reach a
// subscription rather than that some public wrapper looks right.

///|
test "connect carries the reconnect bookkeeping the server needs" {
  let message = connect_message("session-1", 3, "DebugDisconnect", Some("Zg=="))
  @test.assert_eq(json_field(message, "type") is Some(String("Connect")), true)
  @test.assert_eq(
    json_field(message, "sessionId") is Some(String("session-1")),
    true,
  )
  @test.assert_eq(
    expect_counter(required_field(message, "connectionCount", "connect"), "c"),
    3L,
  )
  @test.assert_eq(
    json_field(message, "lastCloseReason") is Some(String("DebugDisconnect")),
    true,
  )
  @test.assert_eq(
    json_field(message, "maxObservedTimestamp") is Some(String("Zg==")),
    true,
  )
}

///|
test "connect omits maxObservedTimestamp before the first transition" {
  let message = connect_message("session-1", 0, "InitialConnect", None)
  @test.assert_eq(json_has_field(message, "maxObservedTimestamp"), false)
}

///|
test "ModifyQuerySet chains newVersion onto baseVersion" {
  let message = modify_query_set_message(7, [
    add_modification(
      2,
      "demo:state",
      json_object([("room", Json::string("r"))]),
    ),
  ])
  @test.assert_eq(
    expect_counter(required_field(message, "baseVersion", "modify"), "base"),
    7L,
  )
  @test.assert_eq(
    expect_counter(required_field(message, "newVersion", "modify"), "new"),
    8L,
  )
  let modifications = expect_array(
    required_field(message, "modifications", "modify"),
    "modifications",
  )
  @test.assert_eq(modifications.length(), 1)
  let add = modifications[0]
  @test.assert_eq(json_field(add, "type") is Some(String("Add")), true)
  @test.assert_eq(
    json_field(add, "udfPath") is Some(String("demo:state")),
    true,
  )
  // Convex takes UDF arguments as a single element positional array.
  let args = expect_array(required_field(add, "args", "add"), "args")
  @test.assert_eq(args.length(), 1)
}

///|
test "a well formed Transition decodes into per-query modifications" {
  let message = @json.parse(
    "{\"type\":\"Transition\"," +
    "\"startVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"}," +
    "\"endVersion\":{\"querySet\":1,\"identity\":0,\"ts\":\"AQAAAAAAAAA=\"}," +
    "\"modifications\":[" +
    "{\"type\":\"QueryUpdated\",\"queryId\":1,\"value\":{\"count\":1},\"logLines\":[\"a\"]}," +
    "{\"type\":\"QueryFailed\",\"queryId\":2,\"errorMessage\":\"nope\",\"errorData\":{\"code\":\"ROOM_EMPTY\"}}," +
    "{\"type\":\"QueryRemoved\",\"queryId\":3}]}",
  )
  guard parse_server_message(message) is Transition(start, end, modifications) else {
    fail("expected a Transition")
  }
  @test.assert_eq(start.ts, "AAAAAAAAAAA=")
  @test.assert_eq(end.query_set, 1L)
  @test.assert_eq(modifications.length(), 3)
  guard modifications[0] is QueryUpdated(id, value, logs) else {
    fail("expected QueryUpdated")
  }
  @test.assert_eq(id, 1L)
  @test.assert_eq(logs.length(), 1)
  @test.assert_eq(
    integer_value(required_field(value, "count", "value"), "count"),
    1L,
  )
  guard modifications[1] is QueryFailed(_, message, data, _) else {
    fail("expected QueryFailed")
  }
  @test.assert_eq(message, "nope")
  guard data is Some(payload) else { fail("expected errorData") }
  @test.assert_eq(
    json_field(payload, "code") is Some(String("ROOM_EMPTY")),
    true,
  )
}

///|
test "hostile Transitions are rejected before anything is applied" {
  let hostile = [
    // Not an object at all.
    "[1,2,3]",
    // Missing the type discriminator.
     "{\"startVersion\":{}}",
    // Version members of the wrong type.
     "{\"type\":\"Transition\",\"startVersion\":{\"querySet\":\"0\",\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"endVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"modifications\":[]}",
    // A fractional queryId, which would silently truncate.
     "{\"type\":\"Transition\",\"startVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"endVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":1.5,\"value\":1}]}",
    // QueryUpdated without a value member.
     "{\"type\":\"Transition\",\"startVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"endVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":1}]}",
    // QueryFailed without an error message.
     "{\"type\":\"Transition\",\"startVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"endVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"modifications\":[{\"type\":\"QueryFailed\",\"queryId\":1}]}",
    // An unknown modification type must not be skipped silently.
     "{\"type\":\"Transition\",\"startVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"endVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"modifications\":[{\"type\":\"QueryInvented\",\"queryId\":1}]}",
    // Modifications that are not an array.
     "{\"type\":\"Transition\",\"startVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"endVersion\":{\"querySet\":0,\"identity\":0,\"ts\":\"AAAAAAAAAAA=\"},\"modifications\":{}}",
  ]
  for text in hostile {
    let outcome = try {
      parse_server_message(@json.parse(text)) |> ignore
      "accepted"
    } catch {
      ConvexError(info) => info.kind.to_string()
      _ => "not a ConvexError"
    }
    @test.assert_eq(outcome, "ProtocolError")
  }
}

///|
test "responses this client does not use are ignored rather than fatal" {
  guard parse_server_message(@json.parse("{\"type\":\"Ping\"}")) is Ping else {
    fail("expected Ping")
  }
  guard parse_server_message(@json.parse("{\"type\":\"MutationResponse\"}"))
    is Ignored else {
    fail("expected MutationResponse to be ignored")
  }
  guard parse_server_message(
      @json.parse("{\"type\":\"AuthError\",\"error\":\"bad token\"}"),
    )
    is Fatal(reason) else {
    fail("expected AuthError to be fatal")
  }
  @test.assert_eq(reason.contains("bad token"), true)
}

///|
test "session ids are formatted as version 4 UUIDs" {
  let raw = Bytes::makei(16, index => index.to_byte())
  let formatted = format_session_id(raw)
  @test.assert_eq(formatted.length(), 36)
  @test.assert_eq(formatted.unsafe_char_at(14), '4')
  // The variant nibble must be one of 8, 9, a, or b.
  let variant = formatted.unsafe_char_at(19)
  @test.assert_eq(
    variant == '8' || variant == '9' || variant == 'a' || variant == 'b',
    true,
  )
}
