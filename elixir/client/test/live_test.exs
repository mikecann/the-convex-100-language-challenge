defmodule Convex.LiveTest do
  use ExUnit.Case, async: true

  alias Convex.{FunctionError, Live}

  test "an atomic Transition delivers its updated query value" do
    reference = make_ref()
    state = live_state(reference)

    transition = %{
      "type" => "Transition",
      "startVersion" => zero_version(),
      "endVersion" => %{"querySet" => 1, "identity" => 0, "ts" => "AQAAAAAAAAA="},
      "modifications" => [
        %{
          "type" => "QueryUpdated",
          "queryId" => 7,
          "value" => %{"count" => 1},
          "logLines" => ["updated"]
        }
      ]
    }

    assert {:ok, next_state} = Live.handle_frame({:text, Jason.encode!(transition)}, state)
    assert next_state.remote_version == transition["endVersion"]
    assert_receive {:convex_update, ^reference, {:ok, %{"count" => 1}, ["updated"]}}
  end

  test "reactive query failures stay typed subscription events" do
    reference = make_ref()
    state = live_state(reference)

    transition = %{
      "type" => "Transition",
      "startVersion" => zero_version(),
      "endVersion" => %{"querySet" => 1, "identity" => 0, "ts" => "AQAAAAAAAAA="},
      "modifications" => [
        %{
          "type" => "QueryFailed",
          "queryId" => 7,
          "errorMessage" => "room empty",
          "errorData" => %{"code" => "ROOM_EMPTY"},
          "logLines" => []
        }
      ]
    }

    assert {:ok, _state} = Live.handle_frame({:text, Jason.encode!(transition)}, state)

    assert_receive {:convex_update, ^reference,
                    {:error, %FunctionError{data: %{"code" => "ROOM_EMPTY"}}}}
  end

  test "Gun receives map-shaped TCP and TLS connection options" do
    assert %{transport: :tcp, protocols: [:http]} =
             Live.connection_options_for_test("http://backend:3210")

    assert %{transport: :tls, protocols: [:http], tls_opts: tls_options} =
             Live.connection_options_for_test("https://example.convex.cloud")

    assert tls_options[:verify] == :verify_peer
    assert tls_options[:server_name_indication] == ~c"example.convex.cloud"
  end

  defp live_state(reference) do
    %{
      active: %{
        7 => %{owner: self(), reference: reference, path: "demo:state", args: %{"room" => "test"}}
      },
      client_version: "elixir-test",
      conn: nil,
      connection_count: 0,
      deliberate_close: false,
      last_close_reason: "InitialConnect",
      max_timestamp: nil,
      next_query_id: 8,
      query_set_version: 1,
      remote_results: %{},
      remote_version: zero_version()
    }
  end

  defp zero_version, do: %{"querySet" => 0, "identity" => 0, "ts" => "AAAAAAAAAAA="}
end
