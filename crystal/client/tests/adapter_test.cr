require "./conformance/adapter"
require "http/server"

def assert(condition : Bool, message : String)
  raise message unless condition
end

def stale_barrier(label : String)
  output = IO::Memory.new
  writer = Mutex.new
  relay = SubscriptionRelay.new
  entered = Channel(Nil).new(1)
  resume = Channel(Nil).new(1)
  relay.pause_after_dequeue(entered, resume)
  done = Channel(Nil).new(1)
  spawn do
    relay.emit(output, writer, {"type" => json("subscription"), "subscriptionId" => json(label), "value" => JSON.parse(%({"count":0}))})
    done.send(nil)
  end
  entered.receive
  relay.invalidate
  emit_event(output, writer, {"id" => json(label), "type" => json("ack")})
  resume.send(nil)
  done.receive
  assert(output.to_s == %({"id":"#{label}","type":"ack"}\n), "#{label} stale delivery crossed acknowledgement")
end

# These are separate executions of the paused-after-dequeue race because same-ID
# replacement and unsubscribe have distinct controller acknowledgement paths.
stale_barrier("unsubscribe")
stale_barrier("replacement")

server = HTTP::Server.new do |context|
  request = JSON.parse(context.request.body.not_nil!.gets_to_end)
  context.response.content_type = "application/json"
  if request["path"].as_s == "demo:success"
    context.response.print({"status" => "success", "value" => {"count" => 1}, "logLines" => [] of String}.to_json)
  else
    context.response.print({"status" => "error", "errorMessage" => "failed", "errorData" => {"code" => "BROKEN"}, "logLines" => ["server-log"]}.to_json)
  end
end
address = server.bind_tcp("127.0.0.1", 0)
spawn { server.listen }

input = IO::Memory.new(%({"protocolVersion":1,"id":"hello","op":"hello"}\n{"id":"result","op":"query","path":"demo:success","args":{}}\n{"id":"function","op":"query","path":"demo:failure","args":{}}\n{"id":"bad","op":"unknown"}\n{"id":"close","op":"close"}\n))
output = IO::Memory.new
ENV["CONVEX_URL"] = "http://127.0.0.1:#{address.port}"
run_adapter(input, output)
server.close
expected = %(\
{"protocolVersion":1,"id":"hello","type":"ready","language":"crystal","implementation":"native-crystal-#{Crystal::VERSION}","runtime":"crystal-#{Crystal::VERSION}"}
{"id":"result","type":"result","value":{"count":1}}
{"id":"function","type":"error","error":{"name":"FunctionError","message":"failed","operation":"query","data":{"code":"BROKEN"},"logs":["server-log"]}}
{"id":"bad","type":"error","error":{"name":"ProtocolError","message":"unknown adapter operation"}}
{"id":"close","type":"closed"}
)
assert(output.to_s == expected, "adapter success/error/close envelopes were not exact:\n#{output}")

missing_id_output = IO::Memory.new
run_adapter(IO::Memory.new("{not-json}\n"), missing_id_output)
missing_id = JSON.parse(missing_id_output.to_s)
assert(missing_id["type"].as_s == "error", "malformed command did not emit an error")
assert(!missing_id["id"]?, "absent command id was serialized")
assert(missing_id["error"].as_h.keys.sort == ["message", "name"], "id-less protocol error envelope had extra fields")

subscription_output = IO::Memory.new
SubscriptionRelay.new.emit(subscription_output, Mutex.new, {"type" => json("subscription"), "subscriptionId" => json("s"), "error" => error_details(Convex::FunctionError.new("failed", "query", JSON.parse(%({"code":"ROOM_EMPTY"})), ["log"]))})
assert(subscription_output.to_s == %({"type":"subscription","subscriptionId":"s","error":{"name":"FunctionError","message":"failed","operation":"query","data":{"code":"ROOM_EMPTY"},"logs":["log"]}}\n), "subscription error envelope was not exact")

subscription_output = IO::Memory.new
SubscriptionRelay.new.emit(subscription_output, Mutex.new, {"type" => json("subscription"), "subscriptionId" => json("s"), "value" => JSON.parse(%({"count":1}))})
assert(subscription_output.to_s == %({"type":"subscription","subscriptionId":"s","value":{"count":1}}\n), "subscription success envelope did not omit absent fields")

oversized = {"id" => json("large"), "type" => json("result"), "value" => json("x" * OUTPUT_MAX_LINE_BYTES)}
begin
  emit_event(IO::Memory.new, Mutex.new, oversized)
  raise "oversized adapter event was accepted"
rescue Convex::ProtocolError
end

assert(OUTPUT_MAX_EVENTS == 17, "direct output count budget changed")
assert(OUTPUT_MAX_RETAINED_BYTES == 51 * 1024 * 1024, "conservative output byte budget changed")
puts "crystal adapter deterministic fixtures passed"
