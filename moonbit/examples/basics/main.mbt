// Convex from MoonBit: the shared counter demonstration.
//
// One room goes from 0 to 1 and every surface agrees about it. The example
// reads the count over Convex's HTTP function endpoint, opens a Live
// subscription over the sync WebSocket, applies a mutation, and then waits for
// the reactive update that the mutation caused. If any of those disagree the
// program fails instead of printing a happy transcript.

///|
/// Build the shared demo's argument object.
///
/// `demo:state` only needs the room. `demo:increment` also takes the language
/// label it records and the idempotency key that makes a retry safe, so those
/// are optional here rather than being two nearly identical builders.
fn room_args(room : String, language? : String, run_id? : String) -> Json {
  let members : Map[String, Json] = Map::new()
  members["room"] = Json::string(room)
  match language {
    Some(value) => members["language"] = Json::string(value)
    None => ()
  }
  match run_id {
    Some(value) => members["runId"] = Json::string(value)
    None => ()
  }
  Json::object(members)
}

///|
/// A random idempotency key for this run.
///
/// `demo:increment` refuses to apply the same `runId` twice, so a retry after a
/// timeout cannot double-count. Falling back to a fixed key would silently turn
/// the mutation into a no-op on a second run against the same room, which is
/// why the failure is loud.
fn fresh_run_id() -> String raise {
  guard @env.rand(16) is Some(raw) else {
    fail("this platform provides no entropy source for an idempotency key")
  }
  let digits = "0123456789abcdef"
  let out = StringBuilder::StringBuilder(size_hint=32)
  for index = 0; index < raw.length(); index = index + 1 {
    let byte = raw[index].to_int()
    out.write_char(digits.unsafe_char_at((byte >> 4) & 0x0f))
    out.write_char(digits.unsafe_char_at(byte & 0x0f))
  }
  out.to_string()
}

///|
/// Read `count` out of a `demo:state` value.
///
/// `@convex.integer_value` accepts an integral number in either `0` or `0.0`
/// form, which Convex's JSON encoding may use interchangeably, and rejects
/// fractional, quoted, non-finite, or overflowing input. Wrapping it here keeps
/// the failure message pointed at the operation that produced the value.
fn count_of(value : Json, what : String) -> Int64 raise {
  @convex.integer_value(
    @convex.required_field(value, "count", what),
    what + " count",
  )
}

///|
/// Wait for the next Live value, refusing to treat a reactive failure as data.
///
/// A Live subscription can deliver a structured failure instead of a value -
/// the query threw, the socket dropped, the server drifted - and a demo that
/// silently retried past one of those would be claiming a reactive guarantee it
/// had not observed.
async fn next_live_count(
  subscription : @convex.Subscription,
  what : String,
) -> Int64 {
  guard subscription.next(timeout_ms=20000) is Some(update) else {
    fail(what + " did not arrive before the deadline")
  }
  match update.error {
    Some(info) =>
      fail(what + " failed: " + info.kind.to_string() + ": " + info.message)
    None => ()
  }
  guard update.value is Some(value) else { fail(what + " carried no value") }
  count_of(value, what)
}

///|
async fn run(url : String, room : String) -> Unit {
  @convex.with_client(url, client => {
    // Read the current count through Convex's documented HTTP endpoint. This
    // is a plain request/response call: no socket, no subscription.
    let current = count_of(
      client.query("demo:state", room_args(room)).value,
      "current",
    )

    // The demonstration is only meaningful from a room nobody has touched.
    guard current == 0L else {
      fail("expected a fresh room, but it already had a count")
    }
    println("current count: " + current.to_string())

    // Subscribe before mutating. Convex delivers the value that is current when
    // the subscription is established and then every value after it, so opening
    // the subscription first is what guarantees the update caused by the
    // mutation below cannot be missed.
    let subscription = client.subscribe("demo:state", room_args(room))

    // The first Live value is the room as it is now, and it has to agree with
    // what HTTP just reported.
    let initial = next_live_count(subscription, "initial Live value")
    guard initial == current else {
      fail("the initial Live value disagreed with the HTTP query")
    }
    println("live initial count: " + initial.to_string())

    // Apply the mutation. The idempotency key is what makes this safe to retry:
    // Convex records it and answers a repeat with `applied: false`.
    let mutation = client.mutation(
        "demo:increment",
        room_args(room, language="MoonBit", run_id=fresh_run_id()),
      ).value
    guard @convex.json_field(mutation, "applied") is Some(True) else {
      fail("the mutation was not applied")
    }
    let mutated = count_of(
      @convex.required_field(mutation, "state", "mutation"),
      "mutation",
    )
    guard mutated == current + 1L else {
      fail("the mutation returned an unexpected count")
    }
    println("mutation applied: true")
    println("mutation count: " + mutated.to_string())

    // The mutation changed data the subscription is watching, so Convex pushes
    // the new value over the same socket. This is the reactive half of the
    // demonstration: nothing polled for it.
    let updated = next_live_count(subscription, "updated Live value")
    guard updated == mutated else {
      fail("the Live update disagreed with the mutation")
    }
    println("live updated count: " + updated.to_string())

    // Retire the subscription now that the proof is complete. Closing the
    // client would do it too, but doing it explicitly is the honest shape for
    // a long-lived program.
    client.unsubscribe(subscription)

    // Only now, with every operation agreeing, is the journey verified.
    println(
      "verified count: " + current.to_string() + " -> " + updated.to_string(),
    )
  })
}

///|
async fn main {
  // Docker supplies the deployment; the verifier supplies a room nobody else is
  // using as the first argument.
  guard @env.get_env_var("CONVEX_URL") is Some(url) else {
    @stdio.stderr.write("MoonBit example failed: CONVEX_URL is required\n") catch {
      _ => ()
    }
    panic()
  }
  let arguments = @env.args()
  let room = if arguments.length() > 1 {
    arguments[1]
  } else {
    // A friendly default for someone running the image by hand.
    match @env.get_env_var("EXAMPLE_ROOM") {
      Some(value) => value
      None => "moonbit-example"
    }
  }
  // A whole-run deadline turns a stalled deployment into a reported failure
  // instead of a container that never exits.
  @async.with_timeout(60000, () => run(url, room)) catch {
    error => {
      @stdio.stderr.write("MoonBit example failed: \{error}\n") catch {
        _ => ()
      }
      panic()
    }
  }
}
