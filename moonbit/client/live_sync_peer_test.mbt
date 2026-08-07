// Live protocol behaviour against a scripted Convex sync peer.
//
// The peer is a real WebSocket server that speaks the sync protocol by hand, so
// every assertion below is about bytes that actually crossed a socket. Each
// test scripts exactly what the server does, which makes reconnects, version
// chains, and rehydration suppression deterministic instead of timing
// dependent.

///|
/// What a scripted peer observed about the client's traffic.
///
/// A handler ends by waiting for the client to tear its connection down, so it
/// has to tolerate an error from the socket - and that tolerance would swallow
/// a failed assertion just as happily. Handlers record what they checked here,
/// and the test body asserts on the record once the client has finished.
/// Without this, every peer-side assertion in this file would be one that
/// cannot fail.
struct PeerLog {
  failures : Array[String]
}

///|
fn PeerLog::new() -> PeerLog {
  { failures: [] }
}

///|
fn PeerLog::check(self : PeerLog, holds : Bool, what : String) -> Unit {
  if !holds {
    self.failures.push(what)
  }
}

///|
fn PeerLog::assert_clean(self : PeerLog) -> Unit raise {
  guard self.failures.length() == 0 else {
    fail("the peer rejected what the client sent: " + self.failures[0])
  }
}

