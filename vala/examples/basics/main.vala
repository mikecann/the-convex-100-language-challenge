using GLib;
using Json;
using Convex;

// Build the shared demo's argument object, including the mutation's optional
// language label and idempotency key when that operation needs them.
static Json.Node object_node (string room, string? language = null, string? run_id = null) {
  var builder = new Builder ();
  builder.begin_object ();
  builder.set_member_name ("room");
  builder.add_string_value (room);
  if (language != null) {
    builder.set_member_name ("language");
    builder.add_string_value (language);
  }
  if (run_id != null) {
    builder.set_member_name ("runId");
    builder.add_string_value (run_id);
  }
  builder.end_object ();
  return builder.get_root ().copy ();
}

// Convex may encode an integral JSON number as either 1 or 1.0. Accept both
// forms while rejecting fractional, non-finite, negative, or overflowing data.
static int64 count_from (Json.Node value, string operation) throws Error {
  if (value.get_node_type () != NodeType.OBJECT) {
    throw new ClientError.PROTOCOL (operation + " did not return an object");
  }
  var count_node = value.get_object ().get_member ("count");
  if (count_node.get_value_type () != typeof (int64) && count_node.get_value_type () != typeof (double)) {
    throw new ClientError.PROTOCOL (operation + " returned a non-numeric count");
  }
  var count = count_node.get_double ();
  if (count != count || count < 0 || count >= 9223372036854775808.0) {
    throw new ClientError.PROTOCOL (operation + " returned an out-of-range count");
  }
  int64 integral = (int64) count;
  if ((double) integral != count) {
    throw new ClientError.PROTOCOL (operation + " returned a non-integral count");
  }
  return integral;
}

int main (string[] args) {
  int exit_code = 1;
  try {
    var url = Environment.get_variable ("CONVEX_URL");
    if (url == null || url.length == 0) throw new ClientError.PROTOCOL ("CONVEX_URL is required");
    var room = args.length > 1 ? args[1] : (Environment.get_variable ("EXAMPLE_ROOM") ?? "vala-example");
    // Configure one client for the deployment supplied by Docker.
    var client = new Client (url);
    // Query the room through Convex's documented HTTP endpoint.
    var current = count_from (client.query ("demo:state", object_node (room)).value, "current query");
    stdout.printf ("current count: %" + int64.FORMAT + "\n", current);
    // Start Live before mutating so no reactive update is missed.
    var subscription = client.subscribe ("demo:state", object_node (room));
    var loop = new MainLoop ();
    int stage = 0;
    uint timeout_source = 0;
    subscription.updated.connect ((value, failure) => {
      try {
        if (failure != null) {
          throw new ClientError.PROTOCOL (failure.message);
        }
        var observed = count_from (value, stage == 0 ? "initial Live value" : "updated Live value");
        if (stage == 0) {
          if (observed != current) {
            throw new ClientError.PROTOCOL ("initial Live count disagreed with HTTP");
          }
          stdout.printf ("live initial count: %" + int64.FORMAT + "\n", observed);
          // This UUID is the mutation idempotency key, so retries cannot increment twice.
          var mutation = client.mutation ("demo:increment", object_node (room, "Vala", Uuid.string_random ())).value;
          if (!mutation.get_object ().get_boolean_member ("applied")) {
            throw new ClientError.PROTOCOL ("mutation was not applied");
          }
          var mutation_count = count_from (mutation.get_object ().get_member ("state"), "mutation");
          if (mutation_count != current + 1) {
            throw new ClientError.PROTOCOL ("mutation returned an unexpected count");
          }
          stdout.printf ("mutation applied: true\nmutation count: %" + int64.FORMAT + "\n", mutation_count);
          stage = 1;
        } else {
          if (observed != current + 1) {
            throw new ClientError.PROTOCOL ("updated Live count disagreed with mutation");
          }
          stdout.printf ("live updated count: %" + int64.FORMAT + "\n", observed);
          stdout.printf ("verified count: %" + int64.FORMAT + " -> %" + int64.FORMAT + "\n", current, observed);
          // Retire the Live query and its transport after the proof is complete.
          client.unsubscribe (subscription);
          client.close ();
          exit_code = 0;
          if (timeout_source != 0) Source.remove (timeout_source);
          loop.quit ();
        }
      } catch (Error error) {
        stderr.printf ("Vala example failed: %s\n", error.message);
        client.close ();
        loop.quit ();
      }
    });
    // Fail clearly instead of leaving a viewer with an example that hangs.
    timeout_source = Timeout.add_seconds (20, () => {
      stderr.printf ("Vala example timed out\n");
      client.close ();
      loop.quit ();
      return false;
    });
    loop.run ();
    return exit_code;
  } catch (Error error) {
    stderr.printf ("Vala example failed: %s\n", error.message);
    return 1;
  }
}
