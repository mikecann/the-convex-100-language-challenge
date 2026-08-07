require "base64"
require "http/web_socket"
require "socket"
require "../client"

def assert(condition : Bool, message : String)
  raise message unless condition
end

def timestamp(value : UInt64) : String
  bytes = Bytes.new(8)
  8.times { |index| bytes[index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
  Base64.strict_encode(bytes)
end

def version(timestamp_value : UInt64, query_set = 1)
  {"querySet" => query_set, "identity" => 0, "ts" => timestamp(timestamp_value)}
end

class SyncConnection
  getter socket : TCPSocket

  def initialize(@socket, upgrade : String? = "websocket", connection : String? = "Upgrade")
    @socket.read_timeout = 2.seconds
    parsed = HTTP::Request.from_io(@socket) || raise "missing WebSocket upgrade"
    request = parsed.as?(HTTP::Request) || raise "invalid WebSocket upgrade: #{parsed}"
    key = request.headers["Sec-WebSocket-Key"]
    @socket << "HTTP/1.1 101 Switching Protocols\r\n"
    @socket << "Connection: #{connection}\r\n" if connection
    @socket << "Upgrade: #{upgrade}\r\n" if upgrade
    @socket << "Sec-WebSocket-Accept: #{HTTP::WebSocket::Protocol.key_challenge(key)}\r\n\r\n"
    @socket.flush
    @protocol = HTTP::WebSocket::Protocol.new(@socket)
    @buffer = Bytes.new(16 * 1024)
  end

  def read_json : JSON::Any
    message = IO::Memory.new
    loop do
      info = @protocol.receive(@buffer)
      case info.opcode
      when .close?
        raise IO::EOFError.new("client closed")
      when .ping?
        @protocol.pong(@buffer[0, info.size])
      when .text?, .continuation?
        message.write(@buffer[0, info.size])
        return JSON.parse(message.to_s) if info.final
      end
    end
  end

  def send_json(value)
    @protocol.send(value.to_json)
  end

  def send_transition(start_ts : UInt64, end_ts : UInt64, modifications, start_query_set = 1)
    send_json({"type" => "Transition", "startVersion" => version(start_ts, start_query_set), "endVersion" => version(end_ts), "modifications" => modifications})
  end

  def send_fragmented_json(value)
    bytes = value.to_json.to_slice
    split = bytes.index! { |byte| byte >= 0x80_u8 }
    split += 1 # split inside the first multibyte UTF-8 scalar
    @protocol.send(bytes[0, split], HTTP::WebSocket::Protocol::Opcode::TEXT, flags: HTTP::WebSocket::Protocol::Flags::None)
    @protocol.ping("fixture-ping")
    @protocol.send(bytes[split..], HTTP::WebSocket::Protocol::Opcode::CONTINUATION)
  end

  def send_half_frame
    @socket.write(Bytes[0x81_u8, 126_u8, 0_u8, 32_u8, '{'.ord.to_u8])
    @socket.flush
  end

  def send_dribbling_frame
    # A 100-byte payload must use the short RFC 6455 length encoding. Using the
    # 16-bit form here would correctly fail immediately as a protocol error,
    # rather than exercising the absolute deadline for an incomplete frame.
    @socket.write(Bytes[0x81_u8, 100_u8])
    @socket.flush
    100.times do
      sleep 100.milliseconds
      @socket.write(Bytes['x'.ord.to_u8])
      @socket.flush
    end
  end

  # Send one valid frame with gaps longer than the old 250 ms socket timeout.
  # The client must preserve its incremental parser state until the absolute
  # frame deadline rather than retiring a healthy hosted-style connection.
  def send_slow_json(value)
    payload = value.to_json.to_slice
    header_size = payload.size <= 125 ? 2 : 4
    raise "slow fixture payload is unexpectedly large" if payload.size > UInt16::MAX
    frame = Bytes.new(header_size + payload.size)
    frame[0] = 0x81_u8
    if header_size == 2
      frame[1] = payload.size.to_u8
    else
      frame[1] = 126_u8
      frame[2] = ((payload.size >> 8) & 0xff).to_u8
      frame[3] = (payload.size & 0xff).to_u8
    end
    payload.each_with_index { |byte, index| frame[header_size + index] = byte }
    first = header_size + 3
    second = first + (frame.size - first) // 2
    @socket.write(frame[0, first])
    @socket.flush
    sleep 350.milliseconds
    @socket.write(frame[first, second - first])
    @socket.flush
    sleep 350.milliseconds
    @socket.write(frame[second, frame.size - second])
    @socket.flush
  end

  def ping
    @protocol.ping("flood")
  end

  # Protocol-negative fixtures need byte-exact encodings that the standard
  # WebSocket writer correctly refuses to generate for us.
  def send_raw_frame(frame : Bytes)
    @socket.write(frame)
    @socket.flush
  end

  # A debug-disconnect acknowledgement is meaningful only once the old
  # transport has been retired. Observe that retirement from the peer rather
  # than relying on a timing delay or a message sent on the replacement socket.
  def wait_closed
    loop do
      info = @protocol.receive(@buffer)
      case info.opcode
      when .close?
        return
      when .ping?
        @protocol.pong(@buffer[0, info.size])
      end
    end
  rescue ex : IO::TimeoutError
    raise ex
  rescue IO::EOFError | IO::Error
  end

  def close
    @socket.close rescue nil
  end

  def reset
    # Abortive close makes the next peer write fail instead of completing a
    # normal FIN handshake. The owner is paused immediately before Remove, so
    # this targets the write-failure path rather than the read loop.
    @socket.linger = 0
    @socket.close
  end
end

class SyncFixture
  getter url : String

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @url = "http://127.0.0.1:#{@server.local_address.port}"
  end

  def accept(upgrade : String? = "websocket", connection : String? = "Upgrade") : SyncConnection
    SyncConnection.new(@server.accept, upgrade, connection)
  end

  def close
    @server.close rescue nil
  end
end

def assert_handshake_rejected(upgrade : String?, connection : String?)
  fixture = SyncFixture.new
  spawn do
    peer = fixture.accept(upgrade, connection)
    peer.close
  rescue
  end
  begin
    socket = Convex::OwnerWebSocket.connect(URI.parse(fixture.url), "crystal-handshake-test")
    socket.close
    raise "invalid WebSocket upgrade was accepted"
  rescue Convex::TransportError
  ensure
    fixture.close
  end
end

def read_add(connection : SyncConnection)
  connect = connection.read_json
  raise "missing Connect" unless connect["type"].as_s == "Connect"
  modify = connection.read_json
  raise "missing Add replay" unless modify["type"].as_s == "ModifyQuerySet"
  add = modify["modifications"].as_a.first
  raise "missing Add" unless add["type"].as_s == "Add"
  {connect, add}
end

def count(update : Convex::Update) : Int32
  raise update.error.not_nil! if update.error
  update.value.not_nil!["count"].as_i
end

# `Subscription#next` exposes a bounded wait as a structured transport error.
# Keep the assertions below focused on the real contract, while turning an
# unrelated fixture exception into a clear failure instead of relying on a
# compiler-specific rescue narrowing rule.
def assert_no_update(subscription : Convex::Subscription, context : String)
  unexpected = subscription.next(100.milliseconds)
  raise "#{context}: #{unexpected.to_json}"
rescue ex
  timeout = ex.as?(Convex::TransportError)
  raise "#{context}: unexpected #{ex.class}: #{ex.message}" unless timeout
  assert(timeout.message == "timed out waiting for Live update", "#{context}: wrong error #{timeout.message}")
end

def assert_protocol_frame_recovery(frame : Bytes, label : String)
  fixture = SyncFixture.new
  spawn do
    first = fixture.accept
    read_add(first)
    first.send_raw_frame(frame)
    replacement = fixture.accept
    read_add(replacement)
    replacement.send_transition(0, 1, [{"type" => "QueryUpdated", "queryId" => 0, "value" => {"count" => 77}, "logLines" => [] of String}], 0)
  rescue ex
    STDERR.puts "fixture #{label} recovery failed: #{ex.message}"
  end
  client = Convex::Client.new(fixture.url)
  subscription = client.subscribe("demo:state", {"room" => JSON::Any.new(label)})
  failure = subscription.next(2.seconds).error
  assert(failure.is_a?(Convex::ProtocolError), "#{label} did not publish ProtocolError")
  assert(count(subscription.next(2.seconds)) == 77, "#{label} did not recover on a replacement socket")
  client.close
  fixture.close
end

# Numeric timestamp ordering must cross the little-endian rollover correctly.
assert(Convex.decode_live_timestamp(timestamp(255_u64)) == 255_u64, "timestamp 255 did not decode")
assert(Convex.decode_live_timestamp(timestamp(256_u64)) == 256_u64, "timestamp 256 did not decode")
assert(Convex.decode_live_timestamp(timestamp(256_u64)) > Convex.decode_live_timestamp(timestamp(255_u64)), "timestamp ordering was lexical")

begin
  Convex.decode_live_timestamp(Base64.strict_encode(Bytes[1, 2, 3]))
  raise "short timestamp was accepted"
rescue Convex::ProtocolError
end

# Upgrade values are case-insensitive tokens, and Connection may contain a
# comma-separated token list. Missing either required token must fail the 101.
fixture = SyncFixture.new
spawn do
  peer = fixture.accept("WebSocket", "keep-alive, uPgRaDe")
  peer.close
rescue
end
socket = Convex::OwnerWebSocket.connect(URI.parse(fixture.url), "crystal-handshake-test")
socket.close
fixture.close
assert_handshake_rejected("h2c", "Upgrade")
assert_handshake_rejected("websocket", "keep-alive")

# TCP progress must not renew the one DNS/TCP/TLS/101 budget. This peer accepts
# and consumes the upgrade request but never sends the 101 response.
stall_server = TCPServer.new("127.0.0.1", 0)
spawn do
  peer = stall_server.accept
  HTTP::Request.from_io(peer)
  sleep 2.seconds
rescue
end
stall_started = Time.monotonic
begin
  Convex::OwnerWebSocket.connect(URI.parse("http://127.0.0.1:#{stall_server.local_address.port}"), "crystal-stalled-101-test")
  raise "stalled WebSocket 101 was accepted"
rescue Convex::TransportError
end
stall_elapsed = Time.monotonic - stall_started
assert(stall_elapsed >= 400.milliseconds && stall_elapsed < 800.milliseconds, "stalled 101 did not use one absolute connect deadline: #{stall_elapsed}")
stall_server.close

# A resolver or TCP connect which never returns is isolated on its own OS
# thread. The owner still observes the one absolute budget and retires a late
# socket instead of waiting for that worker.
dial_entered = Channel(Nil).new(1)
dial_resume = Channel(Nil).new(1)
Convex::OwnerWebSocket.pause_next_dial(dial_entered, dial_resume)
dial_started = Time.monotonic
spawn do
  dial_entered.receive
  sleep 1.second
  dial_resume.send(nil)
end
begin
  Convex::OwnerWebSocket.connect(URI.parse("http://127.0.0.1:9"), "crystal-stalled-dial-test")
  raise "stalled resolver/TCP worker was accepted"
rescue Convex::TransportError
end
dial_elapsed = Time.monotonic - dial_started
assert(dial_elapsed >= 400.milliseconds && dial_elapsed < 800.milliseconds, "stalled resolver/TCP worker escaped the absolute connect deadline: #{dial_elapsed}")

# TCP may connect promptly while TLS itself never produces a handshake byte.
# Closing the raw descriptor at the shared deadline must interrupt OpenSSL.
tls_server = TCPServer.new("127.0.0.1", 0)
spawn do
  peer = tls_server.accept
  sleep 2.seconds
  peer.close
rescue
end
tls_started = Time.monotonic
begin
  Convex::OwnerWebSocket.connect(URI.parse("https://127.0.0.1:#{tls_server.local_address.port}"), "crystal-stalled-tls-test")
  raise "stalled TLS handshake was accepted"
rescue Convex::TransportError
end
tls_elapsed = Time.monotonic - tls_started
assert(tls_elapsed >= 400.milliseconds && tls_elapsed < 800.milliseconds, "stalled TLS handshake escaped the absolute connect deadline: #{tls_elapsed}")
tls_server.close

# The first Connect write belongs to that same absolute budget. Keep making
# real byte-by-byte TCP progress and prove it still expires instead of gaining
# a fresh timeout from every successful write.
fixture = SyncFixture.new
spawn do
  peer = fixture.accept
  sleep 2.seconds
  peer.close
rescue
end
slow_write_entered = Channel(Nil).new(1)
slow_write_started = Time.monotonic
slow_write_deadline = slow_write_started + Convex::OwnerWebSocket::CONNECT_DEADLINE
socket = Convex::OwnerWebSocket.connect(URI.parse(fixture.url), "crystal-slow-first-connect-test", slow_write_deadline)
Convex::OwnerWebSocket.slow_next_write(slow_write_entered)
begin
  socket.send_json({"type" => "Connect"}, slow_write_deadline)
  raise "slow first Connect frame was accepted"
rescue Convex::TransportError
end
slow_write_entered.receive
slow_write_elapsed = Time.monotonic - slow_write_started
assert(slow_write_elapsed >= 400.milliseconds && slow_write_elapsed < 800.milliseconds, "slow first Connect renewed its absolute deadline: #{slow_write_elapsed}")
socket.close
fixture.close

# The resolver/connect worker cannot own the sole manager fiber. Both control
# operations must interrupt a paused dial rather than wait for its full budget.
[:unsubscribe, :close].each do |control|
  fixture = SyncFixture.new
  dial_entered = Channel(Nil).new(1)
  dial_resume = Channel(Nil).new(1)
  Convex::OwnerWebSocket.pause_next_dial(dial_entered, dial_resume)
  client = Convex::Client.new(fixture.url)
  subscription = client.subscribe("demo:state", {"room" => JSON::Any.new("dial-#{control}")})
  dial_entered.receive
  started = Time.monotonic
  control == :close ? client.close : subscription.close
  assert(Time.monotonic - started < 250.milliseconds, "#{control} did not interrupt a paused Live dial")
  client.close unless control == :close
  dial_resume.send(nil)
  fixture.close
end

# Reject every strict RFC6455 boundary at the parser, then prove the active
# query recovers on a clean replacement connection.
assert_protocol_frame_recovery(Bytes[0xc1_u8, 0_u8], "reserved-rsv")
assert_protocol_frame_recovery(Bytes[0x81_u8, 0x80_u8], "masked-server-frame")
assert_protocol_frame_recovery(Bytes[0x83_u8, 0_u8], "reserved-opcode")
assert_protocol_frame_recovery(Bytes[0x80_u8, 0_u8], "unexpected-continuation")
assert_protocol_frame_recovery(Bytes[0x82_u8, 0_u8], "binary-frame")
assert_protocol_frame_recovery(Bytes[0x09_u8, 0_u8], "fragmented-control")
oversized_control = Bytes.new(4 + 126, 0_u8)
oversized_control[0] = 0x89_u8
oversized_control[1] = 126_u8
oversized_control[3] = 126_u8
assert_protocol_frame_recovery(oversized_control, "oversized-control")
assert_protocol_frame_recovery(Bytes[0x81_u8, 126_u8, 0_u8, 1_u8, 'x'.ord.to_u8], "non-minimal-16")
non_minimal_64 = Bytes.new(10 + 126, 'x'.ord.to_u8)
non_minimal_64[0] = 0x81_u8
non_minimal_64[1] = 127_u8
8.times { |index| non_minimal_64[2 + index] = ((126_u64 >> ((7 - index) * 8)) & 0xff_u64).to_u8 }
assert_protocol_frame_recovery(non_minimal_64, "non-minimal-64")
assert_protocol_frame_recovery(Bytes[0x88_u8, 1_u8, 0_u8], "one-byte-close")
assert_protocol_frame_recovery(Bytes[0x88_u8, 2_u8, 0x03_u8, 0xed_u8], "reserved-close-code")
assert_protocol_frame_recovery(Bytes[0x88_u8, 3_u8, 0x03_u8, 0xe8_u8, 0xff_u8], "invalid-close-utf8")

# Add, initial/external updates, QueryFailed recovery, and Remove all travel
# through the real owner and a loopback WebSocket rather than mocked methods.
fixture = SyncFixture.new
remove_seen = Channel(Bool).new(1)
advance = Channel(Nil).new
spawn do
  connection = fixture.accept
  read_add(connection)
  connection.send_transition(0, 1, [{"type" => "QueryUpdated", "queryId" => 0, "value" => {"count" => 0}, "logLines" => [] of String}], 0)
  advance.receive
  connection.send_transition(1, 2, [{"type" => "QueryUpdated", "queryId" => 0, "value" => {"count" => 1}, "logLines" => ["external"]}])
  advance.receive
  connection.send_transition(2, 3, [{"type" => "QueryFailed", "queryId" => 0, "errorMessage" => "room empty", "errorData" => {"code" => "ROOM_EMPTY"}, "logLines" => ["failed"]}])
  advance.receive
  connection.send_transition(3, 4, [{"type" => "QueryUpdated", "queryId" => 0, "value" => {"count" => 2}, "logLines" => ["recovered"]}])
  remove = connection.read_json
  remove_seen.send(remove["modifications"].as_a.first["type"].as_s == "Remove")
  connection.close
rescue ex
  STDERR.puts "fixture add/remove failed: #{ex.message}"
  remove_seen.send(false) rescue nil
end
client = Convex::Client.new(fixture.url)
subscription = client.subscribe("demo:state", {"room" => JSON::Any.new("fixture")})
assert(count(subscription.next(2.seconds)) == 0, "initial QueryUpdated was not delivered")
advance.send(nil)
external = subscription.next(2.seconds)
assert(count(external) == 1 && external.logs == ["external"], "external update was not delivered")
advance.send(nil)
failed = subscription.next(2.seconds)
error = failed.error.as?(Convex::FunctionError) || raise "QueryFailed was not structured"
assert(error.data.not_nil!["code"].as_s == "ROOM_EMPTY", "QueryFailed errorData was lost")
advance.send(nil)
assert(count(subscription.next(2.seconds)) == 2, "QueryFailed did not recover on the same subscription")
subscription.close
assert(remove_seen.receive, "Remove was not sent")
client.close
fixture.close

# A failed Remove used to retire the socket without marking the surviving
# subscription as rehydrating. Pause the owner immediately before that write,
# reset the raw peer, and prove the survivor replays without leaking its
# unchanged snapshot before a later external value.
fixture = SyncFixture.new
reset_peer = Channel(Nil).new(1)
reset_done = Channel(Nil).new(1)
replayed_survivor = Channel(Bool).new(1)
unchanged_sent = Channel(Nil).new(1)
send_external = Channel(Nil).new(1)
remove_after_recovery = Channel(Bool).new(1)
spawn do
  connection = fixture.accept
  _, first_add = read_add(connection)
  raise "wrong first Remove-failure query" unless first_add["queryId"].as_i == 0
  second_modify = connection.read_json
  second_add = second_modify["modifications"].as_a.first
  raise "missing second Remove-failure Add" unless second_add["type"].as_s == "Add" && second_add["queryId"].as_i == 1
  connection.send_transition(0, 1, [
    {"type" => "QueryUpdated", "queryId" => 0, "value" => {"count" => 0}, "logLines" => [] of String},
    {"type" => "QueryUpdated", "queryId" => 1, "value" => {"count" => 10}, "logLines" => [] of String},
  ], 0)

  reset_peer.receive
  connection.reset
  # The owner remains blocked on the explicit test barrier while the loopback
  # RST reaches its kernel. No read poll can consume the failure first.
  sleep 25.milliseconds
  reset_done.send(nil)

  replacement = fixture.accept
  connect = replacement.read_json
  modify = replacement.read_json
  modifications = modify["modifications"].as_a
  replayed_survivor.send(
    connect["connectionCount"].as_i == 1 &&
    modifications.size == 1 &&
    modifications.first["type"].as_s == "Add" &&
    modifications.first["queryId"].as_i == 1
  )
  replacement.send_transition(0, 1, [{"type" => "QueryUpdated", "queryId" => 1, "value" => {"count" => 10}, "logLines" => [] of String}], 0)
  unchanged_sent.send(nil)
  send_external.receive
  replacement.send_transition(1, 2, [{"type" => "QueryUpdated", "queryId" => 1, "value" => {"count" => 11}, "logLines" => ["external-after-remove-failure"]}])
  remove = replacement.read_json
  remove_after_recovery.send(remove["modifications"].as_a.first["type"].as_s == "Remove")
  replacement.close
rescue ex
  STDERR.puts "fixture Remove write failure failed: #{ex.message}"
  reset_done.send(nil) rescue nil
  replayed_survivor.send(false) rescue nil
  unchanged_sent.send(nil) rescue nil
  remove_after_recovery.send(false) rescue nil
end
client = Convex::Client.new(fixture.url)
removed = client.subscribe("demo:state", {"room" => JSON::Any.new("remove-write-failure-removed")})
survivor = client.subscribe("demo:state", {"room" => JSON::Any.new("remove-write-failure-survivor")})
assert(count(removed.next(2.seconds)) == 0, "removed query did not receive its initial value")
assert(count(survivor.next(2.seconds)) == 10, "surviving query did not receive its initial value")
remove_entered = Channel(Nil).new(1)
remove_resume = Channel(Nil).new(1)
remove_failed = Channel(Nil).new(1)
remove_closed = Channel(Nil).new(1)
spawn do
  removed.close_with_remove_pause(remove_entered, remove_resume, remove_failed)
  remove_closed.send(nil)
end
remove_entered.receive
reset_peer.send(nil)
reset_done.receive
remove_resume.send(nil)
select
when remove_failed.receive
when timeout(2.seconds)
  raise "raw peer did not force the Remove write-failure path"
end
remove_closed.receive
remove_error = survivor.next(2.seconds).error
assert(remove_error.is_a?(Convex::TransportError), "failed Remove did not publish TransportError to survivor")
assert(replayed_survivor.receive, "failed Remove did not reconnect and replay the surviving Add")
unchanged_sent.receive
assert_no_update(survivor, "unchanged Remove-failure rehydration was published")
send_external.send(nil)
external_after_remove = survivor.next(2.seconds)
assert(count(external_after_remove) == 11 && external_after_remove.logs == ["external-after-remove-failure"], "survivor did not recover after failed Remove")
survivor.close
assert(remove_after_recovery.receive, "survivor Remove was not sent after recovery")
client.close
fixture.close

# A real frame split by ordinary network latency must survive gaps above 250 ms.
fixture = SyncFixture.new
spawn do
  connection = fixture.accept
  read_add(connection)
  connection.send_slow_json({"type" => "Transition", "startVersion" => version(0, 0), "endVersion" => version(1), "modifications" => [{"type" => "QueryUpdated", "queryId" => 0, "value" => {"count" => 12}, "logLines" => [] of String}]})
rescue ex
  STDERR.puts "fixture slow-frame delivery failed: #{ex.message}"
end
client = Convex::Client.new(fixture.url)
subscription = client.subscribe("demo:state", {"room" => JSON::Any.new("slow-frame")})
assert(count(subscription.next(3.seconds)) == 12, "slow valid frame crossed the absolute deadline")
client.close
fixture.close

# Five actual TCP/WebSocket reconnects must replay the active Add. Each new
# connection first rehydrates the unchanged value and then advances it once.
fixture = SyncFixture.new
observed_connects = Channel(JSON::Any).new(6)
retired = Channel(Nil).new(5)
rehydrated = Channel(Nil).new(5)
external_update = Channel(Nil).new(5)
spawn do
  previous = 0
  connection = fixture.accept
  6.times do |index|
    connect, add = read_add(connection)
    raise "wrong replayed query" unless add["queryId"].as_i == 0
    observed_connects.send(connect)
    if index == 0
      connection.send_transition(0, 1, [{"type" => "QueryUpdated", "queryId" => 0, "value" => {"count" => 0}, "logLines" => [] of String}], 0)
    else
      connection.send_transition(0, 1, [{"type" => "QueryUpdated", "queryId" => 0, "value" => {"count" => previous}, "logLines" => [] of String}], 0)
      rehydrated.send(nil)
      external_update.receive
      connection.send_transition(1, 2, [{"type" => "QueryUpdated", "queryId" => 0, "value" => {"count" => index}, "logLines" => [] of String}])
      previous = index
    end
    if index < 5
      connection.wait_closed
      retired.send(nil)
      connection = fixture.accept
    end
  end
rescue ex
  STDERR.puts "fixture reconnect failed: #{ex.message}"
  observed_connects.close rescue nil
  retired.close rescue nil
  rehydrated.close rescue nil
  external_update.close rescue nil
end
client = Convex::Client.new(fixture.url)
subscription = client.subscribe("demo:state", {"room" => JSON::Any.new("reconnect")})
initial_connect = observed_connects.receive
assert(initial_connect["connectionCount"].as_i == 0, "initial connectionCount was not zero")
assert(!initial_connect["maxObservedTimestamp"]?, "initial Connect sent a zero maxObservedTimestamp")
assert(count(subscription.next(2.seconds)) == 0, "initial reconnect value was not zero")
5.times do |attempt|
  client.debug_disconnect
  retired.receive
  connect = observed_connects.receive
  assert(connect["connectionCount"].as_i == attempt + 1, "connectionCount did not advance")
  assert(connect["lastCloseReason"].as_s == "DebugDisconnect", "debug close reason was not retained")
  expected_max = attempt == 0 ? timestamp(1) : timestamp(2)
  assert(connect["maxObservedTimestamp"].as_s == expected_max, "maxObservedTimestamp was not retained numerically")
  rehydrated.receive
  assert_no_update(subscription, "unchanged rehydration crossed reconnect acknowledgement")
  external_update.send(nil)
  assert(count(subscription.next(2.seconds)) == attempt + 1, "unchanged rehydration crossed reconnect acknowledgement")
end
subscription.close
client.close
fixture.close

# Fragmented UTF-8 with an interleaved ping must assemble into one valid JSON
# message while the owner preserves message state across complete frames.
fixture = SyncFixture.new
spawn do
  connection = fixture.accept
  read_add(connection)
  transition = {"type" => "Transition", "startVersion" => version(0, 0), "endVersion" => version(1), "modifications" => [{"type" => "QueryUpdated", "queryId" => 0, "value" => {"count" => 7, "label" => "café"}, "logLines" => [] of String}]}
  connection.send_fragmented_json(transition)
end
client = Convex::Client.new(fixture.url)
subscription = client.subscribe("demo:state", {"room" => JSON::Any.new("utf8")})
utf8 = subscription.next(2.seconds)
assert(count(utf8) == 7 && utf8.value.not_nil!["label"].as_s == "café", "fragmented UTF-8/control frame failed")
client.close
fixture.close

# A stalled partial frame must be abandoned with its socket. The active Add is
# then replayed on a new connection and a valid value can still be delivered.
fixture = SyncFixture.new
spawn do
  first = fixture.accept
  read_add(first)
  spawn do
    first.send_dribbling_frame
  rescue IO::Error
  end
  second = fixture.accept
  read_add(second)
  second.send_transition(0, 1, [{"type" => "QueryUpdated", "queryId" => 0, "value" => {"count" => 9}, "logLines" => [] of String}], 0)
rescue ex
  STDERR.puts "fixture half-frame recovery failed: #{ex.message}"
end
client = Convex::Client.new(fixture.url)
subscription = client.subscribe("demo:state", {"room" => JSON::Any.new("half-recovery")})
deadline_started = Time.monotonic
transport = subscription.next(7.seconds).error
assert(transport.is_a?(Convex::TransportError), "partial frame did not publish TransportError")
deadline_elapsed = Time.monotonic - deadline_started
assert(deadline_elapsed >= 4.seconds && deadline_elapsed < 7.seconds, "partial frame did not use one bounded absolute deadline: #{deadline_elapsed}")
assert(count(subscription.next(3.seconds)) == 9, "partial-frame reconnect did not recover")
client.close
fixture.close

# Protocol failures are structured too, and retiring the bad connection must
# not strand an otherwise valid active subscription.
fixture = SyncFixture.new
spawn do
  first = fixture.accept
  read_add(first)
  first.send_json({"type" => "UnknownFixtureMessage"})
  second = fixture.accept
  read_add(second)
  second.send_transition(0, 1, [{"type" => "QueryUpdated", "queryId" => 0, "value" => {"count" => 10}, "logLines" => [] of String}], 0)
rescue ex
  STDERR.puts "fixture protocol recovery failed: #{ex.message}"
end
client = Convex::Client.new(fixture.url)
subscription = client.subscribe("demo:state", {"room" => JSON::Any.new("protocol-recovery")})
protocol = subscription.next(2.seconds).error
assert(protocol.is_a?(Convex::ProtocolError), "invalid message did not publish ProtocolError")
assert(count(subscription.next(2.seconds)) == 10, "protocol reconnect did not recover")
client.close
fixture.close

def assert_bounded_control(mode : Symbol)
  fixture = SyncFixture.new
  ready = Channel(Bool).new(1)
  spawn do
    connection = fixture.accept
    read_add(connection)
    ready.send(true)
    case mode
    when :idle
      sleep 2.seconds
    when :flood
      loop do
        connection.ping
      end
    when :half
      connection.send_half_frame
      sleep 2.seconds
    end
  rescue
  end
  client = Convex::Client.new(fixture.url)
  subscription = client.subscribe("demo:state", {"room" => JSON::Any.new(mode.to_s)})
  ready.receive
  started = Time.monotonic
  subscription.close
  unsubscribe_elapsed = Time.monotonic - started
  assert(unsubscribe_elapsed < 1.second, "#{mode} peer made unsubscribe take #{unsubscribe_elapsed}")
  started = Time.monotonic
  client.close
  close_elapsed = Time.monotonic - started
  assert(close_elapsed < 1.second, "#{mode} peer made close take #{close_elapsed}")
  fixture.close
end

assert_bounded_control(:idle)
assert_bounded_control(:flood)
assert_bounded_control(:half)

# Two callers racing close must join one owner transition. The second caller
# must neither enqueue an unacknowledgeable command nor return before the first
# close has actually retired the transport.
fixture = SyncFixture.new
ready = Channel(Nil).new(1)
spawn do
  connection = fixture.accept
  read_add(connection)
  ready.send(nil)
  sleep 2.seconds
rescue
end
client = Convex::Client.new(fixture.url)
client.subscribe("demo:state", {"room" => JSON::Any.new("concurrent-close")})
ready.receive
close_entered = Channel(Nil).new(1)
close_resume = Channel(Nil).new(1)
Convex::LiveManager.pause_next_close(close_entered, close_resume)
closed = Channel(Int32).new(2)
2.times do |index|
  spawn do
    client.close
    closed.send(index)
  end
end
close_entered.receive
select
when early = closed.receive
  raise "concurrent close caller #{early} returned before transport retirement"
else
end
close_resume.send(nil)
2.times do
  select
  when closed.receive
  when timeout(1.second)
    raise "concurrent close caller was stranded"
  end
end
fixture.close

# Count and bytes are both aggregate limits, independent of one subscription.
budget = Convex::LiveUpdateBudget.new
128.times { assert(budget.reserve(1), "aggregate event budget ended early") }
assert(!budget.reserve(1), "aggregate event-count budget was not enforced")
budget.release(128, 128)
assert(budget.reserve(16 * 1024 * 1024), "aggregate byte budget rejected its boundary")
assert(!budget.reserve(1), "aggregate byte budget was not enforced")

puts "crystal live deterministic fixtures passed"
