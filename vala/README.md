# Convex from Vala

This native Vala client calls Convex over documented JSON HTTP endpoints and keeps a query current through the repository's pinned Live WebSocket profile.

It is educational and unofficial. It is not a production SDK and is not intended for package publication.

## Start here

Read [`examples/basics/main.vala`](examples/basics/main.vala). It queries a fresh counter, starts Live before changing it, applies one idempotent mutation, and proves that HTTP and Live agree on `0 -> 1`.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, actions, and structured errors | Implemented, no earned badge |
| Live initial values and updates used by the canonical example | Implemented, no earned badge |
| Full HTTP and Live conformance | Not yet earned |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.vala -->
```vala
using GLib;
using Json;
using Convex;

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
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

```sh
./run sync-examples
./run validate
./run test vala
./run verify-example vala
```

`test` compiles and runs Vala's language-local adapter checks inside Docker. The final-image probes exercise the exact canonical example and adapter under the runtime policy. Root-owned shared conformance is still required before either capability can be earned.

## Conformance and protocol notes

The client implements Convex-specific HTTP envelopes and an attempted pinned `/api/sync` query-set profile in Vala. libsoup supplies ordinary TLS, HTTP, and RFC6455 transport only. One GLib-main-context Live owner opens, reads, writes, retires, and reconnects the socket. It commits a complete Transition before publishing updates, validates query-set versions and uint32 bounds, tracks the little-endian timestamp numerically, reports transport failures as structured events, and suppresses unchanged rehydration. Delivery relays are generation-tagged and bounded to sixteen events and eight MiB; adapter output has a two MiB event cap and eight MiB in-flight budget.

The test-only adapter accepts strict NDJSON v1 over stdin/stdout or one `ADAPTER_LISTEN` TCP controller. `debugDisconnect` is adapter-only and lets the shared harness prove real reconnections.

## Limitations

The basic Live path still lacks deterministic raw-peer coverage for fragmented frames, stalled-frame deadlines, five reconnects, and full recovery behaviour required for a Live badge. The new local tests cover relay invalidation, deduplication, numeric bounds, and the stopped-reader relay budget, but do not replace root-owned shared conformance. Live authentication lifecycle, optimistic updates, mutation and action messages over WebSocket, journals, and TransitionChunk assembly are also deferred. The manifest deliberately declares no earned badges until root-owned local and hosted evidence passes from a clean reviewed commit.
