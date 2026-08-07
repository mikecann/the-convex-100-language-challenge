// Live delivery buffering.
//
// This client owns its update queue rather than relying on a runtime mailbox,
// so the queue has to be bounded deliberately. Two separate bounds apply,
// because either one alone is a lie:
//
//   * a count bound stops a fast publisher from queueing unbounded *numbers* of
//     updates, but one Convex value can be close to the maximum message size,
//     so sixteen of them is still megabytes;
//   * a byte bound stops a small number of very large values from dominating
//     memory, and a process-wide byte budget stops many subscriptions from each
//     staying inside their own budget while together exceeding the container's.
//
// Overflow drops the oldest update, which is the right trade for a reactive
// query: the newest value is the true one and a stale value nobody read is
// worthless. Drops are counted rather than hidden, so a slow consumer can tell
// that it missed intermediate states.
//
// The budgets below are counted in MoonBit string units, which are UTF-16 code
// units rather than bytes. Measuring the real UTF-8 encoding would mean
// encoding every value twice, so the unit is stated instead of hidden: one unit
// costs two bytes in memory and at most three bytes once it is written out.
// Every ceiling in this file therefore has a worst case a small multiple of its
// nominal size, and each of those worst cases is checked against the shared
// 128 MiB container limit where the constant is defined.

///|
/// Most updates retained per subscription before the oldest is dropped.
///
/// The three ceilings are public because they are a documented guarantee about
/// how this client behaves under a slow consumer, not an implementation detail:
/// the README and `manifest.yaml` state them, and the tests assert against the
/// same names rather than against copies that could drift.
pub const SUBSCRIPTION_QUEUE_CAPACITY : Int = 16

///|
/// Most string units of queued update payload retained per subscription: at
/// most 2 MiB of memory and 3 MiB once encoded.
pub const SUBSCRIPTION_QUEUE_BYTES : Int = 1048576

///|
/// Most string units of queued update payload retained across every
/// subscription in the process. The shared conformance runner caps the adapter
/// container at 128 MiB; the worst case here is 16 MiB of memory, which leaves
/// room for the encoded output, the runtime, and the transport buffers.
pub const LIVE_TOTAL_QUEUE_BYTES : Int = 8388608

///|
/// Fixed overhead charged per queued update to account for the array slot, the
/// log array, and the encoded framing the adapter adds. Without it a flood of
/// tiny updates would be charged almost nothing while still costing real
/// memory.
const UPDATE_OVERHEAD_BYTES : Int = 256

///|
/// Process-wide accounting for queued Live payload.
struct MemoryBudget {
  mut used : Int
}

///|
let live_memory : MemoryBudget = { used: 0 }

///|
/// String units of Live update payload currently queued across the whole
/// process. Exposed so tests can prove the budget is released again after
/// draining.
pub fn queued_update_bytes() -> Int {
  live_memory.used
}

///|
/// One Live delivery: either a value or a structured failure, never both.
pub(all) struct Update {
  value : Json?
  error : ErrorInfo?
  logs : Array[String]
}

///|
/// Size of an update in string units, counting the serialised value rather
/// than the parsed one. The adapter has to serialise the value anyway, so this
/// tracks what actually reaches a socket, to within the encoding factor
/// described at the top of this file.
fn update_size(update : Update) -> Int {
  let mut size = UPDATE_OVERHEAD_BYTES
  match update.value {
    Some(value) => size = size + value.stringify().length()
    None => ()
  }
  match update.error {
    Some(info) => {
      size = size + info.message.length()
      match info.data {
        Some(data) => size = size + data.stringify().length()
        None => ()
      }
    }
    None => ()
  }
  for line in update.logs {
    size = size + line.length()
  }
  size
}

///|
/// A Live query registered with the Live worker.
///
/// The struct is shared between the caller and the worker, but only the worker
/// mutates the protocol fields (`add_pending` through `last_value`). The caller
/// only ever touches the queue through `next`, and only the worker publishes
/// into it, so a single-threaded event loop keeps the two apart without a lock.
pub struct Subscription {
  /// Doubles as the Convex `queryId` for the lifetime of the subscription.
  id : Int
  path : String
  args : Json
  manager : LiveManager
  /// Ordering token used to decide which `Add`s a reconnect snapshot covered.
  /// Set once at construction and never reassigned.
  add_sequence : Int
  mut active : Bool
  mut add_pending : Bool
  mut remove_pending : Bool
  mut remove_done : Bool
  /// Set when a reconnect is expected to replay a value this caller has already
  /// seen, so the replay can be suppressed instead of looking like a change.
  mut rehydrating : Bool
  mut has_last_value : Bool
  mut last_value : Json?
  queue : Array[Update]
  mut queued_bytes : Int
  mut dropped : Int
  ready : @cond_var.Cond
}

///|
/// How many updates this subscription discarded because its consumer was too
/// slow. A non-zero count means intermediate values were skipped; the newest
/// value is still correct.
pub fn Subscription::dropped_updates(self : Subscription) -> Int {
  self.dropped
}

///|
/// How many updates are waiting to be read.
pub fn Subscription::pending_updates(self : Subscription) -> Int {
  self.queue.length()
}

