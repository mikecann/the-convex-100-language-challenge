# Convex from Elixir

This demonstration uses Elixir and OTP to query a Convex room, subscribe to it
over Live, mutate it, and prove the reactive value changes from `0` to `1`.

It is educational and unofficial. It is not a production SDK, an officially
sanctioned Convex client, or a package intended for Hex.

## Start here

Read [`examples/basics/main.ex`](examples/basics/main.ex). It is the exact
program Docker runs and the website displays. The comments walk through client
creation, the initial HTTP query, subscribing before the write, idempotent
mutation, and the resulting Live update.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Awaiting shared evidence | Native query, mutation, action, bearer-token lifecycle, logs, and structured errors are implemented. |
| Live | Awaiting shared evidence | Native WebSocket subscriptions, unsubscribe, typed query failures, and reconnect restoration are implemented against the pinned profile. |

The manifest intentionally awards no badges yet. Only the shared local and
hosted black-box controller may turn either row into a passing capability.

## Basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.ex -->
```elixir
defmodule Convex.Example do
  @moduledoc false

  alias Convex.{Client, Subscription}

  def main(arguments \\ System.argv()) do
    deployment_url =
      System.get_env("CONVEX_URL") || raise "CONVEX_URL is required"

    # Create the Convex client using the deployment supplied by the container.
    {:ok, client} = Client.start_link(deployment_url)

    # Always close the OTP processes and network connections before exiting.
    try do
      room = List.first(arguments) || "elixir-example"

      # Query the room over Convex's documented HTTP API to get its current state.
      {:ok, query} = Client.query(client, "demo:state", %{"room" => room})
      state = expect_state("current query", query.value)
      IO.puts("current count: #{state["count"]}")

      # Start Live before changing the room so there is no gap where an update
      # could happen without this process observing it.
      {:ok, subscription} =
        Client.subscribe(client, "demo:state", %{"room" => room})

      try do
        # A Live query first delivers its current value. Check that snapshot
        # agrees with the HTTP query before moving on to the mutation.
        initial = next_update(subscription, "initial Live value")
        expect_count("initial Live value", initial["count"], state["count"])
        print_json("live initial", initial)

        # Increment the room over HTTP. The random run ID is an idempotency key,
        # so retrying this exact write would not increment the room twice.
        {:ok, mutation} =
          Client.mutation(client, "demo:increment", %{
            "room" => room,
            "language" => "elixir",
            "runId" => random_id()
          })

        increment = expect_increment(mutation.value)
        expected_count = state["count"] + 1

        if increment["applied"] != true, do: raise("mutation was not applied")
        expect_count("mutation", increment["state"]["count"], expected_count)
        print_json("mutation", increment)

        # Read the resulting state from Live without issuing another HTTP query.
        updated = next_update(subscription, "updated Live value")
        expect_count("updated Live value", updated["count"], expected_count)
        print_json("live update", updated)

        # Reaching this line proves HTTP query, HTTP mutation, and Live all
        # agreed on the same 0 -> 1 change.
        IO.puts("verified count: #{state["count"]} -> #{updated["count"]}")
      after
        # Stop the server-side reactive query even when a later assertion fails.
        Subscription.close(subscription)
      end
    after
      Client.close(client)
    end
  end

  # Wait for one reactive value, turning a query error or stalled connection
  # into a clear example failure rather than hanging indefinitely.
  defp next_update(subscription, operation) do
    case Subscription.next(subscription, 10_000) do
      {:ok, update} -> expect_state(operation, update.value)
      {:error, :timeout} -> raise "timed out waiting for #{operation}"
      {:error, error} -> raise error
    end
  end

  # Check the small state shape used by the lesson before reading its count.
  # Convex JSON represents these schema numbers as Float64, so normalize whole
  # values such as 0.0 to integers before comparing or printing them.
  defp expect_state(operation, %{"count" => count} = state) do
    Map.put(state, "count", normalize_count!(operation, count))
  end

  defp expect_state(operation, value),
    do: raise("#{operation} returned an unexpected state: #{inspect(value)}")

  # Check the mutation fields used below instead of merely printing any JSON
  # object that happens to come back from the deployment.
  defp expect_increment(%{"applied" => applied, "state" => state} = result)
       when is_boolean(applied),
       do: Map.put(result, "state", expect_state("mutation", state))

  defp expect_increment(value),
    do: raise("mutation returned an unexpected value: #{inspect(value)}")

  # Make every demonstrated count an assertion. Docker can then reject this
  # example if the shared backend returns a value other than the expected one.
  defp expect_count(operation, actual, expected) do
    if actual != expected, do: raise("#{operation} count was #{actual}, expected #{expected}")
  end

  # JSON numbers arrive as floats even though this counter is integral. Accept
  # only finite whole numbers, then turn them into integers so the example's
  # human output and the shared verifier both see exact `0` and `1` values.
  @doc false
  def normalize_count!(_operation, count) when is_integer(count), do: count

  def normalize_count!(operation, count) when is_float(count) do
    normalized =
      try do
        trunc(count)
      rescue
        ArithmeticError -> nil
      end

    if is_integer(normalized) and count == normalized do
      normalized
    else
      raise "#{operation} count must be a finite whole number, got: #{inspect(count)}"
    end
  end

  def normalize_count!(operation, count) do
    raise "#{operation} count must be a finite whole number, got: #{inspect(count)}"
  end

  # Pretty JSON keeps nested Convex values readable in a terminal and provides
  # the exact `"applied": true` evidence line consumed by the shared verifier.
  defp print_json(label, value) do
    IO.puts("#{label}: #{Jason.encode!(value, pretty: true)}")
  end

  # Cryptographic randomness makes the mutation idempotency key unique across
  # concurrent example containers without introducing a third-party ID helper.
  defp random_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```
<!-- END GENERATED EXAMPLE -->

## Verify it in Docker

```sh
./run test elixir
./run verify-example elixir
./run verify elixir
./run verify-hosted elixir
./run verify-all elixir
```

`test` checks formatting, compiles all source and both executables, and runs
language-local unit tests. `verify-example` runs the exact example above against
a unique room. The two conformance commands separately test the approved local
backend and dedicated hosted drift target. `verify-all` runs both from the same
built source.

## Conformance and protocol notes

The public client calls `/api/query`, `/api/mutation`, and `/api/action` using
the documented `format: "json"` HTTP contract. Its OTP Live process implements
the `convex-rs-0.10.4-unversioned-sync` profile pinned at upstream commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7` and endpoint `/api/sync`.

The test-only executable under `client/tests/conformance/` exposes NDJSON
adapter protocol v1 over stdin/stdout or TCP. It includes `debugDisconnect`
only so the shared controller can exercise real reconnection. That hook is not
part of the educational client API.

## Limitations

Live authentication, WebSocket mutations and actions, transition chunks,
mutation replay, optimistic updates, journals, and the non-JSON-safe Convex
value extensions are deliberately outside this demonstration. Realtime is an
internal protocol, so passing evidence for this pinned revision would not make
it a supported third-party SDK contract.

The pinned Gun 2.5.0 dependency currently resolves Cowlib 2.19.0, which Hex
flags for response-header splitting. The example does not create response
headers from untrusted input, but that unresolved advisory is another concrete
reason not to treat this experiment as production-ready software.
