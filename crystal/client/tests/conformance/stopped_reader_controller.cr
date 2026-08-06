require "json"
require "socket"
require "http/server"

# Serve schema-valid near-maximum query results from this controller container.
# The adapter therefore performs its real HTTP decode and NDJSON encode paths;
# the memory proof does not depend on an oversized protocol id.
payload = "x" * 1_900_000
server = HTTP::Server.new do |context|
  context.response.content_type = "application/json"
  context.response.print({"status" => "success", "value" => {"payload" => payload}, "logLines" => [] of String}.to_json)
end
server.bind_tcp("0.0.0.0", 8080)
spawn { server.listen }

host = ENV.fetch("ADAPTER_HOST", "adapter")
port = ENV.fetch("ADAPTER_PORT", "9000").to_i
socket = TCPSocket.new(host, port)
socket.write_timeout = 5.seconds
socket.read_timeout = 10.seconds

# The controller stops reading while two large valid commands are already on
# the connection, so exact ordering and output backpressure are both exercised.
socket.puts({"id" => "first", "op" => "query", "path" => "demo:large", "args" => {} of String => String}.to_json)
socket.puts({"id" => "second", "op" => "query", "path" => "demo:large", "args" => {} of String => String}.to_json)
socket.flush
puts "STOPPED"
STDOUT.flush
sleep 8.seconds

first = JSON.parse(socket.gets || raise "adapter closed before first result")
second = JSON.parse(socket.gets || raise "adapter closed before second result")
raise "large output lost ordering" unless first["id"].as_s == "first" && first["type"].as_s == "result"
raise "first large value was truncated" unless first["value"]["payload"].as_s.bytesize == payload.bytesize
raise "second output lost ordering" unless second["id"].as_s == "second" && second["type"].as_s == "result"
raise "second large value was truncated" unless second["value"]["payload"].as_s.bytesize == payload.bytesize

socket.puts({"id" => "close", "op" => "close"}.to_json)
socket.flush
closed = JSON.parse(socket.gets || raise "adapter closed without envelope")
raise "close envelope was not retained" unless closed["id"].as_s == "close" && closed["type"].as_s == "closed"
server.close
puts "stopped-reader ordering passed"
