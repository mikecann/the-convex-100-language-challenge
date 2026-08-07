# Convex from Haxe

This is a small native Haxe client that calls Convex functions over HTTP and
keeps a query current over Live WebSockets. It is compiled to Neko bytecode,
and Neko supplies only ordinary runtime facilities: sockets, TLS, threads, and
JSON. The Convex HTTP envelopes, the pinned sync protocol, RFC 6455 framing,
reconnect behaviour, and the NDJSON conformance adapter are all written here in
Haxe.
One session UUID is retained across transport reconnects so connection counts
and observed timestamps continue to describe the same server session.

It is educational and unofficial. It is not a production SDK and is not
intended for package publication.

## Start here

Read [`examples/basics/Main.hx`](examples/basics/Main.hx). It queries a fresh
counter room, starts a Live subscription before anything changes, applies one
idempotent mutation, and then waits for that same subscription to observe the
new value. It prints its six lines only when HTTP, the mutation result, and
Live all agree on the `0 -> 1` journey.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions | Implemented, awaiting shared evidence |
| Bearer authentication transport and structured function errors | Implemented, awaiting shared evidence |
| Live initial values, external updates, and query-error recovery | Implemented, awaiting shared evidence |
| Remove, five real reconnects, generation barriers, bounded delivery | Implemented, awaiting shared evidence |
| Live authentication, WebSocket mutations and actions, transition chunks | Not implemented |

Nothing in this table is a badge. Only the shared result evaluator may award
HTTP or Live, and it has not run against this source yet.

