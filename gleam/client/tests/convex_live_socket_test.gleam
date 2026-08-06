//// Deterministic Live coverage against a fixture sync server.
////
//// The failure modes that matter for Live are the ones an ordinary happy-path
//// test never reaches: a query that fails and then recovers, an unsubscribe
//// that races a relay which has already dequeued an event, and a reconnect
//// that has to resend the query set and suppress an unchanged rehydration.
//// Each scenario below drives those from a fixture server in this process, so
//// the ordering is decided rather than hoped for.

import adapter
import convex
import convex_check as check
import convex_json.{JsonObject, JsonString} as json
import convex_live.{
  type SubscriptionEvent, GateHeld, LiveFailure, LiveValue, SubscriptionEvent,
}
import convex_sys.{type Socket}
import convex_ws as ws
import gleam/bit_array
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/string

/// Fixture reads are generous: the point is deterministic ordering, not speed.
const wait = 10_000

pub fn main() -> Nil {
  initial_value_and_external_update()
  query_failure_then_recovery()
  unsubscribe_is_a_barrier()
  same_identifier_replacement_is_a_barrier()
  reconnect_resends_and_suppresses()
  protocol_drift_then_recovery()
  stopped_consumer_has_one_inflight_delivery()
  stalled_frame_has_an_absolute_deadline()
  subscription_capacity_is_bounded()
  check.done("convex_live_socket_test")
}

// ---------------------------------------------------------------------------
// Scenarios
// ---------------------------------------------------------------------------

/// Add, an initial `QueryUpdated`, and an external update on the same query.
fn initial_value_and_external_update() -> Nil {
  let #(listener, port) = start_listener()
  let assert Ok(client) = convex.new(local_url(port))
  let updates = process.new_subject()
  let assert Ok(subscription) =
    convex.subscribe(client, "demo:state", room_args("alpha"), updates)

  let socket = accept_upgrade(listener)
  let #(connect, buffer) = expect_message(socket, <<>>)
  check.ok("the client opens with Connect", contains(connect, "\"Connect\""))
  check.ok(
    "the first connection reports no earlier close",
    contains(connect, "\"connectionCount\":0"),
  )

  let #(modify, buffer) = expect_message(socket, buffer)
  check.ok("the client adds the query", contains(modify, "\"type\":\"Add\""))
  check.ok(
    "the add carries the query path",
    contains(modify, "\"udfPath\":\"demo:state\""),
  )
  check.ok(
    "the query set advances by one",
    contains(modify, "\"baseVersion\":0")
      && contains(modify, "\"newVersion\":1"),
  )

  send_text(socket, transition(0, 0, 1, 1, updated(0, 0)))
  check.equal_int(
    "the initial value arrives",
    next_count(updates, subscription),
    0,
  )

  send_text(socket, transition(1, 1, 1, 2, updated(0, 1)))
  check.equal_int(
    "an external update arrives",
    next_count(updates, subscription),
    1,
  )

  let assert Ok(_) = convex.unsubscribe(client, subscription)
  let #(remove, _buffer) = expect_message(socket, buffer)
  check.ok("unsubscribing removes the query", contains(remove, "\"Remove\""))

  let assert Ok(_) = convex.close(client)
  convex_sys.close(socket)
  convex_sys.close(listener)
}

/// A failed query is reported without stranding the subscription: a later
/// valid value on the same subscription still arrives.
fn query_failure_then_recovery() -> Nil {
  let #(listener, port) = start_listener()
  let assert Ok(client) = convex.new(local_url(port))
  let updates = process.new_subject()
  let assert Ok(subscription) =
    convex.subscribe(client, "demo:fail", room_args("beta"), updates)

  let socket = accept_upgrade(listener)
  let #(_connect, buffer) = expect_message(socket, <<>>)
  let #(_modify, _buffer) = expect_message(socket, buffer)

  send_text(socket, transition(0, 0, 1, 1, failed(0, "boom")))
  case next_event(updates, subscription) {
    LiveFailure(error) -> {
      check.equal_string(
        "a query failure is a FunctionError",
        error.name,
        "FunctionError",
      )
      check.equal_string(
        "the failure carries its message",
        error.message,
        "boom",
      )
    }
    LiveValue(_, _) -> check.ok("expected a failure, not a value", False)
  }

  // The same subscription must still be able to deliver a later value.
  send_text(socket, transition(1, 1, 1, 2, updated(0, 7)))
  check.equal_int(
    "the subscription recovers",
    next_count(updates, subscription),
    7,
  )

  let assert Ok(_) = convex.close(client)
  convex_sys.close(socket)
  convex_sys.close(listener)
}

