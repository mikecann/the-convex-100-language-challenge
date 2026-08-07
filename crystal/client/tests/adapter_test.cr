require "./conformance/adapter"
require "http/server"

def assert(condition : Bool, message : String)
  raise message unless condition
end

def stale_barrier(label : String)
  output = IO::Memory.new
  writer = AdapterOutput.new(output)
  relay = SubscriptionRelay.new
  entered = Channel(Nil).new(1)
  resume = Channel(Nil).new(1)
  relay.pause_after_dequeue(entered, resume)
  done = Channel(Nil).new(1)
  spawn do
    relay.emit(writer, {"type" => json("subscription"), "subscriptionId" => json(label), "value" => JSON.parse(%({"count":0}))})
    done.send(nil)
  end
  entered.receive
  relay.invalidate
  emit_event(writer, {"id" => json(label), "type" => json("ack")}, wait: true)
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
  when "demo:malformed-json"
    context.response.print(%({"status":))
  when "demo:non-object"
    context.response.print(%(["success"]))
  when "demo:missing-status"
    context.response.print(%({"value":{"count":3},"logLines":[]}))
  when "demo:wrong-status-type"
    context.response.print(%({"status":1,"value":{"count":4},"logLines":[]}))
  when "demo:missing-value"
    context.response.print(%({"status":"success","logLines":[]}))
  when "demo:wrong-logs-type"
    context.response.print(%({"status":"success","value":{"count":5},"logLines":"not-an-array"}))
  when "demo:missing-error-message"
    context.response.print(%({"status":"error","errorData":{"code":"MISSING"},"logLines":[]}))
  when "demo:wrong-error-message-type"
    context.response.print(%({"status":"error","errorMessage":false,"errorData":{"code":"WRONG_TYPE"},"logLines":[]}))
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

{
  "demo:malformed-json"           => "invalid Convex response JSON",
  "demo:non-object"               => "Convex response must be an object",
  "demo:missing-status"           => "Convex response is missing status",
  "demo:wrong-status-type"        => "Convex response status must be a string",
  "demo:missing-value"            => "Convex success response is missing value",
  "demo:wrong-logs-type"          => "Convex response logLines must be an array of strings",
  "demo:missing-error-message"    => "Convex response is missing errorMessage",
  "demo:wrong-error-message-type" => "Convex response errorMessage must be a string",
}.each do |path, expected_message|
  begin
    http_client.query(path)
    raise "invalid HTTP protocol envelope was accepted: #{path}"
  rescue ex : Convex::ProtocolError
    assert(ex.message == expected_message, "HTTP protocol error taxonomy was not exact for #{path}: #{ex.message}")
  end
  assert(http_client.query("demo:success").value["count"].as_i == 1, "HTTP client did not recover after protocol error #{path}")
end
http_client.close

input = IO::Memory.new(%({"protocolVersion":1,"id":"hello","op":"hello"}\n{"id":"result","op":"query","path":"demo:success","args":{}}\n{"id":"function","op":"query","path":"demo:failure","args":{}}\n{"id":"bad","op":"unknown"}\n{"id":"close","op":"close"}\n))
output = IO::Memory.new
ENV["CONVEX_URL"] = "http://127.0.0.1:#{address.port}"
run_adapter(input, output)
expected = %(\
{"protocolVersion":1,"id":"hello","type":"ready","language":"crystal","implementation":"native-crystal-#{Crystal::VERSION}","runtime":"crystal-#{Crystal::VERSION}"}
{"id":"result","type":"result","value":{"count":1}}
{"id":"function","type":"error","error":{"name":"FunctionError","message":"failed","operation":"query","data":{"code":"BROKEN"},"logs":["server-log"]}}
{"id":"bad","type":"error","error":{"name":"ProtocolError","message":"unknown adapter operation"}}
{"id":"close","type":"closed"}
)
assert(output.to_s == expected, "adapter success/error/close envelopes were not exact:\n#{output}")

# Run every successful-HTTP but invalid-protocol body through the real adapter.
# Each malformed envelope must serialize as ProtocolError, and a valid query
# immediately after it proves the same adapter/client remains usable.
protocol_input = IO::Memory.new
protocol_paths = [
  "demo:malformed-json",
  "demo:non-object",
  "demo:missing-status",
  "demo:wrong-status-type",
  "demo:missing-value",
  "demo:wrong-logs-type",
  "demo:missing-error-message",
  "demo:wrong-error-message-type",
]
protocol_paths.each_with_index do |path, index|
  protocol_input.puts({"id" => "protocol-#{index}", "op" => "query", "path" => path, "args" => {} of String => String}.to_json)
  protocol_input.puts({"id" => "recovery-#{index}", "op" => "query", "path" => "demo:success", "args" => {} of String => String}.to_json)
end
protocol_input.puts({"id" => "protocol-close", "op" => "close"}.to_json)
protocol_input.rewind
protocol_output = IO::Memory.new
run_adapter(protocol_input, protocol_output)
protocol_events = protocol_output.to_s.lines.map { |line| JSON.parse(line) }
assert(protocol_events.size == protocol_paths.size * 2 + 1, "HTTP protocol adapter fixture emitted the wrong event count")
protocol_paths.each_index do |index|
  error = protocol_events[index * 2]
  recovery = protocol_events[index * 2 + 1]
  assert(error["id"].as_s == "protocol-#{index}" && error["type"].as_s == "error", "HTTP protocol adapter error lost correlation")
  assert(error["error"]["name"].as_s == "ProtocolError" && error["error"]["operation"].as_s == "query", "HTTP protocol violation was flattened by the adapter")
  assert(recovery["id"].as_s == "recovery-#{index}" && recovery["type"].as_s == "result" && recovery["value"]["count"].as_i == 1, "adapter did not recover after HTTP protocol violation")
end
assert(protocol_events.last["id"].as_s == "protocol-close" && protocol_events.last["type"].as_s == "closed", "protocol fixture close envelope was not exact")
server.close

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
  %({"id":"extra","op":"close","unexpected":true})                     => "extra",
  %({"id":"op-type","op":3})                                           => "op-type",
  %({"id":"version","op":"hello","protocolVersion":1.0})               => "version",
  %({"id":"path","op":"query","path":" ","args":{}})                   => "path",
  %({"id":"args","op":"query","path":"demo:state","args":[]})          => "args",
  %({"id":"token","op":"setAuth","token":false})                       => "token",
  %({"id":"sid","op":"unsubscribe","subscriptionId":" "})              => "sid",
  %({"id":"u-path","op":"unsubscribe","subscriptionId":"s","path":7})  => "u-path",
  %({"id":"u-args","op":"unsubscribe","subscriptionId":"s","args":[]}) => "u-args",
  %({"id":"subscribe","op":"subscribe","subscriptionId":"s"})          => "subscribe",
}.each do |line, expected_id|
  event = adapter_command_error(line)
  assert(event["id"].as_s == expected_id, "valid command ID was lost while reporting schema error")
