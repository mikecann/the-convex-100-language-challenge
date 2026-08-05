defmodule Convex.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      case System.get_env("CONVEX_ENTRYPOINT") do
        "example" -> [{Task, &run_example/0}]
        "adapter" -> [{Task, &run_adapter/0}]
        _ -> []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Convex.Supervisor)
  end

  defp run_example do
    room = System.get_env("CONVEX_EXAMPLE_ROOM") || "elixir-example"
    exit_after(fn -> Convex.Example.main([room]) end)
  end

  defp run_adapter do
    exit_after(&Convex.Conformance.Adapter.main/0)
  end

  # A release is a long-running OTP system by default. These two educational
  # entrypoints are command-line programs, so explicitly stop the VM when the
  # selected program finishes and preserve a useful non-zero exit status.
  defp exit_after(fun) do
    status =
      try do
        fun.()
        0
      rescue
        error ->
          IO.puts(:stderr, Exception.format(:error, error, __STACKTRACE__))
          1
      catch
        kind, reason ->
          IO.puts(:stderr, Exception.format(kind, reason, __STACKTRACE__))
          1
      end

    System.stop(status)
  end
end
