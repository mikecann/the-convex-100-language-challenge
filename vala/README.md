<img src="logo.png" alt="Vala logo" width="160">
<!-- Logo source: https://raw.githubusercontent.com/vala-lang/vala-www/main/public/android-icon-192x192.png -->

# Vala

[Vala](https://vala.dev/) is a statically typed language from the GNOME ecosystem. It began as a way to write GObject software with modern, C#-influenced syntax instead of hand-writing all the supporting C. The self-hosting `valac` compiler translates Vala into C and then a native binary, so programs use the existing GLib and GObject world rather than a Vala virtual machine.

That makes Vala a specialist language today: it is most at home in GNOME and Linux desktop applications, command-line tools, and libraries that need a normal C-compatible interface. This repository uses that same niche for a native Convex client built on GLib, JSON-GLib, GIO, and libsoup. It is an educational, unofficial demonstration, not a production SDK or a package intended for publication.

## Getting Started

Start with [`examples/basics/main.vala`](examples/basics/main.vala). It queries a fresh counter, subscribes before changing it, applies one idempotent mutation, and checks that the one-off HTTP result and later Live values agree on `0 -> 1`.

From the repository root, Docker builds the exact canonical example and runs it against an approved test deployment:

```sh
./run verify-example vala
```

## Interesting Parts

### One error domain, four codes, zero exception classes

Vala grew up next to GLib, and GLib error handling predates exception hierarchies: an `errordomain` is a closed set of named codes that `valac` compiles straight down to a `GError`, with no base class to subclass or catch by accident. This client raises exactly one domain for everything Convex can throw at it, and the transport layer catches it by name before falling back to GLib's generic `Error`.

```vala
public errordomain ClientError {
  TRANSPORT, PROTOCOL, FUNCTION, CLOSED
}

try {
  stream = session.send (message, cancellation);
} catch (ClientError error) {
  throw error; // Already carries the right code; just rethrow it.
} catch (Error error) {
  throw new ClientError.TRANSPORT (error.message);
  // TypeScript: try { await client.query(...) } catch (e) { ... } — one Error type, not four.
}
```

Every failure this client can raise fits in `TRANSPORT`, `PROTOCOL`, `FUNCTION`, or `CLOSED` — no `instanceof` chain required to know what went wrong.

### A GObject property is one line

Vala's real payoff for compiling through C is GObject, the object system underneath GTK and most of the GNOME stack. Declaring a field as `{ get; construct; }` tells the compiler to generate the backing storage, the getter, and a construct-time-only setter, wired into GObject's actual property machinery rather than hand-written accessors. Every Convex response this client returns is one of these.

```vala
public class Result : GLib.Object {
  public Json.Node value { get; construct; }
  public string[] logs { get; construct; }
  public Result (Json.Node value, string[] logs = {}) {
    GLib.Object (value: value, logs: logs);
    // TypeScript: `interface Result { value; logs }` — here it's a live GObject.
  }
}
```

`construct` rather than `set` means `value` and `logs` are readable everywhere but only ever assigned once, at construction — Vala's answer to `readonly`.

### Live fires as a signal, not a promise

React's `useQuery` re-renders a component whenever fresh data lands; this client has no component tree, so it exposes the same reactivity through a GObject signal instead. `updated` is declared once on `Subscription` and emitted every time a value or error arrives over the WebSocket — the same `.connect()` idiom GTK code uses for a button click. Since there's no framework event loop running underneath it, the program has to pump GLib's own.

```vala
var subscription = client.subscribe ("demo:state", object_node (room));
subscription.updated.connect ((value, failure) => {
  if (failure != null) throw new ClientError.PROTOCOL (failure.message);
  var observed = count_from (value, "Live value");
  stdout.printf ("live count: %" + int64.FORMAT + "\n", observed);
  // TypeScript: useQuery(api.demo.state, { room }) re-renders — a signal fires here instead.
});
loop.run (); // Nothing else keeps the process alive between emissions.
```

The canonical example below relies on this signal firing twice: once for the initial value, once after the mutation lands.

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, actions, and structured errors | Verified by shared local and hosted conformance |
| Live initial values and updates used by the canonical example | Verified by shared local and hosted conformance |
| Full HTTP and Live conformance | Passed; both capabilities earned |

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.vala -->
```vala
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
static int64 count_from (Json.Node? value, string operation) throws Error {
  if (value == null || value.get_node_type () != NodeType.OBJECT) {
    throw new ClientError.PROTOCOL (operation + " did not return an object");
  }
  // JSON-GLib returns NULL for an absent member, and dereferencing that is a
  // crash rather than a readable failure, so check before reading the count.
  if (!value.get_object ().has_member ("count")) {
    throw new ClientError.PROTOCOL (operation + " returned an object without a count");
  }
  var count_node = value.get_object ().get_member ("count");
  if (count_node.get_node_type () != NodeType.VALUE ||
      (count_node.get_value_type () != typeof (int64) && count_node.get_value_type () != typeof (double))) {
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
          // The same absent-member rule applies to the mutation envelope: read
          // applied and state only once both are present and correctly typed.
          if (mutation.get_node_type () != NodeType.OBJECT ||
              !mutation.get_object ().has_member ("applied") || !mutation.get_object ().has_member ("state") ||
              mutation.get_object ().get_member ("applied").get_value_type () != typeof (bool)) {
            throw new ClientError.PROTOCOL ("mutation did not return applied and state");
          }
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
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

This is a native implementation. Vala owns the Convex request envelopes and Live behaviour; it does not hand protocol work to an existing Convex SDK. The pinned Vala 0.56.3 compiler translates the source to C, and the Docker build produces a native `linux/amd64` executable. libsoup 3 handles HTTP and TLS, JSON-GLib represents values, and GLib/GIO sockets carry the client-owned WebSocket implementation.

The public HTTP calls are synchronous and return a `Result` containing a JSON-GLib node plus Convex log lines. Responses are streamed under a 2 MiB cap and one absolute deadline. The client parses a valid Convex error envelope before classifying the HTTP status so function error messages, data, and logs are not lost.

Live has one owner on the GLib main context. It manages socket reads, writes, query changes, reconnects, and active subscriptions, then publishes complete updates through each subscription's `updated` signal. Delivery is deliberately bounded by both event count and retained memory, and unsubscribe invalidates an old relay before returning. The adapter-only `debugDisconnect` hook exists for conformance tests and is not part of the educational API.

## Known Issues

1. Live authentication refresh, optimistic updates, and mutation or action calls over the WebSocket are deferred. HTTP mutation and action calls still work.
2. `TransitionChunk` assembly is not implemented. Receiving one is treated as protocol drift, reported as a protocol error, and followed by reconnecting the Live owner.
3. Untrusted JSON is refused above an estimated 8 MiB retained tree or 64 nesting levels, and HTTP bodies are capped at 2 MiB. A wire-valid but very node-dense Convex value can therefore be rejected.
4. With libsoup 3.2, a chunked response that also says `Connection: close` is conservatively rejected because the decoded stream cannot prove that the terminating chunk arrived.
