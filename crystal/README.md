# Convex from Crystal

This educational, unofficial demonstration uses Crystal to query and mutate a Convex room over HTTP, then follow the same room through Convex Live. It is not a production SDK.

## Start here

Read the [canonical basic example](examples/basics/main.cr). It performs an HTTP query, starts Live before the mutation, applies an idempotent increment, and checks the resulting `0 -> 1` update.

## What works

| Capability | Status |
| --- | --- |
| Native HTTP query, mutation, action | Source implementation present; shared verification pending |
| Native Live query and reconnect | Source implementation present; shared verification pending |
| Authentication | HTTP bearer token; Live auth deferred |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.cr -->
```text
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

## Docker verification

```sh
./run test crystal
./run verify-example crystal
./run verify crystal
./run verify-hosted crystal
```

The first command formats, compiles, and runs deterministic HTTP/Live, reconnect, frame, relay, and envelope fixtures inside Docker. The remaining commands execute the exact minimal example and adapter against the approved deployments.

## Protocol notes

The adapter speaks NDJSON protocol v1 over stdin/stdout or `ADAPTER_LISTEN`. One Crystal owner fiber creates, reads, writes, retires, reconnects, and replays the Live socket. It counts bytes returned by both raw TCP and OpenSSL-buffered reads, treats a timeout with no frame bytes as idleness, and abandons the connection after a partial-frame deadline. Subscription delivery is bounded by 16 events and 3 MiB each, with a 128-event and 16 MiB aggregate owner budget that includes structured errors, logs, and conservative envelope overhead. The adapter writes directly under one mutex instead of filling another mailbox. It caps the adapter at 16 active subscriptions and one 3 MiB line per relay plus one controller response, a conservative 17-event/51 MiB output ceiling. The final probe runs a stopped-reader case in a separate process and cgroup, with both process RSS and cgroup memory required to stay below a 96 MiB safety gate inside the shared 128 MiB limit.

## Limitations

TransitionChunk assembly, Live authentication, WebSocket mutations, optimistic updates, and the complete Convex value surface remain deferred. Shared local and hosted conformance remain root-owned, so capability badges stay empty until that evidence passes.
