defmodule Convex.Client do
  @moduledoc """
  A small native Elixir client for documented Convex HTTP functions and the
  explicitly pinned `convex-rs-0.10.4-unversioned-sync` Live profile.
  """

  use GenServer

  alias Convex.{ClosedError, FunctionError, ProtocolError, Result, TransportError}

  @client_version "elixir-0.1.0"
  @max_response_bytes 2 * 1024 * 1024

  @type option :: {:bearer_token, String.t()} | {:client_version, String.t()}

  @spec start_link(String.t(), [option()]) :: GenServer.on_start()
  def start_link(deployment_url, options \\ []) do
    with {:ok, normalized_url} <- normalize_url(deployment_url) do
      GenServer.start_link(__MODULE__, {normalized_url, options})
    end
  end

  @spec query(pid(), String.t(), map(), timeout()) :: {:ok, Result.t()} | {:error, Exception.t()}
  def query(client, path, args, timeout \\ 30_000),
    do: GenServer.call(client, {:call, :query, path, args}, timeout)

  @spec mutation(pid(), String.t(), map(), timeout()) ::
          {:ok, Result.t()} | {:error, Exception.t()}
  def mutation(client, path, args, timeout \\ 30_000),
    do: GenServer.call(client, {:call, :mutation, path, args}, timeout)

  @spec action(pid(), String.t(), map(), timeout()) :: {:ok, Result.t()} | {:error, Exception.t()}
  def action(client, path, args, timeout \\ 30_000),
    do: GenServer.call(client, {:call, :action, path, args}, timeout)

  @spec set_auth(pid(), String.t()) :: :ok | {:error, Exception.t()}
  def set_auth(client, token), do: GenServer.call(client, {:set_auth, token})

  @spec subscribe(pid(), String.t(), map(), keyword()) ::
          {:ok, Convex.Subscription.t()} | {:error, Exception.t()}
  def subscribe(client, path, args, options \\ []) do
    # Capture the calling process before delegating to the Client GenServer.
    # Otherwise Live would default to that internal GenServer as the owner and
    # reactive updates would never reach the process that requested them.
    options = Keyword.put_new(options, :owner, self())
    GenServer.call(client, {:subscribe, path, args, options}, 15_000)
  end

  @spec debug_disconnect(pid()) :: :ok | {:error, Exception.t()}
  def debug_disconnect(client), do: GenServer.call(client, :debug_disconnect, 10_000)

  @spec close(pid()) :: :ok
  def close(client) do
    if Process.alive?(client), do: GenServer.call(client, :close, 10_000), else: :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init({deployment_url, options}) do
    {:ok,
     %{
       deployment_url: deployment_url,
       token: Keyword.get(options, :bearer_token, ""),
       client_version: Keyword.get(options, :client_version, @client_version),
       live: nil,
       closed: false
     }}
  end

  @impl true
  def handle_call({:call, _operation, _path, _args}, _from, %{closed: true} = state) do
    {:reply, {:error, %ClosedError{}}, state}
  end

  def handle_call({:call, operation, path, args}, _from, state) do
    {:reply, http_call(state, operation, path, args), state}
  end

  def handle_call({:set_auth, _token}, _from, %{closed: true} = state) do
    {:reply, {:error, %ClosedError{}}, state}
  end

  def handle_call({:set_auth, token}, _from, state) when is_binary(token) do
    {:reply, :ok, %{state | token: token}}
  end

  def handle_call({:subscribe, _path, _args, _options}, _from, %{closed: true} = state) do
    {:reply, {:error, %ClosedError{}}, state}
  end

  def handle_call({:subscribe, path, args, options}, _from, state) do
    with :ok <- validate_call(path, args),
         {:ok, live, state} <- ensure_live(state),
         result <- Convex.Live.subscribe(live, path, args, options) do
      {:reply, result, state}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call(:debug_disconnect, _from, %{live: nil} = state) do
    {:reply, {:error, %TransportError{operation: :live, reason: :not_connected}}, state}
  end

  def handle_call(:debug_disconnect, _from, state) do
    {:reply, Convex.Live.debug_disconnect(state.live), state}
  end

  def handle_call(:close, _from, state) do
    if state.live && Process.alive?(state.live), do: Convex.Live.close(state.live)
    {:stop, :normal, :ok, %{state | closed: true, live: nil}}
  end

  defp ensure_live(%{live: live} = state) when is_pid(live) do
    if Process.alive?(live), do: {:ok, live, state}, else: ensure_live(%{state | live: nil})
  end

  defp ensure_live(state) do
    case Convex.Live.start_link(state.deployment_url, state.client_version) do
      {:ok, live} -> {:ok, live, %{state | live: live}}
      {:error, reason} -> {:error, %TransportError{operation: :live, reason: reason}}
    end
  end

  defp http_call(state, operation, path, args) do
    with :ok <- validate_call(path, args),
         {:ok, request_body} <- encode_request(path, args),
         {:ok, status, response_body} <- request(state, operation, request_body),
         {:ok, decoded} <- decode_response(operation, status, response_body) do
      case decoded do
        %{"status" => "success", "value" => value} ->
          {:ok, %Result{value: value, logs: decoded["logLines"] || []}}

        %{"status" => "error"} ->
          {:error,
           %FunctionError{
             operation: operation,
             message: decoded["errorMessage"] || "Convex function failed",
             data: decoded["errorData"],
             logs: decoded["logLines"] || []
           }}

        other ->
          {:error,
           %ProtocolError{
             message: "HTTP #{status} response has unknown status: #{inspect(other)}"
           }}
      end
    end
  end

  defp validate_call(path, args) when is_binary(path) and path != "" and is_map(args), do: :ok

  defp validate_call("", _args),
    do: {:error, %ArgumentError{message: "Convex function path is required"}}

  defp validate_call(_path, _args) do
    {:error, %ArgumentError{message: "Convex arguments must be a named JSON object"}}
  end

  defp encode_request(path, args) do
    case Jason.encode(%{"path" => path, "args" => args, "format" => "json"}) do
      {:ok, body} ->
        {:ok, body}

      {:error, reason} ->
        {:error, %ArgumentError{message: "encode Convex arguments: #{inspect(reason)}"}}
    end
  end

  defp request(state, operation, body) do
    endpoint = state.deployment_url <> "/api/" <> Atom.to_string(operation)

    headers =
      [
        {~c"accept", ~c"application/json"},
        {~c"convex-client", String.to_charlist(state.client_version)}
      ] ++ auth_header(state.token)

    # Keep JSON as its encoded UTF-8 binary. Turning it into a Unicode charlist
    # creates codepoints above 255 for values such as `世界` and `👋`; those are
    # not valid iodata bytes and can leave `:httpc` waiting indefinitely.
    request = {String.to_charlist(endpoint), headers, ~c"application/json", body}

    case :httpc.request(
           :post,
           request,
           http_options(endpoint),
           body_format: :binary
         ) do
      {:ok, {{_version, status, _reason}, _headers, response_body}}
      when byte_size(response_body) <= @max_response_bytes ->
        {:ok, status, response_body}

      {:ok, {{_version, _status, _reason}, _headers, response_body}} ->
        {:error,
         %TransportError{
           operation: operation,
           reason:
             "response exceeds #{@max_response_bytes} bytes (got #{byte_size(response_body)})"
         }}

      {:error, reason} ->
        {:error, %TransportError{operation: operation, reason: reason}}
    end
  end

  # `:httpc` does not make HTTPS verification intent obvious at a call site.
  # Keep the security policy in one testable helper so hosted calls always use
  # the pinned CA bundle, peer verification, SNI, and HTTPS hostname matching.
  @doc false
  def http_options(endpoint) do
    uri = URI.parse(endpoint)
    common = [timeout: 30_000, connect_timeout: 10_000]

    if uri.scheme == "https" do
      ssl_options = [
        verify: :verify_peer,
        cacertfile: String.to_charlist(CAStore.file_path()),
        server_name_indication: String.to_charlist(uri.host),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]

      Keyword.put(common, :ssl, ssl_options)
    else
      common
    end
  end

  defp auth_header(""), do: []
  defp auth_header(token), do: [{~c"authorization", String.to_charlist("Bearer " <> token)}]

  defp decode_response(operation, status, body) do
    case Jason.decode(body) do
      {:ok, value} ->
        {:ok, value}

      {:error, reason} ->
        {:error,
         %TransportError{
           operation: operation,
           reason: "HTTP #{status} returned non-Convex JSON: #{Exception.message(reason)}"
         }}
    end
  end

  defp normalize_url(deployment_url) when is_binary(deployment_url) do
    uri = URI.parse(deployment_url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, %ArgumentError{message: "Convex deployment URL must use http or https"}}

      is_nil(uri.host) ->
        {:error, %ArgumentError{message: "Convex deployment URL must include a host"}}

      not is_nil(uri.userinfo) ->
        {:error,
         %ArgumentError{message: "Convex deployment URL must not include user information"}}

      true ->
        normalized = %{
          uri
          | path: String.trim_trailing(uri.path || "", "/"),
            query: nil,
            fragment: nil
        }

        {:ok, URI.to_string(normalized)}
    end
  end

  defp normalize_url(_),
    do: {:error, %ArgumentError{message: "Convex deployment URL is required"}}
end