/// Unsubscribe must invalidate a relay that has already taken an event.
///
/// The gate holds the relay after it dequeued the value but before it asks for
/// permission. The unsubscribe then completes, and the held event must never
/// reach the subscriber.
fn unsubscribe_is_a_barrier() -> Nil {
  let #(listener, port) = start_listener()
  let gate = process.new_subject()
  let assert Ok(client) = convex.new_with_relay_gate(local_url(port), gate)
  let updates = process.new_subject()
  let assert Ok(subscription) =
    convex.subscribe(client, "demo:state", room_args("gamma"), updates)

  let socket = accept_upgrade(listener)
  let #(_connect, buffer) = expect_message(socket, <<>>)
  let #(_modify, _buffer) = expect_message(socket, buffer)

  send_text(socket, transition(0, 0, 1, 1, updated(0, 0)))
  let assert Ok(GateHeld(release, held_id, _event)) =
    process.receive(gate, wait)
  check.equal_string("the gate holds this subscription", held_id, subscription)

  // The relay is paused mid-delivery. Unsubscribing now has to win.
  let assert Ok(_) = convex.unsubscribe(client, subscription)
  process.send(release, Nil)

  check.ok(
    "no event crosses the unsubscribe acknowledgement",
    process.receive(updates, 500) == Error(Nil),
  )

  let assert Ok(_) = convex.close(client)
  convex_sys.close(socket)
  convex_sys.close(listener)
}

