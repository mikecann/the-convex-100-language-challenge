# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "socket"

require_relative "convex"

class ConvexWebSocketTest < Minitest::Test
  def setup
    @client_io, @server_io = UNIXSocket.pair
    @socket = Convex::WebSocket.allocate
    @socket.instance_variable_set(:@io, @client_io)
    @socket.instance_variable_set(:@tcp, nil)
  end

  def teardown
    @client_io.close unless @client_io.closed?
    @server_io.close unless @server_io.closed?
  end

  def test_client_text_frames_are_masked_and_decode_to_json
    @socket.write_json("type" => "Connect", "clientTs" => 0)

    first, second = @server_io.read(2).bytes
    assert_equal 0x81, first
    assert_equal 0x80, second & 0x80
    length = second & 0x7f
    mask = @server_io.read(4)
    masked = @server_io.read(length)
    payload = masked.bytes.each_with_index.map do |byte, index|
      byte ^ mask.getbyte(index % 4)
    end.pack("C*")

    assert_equal({ "type" => "Connect", "clientTs" => 0 }, JSON.parse(payload))
  end

  def test_reads_an_unmasked_server_text_frame
    payload = JSON.generate("type" => "Ping")
    @server_io.write([0x81, payload.bytesize].pack("CC") + payload)

    assert_equal payload, @socket.read_message
  end

  def test_rejects_a_masked_server_frame
    @server_io.write([0x81, 0x80].pack("CC"))

    assert_raises(Convex::ProtocolError) { @socket.read_message }
  end
end
