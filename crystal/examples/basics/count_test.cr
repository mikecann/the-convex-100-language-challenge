require "./main"

def assert_rejected(value : JSON::Any, label : String)
  begin
    whole_count(value, label)
  rescue
    return
  end
  raise "#{label} was accepted"
end

raise "0.0 was not decoded as zero" unless whole_count(JSON.parse("0.0"), "zero") == 0
raise "1.0 was not decoded as one" unless whole_count(JSON.parse("1.0"), "one") == 1
assert_rejected(JSON.parse("1.5"), "fractional")
assert_rejected(JSON.parse(%("1")), "quoted")
assert_rejected(JSON::Any.new(Float64::INFINITY), "non-finite")
assert_rejected(JSON::Any.new(Int64::MAX.to_f), "overflowing")

puts "crystal canonical decimal decoding passed"