end

assert(command_identifier({"id" => json("é" * 128)}, "id").size == 128, "128-character Unicode ID was rejected")

# Unsubscribe's optional path is informational in the shared schema. Empty and
# one-character strings are valid there even though query/subscribe paths must
# still name a real Convex function.
validate_command(JSON.parse(%({"id":"u","op":"unsubscribe","subscriptionId":"s","path":""})).as_h, "unsubscribe")
validate_command(JSON.parse(%({"id":"u","op":"unsubscribe","subscriptionId":"s","path":"x"})).as_h, "unsubscribe")

subscription_output = IO::Memory.new
subscription_writer = AdapterOutput.new(subscription_output)
SubscriptionRelay.new.emit(subscription_writer, {"type" => json("subscription"), "subscriptionId" => json("s"), "error" => error_details(Convex::FunctionError.new("failed", "query", JSON.parse(%({"code":"ROOM_EMPTY"})), ["log"]))})
subscription_writer.emit({"id" => json("flush"), "type" => json("ack")}, wait: true)
subscription_text = subscription_output.to_s.lines.first + "\n"
assert(subscription_text == %({"type":"subscription","subscriptionId":"s","error":{"name":"FunctionError","message":"failed","operation":"query","data":{"code":"ROOM_EMPTY"},"logs":["log"]}}\n), "subscription error envelope was not exact")

