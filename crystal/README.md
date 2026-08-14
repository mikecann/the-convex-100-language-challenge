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

### Ruby's `case`, TypeScript's narrowing

Crystal's founding pitch at Manas Tech fits on a sticker: Ruby's syntax, C's speed. The static half shows up the moment a Convex value crosses the wire — `JSON::Any#raw` returns a union type, and a plain Ruby-looking `case` narrows it branch by branch, much the way TypeScript narrows with `typeof`, except here it compiles to a native binary.

```crystal
# Convex numbers travel as JSON, so a counter may arrive as Int64 or Float64.
def whole_count(value : JSON::Any, operation : String) : Int64
  case number = value.raw
  when Int64
    number                     # the compiler knows number : Int64 here
  when Float64                 # ...and number : Float64 here (range checks elided)
    integer = number.to_i64
    raise "#{operation} count was fractional" unless number == integer
    integer
  else
    raise "#{operation} count was not numeric"
  end
end
```

No casts and no annotations inside the branches — flow typing does it all.

### `select` races the Live channel against the clock

Crystal's concurrency is CSP, the model Go made famous: lightweight fibers talking over typed channels. This client spawns one owner fiber for the whole Live WebSocket, and each subscription is a bounded `Channel(Update)` that fiber feeds. Waiting for the next reactive value is a `select` — and even the timeout reads like Ruby, because `10.seconds` is a method call returning a typed `Time::Span`.

```crystal
subscription = client.subscribe("demo:state", {"room" => JSON::Any.new("readme-live")})
# TypeScript: const state = useQuery(api.demo.state, { room: "readme-live" })
update = subscription.next(10.seconds)

# Inside next, delivery is a race between the channel and the clock:
select
when value = @queue.receive
  value
when timeout(10.seconds)
  raise TransportError.new("timed out waiting for Live update", "live")
end
```

Where React resubscribes on render and cleans up on unmount, here `subscription.close` is the unmount — explicit, but one line.

### The whole demo sits inside a compile-time `if`

Those `{% %}` fences in the example below are macros: Crystal code that runs while the compiler does, operating on the program itself. The basics example wraps its entire networked body in one, so building with `-Dexample_count_test` compiles the network program out and leaves only `whole_count` for the unit test. It is `#ifdef`, reborn inside a language that looks like Ruby.

```crystal
{% unless flag?(:example_count_test) %}
  room = ARGV[0]? || "crystal-example"   # [0]? returns nil instead of raising
  client = Convex::Client.new(ENV.fetch("CONVEX_URL"), ENV["CONVEX_AUTH_TOKEN"]?)
  current = client.query("demo:state", {"room" => JSON::Any.new(room)})
  # ... subscribe, mutate, verify — all inside the compile-time block ...
{% end %}
```

One binary carries the demo; the test binary never even links it.

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