/// Reusing an adapter subscription identifier must retire the old relay before
/// the replacement acknowledgement can be produced. This drives the adapter's
/// actual replacement helper while the old relay is deterministically paused.
fn same_identifier_replacement_is_a_barrier() -> Nil {
  let #(listener, port) = start_listener()
  let gate = process.new_subject()
  let assert Ok(client) = convex.new_with_relay_gate(local_url(port), gate)
  let updates = process.new_subject()
  let args = room_args("replacement")
  let assert Ok(old) = convex.subscribe(client, "demo:state", args, updates)

  let socket = accept_upgrade(listener)
  let #(_connect, buffer) = expect_message(socket, <<>>)
  let #(_old_add, buffer) = expect_message(socket, buffer)

  send_text(socket, transition(0, 0, 1, 1, updated(0, 0)))
  let assert Ok(GateHeld(release, held_id, _event)) =
    process.receive(gate, wait)
  check.equal_string(
    "the replacement gate holds the old subscription",
    held_id,
    old,
  )

  let original = dict.from_list([#(old, "shared")])
  let adapter.Replacement(replaced, outcome) =
    adapter.replace_mapping(
      client,
      original,
      "shared",
      "demo:state",
      args,
      updates,
    )
  let assert Ok(_) = outcome
  check.ok(
    "replacement removes the old real identifier",
    !dict.has_key(replaced, old),
  )
  check.equal_int(
    "replacement leaves one real subscription",
    dict.size(replaced),
    1,
  )

  let #(remove, buffer) = expect_message(socket, buffer)
  let #(add, _buffer) = expect_message(socket, buffer)
  check.ok(
    "replacement removes the old query first",
    contains(remove, "\"type\":\"Remove\""),
  )
  check.ok(
    "replacement then adds the new query",
    contains(add, "\"type\":\"Add\""),
  )

  process.send(release, Nil)
  check.ok(
    "no old event crosses the replacement acknowledgement",
    process.receive(updates, 500) == Error(Nil),
  )

  let assert Ok(_) = convex.close(client)
  convex_sys.close(socket)
  convex_sys.close(listener)
}

/// A forced disconnect must retire the old connection, resend the active
/// query set on the new one, and suppress the unchanged rehydration so the
/// subscriber sees only real news.
fn reconnect_resends_and_suppresses() -> Nil {
  let #(listener, port) = start_listener()
  let assert Ok(client) = convex.new(local_url(port))
  let updates = process.new_subject()
  let assert Ok(subscription) =
    convex.subscribe(client, "demo:state", room_args("delta"), updates)

  let first = accept_upgrade(listener)
  let #(connect, buffer) = expect_message(first, <<>>)
  let assert Ok(connect_json) = json.parse(connect)
  let assert Ok(session_id) = json.string_field(connect_json, "sessionId")
  let #(_modify, _buffer) = expect_message(first, buffer)
  send_text(first, transition(0, 0, 1, 1, updated(0, 0)))
  check.equal_int(
    "the initial value arrives",
    next_count(updates, subscription),
    0,
  )

  let #(last_socket, final_count) =
    list.range(1, 5)
    |> list.fold(#(first, 0), fn(state, attempt) {
      let #(socket, current) = state
      reconnect_once(
        listener,
        client,
        socket,
        updates,
        subscription,
        session_id,
        attempt,
        current,
      )
    })
  check.equal_int("five reconnects deliver five real changes", final_count, 5)

  let assert Ok(_) = convex.close(client)
  convex_sys.close(last_socket)
  convex_sys.close(listener)
}

fn reconnect_once(
  listener: Socket,
  client: convex.Client,
  old_socket: Socket,
  updates: Subject(SubscriptionEvent),
  subscription: String,
  session_id: String,
  attempt: Int,
  current: Int,
) -> #(Socket, Int) {
  let assert Ok(_) = convex.debug_disconnect(client)
  convex_sys.close(old_socket)

  let socket = accept_upgrade(listener)
  let #(connect, buffer) = expect_message(socket, <<>>)
  let assert Ok(connect_json) = json.parse(connect)
  let assert Ok(observed_session) = json.string_field(connect_json, "sessionId")
  check.equal_string(
    "a reconnect preserves the Convex session identifier",
    observed_session,
    session_id,
  )
  check.ok(
    "the new connection reports its connection count",
    contains(connect, "\"connectionCount\":" <> int.to_string(attempt)),
  )
  check.ok(
    "the new connection reports why the old one closed",
    contains(connect, "\"lastCloseReason\":\"adapter debug disconnect\""),
  )
  check.ok(
    "the new connection carries the highest timestamp seen",
    contains(connect, "\"maxObservedTimestamp\""),
  )

  let #(modify, _buffer) = expect_message(socket, buffer)
  check.ok("the query set is resent", contains(modify, "\"type\":\"Add\""))
  check.ok(
    "the resent query set starts from zero again",
    contains(modify, "\"baseVersion\":0"),
  )

  let hydration_timestamp = attempt * 2
  // Rehydration with the same value is not news and must be suppressed.
  send_text(
    socket,
    transition(0, 0, 1, hydration_timestamp, updated(0, current)),
  )
  check.ok(
    "an unchanged rehydration is suppressed",
    process.receive(updates, 500) == Error(Nil),
  )

  let next = current + 1
  send_text(
    socket,
    transition(
      1,
      hydration_timestamp,
      1,
      hydration_timestamp + 1,
      updated(0, next),
    ),
  )
  check.equal_int(
    "the value after the reconnect arrives",
    next_count(updates, subscription),
    next,
  )
  #(socket, next)
}