subscription_output = IO::Memory.new
subscription_writer = AdapterOutput.new(subscription_output)
SubscriptionRelay.new.emit(subscription_writer, {"type" => json("subscription"), "subscriptionId" => json("s"), "value" => JSON.parse(%({"count":1}))})
subscription_writer.emit({"id" => json("flush"), "type" => json("ack")}, wait: true)
subscription_text = subscription_output.to_s.lines.first + "\n"
assert(subscription_text == %({"type":"subscription","subscriptionId":"s","value":{"count":1}}\n), "subscription success envelope did not omit absent fields")

oversized = {"id" => json("large"), "type" => json("result"), "value" => json("x" * OUTPUT_MAX_LINE_BYTES)}
begin
  emit_event(AdapterOutput.new(IO::Memory.new), oversized)
  raise "oversized adapter event was accepted"
rescue Convex::ProtocolError
end

assert(OUTPUT_MAX_EVENTS == 17, "direct output count budget changed")
assert(OUTPUT_MAX_RETAINED_BYTES == 51 * 1024 * 1024, "conservative output byte budget changed")

class PermanentlyStoppedOutput < IO
  getter entered : Channel(Nil)

  def initialize
    @entered = Channel(Nil).new(1)
    @closed = Channel(Nil).new(1)
    @announced = false
  end

  def read(slice : Bytes) : Int32
    0
  end

  def write(slice : Bytes) : Nil
    unless @announced
      @announced = true
      @entered.send(nil)
    end
    @closed.receive
    raise IO::Error.new("stopped output closed")
  end

  def close
    select
    when @closed.send(nil)
    else
    end
  end
end

# Fill every data reservation with near-maximum schema-valid results while the
# controller never reads a byte. The terminal close still owns its independent
# admission slot, every retained byte stays charged through the partial write,
# and the one cumulative deadline releases the whole queue without a reader.
stopped = PermanentlyStoppedOutput.new
stopped_writer = AdapterOutput.new(stopped)
near_payload = "x" * (OUTPUT_MAX_LINE_BYTES - 128)
near_event = {"id" => json("near"), "type" => json("result"), "value" => json(near_payload)}
OUTPUT_MAX_EVENTS.times { stopped_writer.emit(near_event) }
stopped.entered.receive
events, retained_bytes, terminal = stopped_writer.budget.retained
assert(events == OUTPUT_MAX_EVENTS && retained_bytes > 50 * 1024 * 1024 && !terminal, "near-maximum output reservations were not retained")
begin
  stopped_writer.emit(near_event)
  raise "output event-count ceiling was not enforced"
rescue Convex::TransportError
end

terminal_done = Channel(Nil).new(1)
spawn do
  begin
    stopped_writer.emit({"id" => json("close"), "type" => json("closed")}, terminal: true, wait: true)
  rescue
  ensure
    terminal_done.send(nil)
  end
end
10.times do
  break if stopped_writer.budget.retained[2]
  Fiber.yield
end
assert(stopped_writer.budget.retained[2], "terminal close did not retain its reserved admission slot")
started = Time.monotonic
select
when terminal_done.receive
  assert(stopped_writer.transport_failed?, "stopped controller did not fail with TransportError")
when timeout(1.second)
  raise "permanently stopped controller stranded terminal close"
end
assert(Time.monotonic - started < 1.second, "adapter output exceeded its cumulative deadline")
100.times do
  break if stopped_writer.budget.retained == {0, 0, false}
  Fiber.yield
end
assert(stopped_writer.budget.retained == {0, 0, false}, "adapter output reservations were not fully released")
puts "crystal adapter deterministic fixtures passed"
