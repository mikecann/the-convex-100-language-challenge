<img src="logo.png" alt="Haxe logo" width="220">
<!-- Logo source: https://haxe.org/img/branding/haxe-logo.png -->

# Haxe

[Haxe](https://haxe.org/) is an open-source, strictly typed language built
around a cross-compiler. Its ECMAScript-influenced syntax is approachable if
you know TypeScript, Java, C#, or ActionScript, but one Haxe codebase can target
JavaScript, C++, JVM bytecode, Python, Lua, PHP, and several other runtimes. The
project began in 2005 under Nicolas Cannasse as a successor to the ActionScript
2 compiler MTASC and the experimental MTypes language.

Haxe's current official site positions it as a cross-platform tool for games,
web apps, mobile and desktop software, command-line tools, and shared APIs. This
demonstration compiles Haxe to Neko bytecode, one of Haxe's own virtual-machine
targets. It is educational and unofficial, not a production SDK or an
officially supported Convex client.

## Getting Started

Start with [`examples/basics/Main.hx`](examples/basics/Main.hx). It queries an
isolated counter, subscribes before changing it, applies one mutation with a
fresh idempotency key, then waits for Live to report the resulting `0 -> 1`
update.

From the repository root, Docker builds the exact checked-in example into its
minimal Neko runtime image and runs it against a unique room:

```sh
./run verify-example haxe
```

That command checks the example's six-line happy-path transcript. The complete
HTTP and Live capability claims below come from the separate shared local and
hosted conformance runs already recorded for this implementation.

## Interesting Parts

### Familiar object literals, dynamic results

React's generated types connect a function, its arguments, and its result. The
handwritten Haxe client accepts an anonymous object but returns `Dynamic` JSON.

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "./convex/_generated/api";
function StateCount({ room }: { room: string }) {
  const state = useQuery(api.demo.state, { room });
  return <span>{state?.count ?? "Loading"}</span>;
}
```

**Haxe**

```haxe
class StateCount {
  public static function openClient():ConvexClient {
    var url = Sys.getEnv("CONVEX_URL");
    if (url == null || url.length == 0)
      throw new haxe.Exception("CONVEX_URL is required");
    return new ConvexClient(url);
  }
  public static function read(client:ConvexClient, room:String):Int {
    var state:Dynamic = client.query("demo:state", {room: room}).value;
    return JsonTools.exactInteger(Reflect.field(state, "count"), "state.count");
  }
}
```

The helper rejects missing and empty URLs. Its caller owns the client and must
close it. `read` is one HTTP request and validates its `Dynamic` count.

### A blocking stream over a background WebSocket

React manages subscription lifetime and rerenders on change. This Haxe client
instead exposes a blocking stream backed by a bounded queue and an owner thread.

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "./convex/_generated/api";
function Counter({ room }: { room: string }) {
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  const addOne = () => increment({ room, language: "TypeScript",
    runId: crypto.randomUUID() });
  return <button onClick={addOne}>Count: {state?.count ?? 0}</button>;
}
```

**Haxe**

```haxe
class LiveCounter {
  public static function increment(client:ConvexClient, room:String):Array<Int> {
    var subscription = client.subscribe("counter", "demo:state", {room: room});
    var failure:Dynamic = null;
    var counts:Array<Int> = [];
    try {
      var initial = subscription.next(10.0);
      if (initial.error != null) throw initial.error;
      counts.push(JsonTools.exactInteger(Reflect.field(initial.value, "count"),
        "initial Live count"));
      client.mutation("demo:increment", {room: room, language: "Haxe",
        runId: ConvexClient.randomId()});
      var updated = subscription.next(10.0);
      if (updated.error != null) throw updated.error;
      counts.push(JsonTools.exactInteger(Reflect.field(updated.value, "count"),
        "updated Live count"));
    } catch (error:Dynamic) {
      failure = error;
    }
    try subscription.close() catch (closeError:Dynamic) {
      if (failure == null) failure = closeError;
    }
    if (failure != null) throw failure;
    return counts;
  }
}
```

Blocking `next` is an API choice, not a Haxe limitation. The helper owns its
subscription and preserves the first failure through cleanup; its caller owns
the client. Closing or replacing a handle invalidates its old generation.

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions | Verified by shared local and hosted conformance |
| Bearer authentication and structured function errors over HTTP | Verified by shared local and hosted conformance |
| Live initial values, external updates, and query-error recovery | Verified by shared local and hosted conformance |
| Unsubscribe, replacement barriers, and five real reconnects | Verified by shared local and hosted conformance |
| Live authentication, WebSocket mutations and actions, transition chunks | Not implemented |

The shared evaluator awarded both `http` and `live` to the reviewed Haxe
source. These are existing evidence-backed results; this README update does not
claim a fresh verification run.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/Main.hx -->
```haxe
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

## Implementation Notes

This is a native Haxe implementation compiled with Haxe 4.2.5 to Neko 2.3.0
bytecode. Neko provides the VM and ordinary sockets, TLS, threads, JSON, and
filesystem access. The Convex HTTP envelopes, Live state machine, WebSocket
framing, reconnect behavior, and test adapter are implemented in Haxe rather
than delegated to another Convex SDK.

The choice of Neko shapes several details. JSON arrives as `Dynamic`, Neko
strings need explicit strict UTF-8 validation for WebSocket text, and its
target `Int` cannot represent every unsigned sync counter. Haxe also lacks
`finally`, so the canonical example captures an error, performs both cleanup
steps, then rethrows it.

For Live queries, one owner thread has exclusive control of the WebSocket and
query set. Public subscription handles send commands to that owner instead of
reading or writing the socket themselves. This makes unsubscribe and same-ID
replacement deterministic, and it lets reconnects restore active queries while
suppressing an unchanged initial value.

Memory and time are deliberately bounded. The client retains at most 64 active
subscriptions, queues at most 16 Live updates within a 24 MiB accounting
budget, caps a server message at 4 MiB, and abandons a connection that stalls
after a frame has begun. The adapter has a separate bounded output queue so a
stopped controller cannot make the process grow indefinitely.

The minimal `linux/amd64` images contain the Neko VM and its runtime library
closure, CA certificates, `/bin/sh`, and only the POSIX tools required by the
shared verifier. They run as `65532:65532` and do not contain Haxe, Haxelib, a
compiler frontend, package manager, network utility, or delegated runtime.

## Known Issues

1. Live authentication, optimistic updates, WebSocket mutations and actions,
   and `TransitionChunk` assembly are deferred.
2. Function values use the JSON-safe subset exercised by this project and
   remain `Dynamic`; there is no generated Haxe API layer that turns Convex
   validators into compile-time result types.
3. There is no server-inactivity watchdog. A completely silent peer is noticed
   only when a later read or write fails.
4. Under delivery pressure, the bounded Live queue drops the globally oldest
   state so a slow consumer can catch up to newer values. An individual
   oversized update becomes a structured failure instead of being retained.
5. Sync counters are limited to Neko's exact non-negative signed integer range.
   Larger unsigned protocol values are rejected rather than wrapped.
