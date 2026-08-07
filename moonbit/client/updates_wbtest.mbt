// Live delivery buffering under a slow consumer.
//
// The client owns its update queue, so the overflow behaviour is a documented
// guarantee rather than an accident of whatever the runtime happened to do.
// These tests pin both bounds and prove the process-wide budget is released
// again, because a budget that leaks is a slower memory leak, not a fix.

///|
/// A subscription detached from any manager, used to exercise the queue on its
/// own. The manager reference is required by the struct but nothing here calls
/// into it.
fn queue_probe() -> Subscription {
  {
    id: 1,
    path: "demo:state",
    args: json_object([]),
    manager: LiveManager::new(),
    add_sequence: 1,
    active: true,
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
fn drain(subscription : Subscription) -> Unit {
  while subscription.queue.length() > 0 {
    let update = subscription.queue[0]
    subscription.queue.remove(0) |> ignore
    let size = update_size(update)
    subscription.queued_bytes = subscription.queued_bytes - size
    live_memory.used = live_memory.used - size
  }
}

///|
test "a slow consumer loses the oldest values, not the newest" {
  let subscription = queue_probe()
  let before = live_memory.used
  for index = 0; index < SUBSCRIPTION_QUEUE_CAPACITY + 4; index = index + 1 {
    subscription.publish({
      value: Some(Json::number(index.to_double())),
      error: None,
      logs: [],
    })
  }
  @test.assert_eq(subscription.pending_updates(), SUBSCRIPTION_QUEUE_CAPACITY)
  @test.assert_eq(subscription.dropped_updates(), 4)
  // The newest value survived and the oldest four did not.
  let newest = subscription.queue[subscription.queue.length() - 1]
  guard newest.value is Some(value) else { fail("expected a value") }
  @test.assert_eq(
    integer_value(value, "value"),
    (SUBSCRIPTION_QUEUE_CAPACITY + 3).to_int64(),
  )
  let oldest = subscription.queue[0]
  guard oldest.value is Some(value) else { fail("expected a value") }
  @test.assert_eq(integer_value(value, "value"), 4L)
  drain(subscription)
  @test.assert_eq(live_memory.used, before)
}

///|
test "one oversized value is refused loudly instead of buffered" {
  let subscription = queue_probe()
  let before = live_memory.used
  let huge = Json::string("x".repeat(SUBSCRIPTION_QUEUE_BYTES + 16))
  subscription.publish({ value: Some(huge), error: None, logs: [] })
  @test.assert_eq(subscription.pending_updates(), 1)
  let update = subscription.queue[0]
  guard update.error is Some(info) else {
    fail("expected a structured refusal")
  }
  @test.assert_eq(info.kind.to_string(), "ProtocolError")
  @test.assert_eq(info.message.contains("exceeded"), true)
  // The refusal itself is small, so the process budget did not absorb the
  // oversized value.
  @test.assert_eq(live_memory.used - before < 4096, true)
  drain(subscription)
  @test.assert_eq(live_memory.used, before)
}

///|
test "the byte budget bounds a queue that is well under the count bound" {
  let subscription = queue_probe()
  let before = live_memory.used
  // Four values of a quarter of the budget each cannot all fit, even though
  // four is far below the sixteen update count bound.
  let chunk = Json::string("y".repeat(SUBSCRIPTION_QUEUE_BYTES / 4))
  for index = 0; index < 8; index = index + 1 {
    subscription.publish({ value: Some(chunk), error: None, logs: [] })
  }
  @test.assert_eq(subscription.pending_updates() <= 4, true)
  @test.assert_eq(subscription.queued_bytes <= SUBSCRIPTION_QUEUE_BYTES, true)
  @test.assert_eq(subscription.dropped_updates() > 0, true)
  drain(subscription)
  @test.assert_eq(live_memory.used, before)
}

///|
test "an unchanged rehydration is suppressed but a changed one is delivered" {
  let subscription = queue_probe()
  let before = live_memory.used
  let zero = @json.parse("{\"count\":0}")
  let one = @json.parse("{\"count\":1}")
  subscription.publish_value(zero, [])
  @test.assert_eq(subscription.pending_updates(), 1)
  drain(subscription)

  // A reconnect replays the value the consumer already holds.
  subscription.rehydrating = true
  subscription.publish_value(zero, [])
  @test.assert_eq(subscription.pending_updates(), 0)

  // A reconnect that replays a different value is a real change.
  subscription.rehydrating = true
  subscription.publish_value(one, [])
  @test.assert_eq(subscription.pending_updates(), 1)
  drain(subscription)
  @test.assert_eq(live_memory.used, before)
}

///|
test "the value after a failure is always delivered" {
  let subscription = queue_probe()
  let before = live_memory.used
  let zero = @json.parse("{\"count\":0}")
  subscription.publish_value(zero, [])
  drain(subscription)
  subscription.publish_error({
    kind: FunctionError,
    message: "ROOM_EMPTY",
    data: None,
    logs: [],
  })
  drain(subscription)
  // Identical to the pre-failure value, but the consumer's last known state was
  // an error, so suppressing this would strand it.
  subscription.rehydrating = true
  subscription.publish_value(zero, [])
  @test.assert_eq(subscription.pending_updates(), 1)
  drain(subscription)
  @test.assert_eq(live_memory.used, before)
}
