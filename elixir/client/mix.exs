defmodule ConvexClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :convex_client,
      version: "0.1.0",
      elixir: "1.17.3",
      # Docker assembles the reader-friendly files into this conventional
      # compiler directory without forcing that build shape into the repo.
      elixirc_paths: ["source"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # BEAM bytecode is portable, so Docker compiles it on the host platform
      # and supplies the pinned target-platform ERTS separately at runtime.
      releases: [convex_client: [include_erts: false, include_executables_for: [:unix]]]
    ]
  end

  def application do
    [
      mod: {Convex.Application, []},
      extra_applications: [:crypto, :inets, :logger, :public_key, :ssl]
    ]
  end

  defp deps do
    [
      {:castore, "1.0.15"},
      {:gun, "2.5.0"},
      {:jason, "1.4.4"},
    ]
  end
end
