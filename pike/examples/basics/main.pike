#!/usr/local/bin/pike

// Convex from Pike: read a shared counter over HTTP, watch the same query over
// Live, increment it once, and prove the 0 -> 1 journey.
//
// This is the canonical example. The README and the website show this exact
// file, and the Docker verifier runs this exact file against a fresh room.

// The client is compiled from source at startup rather than linked in, so the
// example, the tests, and the conformance adapter all run the same code
// wherever it happens to be installed.
string client_source()
{
  array(string) locations = ({
    getenv("CONVEX_CLIENT_PATH"),
    "/opt/convex/client",
    combine_path(dirname(__FILE__), "..", "..", "client"),
  });
  foreach (locations, string directory) {
    if (!directory || !sizeof(directory))
      continue;
    string candidate = combine_path(directory, "convex.pike");
    if (Stdio.is_file(candidate))
      return candidate;
  }
  error("could not find the Pike Convex client source\n");
  return 0;
}

// Convex sends JSON numbers, and a whole number may legitimately arrive as 0.0.
// The client's decoder accepts a mathematically integral value and rejects
// fractions, quoted numbers, and anything out of range, so the example never
// has to guess what a count meant.
int room_count(object convex, mixed state, string what)
{
  mapping room_state = convex->require_object(state, what);
  // Pike's `->` on a mapping returns 0 for a missing key, which is also a
  // legitimate count, so absence has to be checked before extraction can
  // treat a bare 0 as meaningful.
  if (zero_type(room_state->count))
    throw(convex->protocol_error(what + " state is missing its count field"));
  return convex->require_whole_number(room_state->count, what + " count");
}

// A Live update carries either a value or a classified failure, never both.
// Raising on the failure keeps the printed transcript honest: nothing is
// reported as verified unless every operation really agreed.
int live_count(object convex, object update, string what)
{
  if (update->failure)
    error("%s failed: %s\n", what, update->failure->describe());
  return room_count(convex, update->value, what);
}

int demonstrate(object convex, object client, string room)
{
  // Read the room's current state through Convex's documented JSON HTTP query
  // endpoint. A fresh room reports zero without needing to be created first.
  object current = client->query("demo:state", ([ "room": room ]));
  int before = room_count(convex, current->value, "current query");
  if (before != 0)
    error("the room started at %d instead of 0\n", before);
  write("current count: %d\n", before);

  // Subscribe before writing anything. Starting Live first is what makes the
  // increment below observable: a subscription opened afterwards could not
  // prove that the update was pushed rather than polled.
  object updates = client->subscribe("demo:state", ([ "room": room ]));

  // Convex hydrates a new Live query with its current value. That first value
  // has to agree with the HTTP read before the example changes anything.
  object initial = updates->next_update(20000);
  int live_before = live_count(convex, initial, "initial Live value");
  if (live_before != before)
    error("Live started at %d but HTTP reported %d\n", live_before, before);
  write("live initial count: %d\n", live_before);

  // runId is the mutation's idempotency key. Convex records it, so retrying
  // this logical request would return the same write instead of incrementing
  // the room a second time.
  string run_id = sprintf("pike-%s-%d-%d", room, time(), random(1000000000));
  object applied = client->mutation("demo:increment", ([
    "room": room,
    "language": "Pike",
    "runId": run_id,
  ]));
  mapping outcome = convex->require_object(applied->value, "mutation result");
  if (!convex->json_is_true(outcome->applied))
    error("Convex reported that the increment was not applied\n");
  write("mutation applied: true\n");
  int after = room_count(convex, outcome->state, "mutation");
  if (after != before + 1)
    error("the increment moved the count to %d instead of %d\n", after,
          before + 1);
  write("mutation count: %d\n", after);

  // The reactive update now arrives on the subscription opened earlier, with
  // no second HTTP query. This is the whole point of Live.
  object changed = updates->next_update(20000);
  int live_after = live_count(convex, changed, "updated Live value");
  if (live_after != after)
    error("Live reported %d but the mutation returned %d\n", live_after, after);
  write("live updated count: %d\n", live_after);

  // Only now, with HTTP and Live agreeing on the whole journey, is the run
  // verified.
  write("verified count: %d -> %d\n", before, after);

  // Stop this query before the shared client is torn down.
  updates->close();
  return 0;
}

int main(int argc, array(string) argv)
{
  string deployment_url = getenv("CONVEX_URL");
  if (!deployment_url || !sizeof(deployment_url)) {
    werror("CONVEX_URL is required\n");
    return 2;
  }

  // The verifier passes a unique room so independent runs never collide. The
  // default only exists for someone running this image by hand.
  string room = argc > 1 ? argv[1] : (getenv("EXAMPLE_ROOM") || "pike-example");

  object convex = compile_file(client_source())();
  object client = convex->Client(deployment_url);

  // Diagnostics belong on stderr: stdout is the transcript the verifier
  // compares line for line.
  int status = 1;
  mixed failed = catch { status = demonstrate(convex, client, room); };
  client->close();
  if (failed) {
    werror("pike example failed: %s\n",
           convex->as_convex_error(failed)->describe());
    return 1;
  }
  return status;
}
