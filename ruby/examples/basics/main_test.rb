# frozen_string_literal: true

require "minitest/autorun"

require_relative "main"

class RubyBasicExampleTest < Minitest::Test
  def test_whole_float_uses_integer_machine_output
    assert_equal 0, verified_whole_count(0.0, "test")
    assert_equal "0", verified_whole_count(0.0, "test").to_s
    assert_equal 1, verified_whole_count(1.0, "test")
  end

  def test_fractional_and_non_finite_counts_cannot_report_success
    assert_raises(RuntimeError) { verified_whole_count(0.5, "test") }
    assert_raises(RuntimeError) { verified_whole_count(Float::INFINITY, "test") }
    assert_raises(RuntimeError) { verified_whole_count(Float::NAN, "test") }
  end
end
