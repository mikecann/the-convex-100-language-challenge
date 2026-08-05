defmodule Convex.Conformance.Adapter do
  @moduledoc false

  alias Convex.{Client, FunctionError, ProtocolError, Subscription, TransportError}

  @protocol_version 1

  def main do
    {:ok, transport} = open_transport()
    writer = spawn_link(fn -> writer_loop(transport) end)

    try do
      loop(transport, writer, %{client: nil, subscriptions: %{}})
    after
      close_transport(transport)
    end
  end

  defp loop(transport, writer, state) do
    case read_line(transport) do
      {:ok, line} ->
        case Jason.decode(line) do
          {:ok, command} ->
            case handle_command(command, writer, state) do
              {:continue, next_state} -> loop(transport, writer, next_state)
              :stop -> :ok
            end

          {:error, error} ->
            emit_error(writer, nil, nil, %ProtocolError{
              message: "decode command: #{Exception.message(error)}"
            })

            loop(transport, writer, state)
        end

      :eof ->
        close_state(state)

      {:error, reason} ->
        IO.puts(:stderr, "read adapter command: #{inspect(reason)}")
        close_state(state)
    end
  end

  defp handle_command(%{"op" => "hello"} = command, writer, state) do
    if command["protocolVersion"] == @protocol_version do
      emit(writer, %{
        "protocolVersion" => @protocol_version,
        "id" => command["id"],
        "type" => "ready",
        "language" => "elixir",
        "implementation" => "native-elixir-otp",
        "runtime" => "Elixir #{System.version()} / OTP #{System.otp_release()}"
      })
    else
      emit_error(
        writer,
        command["id"],
        nil,
        %ProtocolError{
          message: "unsupported adapter protocol version #{inspect(command["protocolVersion"])}"
        }
      )
    end

    {:continue, state}
  end

  defp handle_command(%{"op" => operation} = command, writer, state)
       when operation in ["query", "mutation", "action"] do
    with {:ok, client, state} <- ensure_client(state),
         {:ok, result} <-
           apply(Client, String.to_existing_atom(operation), [
             client,
             command["path"],
             command["args"] || %{}
           ]) do
      emit(writer, %{
        "id" => command["id"],
        "type" => "result",
        "value" => result.value,
        "logs" => result.logs
      })

      {:continue, state}
    else
      {:error, error, state} ->
        emit_error(writer, command["id"], nil, error)
        {:continue, state}

      {:error, error} ->
        emit_error(writer, command["id"], nil, error)
        {:continue, state}
    end
  end

  defp handle_command(%{"op" => "setAuth"} = command, writer, state) do
    with {:ok, client, state} <- ensure_client(state),
         :ok <- Client.set_auth(client, command["token"] || "") do
      emit(writer, %{"id" => command["id"], "type" => "ack"})
      {:continue, state}
    else
      {:error, error, state} ->
        emit_error(writer, command["id"], nil, error)
        {:continue, state}

      {:error, error} ->
        emit_error(writer, command["id"], nil, error)
        {:continue, state}
    end
  end

  defp handle_command(%{"op" => "subscribe"} = command, writer, state) do
    subscription_id = command["subscriptionId"]

    if !is_binary(subscription_id) or subscription_id == "" do
      emit_error(writer, command["id"], nil, %ArgumentError{message: "subscriptionId is required"})

      {:continue, state}
    else
      with {:ok, client, state} <- ensure_client(state) do
        forwarder = spawn_link(fn -> wait_for_subscription(writer, subscription_id) end)

        case Client.subscribe(client, command["path"], command["args"] || %{}, owner: forwarder) do
          {:ok, subscription} ->
            if previous = state.subscriptions[subscription_id], do: close_subscription(previous)
            send(forwarder, {:subscription, subscription})
            emit(writer, %{"id" => command["id"], "type" => "ack"})

            {:continue,
             %{
               state
               | subscriptions:
                   Map.put(state.subscriptions, subscription_id, {subscription, forwarder})
             }}

          {:error, error} ->
            Process.exit(forwarder, :normal)
            emit_error(writer, command["id"], nil, error)
            {:continue, state}
        end
      else
        {:error, error, state} ->
          emit_error(writer, command["id"], nil, error)
          {:continue, state}
      end
    end
  end

  defp handle_command(%{"op" => "unsubscribe"} = command, writer, state) do
    {subscription, subscriptions} = Map.pop(state.subscriptions, command["subscriptionId"])
    if subscription, do: close_subscription(subscription)
    emit(writer, %{"id" => command["id"], "type" => "ack"})
    {:continue, %{state | subscriptions: subscriptions}}
  end

  defp handle_command(%{"op" => "debugDisconnect"} = command, writer, state) do
    with {:ok, client, state} <- ensure_client(state),
         :ok <- Client.debug_disconnect(client) do
      emit(writer, %{"id" => command["id"], "type" => "ack"})
      {:continue, state}
    else
      {:error, error, state} ->
        emit_error(writer, command["id"], nil, error)
        {:continue, state}

      {:error, error} ->
        emit_error(writer, command["id"], nil, error)
        {:continue, state}
    end
  end

  defp handle_command(%{"op" => "close"} = command, writer, state) do
    close_state(state)
    emit(writer, %{"id" => command["id"], "type" => "closed"})
    :stop
  end

  defp handle_command(command, writer, state) do
    emit_error(
      writer,
      command["id"],
      nil,
      %ProtocolError{message: "unknown operation #{inspect(command["op"])}"}
    )

    {:continue, state}
  end

  defp ensure_client(%{client: client} = state) when is_pid(client), do: {:ok, client, state}

  defp ensure_client(state) do
    case System.get_env("CONVEX_URL") do
      nil ->
        {:error, %ArgumentError{message: "CONVEX_URL is required"}, state}

      deployment_url ->
        options =
          case System.get_env("CONVEX_AUTH_TOKEN") do
            token when is_binary(token) and token != "" -> [bearer_token: token]
            _ -> []
          end

        case Client.start_link(deployment_url, options) do
          {:ok, client} -> {:ok, client, %{state | client: client}}
          {:error, error} -> {:error, error, state}
        end
    end
  end

  defp wait_for_subscription(writer, subscription_id) do
    receive do
      {:subscription, subscription} -> forward_updates(writer, subscription_id, subscription)
    end
  end

  defp forward_updates(writer, subscription_id, subscription) do
    case Subscription.next(subscription, :infinity) do
      {:ok, update} ->
        emit(writer, %{
          "type" => "subscription",
          "subscriptionId" => subscription_id,
          "value" => update.value,
          "logs" => update.logs
        })

        forward_updates(writer, subscription_id, subscription)

      {:error, %Convex.ClosedError{}} ->
        :ok

      {:error, error} ->
        emit_error(writer, nil, subscription_id, error)
        forward_updates(writer, subscription_id, subscription)
    end
  end

  defp close_state(state) do
    Enum.each(state.subscriptions, fn {_id, subscription} -> close_subscription(subscription) end)
    if state.client, do: Client.close(state.client)
  end

  defp close_subscription({subscription, forwarder}) do
    Subscription.close(subscription)
    if Process.alive?(forwarder), do: Process.exit(forwarder, :normal)
  end

  defp emit_error(writer, id, subscription_id, error) do
    {name, data, logs} =
      case error do
        %FunctionError{} -> {"FunctionError", error.data, error.logs}
        %ProtocolError{} -> {"ProtocolError", nil, []}
        %TransportError{} -> {"TransportError", nil, []}
        _ -> {"Error", nil, []}
      end

    event =
      %{
        "type" => if(subscription_id, do: "subscription", else: "error"),
        "logs" => logs,
        "error" => %{"name" => name, "message" => Exception.message(error), "data" => data}
      }
      |> put_optional("id", id)
      |> put_optional("subscriptionId", subscription_id)

    emit(writer, event)
  end

  defp put_optional(event, _key, nil), do: event
  defp put_optional(event, key, value), do: Map.put(event, key, value)

  # Exercise the real writer and JSON encoder from language-local tests without
  # exposing a test hook in the production conformance release.
  if Mix.env() == :test do
    @doc false
    def emit_error_for_test(id, subscription_id, error) do
      writer = spawn(fn -> writer_loop(:stdio) end)

      try do
        emit_error(writer, id, subscription_id, error)
      after
        Process.exit(writer, :kill)
      end
    end
  end

  defp writer_loop(transport) do
    receive do
      {:write, caller, reference, event} ->
        result = write_line(transport, Jason.encode!(event) <> "\n")
        send(caller, {:written, reference, result})
        writer_loop(transport)
    end
  end

  defp emit(writer, event) do
    reference = make_ref()
    send(writer, {:write, self(), reference, event})

    receive do
      {:written, ^reference, :ok} -> :ok
      {:written, ^reference, {:error, reason}} -> raise "write adapter event: #{inspect(reason)}"
    after
      5_000 -> raise "timed out writing adapter event"
    end
  end

  defp open_transport do
    case System.get_env("ADAPTER_LISTEN") do
      nil ->
        {:ok, :stdio}

      address ->
        [host, port] = String.split(address, ":", parts: 2)
        {:ok, ip} = :inet.parse_address(String.to_charlist(host))

        {:ok, listener} =
          :gen_tcp.listen(String.to_integer(port), [
            :binary,
            packet: :line,
            active: false,
            reuseaddr: true,
            ip: ip
          ])

        IO.puts(:stderr, "adapter listening on #{address}")
        {:ok, socket} = :gen_tcp.accept(listener)
        :ok = :gen_tcp.close(listener)
        {:ok, {:tcp, socket}}
    end
  end

  defp read_line(:stdio) do
    case IO.read(:stdio, :line) do
      :eof -> :eof
      {:error, reason} -> {:error, reason}
      line -> {:ok, line}
    end
  end

  defp read_line({:tcp, socket}), do: :gen_tcp.recv(socket, 0)

  defp write_line(:stdio, line), do: IO.binwrite(:stdio, line)
  defp write_line({:tcp, socket}, line), do: :gen_tcp.send(socket, line)

  defp close_transport(nil), do: :ok
  defp close_transport(:stdio), do: :ok
  defp close_transport({:tcp, socket}), do: :gen_tcp.close(socket)
end
