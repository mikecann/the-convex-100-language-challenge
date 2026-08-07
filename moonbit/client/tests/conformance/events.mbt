// NDJSON adapter protocol v1: event encoding and the single ordered writer.
//
// This file is test infrastructure, not client code. It exists so the shared
// black-box controller can drive the real MoonBit client the same way it drives
// every other language's client.
//
// Two rules shape everything here.
//
// The shared controller validates every emitted line against
// `_shared/schemas/adapter.schema.json`, and that schema does not permit a null
// `id` or `subscriptionId`. So absent fields are *omitted*, never serialised as
// null. Building each event as a `Map` and only inserting members that exist
// makes that structural rather than a thing to remember.
//
// Stdout is a single ordered stream. Command handlers and subscription relays
// all produce events concurrently, so exactly one task writes, everything else
// enqueues, and the queue is bounded in bytes as well as in count.

///|
/// Largest single event this adapter will write, in MoonBit string units. A
/// Convex value can be close to the maximum protocol message size, so this is a
/// real bound and not a formality.
const MAX_EVENT_BYTES : Int = 3145728

///|
/// Total queued output allowed to sit in the writer queue, in string units. A
/// producer that would push past this blocks until the writer drains, which
/// turns a stopped reader into backpressure instead of unbounded growth.
///
/// String units are UTF-16 code units, so a unit costs two bytes in memory and
/// at most three once it is written out. Worst case retained output is this
/// budget plus the one event being written: 8 MiB resident and 12 MiB encoded,
/// well inside the shared 128 MiB container limit. The Dockerfile measures the
/// real binary against that limit rather than trusting this arithmetic.
const WRITE_BUDGET_BYTES : Int = 4194304

///|
/// One line waiting to be written.
///
/// `guard_subscription` and `guard_generation` let the writer drop a line whose
/// subscription was retired after the line was queued. Without that check a
/// relay paused between dequeue and write could publish a stale value after the
/// unsubscribe acknowledgement had already gone out.
struct Outgoing {
  line : String
  bytes : Int
  guard_subscription : String?
  guard_generation : Int
}

///|
/// The adapter's only writer.
struct EventWriter {
  pending : Array[Outgoing]
  mut queued_bytes : Int
  mut stopped : Bool
  /// Signalled when a line is queued or the writer is stopped.
  arrived : @cond_var.Cond
  /// Signalled when the writer frees budget.
  drained : @cond_var.Cond
  /// Generation of each live subscription id, consulted at write time.
  generations : Map[String, Int]
}

///|
fn EventWriter::new() -> EventWriter {
  {
    pending: [],
    queued_bytes: 0,
    stopped: false,
    arrived: @cond_var.Cond::Cond(),
    drained: @cond_var.Cond::Cond(),
    generations: Map::new(),
  }
}

///|
/// Record the current generation of a subscription id.
fn EventWriter::register(
  self : EventWriter,
  subscription_id : String,
  generation : Int,
) -> Unit {
  self.generations[subscription_id] = generation
}

///|
/// Retire a subscription id. Any line already queued for an older generation is
/// dropped when the writer reaches it.
fn EventWriter::retire(self : EventWriter, subscription_id : String) -> Unit {
  self.generations.remove(subscription_id)
}

///|
/// True when a queued line is still allowed to be written.
fn EventWriter::admits(self : EventWriter, item : Outgoing) -> Bool {
  match item.guard_subscription {
    None => true
    Some(subscription_id) =>
      match self.generations.get(subscription_id) {
        Some(current) => current == item.guard_generation
        None => false
      }
  }
}

///|
/// Queue one line, blocking while the byte budget is exhausted.
async fn EventWriter::emit(
  self : EventWriter,
  line : String,
  guard_subscription? : String,
  guard_generation? : Int = 0,
) -> Unit {
  if self.stopped {
    return
  }
  let bytes = line.length() + 1
  if bytes > MAX_EVENT_BYTES {
    // Refusing loudly beats writing a line the controller would reject and
    // beats silently dropping a value the controller is waiting for.
    self.emit(
      oversized_event(guard_subscription, bytes),
      guard_subscription?,
      guard_generation~,
    )
    return
  }
  while !self.stopped &&
        self.queued_bytes > 0 &&
        self.queued_bytes + bytes > WRITE_BUDGET_BYTES {
    self.drained.wait()
  }
  if self.stopped {
    return
  }
  self.pending.push({ line, bytes, guard_subscription, guard_generation })
  self.queued_bytes = self.queued_bytes + bytes
  self.arrived.broadcast()
}

