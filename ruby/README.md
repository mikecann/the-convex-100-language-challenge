<img src="logo.png" alt="Ruby logo" width="96">
<!-- Logo source: https://www.ruby-lang.org/images/header-ruby-logo.png -->

# Ruby

[Ruby](https://www.ruby-lang.org/en/) is a dynamic, object-oriented programming
language created by Yukihiro "Matz" Matsumoto and publicly released in 1995. It
mixes ideas from Smalltalk, Perl, Lisp, Eiffel, and Ada, and today is especially
well known for scripting, developer tooling, and web applications built with
Ruby on Rails.

This repository uses Ruby to call Convex over HTTP and listen to reactive
queries over WebSockets. It is an educational, unofficial demonstration, not a
production SDK, an officially sanctioned Convex client, or a gem for
publication.

## Getting Started

Start with [`examples/basics/main.rb`](examples/basics/main.rb). It queries a
fresh counter, subscribes before changing it, performs one idempotent mutation,
and confirms that Live observes the same `0 -> 1` journey.

From the repository root, run the exact example in its minimal Docker image:

```sh
./run verify-example ruby
```

Docker supplies the pinned Ruby runtime and test deployment configuration, so
you do not need to install Ruby or this client on the host.

## Interesting Parts

### A `Result` is just a frozen `Data.define` record

Ruby 3.2 added `Data.define`, a lighter cousin of `Struct` for plain
immutable value objects: one call gives you a class with keyword-or-positional
construction, `==`, and no setters. This client reaches for it the moment an
HTTP response is decoded, so a Convex value and its server logs travel
together as one small, un-mutatable object instead of a loose two-element
array or an ad-hoc hash.

```ruby
# Keeps the decoded value and server log lines together, immutably.
Result = Data.define(:value, :logs)

# Later, once the HTTP response body has been parsed as JSON:
Result.new(decoded["value"], Array(decoded["logLines"]))
# TypeScript: no equivalent record type - useQuery just returns state | undefined
```

### Guard clauses read right to left, like sentences

Ruby lets almost any statement carry a trailing `if` or `unless`, and a method
body can `rescue` without an explicit `begin`. The client's argument validator
leans on both, so the failure conditions read as plain-English preconditions
stacked above the happy path rather than a nested pyramid of `if` blocks.

```ruby
def validate_function(path, args)
  raise ArgumentError, "Convex function path is required" if path.to_s.empty?
  raise ArgumentError, "Convex arguments must be a named JSON object" unless args.is_a?(Hash)

  JSON.generate(args)
rescue JSON::GeneratorError => error
  raise ArgumentError, "encode Convex arguments: #{error.message}"
end
# TypeScript: the generated api.demo.state type rules this out before it runs
```

### Live subscriptions are pulled, one `next_update` at a time

React's `useQuery` re-renders a component whenever a subscription changes;
there is no component tree here to do that for you. So `Subscription` instead
hands back a blocking `next_update`, backed by a `Mutex` and
`ConditionVariable`, that a script calls whenever it is ready for the next
reactive value - turning push-based Live updates into an ordinary,
step-by-step Ruby control flow.

```ruby
subscription = client.subscribe("demo:state", "room" => room)
begin
  update = subscription.next_update(timeout: 10)
  raise update.error if update.error
  puts "count: #{update.value.fetch("count")}"
  # TypeScript: useQuery(api.demo.state, { room }) would re-render instead
ensure
  subscription.close
end
```

## Status

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Verified by shared local and hosted conformance | Native `Net::HTTP` query, mutation, action, bearer-token lifecycle, logs, and structured errors are implemented. |
| Live | Verified by shared local and hosted conformance | Native Ruby WebSocket subscriptions, unsubscribe, reconnect, reactive errors, and clean close target the pinned profile. |

The shared local and hosted black-box tests passed, earning HTTP and Live. A
successful Docker build by itself would not have counted.

## Example

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

## Implementation Notes

The public client is deliberately small and uses Ruby's standard library. HTTP
calls go through `Net::HTTP`; JSON values use `JSON`; TLS comes from `OpenSSL`;
and the WebSocket transport is implemented with `Socket`. There is no delegated
JavaScript client, Convex CLI, or third-party WebSocket gem. Successful HTTP
calls return a `Convex::Result` containing the decoded value and server logs,
while function, protocol, transport, and closed-client failures have distinct
exception classes.

Live uses one worker thread to own the WebSocket, reconnects, and active query
set. Callers send it commands through a thread-safe queue, then each
`Convex::Subscription` exposes `next_update`. A slow consumer can buffer at most
16 updates; when full, the subscription drops the oldest value and retains the
newest reactive state. Closing a subscription clears buffered updates so a
stale value cannot arrive after unsubscribe completes.

Ruby's JSON decoder may represent a Convex whole number as `0.0` or `1.0`. The
canonical example therefore accepts mathematically integral, finite values and
normalizes them to an `Integer`, while rejecting fractional or non-finite
numbers. The final image pins Ruby 3.4.5 and keeps the interpreter and required
standard libraries, but removes RubyGems and development commands.

The test-only adapter under `client/tests/conformance/` speaks adapter protocol
v1 and calls this real client for every operation. Live targets the pinned
`convex-rs-0.10.4-unversioned-sync` profile at commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7`. Because `/api/sync` is an internal
protocol, hosted compatibility must be tested rather than assumed.

## Known Issues

1. Live authentication is not implemented. Bearer tokens apply only to later
   HTTP requests.
2. Live values cover the JSON-safe subset used by this experiment, not lossless
   Convex Int64 values, bytes, special floats, or negative zero.
3. Mutations and actions use the documented HTTP API. WebSocket mutation replay,
   journals, optimistic updates, and read-your-own-write timestamps are outside
   this demonstration.
4. `TransitionChunk` assembly is not implemented. Receiving one is treated as
   protocol drift and reconnects the client.
