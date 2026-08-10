<img src="logo.png" alt="Elixir logo" width="240">
<!-- Logo source: https://elixir-lang.org/downloads/logos/elixir-dark.svg -->

# Elixir

[Elixir](https://elixir-lang.org/) is a functional language created by José
Valim in 2012. It runs on the Erlang virtual machine, usually called the BEAM,
and shares Erlang's OTP tools for processes, supervision, and fault-tolerant
systems. Today its best-known niche is networked software, including web and
realtime applications, though the official ecosystem also covers embedded
systems, data pipelines, machine learning, and distributed systems.

This is an educational, unofficial demonstration. It is not a production SDK,
an officially sanctioned Convex client, or a package intended for Hex.

## Getting Started

Start with [`examples/basics/main.ex`](examples/basics/main.ex). It queries a
room, opens a Live subscription, performs an idempotent mutation, and observes
the count change from `0` to `1`.

From the repository root, run the exact example in its Docker runtime:

```sh
./run verify-example elixir
```

Docker supplies a unique room and the approved test deployment. The command
compiles and executes the same source shown in the Example section below.

## Interesting Parts

### Success and failure are values you can match

TypeScript normally reports a mutation failure by rejecting its promise. This
Elixir client returns a tagged tuple such as `{:ok, result}` or
`{:error, exception}`, so pattern matching makes the branch visible at the call
site.

**TypeScript with React**

```tsx
import { useMutation } from "convex/react";
import { api } from "../convex/_generated/api";

export function IncrementButton() {
  const increment = useMutation(api.demo.increment);

  async function onClick() {
    const result = await increment({
      room: "readme-elixir",
      language: "typescript",
      runId: crypto.randomUUID(),
    });
    console.log(result.state.count); // The generated API makes this a number.
  }

  return <button onClick={onClick}>Increment</button>;
}
```

**Elixir**

```elixir
alias Convex.Client

deployment_url = System.fetch_env!("CONVEX_URL")
{:ok, client} = Client.start_link(deployment_url)

try do
  args = %{
    "room" => "readme-elixir",
    "language" => "elixir",
    "runId" => :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  }

  case Client.mutation(client, "demo:increment", args) do
    {:ok, result} ->
      %{"state" => %{"count" => count}} = result.value
      IO.inspect(count) # This shape is checked by the match at runtime, not statically typed.

    {:error, error} ->
      raise error
  end
after
  Client.close(client)
end
```

Elixir supports optional typespecs and static analysis, but it is dynamically
typed. This demonstration accepts JSON maps, so its nested match is a runtime
shape check. The TypeScript snippet instead gets generated argument and result
types from `api.demo.increment`.

### A Live query belongs to an Elixir process

React owns the subscription behind `useQuery`, rerenders when its value changes,
and cleans it up with the component. This command-line client gives the calling
Elixir process an explicit subscription instead.

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function RoomCount() {
  const state = useQuery(api.demo.state, { room: "readme-elixir" });

  if (state === undefined) return <p>Loading...</p>;
  return <p>{state.count}</p>; // state.count is type-safe and triggers rerenders.
}
```

**Elixir**

```elixir
alias Convex.{Client, Subscription}

deployment_url = System.fetch_env!("CONVEX_URL")
{:ok, client} = Client.start_link(deployment_url)

try do
  args = %{"room" => "readme-elixir"}
  {:ok, subscription} = Client.subscribe(client, "demo:state", args)

  try do
    # The first message is the current reactive value for this room.
    {:ok, update} = Subscription.next(subscription, 10_000)
    %{"count" => count} = update.value
    IO.inspect(count) # `count` is dynamically checked by the map match above.
  after
    # The CLI owns the lifecycle, so it must unsubscribe explicitly.
    Subscription.close(subscription)
  end
after
  Client.close(client)
end
```

The BEAM provides lightweight processes and asynchronous message passing. The
blocking `Subscription.next/2` wrapper is this client's deliberately small CLI
API, not a limitation of Elixir. A long-running program would call it again, or
receive the underlying messages in its own process, to handle later updates.

## Status

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Verified by shared local and hosted conformance | Native query, mutation, action, bearer-token lifecycle, logs, and structured errors are implemented. |
| Live | Verified by shared local and hosted conformance | Native WebSocket subscriptions, unsubscribe, typed query failures, and reconnect restoration are implemented against the pinned profile. |

The manifest records both earned capabilities. These are results for the pinned
test profile, not a claim that Convex supports this client.

## Example

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
        IO.puts("live initial count: #{initial["count"]}")

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
        IO.puts("mutation applied: #{increment["applied"]}")
        IO.puts("mutation count: #{increment["state"]["count"]}")

        # Read the resulting state from Live without issuing another HTTP query.
        updated = next_update(subscription, "updated Live value")
        expect_count("updated Live value", updated["count"], expected_count)
        IO.puts("live updated count: #{updated["count"]}")

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

  # Cryptographic randomness makes the mutation idempotency key unique across
  # concurrent example containers without introducing a third-party ID helper.
  defp random_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

- `Convex.Client` is a `GenServer`, an OTP process with private state and a
  standard request/reply interface. It serializes HTTP calls, owns the bearer
  token, and starts the Live process when the first subscription needs it.
- Documented HTTP queries, mutations, and actions use Erlang's `:httpc`. Jason
  handles JSON, CAStore supplies the certificate bundle, and HTTPS enables peer
  verification, SNI, and hostname checks.
- `Convex.Live` is a second `GenServer` with exclusive ownership of the Gun
  WebSocket. It tracks active subscriptions, restores them after reconnecting,
  and routes updates to each subscribing process's mailbox.
- The Live implementation targets the internal
  `convex-rs-0.10.4-unversioned-sync` profile at upstream commit
  `6f1df8a8ba1665084ec001e307ca841ca17074d7`, using `/api/sync`. Passing the
  shared tests against that pin does not turn it into a supported public
  protocol.
- The test-only adapter under `client/tests/conformance/` speaks adapter
  protocol v1 over standard input/output or TCP. Its `debugDisconnect` command
  exists only so conformance can prove reconnection and is not public client
  API.
- The Docker build pins Elixir 1.17.3 with Erlang/OTP 26.2.5.15. The final
  runtime keeps the Erlang runtime and required OTP applications but excludes
  Mix, Hex, Rebar, the Elixir compiler commands, and general-purpose network
  utilities.

## Known Issues

1. Live authentication, WebSocket mutations and actions, transition chunks,
   mutation replay, journals, and optimistic updates are not implemented.
2. Live values cover only the JSON-safe subset exercised by the shared suite.
   Convex's additional value encodings are outside this demonstration.
3. Gun 2.5.0 and Cowlib 2.19.0 remain flagged for request/response splitting
   (`GHSA-w4f7-4cxr-rv3c`), and Cowlib's cookie encoder is flagged for header
   injection (`GHSA-g2wm-735q-3f56`). This outbound client does not construct
   responses or call that encoder, but the affected dependency code is still
   present and no patched Hex release is currently available.
