<img src="logo.png" alt="Crystal logo" width="260">
<!-- Logo source: https://crystal-lang.org/media/crystal-media-kit-6e57ec7.zip -->

# Crystal

[Crystal](https://crystal-lang.org/) is a general-purpose, object-oriented language with Ruby-inspired syntax, static type checking, type inference, and native compilation. The project [reached 1.0 in 2021](https://crystal-lang.org/2021/03/22/crystal-1.0-what-to-expect/). Today it has a specialist niche, with the official project documenting [production use](https://crystal-lang.org/used_in_prod/) across web services, messaging, security, bioinformatics, and other systems.

This repository uses Crystal to query and mutate a Convex room over HTTP, then watch that room through Convex Live. It is an educational, unofficial demonstration, not a production SDK or an officially supported Convex client.

## Getting Started

Start with the [canonical basic example](examples/basics/main.cr). It reads a room, subscribes before changing it, sends an idempotent increment, and confirms the Live value moves from `0` to `1`.

From the repository root, run the example in its pinned Docker environment:

```sh
./run verify-example crystal
```

That command builds the minimal example image and runs this exact source against the approved test deployment. You do not need Crystal installed on your machine.

## Interesting Parts

### Familiar syntax, explicit JSON at the network boundary

With Convex React, generated API bindings carry the argument and return types into TypeScript. This Crystal client deliberately stays small and accepts function names as strings, so values crossing the network are `JSON::Any` and the caller narrows them explicitly.

**TypeScript with React**

```tsx
import { useMutation } from "convex/react";
import { api } from "../convex/_generated/api";

function IncrementButton() {
  const increment = useMutation(api.demo.increment);

  async function handleClick() {
    const result = await increment({
      room: "readme-mutation",
      language: "typescript",
      runId: crypto.randomUUID(), // Retrying this ID will not increment twice.
    });
    console.log(result.applied); // The generated API makes this a boolean.
  }

  return <button onClick={handleClick}>Increment</button>;
}
```

**Crystal**

```crystal
require "json"
require "./client/client"

client = Convex::Client.new(ENV.fetch("CONVEX_URL"))
begin
  # Crystal infers the hash type, while JSON::Any marks values crossing the wire.
  args = {
    "room"     => JSON::Any.new("readme-mutation"),
    "language" => JSON::Any.new("crystal"),
    "runId"    => JSON::Any.new(Random::Secure.hex(8)),
  }
  result = client.mutation("demo:increment", args)
  puts result.value["applied"].as_bool # Check the dynamic JSON value as a Bool.
ensure
  client.close
end
```

Both snippets call the same mutation with the same three arguments. The React call is asynchronous and generated types describe its result. This Crystal API blocks until the HTTP response arrives and checks the returned JSON shape at runtime.

### React owns subscriptions; this command-line client owns one directly

`useQuery` subscribes when a component renders, rerenders it when the value changes, and cleans up when the component unmounts. The Crystal client exposes a `Subscription` with a blocking `next` method instead. That is a deliberate API choice for a small command-line demonstration, not a limitation of Crystal. Underneath, the client uses Crystal fibers and channels to keep Live work concurrent.

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

function RoomCount() {
  const state = useQuery(api.demo.state, { room: "readme-live" });

  if (state === undefined) return <span>Loading...</span>;
  return <span>{state.count}</span>; // React rerenders when this count changes.
}
```

**Crystal**

```crystal
require "json"
require "./client/client"

client = Convex::Client.new(ENV.fetch("CONVEX_URL"))
begin
  args = {"room" => JSON::Any.new("readme-live")}
  subscription = client.subscribe("demo:state", args)
  begin
    # next waits for the first Live value or raises after the timeout.
    initial = subscription.next(10.seconds)
    raise initial.error.not_nil! if initial.error
    puts initial.value.not_nil!["count"].to_json

    # After another client increments the room, next waits for that new value.
    changed = subscription.next(10.seconds)
    raise changed.error.not_nil! if changed.error
    puts changed.value.not_nil!["count"].to_json
  ensure
    subscription.close # Explicit cleanup replaces React's unmount lifecycle.
  end
ensure
  client.close
end
```

The focused Crystal fragment only shows delivery and cleanup. The complete example below starts Live before its mutation and validates the returned numbers carefully, including Convex numbers encoded as `0.0` or `1.0`.

## Status

| Capability | Status |
| --- | --- |
| Native HTTP query, mutation, and action | Verified by shared local and hosted conformance at this exact head |
| Native Live query and reconnect | Verified by shared local and hosted conformance at this exact head |
| Authentication | HTTP bearer token works; Live authentication is deferred |

The manifest records both `http` and `live` as earned capabilities. This README update does not rerun or change that evidence.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.cr -->
```crystal
require "json"
require "../../client/client"

def whole_count(value : JSON::Any, operation : String) : Int64
  case number = value.raw
  when Int64
    number
  when Float64
    raise "#{operation} count was not finite" unless number.finite?
    # Reject the rounded Float64 boundary before converting to Int64. The
    # conversion must never turn an overflowing Convex number into a value
    # that happens to look like a valid counter.
    raise "#{operation} count was out of range" if number < Int64::MIN.to_f || number >= Int64::MAX.to_f
    integer = number.to_i64
    raise "#{operation} count was fractional" unless number == integer
    integer
  else
    raise "#{operation} count was not numeric"
  end
end

{% unless flag?(:example_count_test) %}
  url = ENV.fetch("CONVEX_URL")
  room = ARGV[0]? || "crystal-example"
  client = Convex::Client.new(url, ENV["CONVEX_AUTH_TOKEN"]?)
  begin
    # Read the room over HTTP before opening Live. This gives the example a
    # concrete value to compare with the initial reactive snapshot.
    current = client.query("demo:state", {"room" => JSON::Any.new(room)})
    current_count = whole_count(current.value["count"], "current query")
    puts "current count: #{current_count}"
    # Subscribe before mutating so the next update proves the Live stream saw
    # the mutation instead of the example merely polling HTTP again.
    subscription = client.subscribe("demo:state", {"room" => JSON::Any.new(room)})
    begin
      initial = subscription.next(10.seconds)
      raise initial.error.not_nil! if initial.error
      initial_count = whole_count(initial.value.not_nil!["count"], "initial Live value")
      raise "initial Live count mismatch" unless initial_count == current_count
      puts "live initial count: #{initial_count}"
      # runId is the idempotency key for this logical increment. Retrying the
      # same mutation does not apply the increment twice on the demo backend.
      mutation = client.mutation("demo:increment", {"room" => JSON::Any.new(room), "language" => JSON::Any.new("crystal"), "runId" => JSON::Any.new(Random::Secure.hex(8))})
      raise "mutation was not applied" unless mutation.value["applied"].as_bool
      puts "mutation applied: true"
      expected = current_count + 1
      mutation_count = whole_count(mutation.value["state"]["count"], "mutation")
      raise "mutation count mismatch" unless mutation_count == expected
      puts "mutation count: #{mutation_count}"
      # Consume the Live update caused by the mutation and compare it with the
      # mutation response before printing the final verification line.
      changed = subscription.next(10.seconds)
      raise changed.error.not_nil! if changed.error
      changed_count = whole_count(changed.value.not_nil!["count"], "updated Live value")
      raise "updated Live count mismatch" unless changed_count == expected
      puts "live updated count: #{changed_count}"
      puts "verified count: #{current_count} -> #{changed_count}"
    ensure
      subscription.close
    end
  ensure
    client.close
  end
{% end %}
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

- This is a native Crystal implementation. It uses Crystal's standard HTTP, JSON, WebSocket, TLS, channel, and fiber support, and does not delegate Convex work to another SDK or runtime.
- The repository pins Crystal 1.14.1 and builds static `linux/amd64` executables. The minimal runtime keeps the TLS certificate and OpenSSL configuration that hosted connections need, but contains no Crystal compiler or package manager.
- HTTP calls stream at most 2 MiB before decoding the Convex response. Non-successful HTTP status codes, malformed protocol responses, and Convex function errors remain distinct failures.
- One owner fiber controls the Live socket, including reconnects and active query replay. Each public subscription receives updates through a bounded channel. A slow consumer keeps the newest useful state without allowing queued data to grow forever.
- The Live parser handles fragmented UTF-8 and control frames. Fixed connect, frame, and write deadlines keep `close` and `unsubscribe` bounded when a peer stalls.
- The test-only conformance adapter translates the shared command stream into calls on this real client. It is not part of the educational client API.

For a deeper look, read the [client implementation](client/client.cr) and the deterministic [Live tests](client/tests/live_test.cr). Crystal's official documentation also explains its [fiber and channel concurrency model](https://crystal-lang.org/reference/latest/guides/concurrency.html) and the runtime checks provided by [`JSON::Any`](https://crystal-lang.org/api/latest/JSON/Any.html).

## Known Issues

1. Live authentication and `TransitionChunk` assembly are not implemented.
2. Convex values are limited to Crystal's JSON types, so the complete Convex value model is not available.
3. Mutations use HTTP. WebSocket mutations, optimistic updates, and mutation replay are deferred.