///|
/// Discard the oldest queued update and release its budget.
fn Subscription::drop_oldest(self : Subscription) -> Unit {
  guard self.queue.length() > 0 else { return }
  let oldest = self.queue[0]
  let size = update_size(oldest)
  self.queue.remove(0) |> ignore
  self.queued_bytes = self.queued_bytes - size
  live_memory.used = live_memory.used - size
  self.dropped = self.dropped + 1
}

///|
/// Replace everything queued with a single structured failure.
///
/// Used when one update cannot fit inside the budget at all. Reporting the
/// refusal is strictly better than dropping it silently: the consumer learns
/// that a value existed and was too large, instead of waiting forever for an
/// update that will never arrive.
fn Subscription::overflow(self : Subscription, message : String) -> Unit {
  while self.queue.length() > 0 {
    self.drop_oldest()
  }
  let update = {
    value: None,
    error: Some({ kind: ProtocolError, message, data: None, logs: [] }),
    logs: [],
  }
  let size = update_size(update)
  self.queue.push(update)
  self.queued_bytes = self.queued_bytes + size
  live_memory.used = live_memory.used + size
  self.ready.broadcast()
}

///|
/// Queue one update for the consumer, enforcing both bounds.
fn Subscription::publish(self : Subscription, update : Update) -> Unit {
  let size = update_size(update)
  if size > SUBSCRIPTION_QUEUE_BYTES {
    self.overflow(
      "Live update of " +
      size.to_string() +
      " string units exceeded the per-subscription buffer and was refused",
    )
    return
  }
  // Make room by discarding the oldest values this consumer has not read.
  while self.queue.length() > 0 &&
        (
          self.queue.length() >= SUBSCRIPTION_QUEUE_CAPACITY ||
          self.queued_bytes + size > SUBSCRIPTION_QUEUE_BYTES ||
          live_memory.used + size > LIVE_TOTAL_QUEUE_BYTES
        ) {
    self.drop_oldest()
  }
  if live_memory.used + size > LIVE_TOTAL_QUEUE_BYTES {
    // This subscription is already empty, so the budget is held by other
    // subscriptions and dropping more here would not help.
    self.overflow(
      "Live update refused: the process-wide Live buffer budget is exhausted",
    )
    return
  }
  self.queue.push(update)
  self.queued_bytes = self.queued_bytes + size
  live_memory.used = live_memory.used + size
  self.ready.broadcast()
}

///|
/// Publish a value, honouring rehydration suppression.
///
/// After a reconnect Convex resends the current value of every query. If that
/// value is identical to the one the consumer already has, forwarding it would
/// look like a change that never happened, so it is swallowed. The first value
/// after a failure is always delivered, because the consumer's last known state
/// was an error rather than a value.
///
/// "Identical" is decided by `json_equivalent`, not by structural equality.
/// Convex may write the same number as `0` on one connection and `0.0` on the
/// next, and MoonBit's `Json` keeps that original spelling, so a structural
/// comparison would call the replay a change and this client would report a
/// count that never moved.
fn Subscription::publish_value(
  self : Subscription,
  value : Json,
  logs : Array[String],
) -> Unit {
  let unchanged = self.has_last_value &&
    (match self.last_value {
      Some(previous) => json_equivalent(previous, value)
      None => false
    })
  let suppress = self.rehydrating && unchanged
  self.last_value = Some(value)
  self.has_last_value = true
  self.rehydrating = false
  if !suppress {
    self.publish({ value: Some(value), error: None, logs })
  }
}

///|
/// Publish a structured failure and forget the last value, so the next
/// successful value is always delivered even if it equals the value that was
/// current before the failure.
fn Subscription::publish_error(self : Subscription, info : ErrorInfo) -> Unit {
  self.last_value = None
  self.has_last_value = false
  self.rehydrating = false
  self.publish({ value: None, error: Some(info), logs: info.logs })
}

///|
/// Take the next update, waiting up to `timeout_ms` for one to arrive.
///
/// Returns `None` when the deadline passes with nothing queued. Raises when the
/// subscription has been retired or the client has been closed, because in that
/// case waiting longer can never produce a value and returning `None` would
/// invite an infinite poll loop.
pub async fn Subscription::next(
  self : Subscription,
  timeout_ms~ : Int,
) -> Update? {
  let deadline = @async.now() + timeout_ms.to_int64()
  while true {
    if self.queue.length() > 0 {
      let update = self.queue[0]
      self.queue.remove(0) |> ignore
      let size = update_size(update)
      self.queued_bytes = self.queued_bytes - size
      live_memory.used = live_memory.used - size
      return Some(update)
    }
    guard self.active && !self.remove_pending else {
      raise closed_error("Live subscription has been retired")
    }
    guard !self.manager.stopped else {
      raise closed_error("client closed before the Live update arrived")
    }
    let remaining = deadline - @async.now()
    if remaining <= 0L {
      return None
    }
    // `Cond::wait` is a cancellation point, so the timeout is enforced by
    // cancelling the wait rather than by polling. Losing the wakeup is safe:
    // the loop re-reads the queue before waiting again.
    @async.with_timeout_opt(remaining.to_int(), () => self.ready.wait())
    |> ignore
  }
  None
}
