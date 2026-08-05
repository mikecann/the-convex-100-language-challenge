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
