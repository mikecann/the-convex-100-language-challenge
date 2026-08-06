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

  def initialize(@socket)
    @socket.read_timeout = 2.seconds
    parsed = HTTP::Request.from_io(@socket) || raise "missing WebSocket upgrade"
    request = parsed.as?(HTTP::Request) || raise "invalid WebSocket upgrade: #{parsed}"
    key = request.headers["Sec-WebSocket-Key"]
    @socket << "HTTP/1.1 101 Switching Protocols\r\n"
    @socket << "Connection: Upgrade\r\n"
    @socket << "Upgrade: websocket\r\n"
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

  def ping
    @protocol.ping("flood")
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
end

class SyncFixture
  getter url : String

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @url = "http://127.0.0.1:#{@server.local_address.port}"
  end

  def accept : SyncConnection
    SyncConnection.new(@server.accept)
  end

  def close
    @server.close rescue nil
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

# Numeric timestamp ordering must cross the little-endian rollover correctly.
assert(Convex.decode_live_timestamp(timestamp(255_u64)) == 255_u64, "timestamp 255 did not decode")
assert(Convex.decode_live_timestamp(timestamp(256_u64)) == 256_u64, "timestamp 256 did not decode")
assert(Convex.decode_live_timestamp(timestamp(256_u64)) > Convex.decode_live_timestamp(timestamp(255_u64)), "timestamp ordering was lexical")

begin
  Convex.decode_live_timestamp(Base64.strict_encode(Bytes[1, 2, 3]))
  raise "short timestamp was accepted"
rescue Convex::ProtocolError
end

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
  begin
    unexpected = subscription.next(100.milliseconds)
    raise "unchanged rehydration crossed reconnect acknowledgement: #{unexpected.to_json}"
  rescue ex : Convex::TransportError
    raise ex unless ex.message == "timed out waiting for Live update"
  end
  external_update.send(nil)
  assert(count(subscription.next(2.seconds)) == attempt + 1, "unchanged rehydration crossed reconnect acknowledgement")
end
subscription.close
client.close
fixture.close

# Fragmented UTF-8 with an interleaved ping must assemble into one valid JSON
# message. Crystal's protocol reports continuations using the original opcode.
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
  first.send_half_frame
  second = fixture.accept
  read_add(second)
  second.send_transition(0, 1, [{"type" => "QueryUpdated", "queryId" => 0, "value" => {"count" => 9}, "logLines" => [] of String}], 0)
rescue ex
  STDERR.puts "fixture half-frame recovery failed: #{ex.message}"
end
client = Convex::Client.new(fixture.url)
subscription = client.subscribe("demo:state", {"room" => JSON::Any.new("half-recovery")})
transport = subscription.next(2.seconds).error
assert(transport.is_a?(Convex::TransportError), "partial frame did not publish TransportError")
assert(count(subscription.next(2.seconds)) == 9, "partial-frame reconnect did not recover")
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

# Count and bytes are both aggregate limits, independent of one subscription.
budget = Convex::LiveUpdateBudget.new
128.times { assert(budget.reserve(1), "aggregate event budget ended early") }
assert(!budget.reserve(1), "aggregate event-count budget was not enforced")
budget.release(128, 128)
assert(budget.reserve(16 * 1024 * 1024), "aggregate byte budget rejected its boundary")
assert(!budget.reserve(1), "aggregate byte budget was not enforced")

puts "crystal live deterministic fixtures passed"
