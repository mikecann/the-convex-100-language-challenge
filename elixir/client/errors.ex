defmodule Convex.Result do
  @moduledoc "A successful function result, including logs kept separate from its value."
  defstruct [:value, logs: []]
  @type t :: %__MODULE__{value: term(), logs: [String.t()]}
end

defmodule Convex.FunctionError do
  @moduledoc "A structured error returned by a Convex function."
  defexception [:operation, :message, :data, logs: []]

  @impl true
  def message(%__MODULE__{operation: operation, message: message}) do
    "Convex #{operation} failed: #{message}"
  end
end

defmodule Convex.ProtocolError do
  @moduledoc "A response that does not match the documented or pinned Convex protocol."
  defexception [:message]

  @impl true
  def message(%__MODULE__{message: message}), do: "Convex protocol error: #{message}"
end

defmodule Convex.TransportError do
  @moduledoc "An HTTP or WebSocket transport failure."
  defexception [:operation, :reason]

  @impl true
  def message(%__MODULE__{operation: operation, reason: reason}) do
    "Convex #{operation} transport error: #{inspect(reason)}"
  end
end

defmodule Convex.ClosedError do
  @moduledoc false
  defexception message: "Convex client is closed"
end