<!-- BEGIN GENERATED EXAMPLE: examples/basics/Main.hx -->
```text
import haxe.Exception;

class Main {
  static function wholeCount(value:Dynamic, operation:String):Int {
    // Convex may encode a whole count as either 1 or 1.0. Accept only a finite,
    // exactly integral value that fits the teaching example's Int range.
    if (!Std.isOfType(value, Int) && !Std.isOfType(value, Float)) {
      throw new Exception('$operation count was not a JSON number');
    }
    var number:Float = value;
    if (!Math.isFinite(number) || Math.floor(number) != number || number < -2147483648.0 || number > 2147483647.0) {
      throw new Exception('$operation count was not an in-range whole number');
    }
    return Std.int(number);
  }

  static function countOf(value:Dynamic, operation:String):Int {
    if (value == null || !Reflect.hasField(value, "count")) {
      throw new Exception('$operation omitted count');
    }
    return wholeCount(Reflect.field(value, "count"), operation);
  }

  public static function main():Void {
    // Read the deployment and verifier-provided isolated room without baking
    // credentials or environment-specific data into the example image.
    var url = Sys.getEnv("CONVEX_URL");
    if (url == null || url.length == 0) throw new Exception("CONVEX_URL is required");
    var arguments = Sys.args();
    var room = arguments.length > 0 ? arguments[0] : "haxe-basic-example";

    // Create the native Haxe client. Its Neko runtime supplies only ordinary
    // TLS and sockets; the Convex protocol lives in the adjacent Haxe source.
    var client = new ConvexClient(url);
    var subscription:Null<LiveSubscription> = null;
    var failure:Dynamic = null;
    try {
      var callArguments:Dynamic = {room: room};

      // Query first so HTTP establishes the expected initial counter value.
      var current = countOf(client.query("demo:state", callArguments).value, "current query");
      if (current != 0) throw new Exception('current count was $current, expected 0');
      Sys.println('current count: $current');

      // Start Live before mutating, so the initial snapshot cannot be missed.
      subscription = client.subscribe("basic-counter", "demo:state", callArguments);
      var initial = subscription.next(10.0);
      if (initial.error != null) throw initial.error;
      if (countOf(initial.value, "initial Live value") != current) {
        throw new Exception("initial Live value disagreed with HTTP");
      }
      Sys.println('live initial count: $current');

      // Use a fresh idempotency key so retrying transport work cannot apply
      // this logical increment twice.
      var mutation = client.mutation("demo:increment", {
        room: room,
        language: "Haxe",
        runId: ConvexClient.randomId()
      }).value;
      if (Reflect.field(mutation, "applied") != true) throw new Exception("mutation was not applied");
      Sys.println("mutation applied: true");
      var expected = current + 1;
      if (countOf(Reflect.field(mutation, "state"), "mutation") != expected) {
        throw new Exception("mutation count disagreed");
      }
      Sys.println('mutation count: $expected');

      // Wait for the same Live query to observe the mutation before claiming
      // the full 0 -> 1 journey succeeded.
      var updated = subscription.next(10.0);
      if (updated.error != null) throw updated.error;
      if (countOf(updated.value, "updated Live value") != expected) {
        throw new Exception("updated Live count disagreed");
      }
      Sys.println('live updated count: $expected');
      Sys.println('verified count: $current -> $expected');
    } catch (error:Dynamic) {
      failure = error;
    }
    // Retire this exact subscription generation before closing the owner. Haxe
    // has no finally statement, so cleanup is explicit and the original error
    // is rethrown only after both lifecycle operations have had a chance to run.
    if (subscription != null) try subscription.close() catch (_:Dynamic) {}
    client.close();
    if (failure != null) throw failure;
  }
}
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

Nothing is built on the host.

```sh
./run sync-examples
./run validate
./run test haxe
./run verify-example haxe
./run verify haxe
./run verify-hosted haxe
./run verify-all haxe
```

`test` pins Haxe 4.2.5 and Neko 2.3.0, compiles the client, the canonical
example, the conformance adapter, and the test suite, then runs that suite
against real sockets. It also proves the example refuses to start without a
deployment instead of printing a partial transcript. `verify-example` runs the
exact `examples/basics/Main.hx` program from its minimal image against a unique
room and compares stdout with the shared expected transcript. `verify` adds
shared black-box conformance against the approved local backend, and
`verify-hosted` repeats it against the hosted drift target. Only the shared
result evaluator awards capability badges, so this branch claims none.

## Conformance and protocol notes

HTTP requests are built and parsed here. The client sends `format: "json"` to
the documented endpoints, bounds responses at 8 MiB, understands both
`Content-Length` and chunked framing, and rejects ambiguous framing rather than
guessing. Convex reports function failures inside the response envelope, so the
envelope is decoded before the HTTP status is consulted; a status only ever
describes a response that is not a Convex error envelope at all. A non-2xx body
that claims `status: success` is rejected. A configured bearer token is
transmitted byte for byte, and a token containing a line break is rejected
rather than allowed to inject a header.

Live uses the pinned `convex-rs-0.10.4-unversioned-sync` profile recorded in
`manifest.yaml`. One owner thread exclusively opens, reads, writes, retires,
and rebuilds the socket. Subscription handles and the adapter send commands to
that owner and wait for bounded acknowledgements. Transitions are validated in
full, including versions, timestamps, and every modification, and only then
committed
and published, so a malformed member can never leave half a transition applied.
Each subscription handle is bound to one generation; unsubscribe and same-ID
replacement invalidate the old generation before the acknowledgement is
published, so an update dequeued a moment earlier can never cross the barrier.
After a reconnect the active `Add` operations are resent and an unchanged
rehydration is suppressed, which keeps the observable sequence exactly initial
value, disconnect acknowledgement, external mutation, new value.

WebSocket framing is strict: masked server frames, set RSV bits, non-minimal
lengths, fragmented control frames, unrequested extensions, and text that is
not well-formed UTF-8 are all rejected. UTF-8 is validated with an explicit
decoder that rejects overlong forms, surrogate halves, and scalars above
U+10FFFF, because a byte-length check would accept all three. Validation
happens on the reassembled message, so a character split across frames still
decodes. Once any byte of a frame has been consumed the connection is
committed: a deadline or a malformed field retires it instead of resuming at a
byte that only looks like a frame boundary. Readiness is a short blocking read
rather than a descriptor select, because under TLS a decoded record can already
be buffered while the descriptor looks idle.

Live delivery is bounded globally rather than per subscription: the newest 16
updates within a 24 MiB budget that charges four times each encoded event plus
a fixed record allowance, because a queued update is retained as a decoded Neko
value. The adapter's output queue is separate and holds at most 16 encoded
lines within 12 MiB, retaining only the bytes it will write. A relay that
dequeued an update before losing ownership is rejected again immediately before
the write. With a reader that has stopped, the adapter fails its own output
instead of growing without bound.

The owner also bounds retained query state to 64 active subscriptions and 8 MiB
of encoded paths and arguments. Pending owner commands and query IDs awaiting a
remote `QueryRemoved` are independently capped, so rapid replacement cannot
move the unbounded state somewhere outside the delivery queue.

The adapter speaks NDJSON protocol v1 over stdin/stdout, or over one
`ADAPTER_LISTEN` TCP connection accepted within a bounded window. It validates
every command strictly, counts identifier lengths in Unicode code points rather
than bytes, and omits absent optional fields entirely rather than serializing
them as null.

Both runtime images contain the Neko VM, the modules it loads, their shared
libraries, the certificate bundle, `/bin/sh`, and the individual POSIX tools
the shared verifier requires. They contain no Haxe compiler, package manager,
network tool, delegated runtime, or multicall binary, and the build proves that
by probing for each. TLS is exercised from that exact rootfs during the build,
so a missing certificate bundle or TLS module is found there rather than during
hosted verification. Both run as `65532:65532`.

## Limitations

Live authentication, optimistic updates, mutations and actions over the
WebSocket, journals, mutation replay, and `TransitionChunk` assembly are
deferred; a `TransitionChunk` is treated as recoverable profile drift and
retires the socket rather than publishing partial state. Values cover Convex's
JSON-safe subset, so tagged encodings are not converted into richer Haxe types.
The client has no server-inactivity watchdog; it relies on the peer closing or
on a read failing. Inputs beyond the documented line, body, frame, delivery, or
output bounds are rejected or coalesced rather than risking unbounded memory.
Docker compilation and the shared local and hosted conformance runs are still
pending, so `manifest.yaml` deliberately leaves `capabilities` empty. Neko's
sync counters are supported through its exact non-negative signed integer range;
the client refuses larger unsigned protocol values instead of wrapping them.
The shared README renderer has no `.hx` syntax mapping yet, so this canonical
example is currently displayed as plain text rather than highlighted Haxe.
