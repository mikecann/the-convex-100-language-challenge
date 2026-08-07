// Reconnect bookkeeping, pinned where it can be made deterministic.
//
// The peer-driven tests in `live_sync_peer_test.mbt` prove the behaviour a real
// socket can show. Three things are not observable that way: how the backoff
// grows and when it is discarded, which connections are worth numbering, and
// what happens to a command whose caller stopped waiting. All three decide how
// a reconnect behaves, so they are exercised here against the worker's own
// state instead of being left to a timing race.

///|
/// Two well formed sync timestamps. The client validates the encoding of every
/// `ts` it sees, so a fixture that used a readable placeholder would be
/// rejected for the wrong reason and would stop testing what it names.
const FIRST_TIMESTAMP : String = "AQAAAAAAAAA="

///|
const SECOND_TIMESTAMP : String = "AgAAAAAAAAA="

///|
/// A subscription that is registered with a manager but attached to no socket,
/// so decoded server messages can be applied to it directly.
fn detached_subscription(manager : LiveManager) -> Subscription {
  {
    id: 1,
    path: "demo:state",
    args: json_object([]),
    manager,
    add_sequence: 1,
    active: true,
    // The server has already been told about this query, which is what makes
    // it eligible for a connection-level failure report.
    add_pending: false,
    remove_pending: false,
    remove_done: false,
    rehydrating: false,
    has_last_value: false,
    last_value: None,
    queue: [],
    queued_bytes: 0,
    dropped: 0,
    ready: @cond_var.Cond::Cond(),
  }
}

///|
fn live_probe() -> (LiveManager, Subscription) {
  let manager = LiveManager::new()
  let subscription = detached_subscription(manager)
  manager.subscriptions.push(subscription)
  (manager, subscription)
}

///|
/// Build one `Transition` message as the server would send it.
fn transition_message(
  start_query_set : Int,
  start_ts : String,
  end_query_set : Int,
  end_ts : String,
  query_id : Int,
  count : Int,
) -> Json raise @json.ParseError {
  @json.parse(
    "{\"type\":\"Transition\",\"startVersion\":{\"querySet\":" +
    start_query_set.to_string() +
    ",\"identity\":0,\"ts\":\"" +
    start_ts +
    "\"},\"endVersion\":{\"querySet\":" +
    end_query_set.to_string() +
    ",\"identity\":0,\"ts\":\"" +
    end_ts +
    "\"},\"modifications\":[{\"type\":\"QueryUpdated\",\"queryId\":" +
    query_id.to_string() +
    ",\"value\":{\"count\":" +
    count.to_string() +
    "},\"logLines\":[]}]}",
  )
}

///|
test "the reconnect delay grows and saturates rather than running away" {
  let manager = LiveManager::new()
  @test.assert_eq(manager.backoff_ms, LIVE_BACKOFF_MIN_MS)
  manager.schedule_reconnect()
  @test.assert_eq(manager.backoff_ms, LIVE_BACKOFF_MIN_MS * 2)
  // Far more failures than it takes to reach the ceiling, so the doubling is
  // proven to stop rather than merely to be slow.
  for attempt = 0; attempt < 32; attempt = attempt + 1 {
    manager.schedule_reconnect()
  }
  @test.assert_eq(manager.backoff_ms, LIVE_BACKOFF_MAX_MS)
  @test.assert_eq(manager.reconnect_at > @async.now(), true)
}

///|
async test "a valid transition discards a backoff an earlier bad run earned" {
  let (manager, subscription) = live_probe()
  for attempt = 0; attempt < 32; attempt = attempt + 1 {
    manager.schedule_reconnect()
  }
  @test.assert_eq(manager.backoff_ms, LIVE_BACKOFF_MAX_MS)
  let step = manager.apply_server_message(
    transition_message(0, INITIAL_TIMESTAMP, 1, FIRST_TIMESTAMP, 1, 3),
  )
  @test.assert_eq(step is Continue, true)
  // A server that is answering correctly is evidence of a healthy peer, so the
  // next interruption starts from the shortest delay instead of inheriting a
  // punishment the peer has already worked off.
  @test.assert_eq(manager.backoff_ms, LIVE_BACKOFF_MIN_MS)
  @test.assert_eq(manager.max_observed_timestamp(), Some(FIRST_TIMESTAMP))
  @test.assert_eq(subscription.pending_updates(), 1)
  drain(subscription)
}

///|
async test "an unchained transition is drift and its value is never applied" {
  let (manager, subscription) = live_probe()
  let step = manager.apply_server_message(
    transition_message(4, SECOND_TIMESTAMP, 5, FIRST_TIMESTAMP, 1, 9),
  )
  // The local version is still {0, 0, initial}, so a transition starting
  // anywhere else means something was lost between here and the server.
  @test.assert_eq(step is EndSession, true)
  @test.assert_eq(subscription.pending_updates(), 1)
  guard subscription.queue[0].error is Some(info) else {
    fail("expected the drift to be reported to the subscription")
  }
  @test.assert_eq(info.kind.to_string(), "ProtocolError")
  // The unchained value was reported as a failure, not delivered as data.
  @test.assert_eq(subscription.has_last_value, false)
  drain(subscription)
}

///|
test "only a connection that existed is numbered for the next Connect" {
  let manager = LiveManager::new()
  // A connect attempt that never completed its handshake records why it failed
  // but must not tell the server about a connection it never saw.
  manager.record_close("Live connect failed: connection refused")
  @test.assert_eq(manager.connection_count(), 0)
  @test.assert_eq(
    manager.last_close_reason(),
    "Live connect failed: connection refused",
  )
  manager.connected = true
  manager.record_close("DebugDisconnect")
  @test.assert_eq(manager.connection_count(), 1)
  @test.assert_eq(manager.last_close_reason(), "DebugDisconnect")
}

///|
test "an implausibly long close reason is replaced, not reflected" {
  let manager = LiveManager::new()
  manager.connected = true
  // A `Fatal` reason can quote text the peer chose. Sending it back verbatim
  // would let a server decide how much this client writes to it.
  manager.record_close("z".repeat(LIVE_CLOSE_REASON_MAX_CHARS + 1))
  @test.assert_eq(manager.last_close_reason(), "CloseReasonTooLong")
  // A reason of a normal length still reaches the server intact.
  manager.record_close("z".repeat(LIVE_CLOSE_REASON_MAX_CHARS))
  @test.assert_eq(
    manager.last_close_reason().length(),
    LIVE_CLOSE_REASON_MAX_CHARS,
  )
}

///|
test "an Add whose caller stopped waiting is retired instead of registered" {
  let manager = LiveManager::new()
  let subscription = detached_subscription(manager)
  let completion = Completion::new()
  // This is what a caller's bounded wait leaves behind when the owner is too
  // busy to reach the command in time.
  completion.abandoned = true
  manager.apply_offline_command(AddQuery(subscription, completion))
  // Registering it would keep the worker reconnecting forever on behalf of a
  // consumer that has already given up and thrown the handle away.
  @test.assert_eq(manager.subscriptions.length(), 0)
  @test.assert_eq(manager.active_count(), 0)
  @test.assert_eq(subscription.remove_done, true)
}

///|
test "an Add whose caller is still waiting is registered and acknowledged" {
  let manager = LiveManager::new()
  let subscription = detached_subscription(manager)
  let completion = Completion::new()
  manager.apply_offline_command(AddQuery(subscription, completion))
  @test.assert_eq(manager.active_count(), 1)
  @test.assert_eq(completion.settled, true)
}
