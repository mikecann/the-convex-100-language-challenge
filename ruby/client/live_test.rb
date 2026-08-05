# frozen_string_literal: true

require "base64"
require "digest/sha1"
require "json"
require "minitest/autorun"
require "socket"
require "timeout"

require_relative "convex"

# A tiny test peer speaks enough RFC 6455 to exercise the real Live manager.
# It deliberately lives in the test file and is not part of the client.
class FakeSyncServer
  GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  attr_reader :url

  def initialize(&handler)
    @handler = handler
    @server = TCPServer.new("127.0.0.1", 0)
    @url = "http://127.0.0.1:#{@server.local_address.ip_port}"
    @thread = Thread.new { @handler.call(self) }
  end

  def accept
    socket = @server.accept
    request_line = socket.gets("\r\n")
    raise "unexpected WebSocket path: #{request_line}" unless request_line&.include?(" /api/sync ")

    headers = {}
    while (line = socket.gets("\r\n")) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.strip
    end
    accept = Base64.strict_encode64(Digest::SHA1.digest(headers.fetch("sec-websocket-key") + GUID))
    socket.write(
      "HTTP/1.1 101 Switching Protocols\r\n" \
      "Upgrade: websocket\r\n" \
      "Connection: Upgrade\r\n" \
      "Sec-WebSocket-Accept: #{accept}\r\n\r\n"
    )
    socket
  end

  def read_json(socket)
    first, second = socket.read(2).bytes
    raise "expected a final text frame" unless first == 0x81
    raise "client frame was not masked" if (second & 0x80).zero?

    length = second & 0x7f
    length = socket.read(2).unpack1("n") if length == 126
    length = socket.read(8).unpack1("Q>") if length == 127
    mask = socket.read(4)
    payload = socket.read(length)
    decoded = payload.bytes.each_with_index.map do |byte, index|
      byte ^ mask.getbyte(index % 4)
    end.pack("C*")
    JSON.parse(decoded)
  end

  def write_json(socket, value)
    payload = JSON.generate(value)
    header = [0x81]
    encoded_length = if payload.bytesize < 126
                       [payload.bytesize].pack("C")
                     elsif payload.bytesize <= 0xffff
                       [126, payload.bytesize].pack("Cn")
                     else
                       [127, payload.bytesize].pack("CQ>")
                     end
    socket.write(header.pack("C") + encoded_length + payload)
  end

  def transition(start_query_set:, end_query_set:, start_ts:, end_ts:, query_id:, count:)
    {
      "type" => "Transition",
      "startVersion" => { "querySet" => start_query_set, "identity" => 0, "ts" => start_ts },
      "endVersion" => { "querySet" => end_query_set, "identity" => 0, "ts" => end_ts },
      "modifications" => [
        {
          "type" => "QueryUpdated",
          "queryId" => query_id,
          "value" => { "count" => count },
          "logLines" => []
        }
      ]
    }
  end

  def close
    @server.close
    Timeout.timeout(2) { @thread.join }
    raise @thread[:error] if @thread[:error]
  rescue IOError, Errno::EBADF
    Timeout.timeout(2) { @thread.join }
  end

  def record_error(error)
    @thread[:error] = error
  end
end

