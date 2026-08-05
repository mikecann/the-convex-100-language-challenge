defmodule Convex.Conformance.AdapterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Convex.Conformance.Adapter
  alias Convex.TransportError

  test "HTTP-style errors omit the unrelated subscription identifier" do
    event = serialized_error("request-1", nil)

    assert event["type"] == "error"
    assert event["id"] == "request-1"
    refute Map.has_key?(event, "subscriptionId")
  end

  test "subscription errors omit the unrelated request identifier" do
    event = serialized_error(nil, "subscription-1")

    assert event["type"] == "subscription"
    assert event["subscriptionId"] == "subscription-1"
    refute Map.has_key?(event, "id")
  end

  # Capture the exact NDJSON line written by the adapter writer, including its
  # real Jason encoding step, so this cannot pass by inspecting a helper map.
  defp serialized_error(id, subscription_id) do
    capture_io(fn ->
      Adapter.emit_error_for_test(
        id,
        subscription_id,
        %TransportError{operation: :query, reason: :timeout}
      )
    end)
    |> Jason.decode!()
  end
end
