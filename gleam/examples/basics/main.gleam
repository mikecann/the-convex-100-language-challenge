//// Convex from Gleam: one shared counter, read two different ways.
////
//// The program reads a room's counter over Convex's HTTP API, subscribes to
//// the same query over the reactive `/api/sync` connection, increments the
//// counter once, and shows both surfaces agreeing on the journey from 0 to 1.

import convex
import convex_json.{type Json, JsonObject, JsonString} as json
import convex_live.{
  type SubscriptionEvent, LiveFailure, LiveValue, SubscriptionEvent,
}
import convex_sys
import gleam/erlang/process.{type Subject}
import gleam/io

/// A Live update should arrive in milliseconds. Waiting forever would turn a
/// broken subscription into a hung example instead of a clear failure.
const live_timeout = 10_000

pub fn main() -> Nil {
  // The verifier passes a unique room so concurrent runs cannot share a
  // counter. The default only exists for someone running the image by hand.
  let room = case convex_sys.plain_arguments() {
    [first, ..] -> first
    [] -> "gleam-basic-example"
  }
  // The verifier also supplies the deployment URL; the default points at the
  // repository's local self-hosted backend.
  let deployment = convex_sys.env("CONVEX_URL", "http://127.0.0.1:3210")

  // One client owns both documented HTTP calls and the single sync connection.
  let assert Ok(client) = convex.new(deployment)
  let args = JsonObject([#("room", JsonString(room))])

  // These demo functions are public, so no token is needed. A protected
  // function would call `convex.set_auth` before any HTTP call.

  // Read the durable counter through Convex's documented HTTP API first.
  let assert Ok(initial) = convex.call(client, convex.Query, "demo:state", args)
  expect(count(initial.value) == 0, "expected the room to start at 0")
  io.println("current count: 0")

  // Subscribe before changing anything. Starting Live first means no update
  // can fall into a gap between the initial read and the subscription.
  let updates = process.new_subject()
  let assert Ok(subscription) =
    convex.subscribe(client, "demo:state", args, updates)

  // A Live query first hydrates with its current value. Decode it into the
  // same idiomatic integer the HTTP result produced.
  expect(next_count(updates, subscription) == 0, "expected Live to start at 0")
  io.println("live initial count: 0")

  // Convex records this idempotency key, so retrying this exact write cannot
  // increment the room twice.
  let mutation_args =
    JsonObject([
      #("room", JsonString(room)),
      #("language", JsonString("Gleam")),
      #("runId", JsonString(room <> "-once")),
    ])
  let assert Ok(mutation) =
    convex.call(client, convex.Mutation, "demo:increment", mutation_args)
  expect(
    json.field(mutation.value, "applied") == Ok(json.JsonBool(True)),
    "expected the mutation to be applied",
  )
  let assert Ok(state) = json.field(mutation.value, "state")
  expect(count(state) == 1, "expected the mutation to leave the room at 1")
  io.println("mutation applied: true")
  io.println("mutation count: 1")

  // The sole Live owner decodes the resulting WebSocket transition and relays
  // the changed value in protocol order.
  expect(
    next_count(updates, subscription) == 1,
    "expected Live to report the incremented value",
  )
  io.println("live updated count: 1")

  // Remove the server-side query, then release the socket and the owner.
  let assert Ok(_) = convex.unsubscribe(client, subscription)
  let assert Ok(_) = convex.close(client)

  // Reaching this line proves HTTP and Live agreed on one 0 -> 1 journey.
  io.println("verified count: 0 -> 1")
}

/// Wait for the next value on one subscription.
///
/// Live also reports query failures and transport failures on the same
/// channel. Turning those into an immediate stop keeps the example honest: a
/// failed subscription must never look like a missing update.
fn next_count(updates: Subject(SubscriptionEvent), subscription: String) -> Int {
  case process.receive(updates, live_timeout) {
    Error(_) -> {
      report("Live delivered no update before the timeout")
      panic as "Live delivered no update before the timeout"
    }
    Ok(SubscriptionEvent(id, event, acknowledged)) -> {
      expect(id == subscription, "received an event for another subscription")
      // Tell the bounded relay this value has left our mailbox before it sends
      // another one. A consumer that stops reading therefore cannot grow an
      // unbounded BEAM mailbox behind the client's queue limits.
      process.send(acknowledged, Nil)
      case event {
        LiveValue(value, _logs) -> count(value)
        LiveFailure(error) -> {
          report(error.name <> ": " <> error.message)
          panic as "Live reported a failure"
        }
      }
    }
  }
}

/// Decode the room's counter.
///
/// Convex may spell a whole number as `0` or `0.0`, so both are accepted, and
/// a fraction, a quoted number, or an out-of-range value is rejected rather
/// than rounded into something that looks like agreement.
///
/// This is public only so the regression test can exercise the exact function
/// the example uses, rather than a second copy of it.
pub fn count(value: Json) -> Int {
  case json.field(value, "count") {
    Error(_) -> {
      report("Convex value has no count field")
      panic as "Convex value has no count field"
    }
    Ok(raw) ->
      case json.integral_int(raw) {
        Ok(number) -> number
        Error(_) -> {
          report("count is not a whole number in range")
          panic as "count is not a whole number in range"
        }
      }
  }
}

/// Stop on an unexpected value. Compilation is not evidence, so every step the
/// example demonstrates has to be checked at runtime.
fn expect(condition: Bool, message: String) -> Nil {
  case condition {
    True -> Nil
    False -> {
      report(message)
      panic as "unexpected Convex value"
    }
  }
}

/// Diagnostics go to standard error, because standard output is the shared
/// transcript every language in this repository has to match exactly.
fn report(message: String) -> Nil {
  convex_sys.stderr_write(message)
}