class ConvexLiveManagerTest < Minitest::Test
  def teardown
    @client&.close
    @server&.close
  end

  def test_initial_update_later_update_and_unsubscribe
    continue = Queue.new
    removed = Queue.new
    @server = FakeSyncServer.new do |server|
      socket = server.accept
      connect = server.read_json(socket)
      add = server.read_json(socket)
      query_id = add.dig("modifications", 0, "queryId")
      raise "missing Connect" unless connect["type"] == "Connect"
      raise "missing query Add" unless add.dig("modifications", 0, "type") == "Add"

      server.write_json(
        socket,
        server.transition(
          start_query_set: 0,
          end_query_set: 1,
          start_ts: "AAAAAAAAAAA=",
          end_ts: "AQAAAAAAAAA=",
          query_id: query_id,
          count: 0
        )
      )
      continue.pop
      server.write_json(
        socket,
        server.transition(
          start_query_set: 1,
          end_query_set: 1,
          start_ts: "AQAAAAAAAAA=",
          end_ts: "AgAAAAAAAAA=",
          query_id: query_id,
          count: 1
        )
      )
      remove = server.read_json(socket)
      removed << remove.dig("modifications", 0, "type")
      socket.close
    rescue StandardError => error
      server.record_error(error)
    end

    @client = Convex::Client.new(@server.url)
    subscription = @client.subscribe("demo:state", "room" => "unit")
    assert_equal 0, subscription.next_update(timeout: 2).value.fetch("count")
    continue << true
    assert_equal 1, subscription.next_update(timeout: 2).value.fetch("count")
    subscription.close
    assert_equal "Remove", Timeout.timeout(2) { removed.pop }
  end

  def test_reconnect_rebuilds_active_query_set
    @server = FakeSyncServer.new do |server|
      2.times do |index|
        socket = server.accept
        connect = server.read_json(socket)
        add = server.read_json(socket)
        query_id = add.dig("modifications", 0, "queryId")
        raise "wrong reconnect count" unless connect["connectionCount"] == index

        timestamp = index.zero? ? "AQAAAAAAAAA=" : "AgAAAAAAAAA="
        server.write_json(
          socket,
          server.transition(
            start_query_set: 0,
            end_query_set: 1,
            start_ts: "AAAAAAAAAAA=",
            end_ts: timestamp,
            query_id: query_id,
            count: index + 1
          )
        )
        socket.close if index.zero?
      end
    rescue StandardError => error
      server.record_error(error)
    end

    @client = Convex::Client.new(@server.url)
    subscription = @client.subscribe("demo:state", "room" => "reconnect")
    assert_equal 1, subscription.next_update(timeout: 2).value.fetch("count")
    assert_equal 2, subscription.next_update(timeout: 3).value.fetch("count")
    subscription.close
  end

  def test_bounded_subscription_queue_has_no_stale_timeout_signal
    manager = Object.new
    manager.define_singleton_method(:unsubscribe) { |_query_id| nil }
    subscription = Convex::Subscription.new(manager, 7)

    # Seventeen rapid values overflow the sixteen-value buffer. Reactive state
    # keeps the newest sixteen values and drops only the oldest one.
    17.times do |count|
      subscription.deliver(Convex::Update.new({ "count" => count }, nil, []))
    end
    observed = 16.times.map { subscription.next_update(timeout: 0.1).value.fetch("count") }
    assert_equal((1..16).to_a, observed)

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(Convex::TransportError) { subscription.next_update(timeout: 0.05) }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    assert_operator elapsed, :<, 0.5
  ensure
    subscription&.close
  end

  def test_subscription_close_is_harmless_after_client_shutdown
    @server = FakeSyncServer.new do |server|
      socket = server.accept
      server.read_json(socket)
      add = server.read_json(socket)
      query_id = add.dig("modifications", 0, "queryId")
      server.write_json(
        socket,
        server.transition(
          start_query_set: 0,
          end_query_set: 1,
          start_ts: "AAAAAAAAAAA=",
          end_ts: "AQAAAAAAAAA=",
          query_id: query_id,
          count: 0
        )
      )
      socket.read(2)
      socket.close
    rescue StandardError => error
      server.record_error(error)
    end

    @client = Convex::Client.new(@server.url)
    subscription = @client.subscribe("demo:state", "room" => "close-order")
    assert_equal 0, subscription.next_update(timeout: 2).value.fetch("count")

    @client.close
    assert_nil subscription.close
    assert_nil subscription.close
  end

  def test_dead_manager_rejects_new_work_with_typed_closed_error
    manager = Convex::LiveManager.new("http://127.0.0.1:1", "ruby-test")
    manager.close

    error = assert_raises(Convex::ClosedError) do
      manager.subscribe("demo:state", "room" => "closed")
    end
    assert_match(/closed/, error.message)
  end
end
