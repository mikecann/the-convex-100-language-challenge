# frozen_string_literal: true

require "digest/sha1"
require "openssl"
require "securerandom"
require "socket"
require "uri"

module Convex
  # A deliberately small RFC 6455 client transport. It handles only the text,
  # ping, pong, and close frames needed by Convex. The Convex sync state machine
  # remains separate in LiveManager below.
  class WebSocket
    WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    MAX_MESSAGE_BYTES = 2 * 1024 * 1024

    attr_reader :io

    def pending?
      @io.respond_to?(:pending) && @io.pending.positive?
    end

    def self.connect(url, client_version:)
      new(url, client_version: client_version).tap(&:connect)
    end

    def initialize(url, client_version:)
      @uri = URI.parse(url)
      @client_version = client_version
      @io = nil
      @tcp = nil
    end

    def connect
      port = @uri.port || (@uri.scheme == "wss" ? 443 : 80)
      @tcp = Socket.tcp(@uri.host, port, connect_timeout: 10)
      @tcp.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      @io = @uri.scheme == "wss" ? wrap_tls(@tcp) : @tcp

      key = strict_base64(SecureRandom.random_bytes(16))
      resource = @uri.request_uri.empty? ? "/" : @uri.request_uri
      host = @uri.host
      default_port = @uri.scheme == "wss" ? 443 : 80
      host = "#{host}:#{port}" unless port == default_port
      request = [
        "GET #{resource} HTTP/1.1",
        "Host: #{host}",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: #{key}",
        "Sec-WebSocket-Version: 13",
        "Convex-Client: #{@client_version}",
        "\r\n"
      ].join("\r\n")
      @io.write(request)

      response = read_http_headers
      status, *headers = response.split("\r\n")
      unless status&.match?(%r{\AHTTP/1\.[01] 101(?: |\z)})
        raise ProtocolError, "WebSocket upgrade failed: #{status || "empty response"}"
      end
      parsed_headers = headers.filter_map do |line|
        name, value = line.split(":", 2)
        [name.downcase, value.strip] if name && value
      end.to_h
      expected_accept = strict_base64(Digest::SHA1.digest(key + WEBSOCKET_GUID))
      unless parsed_headers["sec-websocket-accept"] == expected_accept
        raise ProtocolError, "WebSocket upgrade returned an invalid accept key"
      end

      self
    rescue StandardError
      close_now
      raise
    end

    def write_json(value)
      write_frame(0x1, JSON.generate(value))
    end

    # Read one complete text message. Control frames are handled internally and
    # nil means the peer closed cleanly.
    def read_message
      message = +"".b
      message_opcode = nil
      loop do
        fin, opcode, payload = read_frame
        case opcode
        when 0x0
          raise ProtocolError, "unexpected WebSocket continuation" unless message_opcode

          message << payload
        when 0x1
          raise ProtocolError, "interleaved WebSocket text messages" if message_opcode

          message_opcode = opcode
          message << payload
        when 0x8
          write_frame(0x8, payload) rescue nil
          return nil
        when 0x9
          write_frame(0xA, payload)
          next
        when 0xA
          next
        else
          raise ProtocolError, "unsupported WebSocket opcode #{opcode}"
        end

        raise ProtocolError, "WebSocket message exceeds #{MAX_MESSAGE_BYTES} bytes" if message.bytesize > MAX_MESSAGE_BYTES
        return message.force_encoding(Encoding::UTF_8) if fin
      end
    end

    def close
      write_frame(0x8, [1000].pack("n") + "client closed") if @io
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      nil
    ensure
      close_now
    end

    def close_now
      @io&.close
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      nil
    ensure
      @io = nil
      begin
        @tcp&.close unless @tcp&.closed?
      rescue IOError, SystemCallError
        nil
      end
      @tcp = nil
    end

    private

    # Ruby's core pack directive provides RFC 4648 base64 without loading the
    # RubyGems-packaged base64 helper into the minimal runtime.
    def strict_base64(value)
      [value].pack("m0")
    end

    def wrap_tls(tcp)
      context = OpenSSL::SSL::SSLContext.new
      context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
      ssl = OpenSSL::SSL::SSLSocket.new(tcp, context)
      ssl.hostname = @uri.host
      ssl.sync_close = true
      ssl.connect
      ssl.post_connection_check(@uri.host)
      ssl
    end

    def read_http_headers
      response = +"".b
      until response.end_with?("\r\n\r\n")
        response << read_exact(1)
        raise ProtocolError, "WebSocket upgrade headers are too large" if response.bytesize > 32 * 1024
      end
      response.force_encoding(Encoding::UTF_8)
    end

    def read_frame
      header = read_exact(2)
      first, second = header.bytes
      fin = (first & 0x80) != 0
      opcode = first & 0x0f
      masked = (second & 0x80) != 0
      raise ProtocolError, "server WebSocket frames must not be masked" if masked

      length = second & 0x7f
      length = read_exact(2).unpack1("n") if length == 126
      length = read_exact(8).unpack1("Q>") if length == 127
      raise ProtocolError, "WebSocket frame exceeds #{MAX_MESSAGE_BYTES} bytes" if length > MAX_MESSAGE_BYTES
      raise ProtocolError, "fragmented WebSocket control frame" if opcode >= 0x8 && !fin
      raise ProtocolError, "oversized WebSocket control frame" if opcode >= 0x8 && length > 125

      [fin, opcode, read_exact(length)]
    end

    # Client-to-server WebSocket frames must be masked, including control
    # frames. SecureRandom gives every frame a fresh RFC 6455 mask.
    def write_frame(opcode, payload)
      data = payload.to_s.b
      mask = SecureRandom.random_bytes(4)
      header = [(0x80 | opcode)].pack("C")
      header << if data.bytesize < 126
                  [(0x80 | data.bytesize)].pack("C")
                elsif data.bytesize <= 0xffff
                  [(0x80 | 126), data.bytesize].pack("Cn")
                else
                  [(0x80 | 127), data.bytesize].pack("CQ>")
                end
      masked = data.bytes.each_with_index.map { |byte, index| byte ^ mask.getbyte(index % 4) }.pack("C*")
      @io.write(header + mask + masked)
    end

    def read_exact(length)
      value = +"".b
      while value.bytesize < length
        chunk = @io.read(length - value.bytesize)
        raise EOFError, "WebSocket closed while reading a frame" unless chunk

        value << chunk
      end
      value
    end
  end
end
