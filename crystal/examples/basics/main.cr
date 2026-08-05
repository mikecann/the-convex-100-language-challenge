require "json"
require "../../client/client"

def whole_count(value : JSON::Any, operation : String) : Int64
  case number = value.raw
  when Int64
    number
  when Float64
    raise "#{operation} count was not finite" unless number.finite?
    integer = number.to_i64
    raise "#{operation} count was fractional" unless number == integer
    integer
  else
    raise "#{operation} count was not numeric"
  end
end

url = ENV.fetch("CONVEX_URL")
room = ARGV[0]? || "crystal-example"
client = Convex::Client.new(url, ENV["CONVEX_AUTH_TOKEN"]?)
begin
  current = client.query("demo:state", {"room" => JSON::Any.new(room)})
  current_count = whole_count(current.value["count"], "current query")
  puts "current count: #{current_count}"
  subscription = client.subscribe("demo:state", {"room" => JSON::Any.new(room)})
  begin
    initial = subscription.next(10.seconds)
    raise initial.error.not_nil! if initial.error
    initial_count = whole_count(initial.value.not_nil!["count"], "initial Live value")
    raise "initial Live count mismatch" unless initial_count == current_count
    puts "live initial count: #{initial_count}"
    mutation = client.mutation("demo:increment", {"room" => JSON::Any.new(room), "language" => JSON::Any.new("crystal"), "runId" => JSON::Any.new(Random::Secure.hex(8))})
    raise "mutation was not applied" unless mutation.value["applied"].as_bool
    puts "mutation applied: true"
    expected = current_count + 1
    mutation_count = whole_count(mutation.value["state"]["count"], "mutation")
    raise "mutation count mismatch" unless mutation_count == expected
    puts "mutation count: #{mutation_count}"
    changed = subscription.next(10.seconds)
    raise changed.error.not_nil! if changed.error
    changed_count = whole_count(changed.value.not_nil!["count"], "updated Live value")
    raise "updated Live count mismatch" unless changed_count == expected
    puts "live updated count: #{changed_count}"
    puts "verified count: #{current_count} -> #{changed_count}"
  ensure
    subscription.close
  end
ensure
  client.close
end
