# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "socket"

require_relative "convex"

class FakeConvexHTTP
  attr_reader :url, :requests

  def initialize(&handler)
    @handler = handler
    @requests = Queue.new
    @server = TCPServer.new("127.0.0.1", 0)
    @url = "http://127.0.0.1:#{@server.local_address.ip_port}"
    @thread = Thread.new { serve }
  end

  def close
    @server.close
    @thread.join
  rescue IOError, Errno::EBADF
    @thread.join
  end

  private

  def serve
    loop do
      socket = @server.accept
      request_line = socket.gets("\r\n").to_s.strip
      headers = {}
      while (line = socket.gets("\r\n")) && line != "\r\n"
        name, value = line.split(":", 2)
        headers[name.downcase] = value.strip
      end
      body = socket.read(headers.fetch("content-length", "0").to_i)
      request = {
        line: request_line,
        headers: headers,
        body: JSON.parse(body)
      }
      @requests << request
      response = @handler.call(request)
      encoded = JSON.generate(response)
      socket.write(
        "HTTP/1.1 200 OK\r\n" \
        "Content-Type: application/json\r\n" \
        "Content-Length: #{encoded.bytesize}\r\n" \
        "Connection: close\r\n\r\n" \
        "#{encoded}"
      )
      socket.close
    end
  rescue IOError, Errno::EBADF
    nil
  end
end

class ConvexClientTest < Minitest::Test
  def teardown
    @client&.close
    @server&.close
  end

  def test_query_uses_documented_json_api_and_preserves_logs
    @server = FakeConvexHTTP.new do |request|
      {
        status: "success",
        value: request.fetch(:body).fetch("args"),
        logLines: ["[LOG] demo:echo"]
      }
    end
    @client = Convex::Client.new(@server.url, bearer_token: "opaque token")

    result = @client.query("demo:echo", "nested" => { "works" => true })
    request = @server.requests.pop

    assert_equal({ "nested" => { "works" => true } }, result.value)
    assert_equal ["[LOG] demo:echo"], result.logs
    assert_equal "POST /api/query HTTP/1.1", request.fetch(:line)
    assert_equal "json", request.dig(:body, "format")
    assert_equal "Bearer opaque token", request.dig(:headers, "authorization")
    assert_equal "ruby-0.1.0", request.dig(:headers, "convex-client")
  end

  def test_auth_can_be_replaced_and_cleared
    @server = FakeConvexHTTP.new do |_request|
      { status: "success", value: true, logLines: [] }
    end
    @client = Convex::Client.new(@server.url)

    @client.set_auth("first")
    @client.query("demo:state", "room" => "one")
    assert_equal "Bearer first", @server.requests.pop.dig(:headers, "authorization")

    @client.set_auth("second")
    @client.query("demo:state", "room" => "two")
    assert_equal "Bearer second", @server.requests.pop.dig(:headers, "authorization")

    @client.set_auth("")
    @client.query("demo:state", "room" => "three")
    refute @server.requests.pop.fetch(:headers).key?("authorization")
  end

  def test_structured_function_error_keeps_data_and_logs
    @server = FakeConvexHTTP.new do |_request|
      {
        status: "error",
        errorMessage: "expected failure",
        errorData: { code: "EXPECTED" },
        logLines: ["before failure"]
      }
    end
    @client = Convex::Client.new(@server.url)

    error = assert_raises(Convex::FunctionError) do
      @client.query("demo:fail", "code" => "EXPECTED")
    end

    assert_equal({ "code" => "EXPECTED" }, error.data)
    assert_equal ["before failure"], error.logs
    assert_match(/expected failure/, error.message)
  end

  def test_rejects_invalid_urls_non_object_arguments_and_calls_after_close
    assert_raises(ArgumentError) { Convex::Client.new("ftp://example.com") }

    @server = FakeConvexHTTP.new { |_request| { status: "success", value: nil } }
    @client = Convex::Client.new(@server.url)
    assert_raises(ArgumentError) { @client.query("demo:echo", ["not", "named"]) }
    @client.close
    assert_raises(Convex::ClosedError) { @client.query("demo:state", {}) }
  end
end
