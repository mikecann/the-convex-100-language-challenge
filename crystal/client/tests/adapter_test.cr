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
  case request["path"].as_s
  when "demo:success"
    context.response.print({"status" => "success", "value" => {"count" => 1}, "logLines" => [] of String}.to_json)
  when "demo:http500"
    context.response.status = HTTP::Status::INTERNAL_SERVER_ERROR
    # This deliberately looks like a valid Convex success. HTTP status must win
    # before the client inspects any application-level body fields.
    context.response.print({"status" => "success", "value" => {"count" => 500}, "logLines" => [] of String}.to_json)
  when "demo:oversized"
    # Flushing without a content length makes this a chunked response. The
    # client must stop retaining bytes as soon as the 2 MiB ceiling is crossed.
    context.response.headers["Transfer-Encoding"] = "chunked"
    begin
      context.response.print(%({"status":"success","value":"))
      context.response.flush
      129.times do
        context.response.print("x" * (16 * 1024))
        context.response.flush
        Fiber.yield
      end
      context.response.print(%(","logLines":[]}))
    rescue IO::Error | HTTP::Server::ClientError
      # Expected when the bounded client closes before the fixture finishes.
    end
  when "demo:slow"
    context.response.headers["Transfer-Encoding"] = "chunked"
    context.response.print(%({"status":"success","value":))
    context.response.flush
    sleep 350.milliseconds
    context.response.print(%({"count":2},"logLines":[]}))
  else
    context.response.print({"status" => "error", "errorMessage" => "failed", "errorData" => {"code" => "BROKEN"}, "logLines" => ["server-log"]}.to_json)
  end
end
address = server.bind_tcp("127.0.0.1", 0)
spawn { server.listen }

http_client = Convex::Client.new("http://127.0.0.1:#{address.port}")
begin
  http_client.query("demo:http500")
  raise "HTTP 500 success-shaped body was accepted"
rescue ex : Convex::TransportError
  assert(ex.message == "HTTP request failed with status 500", "HTTP status error was not exact")
end
assert(http_client.query("demo:success").value["count"].as_i == 1, "HTTP client did not recover after status error")
begin
  http_client.query("demo:oversized")
  raise "oversized chunked HTTP response was accepted"
rescue ex : Convex::TransportError
  assert(ex.message == "HTTP response too large", "oversized HTTP error was not exact")
end
assert(http_client.query("demo:success").value["count"].as_i == 1, "HTTP client did not recover after oversized body")
assert(http_client.query("demo:slow").value["count"].as_i == 2, "slow chunked HTTP response failed")
assert(http_client.query("demo:success").value["count"].as_i == 1, "HTTP client did not recover after slow response")
http_client.close

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
assert(missing_id["error"]["name"].as_s == "ProtocolError", "malformed JSON was not a structured ProtocolError")
assert(missing_id["error"].as_h.keys.sort == ["message", "name"], "id-less protocol error envelope had extra fields")

def adapter_command_error(line : String) : JSON::Any
  output = IO::Memory.new
  run_adapter(IO::Memory.new("#{line}\n{\"id\":\"close-invalid-fixture\",\"op\":\"close\"}\n"), output)
  events = output.to_s.lines
  raise "invalid adapter fixture did not close cleanly" unless events.size == 2
  event = JSON.parse(events.first)
  raise "invalid adapter fixture did not emit ProtocolError: #{event}" unless event["error"]["name"].as_s == "ProtocolError"
  event
end

# Validate the command schema before any narrowing cast. An invalid command ID
# must never be reflected, while a valid ID may correlate another schema error.
[
  "[]",
  %({"op":"close"}),
  %({"id":7,"op":"close"}),
  %({"id":"   ","op":"close"}),
  {"id" => "x" * 129, "op" => "close"}.to_json,
].each do |line|
  event = adapter_command_error(line)
  assert(!event["id"]?, "schema-invalid command ID was echoed")
end

{
  %({"id":"extra","op":"close","unexpected":true})            => "extra",
  %({"id":"op-type","op":3})                                  => "op-type",
  %({"id":"version","op":"hello","protocolVersion":1.0})      => "version",
  %({"id":"path","op":"query","path":" ","args":{}})          => "path",
  %({"id":"args","op":"query","path":"demo:state","args":[]}) => "args",
  %({"id":"token","op":"setAuth","token":false})              => "token",
  %({"id":"sid","op":"unsubscribe","subscriptionId":" "})     => "sid",
  %({"id":"subscribe","op":"subscribe","subscriptionId":"s"}) => "subscribe",
}.each do |line, expected_id|
  event = adapter_command_error(line)
  assert(event["id"].as_s == expected_id, "valid command ID was lost while reporting schema error")
end

assert(command_identifier({"id" => json("é" * 128)}, "id").size == 128, "128-character Unicode ID was rejected")

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