/// An unsolicited QueryRemoved would strand a still-active local
/// subscription. It is protocol drift, followed by a clean replay and later
/// recovery on the same public handle.
fn protocol_drift_then_recovery() -> Nil {
  let #(listener, port) = start_listener()
  let assert Ok(client) = convex.new(local_url(port))
  let updates = process.new_subject()
  let assert Ok(subscription) =
    convex.subscribe(client, "demo:state", room_args("protocol"), updates)
  let first = accept_upgrade(listener)
  let #(_connect, buffer) = expect_message(first, <<>>)
  let #(_modify, _buffer) = expect_message(first, buffer)
  send_text(first, transition(0, 0, 1, 1, updated(0, 0)))
  check.equal_int(
    "protocol recovery starts healthy",
    next_count(updates, subscription),
    0,
  )

  send_text(first, transition(1, 1, 1, 2, removed(0)))
  case next_event(updates, subscription) {
    LiveFailure(error) ->
      check.equal_string(
        "active QueryRemoved is protocol drift",
        error.name,
        "ProtocolError",
      )
    LiveValue(_, _) ->
      check.ok("protocol drift must not publish a value", False)
  }
  convex_sys.close(first)

  let second = accept_upgrade(listener)
  let #(_connect, buffer) = expect_message(second, <<>>)
  let #(_modify, _buffer) = expect_message(second, buffer)
  send_text(second, transition(0, 0, 1, 3, updated(0, 9)))
  check.equal_int(
    "the subscription recovers after drift",
    next_count(updates, subscription),
    9,
  )

  let assert Ok(_) = convex.close(client)
  convex_sys.close(second)
  convex_sys.close(listener)
}

/// Delivery does not advance until the consumer acknowledges the value it
/// removed from its mailbox. This proves a stopped reader cannot accumulate
/// an unbounded series of already-delivered messages outside the client queue.
fn stopped_consumer_has_one_inflight_delivery() -> Nil {
  let #(listener, port) = start_listener()
  let assert Ok(client) = convex.new(local_url(port))
  let updates = process.new_subject()
  let assert Ok(subscription) =
    convex.subscribe(client, "demo:state", room_args("slow"), updates)
  let socket = accept_upgrade(listener)
  let #(_connect, buffer) = expect_message(socket, <<>>)
  let #(_modify, _buffer) = expect_message(socket, buffer)
  send_text(socket, transition(0, 0, 1, 1, updated(0, 0)))
  let assert Ok(SubscriptionEvent(_, _, first_ack)) =
    process.receive(updates, wait)

  list.range(1, 100)
  |> list.each(fn(value) {
    send_text(socket, transition(1, value, 1, value + 1, updated(0, value)))
  })
  check.ok(
    "a stopped consumer receives only one unacknowledged delivery",
    process.receive(updates, 500) == Error(Nil),
  )
  process.send(first_ack, Nil)
  let resumed = next_count(updates, subscription)
  check.ok("the bounded queue resumes with a newer value", resumed > 0)

  let assert Ok(_) = convex.close(client)
  convex_sys.close(socket)
  convex_sys.close(listener)
}

/// A peer that starts a frame and then stops cannot retain parser state
/// forever. The owner reports drift and retires that exact connection.
fn stalled_frame_has_an_absolute_deadline() -> Nil {
  let #(listener, port) = start_listener()
  let assert Ok(client) = convex.new(local_url(port))
  let updates = process.new_subject()
  let assert Ok(subscription) =
    convex.subscribe(client, "demo:state", room_args("stalled"), updates)
  let socket = accept_upgrade(listener)
  let #(_connect, buffer) = expect_message(socket, <<>>)
  let #(_modify, _buffer) = expect_message(socket, buffer)

  let started = convex_sys.monotonic_ms()
  let assert Ok(_) =
    convex_sys.send(socket, <<0x81, 126, 0, 200, "{\"ty":utf8>>, wait)
  case next_event(updates, subscription) {
    LiveFailure(error) ->
      check.equal_string(
        "a stalled frame is protocol drift",
        error.name,
        "ProtocolError",
      )
    LiveValue(_, _) ->
      check.ok("a stalled frame must not publish a value", False)
  }
  check.ok(
    "the partial-frame deadline is bounded",
    convex_sys.monotonic_ms() - started < 6000,
  )

  let assert Ok(_) = convex.close(client)
  convex_sys.close(socket)
  convex_sys.close(listener)
}

