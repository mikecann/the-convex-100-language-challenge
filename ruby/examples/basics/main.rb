#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "securerandom"

$LOAD_PATH.unshift(ENV.fetch("CONVEX_CLIENT_PATH", File.expand_path("../../client", __dir__)))
require "convex"

deployment_url = ENV.fetch("CONVEX_URL")

# Create a Convex client connected to the deployment from the environment.
client = Convex::Client.new(deployment_url)

# The verifier passes a unique room so repeated and concurrent runs stay apart.
room = ARGV.fetch(0, "ruby-example")

begin
  # Run a Convex query over HTTP to get the room's current state.
  current = client.query("demo:state", "room" => room)
  state = current.value

  # Fail on an unexpected shape instead of printing misleading success output.
  raise "current query did not return a numeric count" unless state["count"].is_a?(Numeric)

  puts "current count: #{state.fetch("count")}"

  # Begin listening to the same query before making a change, which means Live
  # cannot miss the mutation between the initial query and subscription setup.
  subscription = client.subscribe("demo:state", "room" => room)
  begin
    # A subscription first sends its current value. Confirm it agrees with the
    # HTTP query before the example changes anything.
    initial_update = subscription.next_update(timeout: 10)
    raise initial_update.error if initial_update.error

    initial_state = initial_update.value
    unless initial_state["count"] == state["count"]
      raise "initial Live count was #{initial_state["count"]}, expected #{state["count"]}"
    end
    puts "live initial: #{JSON.pretty_generate(initial_state)}"

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

    expected_count = state["count"] + 1
    unless increment.dig("state", "count") == expected_count
      raise "mutation count was #{increment.dig("state", "count")}, expected #{expected_count}"
    end
    puts "mutation: #{JSON.pretty_generate(increment)}"

    # Receive the changed room through Live, without issuing another HTTP query.
    changed_update = subscription.next_update(timeout: 10)
    raise changed_update.error if changed_update.error

    changed_state = changed_update.value
    unless changed_state["count"] == expected_count
      raise "updated Live count was #{changed_state["count"]}, expected #{expected_count}"
    end
    puts "live update: #{JSON.pretty_generate(changed_state)}"

    # Reaching this line proves HTTP query, HTTP mutation, and Live all agreed
    # on one 0 -> 1 state change.
    puts "verified count: #{state["count"]} -> #{changed_state["count"]}"
  ensure
    # Stop listening even when a later example assertion fails.
    subscription.close
  end
ensure
  # Close the client's network worker whenever the example exits.
  client.close
end
