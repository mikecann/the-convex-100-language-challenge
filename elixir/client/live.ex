defmodule Convex.Subscription do
  @moduledoc "A Convex Live query that delivers updates to its owning process."

  defstruct [:manager, :query_id, :reference, :owner]

  @type t :: %__MODULE__{
          manager: pid(),
          query_id: non_neg_integer(),
          reference: reference(),
          owner: pid()
        }

  @spec next(t(), timeout()) :: {:ok, map()} | {:error, Exception.t()} | {:error, :timeout}
  def next(%__MODULE__{reference: reference}, timeout \\ 10_000) do
    receive do
      {:convex_update, ^reference, {:ok, value, logs}} -> {:ok, %{value: value, logs: logs}}
      {:convex_update, ^reference, {:error, error}} -> {:error, error}
      {:convex_closed, ^reference} -> {:error, %Convex.ClosedError{}}
    after
      timeout -> {:error, :timeout}
    end
  end

  @spec close(t()) :: :ok
  def close(%__MODULE__{} = subscription), do: Convex.Live.unsubscribe(subscription)
end

defmodule Convex.Live do
  @moduledoc false

  use GenServer

  alias Convex.{FunctionError, ProtocolError, Subscription, TransportError}

  @zero_version %{"querySet" => 0, "identity" => 0, "ts" => "AAAAAAAAAAA="}
  @reconnect_delay 100

  def start_link(deployment_url, client_version) do
    GenServer.start_link(__MODULE__, {deployment_url, client_version})
  end

  def subscribe(manager, path, args, options) do
    GenServer.call(manager, {:subscribe, path, args, Keyword.get(options, :owner, self())})
  end

  def unsubscribe(%Subscription{} = subscription) do
    if Process.alive?(subscription.manager) do
      GenServer.call(subscription.manager, {:unsubscribe, subscription.query_id})
    else
      :ok
    end
  catch
    :exit, _ -> :ok
  end

  def debug_disconnect(manager), do: GenServer.call(manager, :debug_disconnect)

  def close(manager) do
    if Process.alive?(manager), do: GenServer.call(manager, :close, 10_000), else: :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init({deployment_url, client_version}) do
    uri = URI.parse(deployment_url)

    state = %{
      active: %{},
      client_version: client_version,
      connection: nil,
      connection_count: 0,
      deliberate_close: false,
      last_close_reason: "InitialConnect",
      max_timestamp: nil,
      next_query_id: 0,
      query_set_version: 0,
      reconnect_timer: nil,
      remote_results: %{},
      remote_version: @zero_version,
      uri: uri,
      websocket_ref: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: connect(state)

  @impl true
  def handle_call({:subscribe, path, args, owner}, _from, state) do
    query_id = state.next_query_id
    reference = make_ref()
    subscription = %{owner: owner, reference: reference, path: path, args: args}
    active = Map.put(state.active, query_id, subscription)
    state = %{state | active: active, next_query_id: query_id + 1}

    state =
      if connected?(state) do
        new_version = state.query_set_version + 1

        send_json(
          state,
          modify_query_set(state.query_set_version, new_version, [
            add_modification(query_id, path, args)
          ])
        )

        %{state | query_set_version: new_version}
      else
        schedule_reconnect(state, 0)
      end

    result =
      {:ok,
       %Subscription{manager: self(), query_id: query_id, reference: reference, owner: owner}}

    {:reply, result, state}
  end

  def handle_call({:unsubscribe, query_id}, _from, state) do
    case Map.pop(state.active, query_id) do
      {nil, active} ->
        {:reply, :ok, %{state | active: active}}

      {subscription, active} ->
        send(subscription.owner, {:convex_closed, subscription.reference})

        state =
          if connected?(state) do
            new_version = state.query_set_version + 1

            send_json(
              state,
              modify_query_set(state.query_set_version, new_version, [
                %{"type" => "Remove", "queryId" => query_id}
              ])
            )

            %{state | query_set_version: new_version}
          else
            state
          end

        {:reply, :ok,
         %{state | active: active, remote_results: Map.delete(state.remote_results, query_id)}}
    end
  end

  def handle_call(:debug_disconnect, _from, %{connection: nil} = state) do
    {:reply, {:error, %TransportError{operation: :debug_disconnect, reason: :not_connected}},
     state}
  end

  def handle_call(:debug_disconnect, _from, state) do
    :ok = :gun.close(state.connection)
    {:reply, :ok, disconnected_state(state, "DebugDisconnect") |> schedule_reconnect(0)}
  end

  def handle_call(:close, _from, state) do
    if state.reconnect_timer, do: Process.cancel_timer(state.reconnect_timer)
    if state.connection, do: :gun.close(state.connection)

    Enum.each(state.active, fn {_query_id, subscription} ->
      send(subscription.owner, {:convex_closed, subscription.reference})
    end)

    {:stop, :normal, :ok, %{state | active: %{}, deliberate_close: true}}
  end

  @impl true
  def handle_info(:reconnect, %{deliberate_close: true} = state), do: {:noreply, state}

  def handle_info(:reconnect, state) do
    connect(%{state | reconnect_timer: nil})
  end

  def handle_info(
        {:gun_ws, connection, websocket_ref, {:text, payload}},
        %{connection: connection, websocket_ref: websocket_ref} = state
      ) do
    with {:ok, message} <- Jason.decode(payload),
         {:ok, state} <- handle_server_message(message, state) do
      {:noreply, state}
    else
      {:error, %ProtocolError{} = error} ->
        {:noreply, publish_protocol_error(state, error)}

      {:error, reason} ->
        error = %ProtocolError{message: "decode server message: #{Exception.message(reason)}"}
        {:noreply, publish_protocol_error(state, error)}
    end
  end

  def handle_info({:gun_ws, connection, websocket_ref, {:binary, payload}}, state),
    do: handle_info({:gun_ws, connection, websocket_ref, {:text, payload}}, state)

  def handle_info(
        {:gun_down, connection, _protocol, reason, _killed, _unprocessed},
        %{connection: connection} = state
      ) do
    state = disconnected_state(state, inspect(reason))
    {:noreply, if(map_size(state.active) > 0, do: schedule_reconnect(state), else: state)}
  end

  def handle_info({:gun_error, connection, _stream, reason}, %{connection: connection} = state) do
    state = disconnected_state(state, inspect(reason))
    {:noreply, if(map_size(state.active) > 0, do: schedule_reconnect(state), else: state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # This callback-shaped helper remains public so the language-local tests can
  # exercise atomic transition application without mocking a Convex backend.
  def handle_frame({:text, payload}, state) do
    with {:ok, message} <- Jason.decode(payload), do: handle_server_message(message, state)
  end

  defp connect(%{deliberate_close: true} = state), do: {:noreply, state}

  defp connect(state) do
    uri = state.uri
    port = uri.port || if(uri.scheme == "https", do: 443, else: 80)

    options = connection_options(uri)

    with {:ok, connection} <- :gun.open(String.to_charlist(uri.host), port, options),
         {:ok, _protocol} <- :gun.await_up(connection, 10_000),
         websocket_ref <-
           :gun.ws_upgrade(
             connection,
             String.trim_trailing(uri.path || "", "/") <> "/api/sync",
             [{"convex-client", state.client_version}]
           ),
         {:ok, _headers} <- await_upgrade(connection, websocket_ref) do
      state = %{
        state
        | connection: connection,
          query_set_version: 0,
          reconnect_timer: nil,
          remote_results: %{},
          remote_version: @zero_version,
          websocket_ref: websocket_ref
      }

      send_json(state, connect_message(state))
      state = restore_active_queries(state)
      {:noreply, state}
    else
      {:error, reason} ->
        state = disconnected_state(state, inspect(reason))
        {:noreply, if(map_size(state.active) > 0, do: schedule_reconnect(state), else: state)}
    end
  end

  # Gun 2.5 accepts its connection options as a map. TLS configuration remains
  # a keyword list because that nested value is passed on to Erlang's SSL API.
  defp connection_options(%URI{scheme: "https"} = uri) do
    %{
      transport: :tls,
      protocols: [:http],
      tls_opts: [
        verify: :verify_peer,
        cacertfile: String.to_charlist(CAStore.file_path()),
        server_name_indication: String.to_charlist(uri.host),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    }
  end

  defp connection_options(%URI{}), do: %{transport: :tcp, protocols: [:http]}

  if Mix.env() == :test do
    @doc false
    def connection_options_for_test(url), do: url |> URI.parse() |> connection_options()
  end

  defp await_upgrade(connection, websocket_ref) do
    receive do
      {:gun_upgrade, ^connection, ^websocket_ref, ["websocket"], headers} ->
        {:ok, headers}

      {:gun_response, ^connection, ^websocket_ref, _fin, status, _headers} ->
        {:error, {:upgrade_failed, status}}

      {:gun_error, ^connection, ^websocket_ref, reason} ->
        {:error, reason}
    after
      10_000 -> {:error, :upgrade_timeout}
    end
  end

  defp restore_active_queries(%{active: active} = state) when map_size(active) == 0, do: state

  defp restore_active_queries(state) do
    modifications =
      state.active
      |> Enum.sort_by(fn {query_id, _} -> query_id end)
      |> Enum.map(fn {query_id, subscription} ->
        add_modification(query_id, subscription.path, subscription.args)
      end)

    send_json(state, modify_query_set(0, 1, modifications))
    %{state | query_set_version: 1}
  end

  defp connect_message(state) do
    message = %{
      "type" => "Connect",
      "sessionId" => uuid4(),
      "connectionCount" => state.connection_count,
      "lastCloseReason" => state.last_close_reason,
      "clientTs" => 0
    }

    if state.max_timestamp,
      do: Map.put(message, "maxObservedTimestamp", state.max_timestamp),
      else: message
  end

  defp handle_server_message(%{"type" => "Transition"} = transition, state) do
    if transition["startVersion"] != state.remote_version do
      {:error, %ProtocolError{message: "Transition start version does not match local version"}}
    else
      with {:ok, changed, remote_results} <-
             apply_modifications(transition["modifications"] || [], state.remote_results) do
        Enum.each(changed, fn {query_id, update} -> deliver(state.active[query_id], update) end)
        end_version = transition["endVersion"]

        {:ok,
         %{
           state
           | remote_results: remote_results,
             remote_version: end_version,
             max_timestamp: end_version["ts"] || state.max_timestamp
         }}
      else
        {:error, message} -> {:error, %ProtocolError{message: message}}
      end
    end
  end

  defp handle_server_message(%{"type" => type}, state)
       when type in ["Ping", "MutationResponse", "ActionResponse"],
       do: {:ok, state}

  defp handle_server_message(%{"type" => "TransitionChunk"}, _state),
    do:
      {:error,
       %ProtocolError{
         message: "TransitionChunk assembly is not implemented by the Elixir demonstration"
       }}

  defp handle_server_message(%{"type" => type, "error" => error}, _state)
       when type in ["FatalError", "AuthError"],
       do: {:error, %ProtocolError{message: "#{type}: #{error}"}}

  defp handle_server_message(%{"type" => type}, _state),
    do: {:error, %ProtocolError{message: "unknown server message #{inspect(type)}"}}

  defp handle_server_message(_message, _state),
    do: {:error, %ProtocolError{message: "server message omitted its type"}}

  defp apply_modifications(modifications, remote_results) do
    Enum.reduce_while(modifications, {:ok, %{}, remote_results}, fn modification,
                                                                    {:ok, changed, results} ->
      query_id = modification["queryId"]

      case modification["type"] do
        "QueryUpdated" ->
          update = {:ok, modification["value"], modification["logLines"] || []}
          {:cont, {:ok, Map.put(changed, query_id, update), Map.put(results, query_id, update)}}

        "QueryFailed" ->
          error = %FunctionError{
            operation: :query,
            message: modification["errorMessage"] || "Reactive query failed",
            data: modification["errorData"],
            logs: modification["logLines"] || []
          }

          update = {:error, error}
          {:cont, {:ok, Map.put(changed, query_id, update), Map.put(results, query_id, update)}}

        "QueryRemoved" ->
          {:cont, {:ok, changed, Map.delete(results, query_id)}}

        type ->
          {:halt, {:error, "unknown Transition modification #{inspect(type)}"}}
      end
    end)
  end

  defp send_json(state, message) do
    :ok = :gun.ws_send(state.connection, state.websocket_ref, {:text, Jason.encode!(message)})
  end

  defp connected?(state), do: is_pid(state.connection) and is_reference(state.websocket_ref)

  defp schedule_reconnect(state, delay \\ @reconnect_delay) do
    if state.reconnect_timer,
      do: state,
      else: %{state | reconnect_timer: Process.send_after(self(), :reconnect, delay)}
  end

  defp disconnected_state(state, reason) do
    %{
      state
      | connection: nil,
        connection_count: state.connection_count + 1,
        last_close_reason: reason,
        query_set_version: 0,
        remote_results: %{},
        remote_version: @zero_version,
        websocket_ref: nil
    }
  end

  defp publish_protocol_error(state, error) do
    Enum.each(state.active, fn {_query_id, subscription} ->
      deliver(subscription, {:error, error})
    end)

    if state.connection, do: :gun.close(state.connection)
    disconnected_state(state, Exception.message(error)) |> schedule_reconnect()
  end

  defp deliver(nil, _update), do: :ok

  defp deliver(subscription, update),
    do: send(subscription.owner, {:convex_update, subscription.reference, update})

  defp modify_query_set(base_version, new_version, modifications) do
    %{
      "type" => "ModifyQuerySet",
      "baseVersion" => base_version,
      "newVersion" => new_version,
      "modifications" => modifications
    }
  end

  defp add_modification(query_id, path, args) do
    %{"type" => "Add", "queryId" => query_id, "udfPath" => path, "args" => [args]}
  end

  defp uuid4 do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.band(c, 0x0FFF) |> Bitwise.bor(0x4000)
    d = Bitwise.band(d, 0x3FFF) |> Bitwise.bor(0x8000)

    [a, b, c, d, e]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {value, width} ->
      value |> Integer.to_string(16) |> String.pad_leading(width, "0")
    end)
  end
end