///|
/// Drain the queue onto `sink` in strict arrival order until stopped.
async fn EventWriter::run(self : EventWriter, sink : &@io.Writer) -> Unit {
  for ;; {
    while self.pending.length() == 0 && !self.stopped {
      self.arrived.wait()
    }
    if self.pending.length() == 0 {
      return
    }
    let item = self.pending.remove(0)
    self.queued_bytes = self.queued_bytes - item.bytes
    self.drained.broadcast()
    if self.admits(item) {
      sink.write(@utf8.encode(item.line + "\n")) catch {
        // The controller has gone away. Nothing useful can be reported over the
        // stream that just died, so stop cleanly instead of looping on a dead
        // descriptor.
        _ => {
          self.stopped = true
          return
        }
      }
    }
  }
}

///|
/// Stop the writer once everything already queued has been written.
fn EventWriter::stop(self : EventWriter) -> Unit {
  self.stopped = true
  self.arrived.broadcast()
  self.drained.broadcast()
}

///|
fn json_line(members : Array[(String, Json)]) -> String {
  let object : Map[String, Json] = Map::new()
  for member in members {
    object[member.0] = member.1
  }
  Json::object(object).stringify()
}

///|
/// The event emitted in place of one that is too large to write.
fn oversized_event(subscription_id : String?, bytes : Int) -> String {
  let message = "adapter event of " +
    bytes.to_string() +
    " string units exceeded the writer limit"
  match subscription_id {
    Some(id) => subscription_error_event(id, "ProtocolError", message, None)
    None => error_event(None, "ProtocolError", message, None)
  }
}

///|
/// Build the `error` member. `data` is omitted when Convex did not supply one,
/// because the schema treats a missing payload and a null payload differently.
fn error_object(name : String, message : String, data : Json?) -> Json {
  let members : Map[String, Json] = Map::new()
  members["name"] = Json::string(name)
  members["message"] = Json::string(message)
  match data {
    Some(value) => members["data"] = value
    None => ()
  }
  Json::object(members)
}

///|
fn log_array(logs : Array[String]) -> Json {
  let items : Array[Json] = []
  for line in logs {
    items.push(Json::string(line))
  }
  Json::array(items)
}

///|
fn ready_event(
  id : String,
  language : String,
  implementation : String,
  runtime : String,
) -> String {
  json_line([
    ("protocolVersion", Json::number(1.0)),
    ("id", Json::string(id)),
    ("type", Json::string("ready")),
    ("language", Json::string(language)),
    ("implementation", Json::string(implementation)),
    ("runtime", Json::string(runtime)),
  ])
}

///|
fn result_event(id : String, value : Json, logs : Array[String]) -> String {
  json_line([
    ("id", Json::string(id)),
    ("type", Json::string("result")),
    ("value", value),
    ("logs", log_array(logs)),
  ])
}

///|
fn ack_event(id : String) -> String {
  json_line([("id", Json::string(id)), ("type", Json::string("ack"))])
}

///|
fn closed_event(id : String) -> String {
  json_line([("id", Json::string(id)), ("type", Json::string("closed"))])
}

///|
/// A command failure. `id` is omitted when the command was too malformed to
/// carry one, rather than being written as null.
fn error_event(
  id : String?,
  name : String,
  message : String,
  data : Json?,
) -> String {
  let members : Array[(String, Json)] = []
  match id {
    Some(value) => members.push(("id", Json::string(value)))
    None => ()
  }
  members.push(("type", Json::string("error")))
  members.push(("error", error_object(name, message, data)))
  json_line(members)
}

///|
fn subscription_value_event(
  subscription_id : String,
  value : Json,
  logs : Array[String],
) -> String {
  json_line([
    ("type", Json::string("subscription")),
    ("subscriptionId", Json::string(subscription_id)),
    ("value", value),
    ("logs", log_array(logs)),
  ])
}

///|
fn subscription_error_event(
  subscription_id : String,
  name : String,
  message : String,
  data : Json?,
) -> String {
  json_line([
    ("type", Json::string("subscription")),
    ("subscriptionId", Json::string(subscription_id)),
    ("error", error_object(name, message, data)),
  ])
}
