require "json"
require "../../client/client"

def whole_count(value : JSON::Any, operation : String) : Int64
  case number = value.raw
  when Int64
    number
  when Float64
    raise "#{operation} count was not finite" unless number.finite?
    # Reject the rounded Float64 boundary before converting to Int64. The
    # conversion must never turn an overflowing Convex number into a value
    # that happens to look like a valid counter.
    raise "#{operation} count was out of range" if number < Int64::MIN.to_f || number >= Int64::MAX.to_f
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
  # Read the room over HTTP before opening Live. This gives the example a
  # concrete value to compare with the initial reactive snapshot.
  current = client.query("demo:state", {"room" => JSON::Any.new(room)})
  current_count = whole_count(current.value["count"], "current query")
  puts "current count: #{current_count}"
  # Subscribe before mutating so the next update proves the Live stream saw
  # the mutation instead of the example merely polling HTTP again.
  subscription = client.subscribe("demo:state", {"room" => JSON::Any.new(room)})
  begin
    initial = subscription.next(10.seconds)
    raise initial.error.not_nil! if initial.error
    initial_count = whole_count(initial.value.not_nil!["count"], "initial Live value")
    raise "initial Live count mismatch" unless initial_count == current_count
    puts "live initial count: #{initial_count}"
    # runId is the idempotency key for this logical increment. Retrying the
    # same mutation does not apply the increment twice on the demo backend.
    mutation = client.mutation("demo:increment", {"room" => JSON::Any.new(room), "language" => JSON::Any.new("crystal"), "runId" => JSON::Any.new(Random::Secure.hex(8))})
    raise "mutation was not applied" unless mutation.value["applied"].as_bool
    puts "mutation applied: true"
    expected = current_count + 1
    mutation_count = whole_count(mutation.value["state"]["count"], "mutation")
    raise "mutation count mismatch" unless mutation_count == expected
    puts "mutation count: #{mutation_count}"
    # Consume the Live update caused by the mutation and compare it with the
    # mutation response before printing the final verification line.
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
