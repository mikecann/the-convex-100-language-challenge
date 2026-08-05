defmodule Convex.ExampleTest do
  use ExUnit.Case, async: true

  test "Float64 counter values produce the verifier's exact integer text" do
    assert Convex.Example.normalize_count!("initial", 0.0) == 0
    assert Convex.Example.normalize_count!("updated", 1.0) == 1

    assert "current count: #{Convex.Example.normalize_count!("query", 0.0)}" ==
             "current count: 0"

    assert "verified count: #{Convex.Example.normalize_count!("query", 0.0)} -> #{Convex.Example.normalize_count!("Live", 1.0)}" ==
             "verified count: 0 -> 1"
  end

  test "whole integer values remain valid" do
    assert Convex.Example.normalize_count!("query", 42) == 42
  end

  test "fractions and non-numeric values cannot look like a passing counter" do
    assert_raise RuntimeError, ~r/finite whole number/, fn ->
      Convex.Example.normalize_count!("query", 0.5)
    end

    assert_raise RuntimeError, ~r/finite whole number/, fn ->
      Convex.Example.normalize_count!("query", "0")
    end

    assert_raise RuntimeError, ~r/finite whole number/, fn ->
      Convex.Example.normalize_count!("query", :infinity)
    end
  end
end
