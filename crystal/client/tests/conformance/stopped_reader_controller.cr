require "json"
require "socket"
require "http/server"

# Serve large schema-valid query results from this controller container. A
# 256 KiB value fills a stopped TCP receive window while still allowing all 17
# commands and the terminal close to reach the output queue before its one
# second deadline on a CPU-throttled verifier.
payload = "x" * 256_000
request_lock = Mutex.new
request_count = 0
server = HTTP::Server.new do |context|
  complete = request_lock.synchronize do
    request_count += 1
    request_count == 17
  end
  context.response.content_type = "application/json"
  context.response.print({"status" => "success", "value" => {"payload" => payload}, "logLines" => [] of String}.to_json)
  if complete
    puts "REQUESTS=17"
    STDOUT.flush
  end
end
server.bind_tcp("0.0.0.0", 8080)
spawn { server.listen }

host = ENV.fetch("ADAPTER_HOST", "adapter")
port = ENV.fetch("ADAPTER_PORT", "9000").to_i
socket = TCPSocket.new(host, port)
socket.write_timeout = 5.seconds
socket.read_timeout = 10.seconds

# Fill all 17 ordinary output reservations with schema-valid large results,
# then submit close into its separate terminal slot. This controller never
# reads again. The fixture therefore cannot pass because a cooperative reader
# eventually drained the socket after a timed sleep.
17.times do |index|
  socket.puts({"id" => "result-#{index}", "op" => "query", "path" => "demo:large", "args" => {} of String => String}.to_json)
end
socket.puts({"id" => "close", "op" => "close"}.to_json)
socket.flush
puts "STOPPED"
STDOUT.flush
loop { sleep 1.second }