fn subscription_capacity_is_bounded() -> Nil {
  let #(listener, port) = start_listener()
  let assert Ok(client) = convex.new(local_url(port))
  let updates = process.new_subject()
  list.range(0, 7)
  |> list.each(fn(index) {
    check.ok(
      "eight active subscriptions fit the documented bound",
      case
        convex.subscribe(
          client,
          "demo:state",
          room_args("capacity-" <> int.to_string(index)),
          updates,
        )
      {
        Ok(_) -> True
        Error(_) -> False
      },
    )
  })
  check.ok(
    "a ninth active subscription is rejected",
    case
      convex.subscribe(client, "demo:state", room_args("overflow"), updates)
    {
      Error(_) -> True
      Ok(_) -> False
    },
  )
  let assert Ok(_) = convex.close(client)
  convex_sys.close(listener)
}

// ---------------------------------------------------------------------------
// Subscriber helpers
// ---------------------------------------------------------------------------

fn next_event(
  updates: Subject(SubscriptionEvent),
  subscription: String,
) -> convex_live.LiveEvent {
  let assert Ok(SubscriptionEvent(id, event, acknowledged)) =
    process.receive(updates, wait)
  check.equal_string("the event names its subscription", id, subscription)
  process.send(acknowledged, Nil)
  event
}

fn next_count(updates: Subject(SubscriptionEvent), subscription: String) -> Int {
  case next_event(updates, subscription) {
    LiveValue(value, _logs) -> {
      let assert Ok(raw) = json.field(value, "count")
      let assert Ok(number) = json.integral_int(raw)
      number
    }
    LiveFailure(error) -> {
      convex_sys.stderr_write("unexpected failure: " <> error.message)
      panic as "expected a Live value"
    }
  }
}

fn room_args(room: String) -> json.Json {
  JsonObject([#("room", JsonString(room))])
}

fn local_url(port: Int) -> String {
  "http://127.0.0.1:" <> int.to_string(port)
}

// ---------------------------------------------------------------------------
// Fixture sync server
// ---------------------------------------------------------------------------

fn start_listener() -> #(Socket, Int) {
  let assert Ok(listener) = convex_sys.listen(0)
  let assert Ok(port) = convex_sys.listen_port(listener)
  #(listener, port)
}

/// Accept one connection and complete the WebSocket upgrade the way a Convex
/// deployment would, including the derived accept header.
fn accept_upgrade(listener: Socket) -> Socket {
  let assert Ok(socket) = convex_sys.accept(listener, wait)
  let #(head, _rest) = read_until_blank_line(socket, <<>>)
  let assert Ok(text) = bit_array.to_string(head)
  let assert Ok(key) = header_value(text, "sec-websocket-key:")
  let response =
    "HTTP/1.1 101 Switching Protocols\r\n"
    <> "upgrade: websocket\r\n"
    <> "connection: Upgrade\r\n"
    <> "sec-websocket-accept: "
    <> ws.expected_accept(key)
    <> "\r\n\r\n"
  let assert Ok(_) = convex_sys.send(socket, <<response:utf8>>, wait)
  socket
}

fn header_value(head: String, name: String) -> Result(String, Nil) {
  string.split(head, "\r\n")
  |> list.filter_map(fn(line) {
    case string.starts_with(string.lowercase(line), name) {
      True -> Ok(string.trim(string.drop_start(line, string.length(name))))
      False -> Error(Nil)
    }
  })
  |> list.first
}

fn read_until_blank_line(
  socket: Socket,
  buffer: BitArray,
) -> #(BitArray, BitArray) {
  case split_head(buffer, <<>>) {
    Ok(split) -> split
    Error(_) -> {
      let assert convex_sys.Received(chunk) = convex_sys.recv(socket, 0, wait)
      read_until_blank_line(socket, <<buffer:bits, chunk:bits>>)
    }
  }
}