///|
/// Run `body` against a sync peer. `handle` is invoked once per accepted
/// connection with the zero-based connection index, so a test can script what
/// the first connection does and what its replacement does.
async fn with_sync_peer(
  handle : async (Int, @websocket.Conn) -> Unit,
  body : async (String) -> Unit,
) -> Unit {
  @async.with_task_group(group => {
    let server = @http.Server(
      @socket.Addr::parse("127.0.0.1:0"),
      reuse_addr=true,
    )
    let port = server.addr.port()
    group.spawn_bg(
      () => {
        defer server.close()
        let mut index = 0
        for ;; {
          let (connection, _) = server.accept()
          let current = index
          index = index + 1
          // Each connection is handled in its own task. A reconnect arrives
          // while the previous handler is still blocked reading the socket it
          // is about to lose, so serving them one at a time would deadlock.
          group.spawn_bg(
            () => {
              let request = connection.read_request()
              let socket = @websocket.from_http_server(request, connection)
              defer socket.close()
              // A scripted handler ends by letting the client tear the
              // connection down, so a failure here is expected. Assertions go
              // through a `PeerLog` precisely because this swallows errors.
              handle(current, socket) catch {
                _ => ()
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
/// Read one client message off the socket and decode it.
async fn peer_recv(socket : @websocket.Conn) -> Json {
  let message = socket.recv()
  @json.parse(message.read_all().text())
}

///|
/// Read one client message and record whether its `type` was the expected one.
async fn peer_expect(
  log : PeerLog,
  socket : @websocket.Conn,
  expected : String,
) -> Json {
  let message = peer_recv(socket)
  log.check(
    @convex.json_field(message, "type") is Some(String(found)) &&
    found == expected,
    "expected a " + expected + " message",
  )
  message
}

///|
/// Pull the `queryId` out of the first `Add` in a `ModifyQuerySet`.
fn add_query_id(message : Json) -> Int raise {
  let modifications = @convex.required_field(
    message, "modifications", "ModifyQuerySet",
  )
  guard modifications is Array(entries) else {
    fail("ModifyQuerySet modifications were not an array")
  }
  for entry in entries {
    if @convex.json_field(entry, "type") is Some(String("Add")) {
      return @convex.integer_value(
        @convex.required_field(entry, "queryId", "Add"),
        "queryId",
      ).to_int()
    }
  }
  fail("ModifyQuerySet contained no Add")
}

///|
/// The `queryId` of the first `Remove` in a `ModifyQuerySet`, or `-1` when the
/// message removed nothing. Returning a sentinel rather than failing keeps the
/// answer reportable through a `PeerLog`.
fn remove_query_id(message : Json) -> Int raise {
  let modifications = @convex.json_field(message, "modifications")
  guard modifications is Some(Array(entries)) else { return -1 }
  for entry in entries {
    if @convex.json_field(entry, "type") is Some(String("Remove")) {
      return @convex.integer_value(
        @convex.required_field(entry, "queryId", "Remove"),
        "queryId",
      ).to_int()
    }
  }
  -1
}

///|
fn transition(
  start_query_set : Int,
  start_ts : String,
  end_query_set : Int,
  end_ts : String,
  modifications : String,
) -> String {
  "{\"type\":\"Transition\",\"startVersion\":{\"querySet\":" +
  start_query_set.to_string() +
  ",\"identity\":0,\"ts\":\"" +
  start_ts +
  "\"},\"endVersion\":{\"querySet\":" +
  end_query_set.to_string() +
  ",\"identity\":0,\"ts\":\"" +
  end_ts +
  "\"},\"modifications\":[" +
  modifications +
  "]}"
}

///|
fn query_updated(query_id : Int, value : String) -> String {
  "{\"type\":\"QueryUpdated\",\"queryId\":" +
  query_id.to_string() +
  ",\"value\":" +
  value +
  ",\"logLines\":[]}"
}

///|
fn query_failed(query_id : Int, code : String) -> String {
  "{\"type\":\"QueryFailed\",\"queryId\":" +
  query_id.to_string() +
  ",\"errorMessage\":\"query failed\",\"errorData\":{\"code\":\"" +
  code +
  "\"},\"logLines\":[]}"
}

///|
/// A syntactically valid Convex sync timestamp for step `step`.
///
/// The client validates the encoding of every `ts` it sees, because the value
/// is handed straight back to the deployment as `maxObservedTimestamp` on the
/// next `Connect`. It never orders or decodes one, so a fixture only has to
/// produce distinct well-formed values: eight bytes of database time is eleven
/// base64 characters and one pad.
fn peer_ts(step : Int) -> String {
  let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ" +
    "abcdefghijklmnopqrstuvwxyz0123456789+/"
  let low = step % 64
  let high = step / 64 % 64
  "AAAAAAAAA" +
  alphabet.substring(start=high, end=high + 1) +
  alphabet.substring(start=low, end=low + 1) +
  "="
}

///|
/// The `ts` a client reports before it has seen any transition, which is also
/// what `peer_ts(0)` produces.
let initial_ts : String = "AAAAAAAAAAA="

///|
/// A string that is not a Convex sync timestamp at all, used where the point of
/// the fixture is that the encoding itself is refused.
let malformed_ts : String = "not-a-timestamp"

///|
/// A timestamp taken inside a client body and asserted after it returns, so a
/// deadline that covers `close` can still be measured from outside.
struct Instant {
  mut at : Int64
}

///|
/// Take the next update, failing the test rather than hanging if none arrives.
async fn expect_update(subscription : @convex.Subscription) -> @convex.Update {
  match subscription.next(timeout_ms=8000) {
    Some(update) => update
    None => fail("expected a Live update but none arrived")
  }
}

///|
fn update_count(update : @convex.Update) -> Int64 raise {
  guard update.value is Some(value) else {
    fail("expected a value, got a failure")
  }
  @convex.integer_value(
    @convex.required_field(value, "count", "live value"),
    "count",
  )
}

///|
async test "an initial value and a later update both reach the consumer" {
  let peer = PeerLog::new()
  with_sync_peer(
    (_, socket) => {
      peer_expect(peer, socket, "Connect") |> ignore
      let modify = peer_expect(peer, socket, "ModifyQuerySet")
      let query_id = add_query_id(modify)
      socket.send_text(
        transition(
          0,
          initial_ts,
          1,
          peer_ts(1),
          query_updated(query_id, "{\"count\":0}"),
        ),
      )
      socket.send_text(
        transition(
          1,
          peer_ts(1),
          2,
          peer_ts(2),
          query_updated(query_id, "{\"count\":1}"),
        ),
      )
      // Hold the connection open until the client tears it down.
      peer_recv(socket) |> ignore
    },
    origin => {
      @convex.with_client(origin, client => {
        let subscription = client.subscribe(
          "demo:state",
          @json.parse("{\"room\":\"r\"}"),
        )
        @test.assert_eq(update_count(expect_update(subscription)), 0L)
        @test.assert_eq(update_count(expect_update(subscription)), 1L)
        client.unsubscribe(subscription)
      })
    },
  )
  peer.assert_clean()
}

///|
async test "a failed query recovers on the same subscription" {
  let peer = PeerLog::new()
  with_sync_peer(
    (_, socket) => {
      peer_expect(peer, socket, "Connect") |> ignore
      let query_id = add_query_id(peer_expect(peer, socket, "ModifyQuerySet"))
      socket.send_text(
        transition(
          0,
          initial_ts,
          1,
          peer_ts(1),
          query_failed(query_id, "ROOM_EMPTY"),
        ),
      )
      socket.send_text(
        transition(
          1,
          peer_ts(1),
          2,
          peer_ts(2),
          query_updated(query_id, "{\"count\":1}"),
        ),
      )
      peer_recv(socket) |> ignore
    },
    origin => {
      @convex.with_client(origin, client => {
        let subscription = client.subscribe(
          "demo:requiresNonzero",
          @json.parse("{\"room\":\"r\"}"),
        )
        let failed = expect_update(subscription)
        guard failed.error is Some(info) else { fail("expected a failure") }
        @test.assert_eq(info.kind.to_string(), "FunctionError")
        guard info.data is Some(data) else { fail("expected errorData") }
        @test.assert_eq(
          @convex.json_field(data, "code") is Some(String("ROOM_EMPTY")),
          true,
        )
        // The subscription is not stranded: the next valid value still arrives.
        @test.assert_eq(update_count(expect_update(subscription)), 1L)
        client.unsubscribe(subscription)
      })
    },
  )
  peer.assert_clean()
}

///|
async test "a broken version chain is reported and the client recovers" {
  let peer = PeerLog::new()
  with_sync_peer(
    (index, socket) => {
      peer_expect(peer, socket, "Connect") |> ignore
      let query_id = add_query_id(peer_expect(peer, socket, "ModifyQuerySet"))
      if index == 0 {
        // The client's local version is {0, 0, initial}. Starting a transition
        // anywhere else means an update was lost, so it must not be applied.
        // Every timestamp here is well formed, so the chain is the only thing
        // wrong with this message.
        socket.send_text(
          transition(
            5,
            peer_ts(5),
            6,
            peer_ts(6),
            query_updated(query_id, "{\"count\":9}"),
          ),
        )
      } else {
        socket.send_text(
          transition(
            0,
            initial_ts,
            1,
            peer_ts(1),
            query_updated(query_id, "{\"count\":1}"),
          ),
        )
      }
      peer_recv(socket) |> ignore
    },
    origin => {
      @convex.with_client(origin, client => {
        let subscription = client.subscribe(
          "demo:state",
          @json.parse("{\"room\":\"r\"}"),
        )
        let drift = expect_update(subscription)
        guard drift.error is Some(info) else {
          fail("expected a protocol error")
        }
        @test.assert_eq(info.kind.to_string(), "ProtocolError")
        // The value from the unchained transition was never delivered, and the
        // replacement connection produces a real value.
        @test.assert_eq(update_count(expect_update(subscription)), 1L)
        client.unsubscribe(subscription)
      })
    },
  )
  peer.assert_clean()
}

///|
async test "unsubscribe removes the query and invalidates what was queued" {
  let peer = PeerLog::new()
  with_sync_peer(
    (_, socket) => {
      peer_expect(peer, socket, "Connect") |> ignore
      let query_id = add_query_id(peer_expect(peer, socket, "ModifyQuerySet"))
      socket.send_text(
        transition(
          0,
          initial_ts,
          1,
          peer_ts(1),
          query_updated(query_id, "{\"count\":0}"),
        ),
      )
      socket.send_text(
        transition(
          1,
          peer_ts(1),
          2,
          peer_ts(2),
          query_updated(query_id, "{\"count\":1}"),
        ),
      )
      socket.send_text(
        transition(
          2,
          peer_ts(2),
          3,
          peer_ts(3),
          query_updated(query_id, "{\"count\":2}"),
        ),
      )
      // Retiring a subscription has to reach the server as a `Remove`, not just
      // as a local invalidation, otherwise the deployment keeps computing a
      // reactive query nobody is listening to.
      let modify = peer_expect(peer, socket, "ModifyQuerySet")
      peer.check(
        remove_query_id(modify) == query_id,
        "expected a Remove for the query that was added",
      )
      peer_recv(socket) |> ignore
    },
    origin => {
      @convex.with_client(origin, client => {
        let subscription = client.subscribe(
          "demo:state",
          @json.parse("{\"room\":\"r\"}"),
        )
        @test.assert_eq(update_count(expect_update(subscription)), 0L)
        // Let the two later transitions land in the queue unread, so there is
        // something that could leak past the acknowledgement.
        @async.sleep(200)
        @test.assert_eq(subscription.pending_updates() > 0, true)
        client.unsubscribe(subscription)
        // The acknowledgement is only published after invalidation, so by the
        // time `unsubscribe` returns there is nothing left that could be
        // delivered.
        @test.assert_eq(subscription.pending_updates(), 0)
        let stranded = try {
          subscription.next(timeout_ms=200) |> ignore
          "delivered"
        } catch {
          @convex.ConvexError(info) => info.kind.to_string()
          _ => "unexpected error"
        }
        @test.assert_eq(stranded, "ClientClosed")
      })
    },
  )
  peer.assert_clean()
}

///|
async test "a peer that never stops sending cannot delay unsubscribe or close" {
  let peer = PeerLog::new()
  // Only the control work is timed, and `close` runs inside `with_client`, so
  // the start is taken in there and asserted out here.
  let control = Instant::{ at: 0L }
  with_sync_peer(
    (_, socket) => {
      peer_expect(peer, socket, "Connect") |> ignore
      let query_id = add_query_id(peer_expect(peer, socket, "ModifyQuerySet"))
      socket.send_text(
        transition(
          0,
          initial_ts,
          1,
          peer_ts(1),
          query_updated(query_id, "{\"count\":0}"),
        ),
      )
      // Then talk forever, chaining each transition onto the last so the client
      // has no protocol excuse to hang up. Its reader stays busy and its update
      // queue overflows for as long as this connection lives.
      let mut version = 1
      for ;; {
        socket.send_text(
          transition(
            version,
            peer_ts(version),
            version + 1,
            peer_ts(version + 1),
            query_updated(query_id, "{\"count\":1}"),
          ),
        )
        version = version + 1
      }
    },
    origin => {
      @convex.with_client(origin, client => {
        let subscription = client.subscribe(
          "demo:state",
          @json.parse("{\"room\":\"r\"}"),
        )
        @test.assert_eq(update_count(expect_update(subscription)), 0L)
        // Everything after this point is control work, which goes through the
        // command queue rather than the socket the reader is saturating.
        control.at = @async.now()
        // Either it completes or it gives up on its own deadline; what it must
        // not do is wait on a peer that never stops talking.
        let outcome = try {
          client.unsubscribe(subscription)
          "returned"
        } catch {
          @convex.ConvexError(info) => info.kind.to_string()
          _ => "unexpected error"
        }
        @test.assert_eq(
          outcome == "returned" || outcome == "TransportError",
          true,
        )
      })
    },
  )
  // Deadlines, not cooperation. Each of `unsubscribe` and `close` bounds both
  // handing its command to the worker and waiting for the acknowledgement, so
  // the pair cannot outlast twice that however long the peer keeps going.
  @test.assert_eq(control.at > 0L, true)
  @test.assert_eq(@async.now() - control.at < 24000L, true)
  peer.assert_clean()
}

///|
async test "five debug disconnects each resend the query and suppress the replay" {
  let peer = PeerLog::new()
  with_sync_peer(
    (index, socket) => {
      let connect = peer_expect(peer, socket, "Connect")
      // Every connection reports how many predecessors it had and why the last
      // one went away, so the server can avoid replaying values this client
      // has already seen.
      peer.check(
        @convex.json_field(connect, "connectionCount")
        is Some(Number(counted, ..)) &&
        counted == index.to_double(),
        "expected connectionCount " + index.to_string(),
      )
      if index > 0 {
        peer.check(
          @convex.json_field(connect, "lastCloseReason")
          is Some(String("DebugDisconnect")),
          "expected lastCloseReason DebugDisconnect",
        )
        // The highest timestamp this client validated on the previous
        // connection comes back with the next `Connect`, which is how the
        // deployment avoids replaying values already seen. It has to be the
        // exact string that was accepted, so a rejected or invented timestamp
        // would show up here rather than staying invisible.
        let expected = if index == 1 {
          peer_ts(1)
        } else {
          peer_ts(10 * (index - 1) + 2)
        }
        peer.check(
          @convex.json_field(connect, "maxObservedTimestamp")
          is Some(String(reported)) &&
          reported == expected,
          "expected maxObservedTimestamp " + expected,
        )
      }
      // Each connection starts from query-set version zero, so the active
      // query has to be sent again.
      let query_id = add_query_id(peer_expect(peer, socket, "ModifyQuerySet"))
      let value = index.to_string()
      if index == 0 {
        socket.send_text(
          transition(
            0,
            initial_ts,
            1,
            peer_ts(1),
            query_updated(query_id, "{\"count\":0}"),
          ),
        )
      } else {
        // Replay the value the client already holds, written the other way
        // Convex is entitled to write it: `1.0` rather than `1`. It is the same
        // number, so it must be suppressed. A client that compared the parsed
        // documents structurally would see the retained spelling change and
        // report a count that never moved, which would break the exact
        // sequence this test asserts.
        socket.send_text(
          transition(
            0,
            initial_ts,
            1,
            peer_ts(10 * index + 1),
            query_updated(
              query_id,
              "{\"count\":" + (index - 1).to_string() + ".0}",
            ),
          ),
        )
        // Then the value that actually changed.
        socket.send_text(
          transition(
            1,
            peer_ts(10 * index + 1),
            2,
            peer_ts(10 * index + 2),
            query_updated(query_id, "{\"count\":" + value + "}"),
          ),
        )
      }
      peer_recv(socket) |> ignore
    },
    origin => {
      @convex.with_client(origin, client => {
        let subscription = client.subscribe(
          "demo:state",
          @json.parse("{\"room\":\"r\"}"),
        )
        @test.assert_eq(update_count(expect_update(subscription)), 0L)
        for attempt = 1; attempt <= 5; attempt = attempt + 1 {
          client.debug_disconnect()
          // Exactly one update per reconnect: the unchanged replay is swallowed
          // and only the real change is delivered.
          @test.assert_eq(
            update_count(expect_update(subscription)),
            attempt.to_int64(),
          )
        }
        client.unsubscribe(subscription)
      })
    },
  )
  peer.assert_clean()
}

///|
/// A `QueryRemoved` modification, which the server sends when a query leaves
/// its query set.
fn query_removed(query_id : Int) -> String {
  "{\"type\":\"QueryRemoved\",\"queryId\":" + query_id.to_string() + "}"
}

///|
async test "a malformed transition timestamp is refused and never reported back" {
  let peer = PeerLog::new()
  with_sync_peer(
    (index, socket) => {
      let connect = peer_expect(peer, socket, "Connect")
      if index > 0 {
        // Nothing was ever validated, so there is no highest observed
        // timestamp to report. A client that accepted the malformed value would
        // hand it straight back to the deployment here.
        peer.check(
          @convex.json_field(connect, "maxObservedTimestamp") is None,
          "expected no maxObservedTimestamp after a refused timestamp",
        )
      }
      let query_id = add_query_id(peer_expect(peer, socket, "ModifyQuerySet"))
      if index == 0 {
        socket.send_text(
          transition(
            0,
            initial_ts,
            1,
            malformed_ts,
            query_updated(query_id, "{\"count\":3}"),
          ),
        )
      } else {
        socket.send_text(
          transition(
            0,
            initial_ts,
            1,
            peer_ts(1),
            query_updated(query_id, "{\"count\":4}"),
          ),
        )
      }
      peer_recv(socket) |> ignore
    },
    origin => {
      @convex.with_client(origin, client => {
        let subscription = client.subscribe(
          "demo:state",
          @json.parse("{\"room\":\"r\"}"),
        )
        let refused = expect_update(subscription)
        guard refused.error is Some(info) else {
          fail("expected the malformed timestamp to be refused")
        }
        @test.assert_eq(info.kind.to_string(), "ProtocolError")
        // The value that arrived alongside the bad timestamp was never applied,
        // and the replacement connection produces a real one.
        @test.assert_eq(update_count(expect_update(subscription)), 4L)
        client.unsubscribe(subscription)
      })
    },
  )
  peer.assert_clean()
}

///|
async test "an unsolicited QueryRemoved is drift and the query comes back" {
  let peer = PeerLog::new()
  let readded = Counter::{ value: 0 }
  with_sync_peer(
    (index, socket) => {
      peer_expect(peer, socket, "Connect") |> ignore
      let query_id = add_query_id(peer_expect(peer, socket, "ModifyQuerySet"))
      readded.value = readded.value + 1
      if index == 0 {
        socket.send_text(
          transition(
            0,
            initial_ts,
            1,
            peer_ts(1),
            query_updated(query_id, "{\"count\":0}"),
          ),
        )
        // The server drops a query this client is still watching. Ignoring it
        // would leave the consumer waiting for values the deployment has
        // stopped computing, so it has to be treated as drift.
        socket.send_text(
          transition(1, peer_ts(1), 2, peer_ts(2), query_removed(query_id)),
        )
      } else {
        socket.send_text(
          transition(
            0,
            initial_ts,
            1,
            peer_ts(1),
            query_updated(query_id, "{\"count\":6}"),
          ),
        )
      }
      peer_recv(socket) |> ignore
    },
    origin => {
      @convex.with_client(origin, client => {
        let subscription = client.subscribe(
          "demo:state",
          @json.parse("{\"room\":\"r\"}"),
        )
        @test.assert_eq(update_count(expect_update(subscription)), 0L)
        let dropped = expect_update(subscription)
        guard dropped.error is Some(info) else {
          fail("expected the removal to be reported")
        }
        @test.assert_eq(info.kind.to_string(), "ProtocolError")
        // Recovery is the reconnect: every connection resends the active `Add`
        // operations, so the subscription is not stranded.
        @test.assert_eq(update_count(expect_update(subscription)), 6L)
        client.unsubscribe(subscription)
      })
    },
  )
  // The second connection really did add the query again rather than the
  // client quietly keeping a subscription the server had dropped.
  @test.assert_eq(readded.value >= 2, true)
  peer.assert_clean()
}

///|
async test "debugDisconnect is acknowledged before the replacement connects" {
  let peer = PeerLog::new()
  // The invariant under test: the acknowledgement is published only after the
  // old connection has been retired and the reconnect scheduled, so the
  // replacement connection cannot be accepted before `debug_disconnect`
  // returns. Both moments are recorded and compared after the run.
  let acknowledged = Instant::{ at: 0L }
  let replaced = Instant::{ at: 0L }
  with_sync_peer(
    (index, socket) => {
      let connect = peer_expect(peer, socket, "Connect")
      if index == 1 {
        replaced.at = @async.now()
        // The old connection was closed and counted before this one was opened,
        // which is the other half of "the old connection is genuinely gone".
        peer.check(
          @convex.json_field(connect, "connectionCount")
          is Some(Number(counted, ..)) &&
          counted == 1.0,
          "expected the replacement to report one previous connection",
        )
        peer.check(
          @convex.json_field(connect, "lastCloseReason")
          is Some(String("DebugDisconnect")),
          "expected lastCloseReason DebugDisconnect",
        )
      }
      let query_id = add_query_id(peer_expect(peer, socket, "ModifyQuerySet"))
      let count = if index == 0 { "0" } else { "1" }
      socket.send_text(
        transition(
          0,
          initial_ts,
          1,
          peer_ts(index + 1),
          query_updated(query_id, "{\"count\":" + count + "}"),
        ),
      )
      peer_recv(socket) |> ignore
    },
    origin => {
      @convex.with_client(origin, client => {
        let subscription = client.subscribe(
          "demo:state",
          @json.parse("{\"room\":\"r\"}"),
        )
        @test.assert_eq(update_count(expect_update(subscription)), 0L)
        client.debug_disconnect()
        acknowledged.at = @async.now()
        @test.assert_eq(update_count(expect_update(subscription)), 1L)
        client.unsubscribe(subscription)
      })
    },
  )
  @test.assert_eq(acknowledged.at > 0L, true)
  @test.assert_eq(replaced.at > 0L, true)
  @test.assert_eq(acknowledged.at <= replaced.at, true)
  peer.assert_clean()
}

///|
/// A `QueryUpdated` whose value carries `filler` characters of padding, used to
/// put real pressure on the delivery budgets.
fn padded_value(count : Int, filler : Int) -> String {
  "{\"count\":" +
  count.to_string() +
  ",\"filler\":\"" +
  "p".repeat(filler) +
  "\"}"
}

///|
async test "a stopped consumer bounds the Live budget and gets it back" {
  let peer = PeerLog::new()
  let before = @convex.queued_update_bytes()
  // Each value is distinct, so nothing here can be collapsed by rehydration
  // suppression or shared between queue entries: every one of them is real
  // retained payload.
  let large = @convex.SUBSCRIPTION_QUEUE_BYTES / 4
  let flood = 12
  with_sync_peer(
    (_, socket) => {
      peer_expect(peer, socket, "Connect") |> ignore
      let query_id = add_query_id(peer_expect(peer, socket, "ModifyQuerySet"))
      socket.send_text(
        transition(
          0,
          initial_ts,
          1,
          peer_ts(1),
          query_updated(query_id, "{\"count\":0}"),
        ),
      )
      for step = 1; step <= flood; step = step + 1 {
        socket.send_text(
          transition(
            step,
            peer_ts(step),
            step + 1,
            peer_ts(step + 1),
            "{\"type\":\"QueryUpdated\",\"queryId\":" +
            query_id.to_string() +
            ",\"value\":" +
            padded_value(step, large) +
            ",\"logLines\":[]}",
          ),
        )
      }
      // Then one value that cannot fit in the per-subscription budget at all.
      // It has to be refused loudly rather than buffered or dropped in silence.
      socket.send_text(
        transition(
          flood + 1,
          peer_ts(flood + 1),
          flood + 2,
          peer_ts(flood + 2),
          "{\"type\":\"QueryUpdated\",\"queryId\":" +
          query_id.to_string() +
          ",\"value\":" +
          padded_value(flood + 1, @convex.SUBSCRIPTION_QUEUE_BYTES + 4096) +
          ",\"logLines\":[]}",
        ),
      )
      peer_recv(socket) |> ignore
    },
    origin => {
      @convex.with_client(origin, client => {
        let subscription = client.subscribe(
          "demo:state",
          @json.parse("{\"room\":\"r\"}"),
        )
        @test.assert_eq(update_count(expect_update(subscription)), 0L)
        // Stop reading while the flood lands.
        @async.sleep(2000)
        // Neither ceiling may be exceeded, however much the peer sends.
        @test.assert_eq(
          subscription.pending_updates() <= @convex.SUBSCRIPTION_QUEUE_CAPACITY,
          true,
        )
        @test.assert_eq(
          @convex.queued_update_bytes() <= @convex.LIVE_TOTAL_QUEUE_BYTES,
          true,
        )
        // Values were discarded to stay inside them, and the discarding was
        // counted rather than hidden.
        @test.assert_eq(subscription.dropped_updates() > 0, true)
        // Drain everything the consumer can still see. The last thing queued is
        // the refusal of the value that was too large to buffer.
        let mut refusals = 0
        for ;; {
          guard subscription.next(timeout_ms=500) is Some(update) else { break }
          if update.error is Some(_) {
            refusals = refusals + 1
          }
        }
        @test.assert_eq(refusals >= 1, true)
        client.unsubscribe(subscription)
      })
    },
  )
  // Every string unit charged to the process-wide budget was released again. A
  // budget that only ever grows is a slower leak, not a bound.
  @test.assert_eq(@convex.queued_update_bytes(), before)
  peer.assert_clean()
}
