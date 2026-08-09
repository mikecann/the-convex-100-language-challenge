# Convex from Ruby

This demonstration uses ordinary Ruby to query and mutate a Convex deployment
over its documented HTTP API, then listens to the same query over a native Ruby
WebSocket implementation.

It is an educational, unofficial experiment. It is not a production SDK, an
officially sanctioned Convex client, or a gem intended for publication.

## Start here

[`examples/basics/main.rb`](examples/basics/main.rb) is the canonical example.
It reads a new counter room over HTTP, subscribes before changing the room,
applies one idempotent mutation, and proves Live observed the same `0 -> 1`
journey. The source below is generated directly from that runnable file.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Verified by shared local and hosted conformance | Native `Net::HTTP` query, mutation, action, bearer-token lifecycle, logs, and structured errors are implemented. |
| Live | Verified by shared local and hosted conformance | Native Ruby WebSocket subscriptions, unsubscribe, reconnect, reactive errors, and clean close target the pinned profile. |

The shared local and hosted black-box tests passed, earning HTTP and Live. A
successful Docker build by itself would not have counted.

## The basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.rb -->
```ruby
#!/usr/local/bin/ruby
# frozen_string_literal: true

require "json"
require "securerandom"

$LOAD_PATH.unshift(ENV.fetch("CONVEX_CLIENT_PATH", File.expand_path("../../client", __dir__)))
require "convex"

# Convex's exported JSON may decode a whole number as a Ruby Float such as 0.0.
# Validate the value before converting it so the verifier gets stable `0 -> 1`
# output without hiding a fractional, infinite, or otherwise invalid count.
def verified_whole_count(value, operation)
  unless value.is_a?(Numeric) && value.finite? && value == value.to_i
    raise "#{operation} count was #{value.inspect}, expected a finite whole number"
  end

  value.to_i
end

def run_example
  deployment_url = ENV.fetch("CONVEX_URL")

  # Create a Convex client connected to the deployment from the environment.
  client = Convex::Client.new(deployment_url)

  # The verifier passes a unique room so repeated and concurrent runs stay apart.
  room = ARGV.fetch(0, "ruby-example")

  begin
    # Run a Convex query over HTTP to get the room's current state.
    current = client.query("demo:state", "room" => room)
    state = current.value

    # Validate and normalize the JSON number before printing machine-checked output.
    current_count = verified_whole_count(state["count"], "current query")
    puts "current count: #{current_count}"

    # Begin listening to the same query before making a change, which means Live
    # cannot miss the mutation between the initial query and subscription setup.
    subscription = client.subscribe("demo:state", "room" => room)
    begin
      # A subscription first sends its current value. Confirm it agrees with the
      # HTTP query before the example changes anything.
      initial_update = subscription.next_update(timeout: 10)
      raise initial_update.error if initial_update.error

      initial_state = initial_update.value
      initial_count = verified_whole_count(initial_state["count"], "initial Live value")
      unless initial_count == current_count
        raise "initial Live count was #{initial_count}, expected #{current_count}"
      end
      puts "live initial count: #{initial_count}"

      # Run an HTTP mutation. The random runId is its idempotency key, so retrying
      # the same logical write would return the existing result instead of adding
      # to the counter twice.
      mutation = client.mutation(
        "demo:increment",
        "room" => room,
        "language" => "ruby",
        "runId" => SecureRandom.hex(8)
      )
      increment = mutation.value
      raise "mutation was not applied" unless increment["applied"] == true
      puts "mutation applied: #{increment["applied"]}"

      expected_count = current_count + 1
      mutation_count = verified_whole_count(increment.dig("state", "count"), "mutation")
      unless mutation_count == expected_count
        raise "mutation count was #{mutation_count}, expected #{expected_count}"
      end
      puts "mutation count: #{mutation_count}"

      # Receive the changed room through Live, without issuing another HTTP query.
      changed_update = subscription.next_update(timeout: 10)
      raise changed_update.error if changed_update.error

      changed_state = changed_update.value
      changed_count = verified_whole_count(changed_state["count"], "updated Live value")
      unless changed_count == expected_count
        raise "updated Live count was #{changed_count}, expected #{expected_count}"
      end
      puts "live updated count: #{changed_count}"

      # Reaching this line proves HTTP query, HTTP mutation, and Live all agreed
      # on one 0 -> 1 state change.
      puts "verified count: #{current_count} -> #{changed_count}"
    ensure
      # Stop listening even when a later example assertion fails.
      subscription.close
    end
  ensure
    # Close the client's network worker whenever the example exits.
    client.close
  end
end

run_example if $PROGRAM_NAME == __FILE__
```
<!-- END GENERATED EXAMPLE -->

## Verify it in Docker

From the repository root:

```sh
./run test ruby
./run verify-example ruby
./run verify ruby
./run verify-hosted ruby
./run verify-all ruby
```

`test` runs syntax checks and language-local tests inside Docker.
`verify-example` executes the exact source shown above and rejects anything
other than the expected `0 -> 1` result. `verify` and `verify-hosted` add the
shared HTTP and Live conformance suites against the approved local and hosted
deployments. `verify-all` runs both deployment profiles from the same source.

## Conformance and protocol notes

The test-only adapter lives under `client/tests/conformance/`. It speaks NDJSON
adapter protocol v1 over stdin/stdout or TCP and calls the real Ruby client for
every operation. `debugDisconnect` exists only there so the controller can
prove five genuine reconnects.

HTTP uses Convex's documented `format: "json"` endpoints. Live pins
`convex-rs-0.10.4-unversioned-sync` at upstream commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7` and `/api/sync`. Realtime is an
internal protocol, so hosted compatibility can drift and must be tested rather
than assumed.

## Limitations

- Live authentication is not implemented.
- Live values cover this experiment's JSON-safe subset, not lossless Convex
  Int64, bytes, special floats, or negative zero.
- Mutations and actions use the documented HTTP API. WebSocket mutation replay,
  journals, optimistic updates, and read-your-own-write timestamps are outside
  this demonstration.
- `TransitionChunk` assembly is not implemented. Receiving one is treated as
  protocol drift and reconnects the client.
