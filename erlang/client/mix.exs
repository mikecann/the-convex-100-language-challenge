defmodule ErlangConvex.MixProject do
  use Mix.Project

  def project do
    [app: :erlang_convex, version: "0.1.0", deps: [{:gun, "2.5.0"}, {:jsx, "3.1.0"}]]
  end
end