fn split_head(
  input: BitArray,
  seen: BitArray,
) -> Result(#(BitArray, BitArray), Nil) {
  case input {
    <<"\r\n\r\n":utf8, rest:bits>> -> Ok(#(seen, rest))
    <<byte, rest:bits>> -> split_head(rest, <<seen:bits, byte>>)
    _ -> Error(Nil)
  }
}

/// Read one masked client frame. Convex clients must mask, so the fixture
/// insists on it rather than quietly accepting an unmasked frame.
fn expect_message(socket: Socket, buffer: BitArray) -> #(String, BitArray) {
  case take_client_frame(buffer) {
    Ok(#(text, rest)) -> #(text, rest)
    Error(_) -> {
      let assert convex_sys.Received(chunk) = convex_sys.recv(socket, 0, wait)
      expect_message(socket, <<buffer:bits, chunk:bits>>)
    }
  }
}

fn take_client_frame(buffer: BitArray) -> Result(#(String, BitArray), Nil) {
  case buffer {
    <<0x81, 1:size(1), length:size(7), rest:bits>> ->
      case length {
        126 ->
          case rest {
            <<extended:size(16)-unsigned-big-int, rest:bits>> ->
              take_masked(extended, rest)
            _ -> Error(Nil)
          }
        127 -> Error(Nil)
        _ -> take_masked(length, rest)
      }
    _ -> Error(Nil)
  }
}

fn take_masked(length: Int, rest: BitArray) -> Result(#(String, BitArray), Nil) {
  case bit_array.byte_size(rest) >= length + 4 {
    False -> Error(Nil)
    True -> {
      let assert Ok(key) = bit_array.slice(rest, 0, 4)
      let assert Ok(payload) = bit_array.slice(rest, 4, length)
      let assert Ok(tail) =
        bit_array.slice(
          rest,
          4 + length,
          bit_array.byte_size(rest) - 4 - length,
        )
      let bytes =
        list.range(0, int.max(0, length - 1))
        |> list.fold(<<>>, fn(acc, index) {
          case length {
            0 -> acc
            _ -> {
              let assert Ok(<<byte>>) = bit_array.slice(payload, index, 1)
              let assert Ok(<<key_byte>>) = bit_array.slice(key, index % 4, 1)
              <<acc:bits, int.bitwise_exclusive_or(byte, key_byte)>>
            }
          }
        })
      case bit_array.to_string(bytes) {
        Ok(text) -> Ok(#(text, tail))
        Error(_) -> Error(Nil)
      }
    }
  }
}

/// Servers do not mask, so the fixture writes plain frames.
fn send_text(socket: Socket, text: String) -> Nil {
  let payload = bit_array.from_string(text)
  let length = bit_array.byte_size(payload)
  let header = case length < 126 {
    True -> <<0x81, length>>
    False -> <<0x81, 126, length:size(16)-big-int>>
  }
  let assert Ok(_) =
    convex_sys.send(socket, <<header:bits, payload:bits>>, wait)
  Nil
}

// ---------------------------------------------------------------------------
// Sync protocol fixtures
// ---------------------------------------------------------------------------

/// Build a Transition between two versions. The timestamps are the base64
/// little-endian encoding the pinned profile uses.
fn transition(
  start_query_set: Int,
  start_ts: Int,
  end_query_set: Int,
  end_ts: Int,
  modification: String,
) -> String {
  "{\"type\":\"Transition\",\"startVersion\":"
  <> version(start_query_set, start_ts)
  <> ",\"endVersion\":"
  <> version(end_query_set, end_ts)
  <> ",\"modifications\":["
  <> modification
  <> "]}"
}

fn version(query_set: Int, ts: Int) -> String {
  "{\"querySet\":"
  <> int.to_string(query_set)
  <> ",\"identity\":0,\"ts\":\""
  <> timestamp(ts)
  <> "\"}"
}

fn timestamp(value: Int) -> String {
  convex_sys.base64_encode(<<value:size(64)-little-int>>)
}

fn updated(query_id: Int, count: Int) -> String {
  "{\"type\":\"QueryUpdated\",\"queryId\":"
  <> int.to_string(query_id)
  <> ",\"value\":{\"count\":"
  <> int.to_string(count)
  <> "},\"logLines\":[]}"
}

fn failed(query_id: Int, message: String) -> String {
  "{\"type\":\"QueryFailed\",\"queryId\":"
  <> int.to_string(query_id)
  <> ",\"errorMessage\":\""
  <> message
  <> "\",\"logLines\":[]}"
}

fn removed(query_id: Int) -> String {
  "{\"type\":\"QueryRemoved\",\"queryId\":"
  <> int.to_string(query_id)
  <> ",\"logLines\":[]}"
}

fn contains(haystack: String, needle: String) -> Bool {
  string.contains(haystack, needle)
}
