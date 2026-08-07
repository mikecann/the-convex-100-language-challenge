require "http/client"
require "http/web_socket"
require "http/headers"
require "base64"
require "openssl"
require "json"
require "uuid"

module Convex
  class Error < Exception
    getter operation : String?
    getter data : JSON::Any?
    getter logs : Array(String)

    def initialize(message : String, @operation = nil, @data = nil, @logs = [] of String)
      super(message)
    end
  end

  class FunctionError < Error; end

  class ProtocolError < Error; end

  class TransportError < Error; end

  class ClosedError < Error; end

  # Convex encodes sync timestamps as eight little-endian bytes in base64.
  # Comparing the base64 text is wrong once a timestamp crosses 255.
  def self.decode_live_timestamp(timestamp : String) : UInt64
    bytes = Base64.decode_string(timestamp).to_slice
    raise ProtocolError.new("Live timestamp is not an eight-byte uint64", "live") unless bytes.size == 8
    value = 0_u64
    8.times { |index| value |= bytes[index].to_u64 << (index * 8) }
    value
  rescue ex : ProtocolError
    raise ex
  rescue ex
    raise ProtocolError.new("invalid Live timestamp: #{ex.message}", "live")
  end

  struct Result
    getter value : JSON::Any
    getter logs : Array(String)

    def initialize(@value, @logs); end
  end

  struct Update
    getter value : JSON::Any?
    getter error : Error?
    getter logs : Array(String)

    def initialize(@value = nil, @error = nil, @logs = [] of String); end

    # Include the complete structured error and logs, then leave conservative
    # room for the adapter's subscription envelope and runtime bookkeeping.
    # A value-only byte count is not a memory bound for large errorData/logs.
    def retained_bytes : Int32
      to_json.bytesize + 256
    end
  end

  record UpdateFingerprint, bytes : Int32, first : UInt64, second : UInt64

  # Rehydration comparison must include value, structured errors, and logs, but
  # retaining every previous multi-megabyte JSON value per subscription would
  # bypass the aggregate queue budget. Two independent 64-bit fingerprints plus
  # the encoded length keep that state fixed-size.
  def self.update_fingerprint(encoded : String) : UpdateFingerprint
    first = 0xcbf29ce484222325_u64
    second = 0x9e3779b185ebca87_u64
    encoded.each_byte do |byte|
      first = (first ^ byte.to_u64) &* 0x100000001b3_u64
      second = (second ^ byte.to_u64) &* 0xc2b2ae3d27d4eb4f_u64
    end
    UpdateFingerprint.new(encoded.bytesize, first, second)
  end

  # The owner has one aggregate budget for all live subscriptions. Per-channel
  # bounds alone are not a memory bound when a controller can create many IDs.
  class LiveUpdateBudget
    MAX_EVENTS = 128
    MAX_BYTES  = 16 * 1024 * 1024

    def initialize
      @mutex = Mutex.new
      @events = 0
      @bytes = 0
    end

    def reserve(bytes : Int32) : Bool
      @mutex.synchronize do
        return false if @events >= MAX_EVENTS || @bytes + bytes > MAX_BYTES
        @events += 1
        @bytes += bytes
        true
      end
    end

    def release(bytes : Int32, events = 1)
      @mutex.synchronize do
        @events -= events
        @events = 0 if @events < 0
        @bytes -= bytes
        @bytes = 0 if @bytes < 0
      end
    end
  end

  # Subscription delivery is bounded by both event count and encoded bytes.
  # Dropping the oldest value keeps a slow adapter consumer from retaining an
  # unbounded stream while preserving the newest Convex state.
  class Subscription
    MAX_EVENTS = 16
    # One legal Live message may approach the owner's 2 MiB frame ceiling.
    # Keep enough room for its encoded envelope while the aggregate 16 MiB
    # budget still bounds many slow subscriptions together.
    MAX_BYTES = 3 * 1024 * 1024
    getter id : Int32

    def initialize(@manager : LiveManager, @id : Int32, @budget : LiveUpdateBudget)
      @queue = Channel(Update).new(MAX_EVENTS)
      @bytes = 0
      @events = 0
      @mutex = Mutex.new
      @finished = false
    end

    def next(timeout : Time::Span? = nil) : Update
      update = if timeout
                 select
                 when value = @queue.receive
                   value
                 when timeout(timeout.not_nil!)
                   raise TransportError.new("timed out waiting for Live update", "live")
                 end
               else
                 @queue.receive
               end
      encoded = update.retained_bytes
      @mutex.synchronize do
        @bytes -= encoded
        @events -= 1 if @events > 0
      end
      @budget.release(encoded)
      update
    rescue Channel::ClosedError
      raise ClosedError.new("Live subscription is closed", "live")
    end

    def deliver(update : Update)
      encoded = update.retained_bytes
      return if encoded > MAX_BYTES
      @mutex.synchronize do
        return if @finished

        # Keep both bounds real. A full queue can still be well below the byte
        # limit, and a few large JSON values can fill the byte budget first.
        while @bytes + encoded > MAX_BYTES
          select
          when dropped = @queue.receive
            dropped_bytes = dropped.retained_bytes
            @bytes -= dropped_bytes
            @events -= 1 if @events > 0
            @budget.release(dropped_bytes)
          else
            break
          end
        end

        # If another subscription owns the aggregate budget, sacrifice this
        # subscription's oldest snapshot once before dropping the new one.
        unless @budget.reserve(encoded)
          select
          when dropped = @queue.receive
            dropped_bytes = dropped.retained_bytes
            @bytes -= dropped_bytes
            @events -= 1 if @events > 0
            @budget.release(dropped_bytes)
          else
            return
          end
          return unless @budget.reserve(encoded)
        end

        begin
          select
          when @queue.send(update)
            @bytes += encoded
            @events += 1
          else
            select
            when dropped = @queue.receive
              dropped_bytes = dropped.retained_bytes
              @bytes -= dropped_bytes
              @events -= 1 if @events > 0
              @budget.release(dropped_bytes)
            else
              @budget.release(encoded)
              return
            end
            select
            when @queue.send(update)
              @bytes += encoded
              @events += 1
            else
              # A slow consumer must never make the Live owner wait.
              @budget.release(encoded)
            end
          end
        rescue Channel::ClosedError
          @budget.release(encoded)
        end
      end
    end

    def finish
      @mutex.synchronize do
        return if @finished
        @finished = true
        # Drain buffered values before closing. A consumer that already
        # dequeued an item owns its later release; releasing @bytes wholesale
        # here would also release that in-flight item and undercount another
        # subscription's aggregate reservation.
        loop do
          select
          when dropped = @queue.receive
            dropped_bytes = dropped.retained_bytes
            @bytes -= dropped_bytes
            @events -= 1 if @events > 0
            @budget.release(dropped_bytes)
          else
            break
          end
        end
        @queue.close
      end
    end

    def close
      @manager.unsubscribe(@id)
    rescue ClosedError
    end

    {% if flag?(:live_test) %}
      # The raw-peer fixture pauses the owner immediately before a Remove write
      # so it can make that exact send fail without racing the read poll.
      def close_with_remove_pause(entered : Channel(Nil), resume : Channel(Nil), failed : Channel(Nil))
        @manager.unsubscribe_with_remove_pause(@id, entered, resume, failed)
      rescue ClosedError
      end
    {% end %}
  end

  # HTTP::WebSocket#run owns its own callback loop, which made the first Crystal
  # implementation split socket ownership between that callback and the manager.
  # This small wrapper keeps the raw IO and frame parser in the manager's one
  # owner fiber. A frame that stalls after bytes are available is abandoned with
  # its connection, never resumed as though its next byte were a new header.
  alias LiveIO = TCPSocket | OpenSSL::SSL::Socket::Client

  record IncomingFrame, opcode : UInt8, final : Bool, payload_offset : Int32, payload_size : Int32, total_size : Int32

  class OwnerWebSocket
    CONNECT_DEADLINE     = {% if flag?(:live_test) %} 500.milliseconds {% else %} 5.seconds {% end %}
    IDLE_READ_SLICE      = 25.milliseconds
    FRAME_DEADLINE       = 5.seconds
    WRITE_DEADLINE       = 250.milliseconds
    MAX_MESSAGE_BYTES    = 2 * 1024 * 1024
    MAX_FRAME_WIRE_BYTES = MAX_MESSAGE_BYTES + 10
    MAX_FRAMES_PER_POLL  = 8
    @frame_started_at : Time::Span?

    {% if flag?(:live_test) %}
      @@dial_pause_entered : Channel(Nil)? = nil
      @@dial_pause_resume : Channel(Nil)? = nil
      @@slow_write_entered : Channel(Nil)? = nil
      @@slow_write_interval = 25.milliseconds

      # Deterministically hold the next resolver/connect worker. The owner must
      # still regain control at CONNECT_DEADLINE instead of inheriting an
      # unbounded libc resolver or connect call.
      def self.pause_next_dial(entered : Channel(Nil), resume : Channel(Nil))
        @@dial_pause_entered = entered
        @@dial_pause_resume = resume
      end

      # Drip bytes through the real socket deadline wrapper. Unlike a simple
      # pre-write pause, this proves that partial progress cannot renew the
      # absolute budget shared by the first Connect frame.
      def self.slow_next_write(entered : Channel(Nil), interval = 25.milliseconds)
        @@slow_write_entered = entered
        @@slow_write_interval = interval
      end
    {% end %}

    def initialize(@io : LiveIO, @tcp : TCPSocket)
      # Crystal's protocol reader does not retain a partially consumed frame if
      # a socket timeout unwinds its call stack. Keep an incremental wire buffer
      # here so short idle polls can return control to the owner command loop
      # without losing the true frame boundary.
      @writer = HTTP::WebSocket::Protocol.new(@io, masked: true)
      @frame_buffer = Bytes.new(MAX_FRAME_WIRE_BYTES)
      @frame_size = 0
      @frame_started_at = nil
      @message = IO::Memory.new
      @message_in_progress = false
    end

    def self.connect(uri : URI, client_version : String, deadline = Time.monotonic + CONNECT_DEADLINE, cancelled : Proc(Bool) = -> { false }) : OwnerWebSocket
      host = uri.hostname || raise ArgumentError.new("Live URL has no host")
      path = uri.request_target
      raise ArgumentError.new("Live URL has no path") unless path
      tls = ["https", "wss"].includes?(uri.scheme)
      port = uri.port || (tls ? 443 : 80)
      tcp = dial_tcp(host, port, deadline, cancelled)
      io : LiveIO = tcp
      secured_socket : OpenSSL::SSL::Socket::Client? = nil
      begin
        with_socket_deadline(tcp, deadline, "Live WebSocket dial deadline exceeded", cancelled) do
          if tls
            context = OpenSSL::SSL::Context::Client.new
            secured = OpenSSL::SSL::Socket::Client.new(tcp, context: context, sync_close: true, hostname: host)
            secured_socket = secured
            io = secured
          end
          key = Base64.strict_encode(StaticArray(UInt8, 16).new { rand(256).to_u8 })
          headers = HTTP::Headers{
            "Host"                  => "#{host}:#{port}",
            "Connection"            => "Upgrade",
            "Upgrade"               => "websocket",
            "Sec-WebSocket-Version" => HTTP::WebSocket::Protocol::VERSION,
            "Sec-WebSocket-Key"     => key,
            "Convex-Client"         => client_version,
          }
          HTTP::Request.new("GET", path, headers).to_io(io)
          io.flush
          response = HTTP::Client::Response.from_io(io, ignore_body: true)
          unless response.status.switching_protocols? &&
                 header_has_token?(response.headers, "Upgrade", "websocket") &&
                 header_has_token?(response.headers, "Connection", "upgrade") &&
                 response.headers["Sec-WebSocket-Accept"]? == HTTP::WebSocket::Protocol.key_challenge(key)
            raise TransportError.new("Live WebSocket handshake was denied", "live dial")
          end
        end
        tcp.read_timeout = IDLE_READ_SLICE
        tcp.write_timeout = WRITE_DEADLINE
        if secured = secured_socket
          secured.read_timeout = IDLE_READ_SLICE
          secured.write_timeout = WRITE_DEADLINE
        end
        OwnerWebSocket.new(io, tcp)
      rescue ex
        io.close rescue nil
        raise ex
      end
    end

    private def self.dial_tcp(host : String, port : Int32, deadline : Time::Span, cancelled : Proc(Bool)) : TCPSocket
      state = Mutex.new
      abandoned = false
      outcome : TCPSocket | Exception | Nil = nil
      dial_paused = false

      {% if flag?(:live_test) %}
        if entered = @@dial_pause_entered
          resume = @@dial_pause_resume.not_nil!
          @@dial_pause_entered = nil
          @@dial_pause_resume = nil
          state.synchronize { dial_paused = true }
          # Channels remain on Crystal's owner scheduler. The real OS thread
          # below shares only mutex-protected state, which works without the
          # preview multithreaded scheduler.
          entered.send(nil)
          spawn do
            resume.receive
            state.synchronize { dial_paused = false }
          end
        end
      {% end %}

      # DNS resolution may enter libc before Crystal has a socket it can poll.
      # Use a real OS thread so that call cannot monopolise the owner's
      # cooperative scheduler past the absolute connection deadline.
      Thread.new do
        begin
          loop do
            break unless state.synchronize { dial_paused }
            sleep 1.millisecond
          end
          socket = TCPSocket.new(host, port)
          retire = state.synchronize do
            if abandoned
              true
            else
              outcome = socket
              false
            end
          end
          socket.close rescue nil if retire
        rescue ex
          state.synchronize { outcome = ex unless abandoned }
        end
      end

      loop do
        remaining = deadline - Time.monotonic
        interrupted = cancelled.call
        if remaining <= 0.seconds || interrupted
          late = state.synchronize do
            abandoned = true
            value = outcome
            outcome = nil
            value
          end
          # Close a socket that won the resolver race but was buffered just as
          # the deadline or control-command branch fired. A later resolver
          # result observes `cancelled` itself and closes before publishing.
          late.close rescue nil if late.is_a?(TCPSocket)
          message = interrupted ? "Live WebSocket dial interrupted by control command" : "Live WebSocket dial deadline exceeded"
          raise TransportError.new(message, "live dial")
        end
        if value = state.synchronize { current = outcome; outcome = nil if current; current }
          raise value if value.is_a?(Exception)
          return value
        end
        slice = remaining < 5.milliseconds ? remaining : 5.milliseconds
        sleep slice
      end
    end

    def self.with_socket_deadline(tcp : TCPSocket, deadline : Time::Span, message : String, cancelled : Proc(Bool), &)
      state = Mutex.new
      completed = false
      expired = false
      remaining = deadline - Time.monotonic
      raise TransportError.new(message, "live dial") if remaining <= 0.seconds
      spawn do
        loop do
          remaining = deadline - Time.monotonic
          interrupted = cancelled.call
          should_close = state.synchronize do
            if !completed && (remaining <= 0.seconds || interrupted)
              expired = true
              true
            else
              false
            end
          end
          if should_close
            tcp.close rescue nil
            break
          end
          break if state.synchronize { completed }
          sleep(remaining < 5.milliseconds ? remaining : 5.milliseconds)
        end
      end
      begin
        result = yield
        raise TransportError.new(message, "live dial") if state.synchronize { expired }
        result
      rescue ex
        raise TransportError.new(message, "live dial") if state.synchronize { expired }
        raise ex
      ensure
        state.synchronize { completed = true }
      end
    end

    private def self.header_has_token?(headers : HTTP::Headers, name : String, expected : String) : Bool
      value = headers[name]?
      return false unless value
      value.split(',').any? { |token| token.strip.downcase == expected }
    end

    # Returns at most one complete UTF-8 text message. A short read timeout is
    # ordinary idleness, even after part of a frame has arrived. The frame bytes
    # remain buffered until the absolute deadline expires, at which point the
    # owner abandons the connection and its parser state together.
    def poll(cancelled : Proc(Bool) = -> { false }) : String?
      frames = 0
      loop do
        if frame = next_frame?
          frames += 1
          message = handle_frame(frame, cancelled)
          consume_frame(frame.total_size)
          return message if message
          return nil if frames >= MAX_FRAMES_PER_POLL
          next
        end

        enforce_frame_deadline
        read_frame_bytes
        # One read per poll keeps a peer that continuously dribbles a large
        # frame from monopolising the owner before close/unsubscribe commands.
        enforce_frame_deadline
        return nil
      end
    rescue ex : IO::TimeoutError
      enforce_frame_deadline
      nil
    end

    def send_json(value, deadline = Time.monotonic + WRITE_DEADLINE, cancelled : Proc(Bool) = -> { false })
      write_frame(deadline, cancelled) { @writer.send(value.to_json) }
    end

    def close
      # Abort the raw descriptor first. TLS close_notify can otherwise wait on
      # an idle or flooding peer and violate the owner's close deadline.
      @tcp.close rescue nil
      @io.close rescue nil
    end

    private def read_frame_bytes
      raise ProtocolError.new("Live frame exceeds byte budget", "live read") if @frame_size >= @frame_buffer.size
      count = @io.read(@frame_buffer[@frame_size, @frame_buffer.size - @frame_size])
      raise IO::EOFError.new("Live peer closed the WebSocket") if count == 0
      @frame_started_at ||= Time.monotonic
      @frame_size += count
    end

    private def enforce_frame_deadline
      return unless started = @frame_started_at
      if Time.monotonic - started >= FRAME_DEADLINE
        raise TransportError.new("Live half-frame deadline exceeded", "live read")
      end
    end

    private def next_frame? : IncomingFrame?
      return nil if @frame_size < 2
      first = @frame_buffer[0]
      second = @frame_buffer[1]
      raise ProtocolError.new("Live frame uses unsupported RSV bits", "live read") unless first & 0x70_u8 == 0
      raise ProtocolError.new("Live server frame must not be masked", "live read") unless second & 0x80_u8 == 0

      opcode = first & 0x0f_u8
      final = first & 0x80_u8 != 0
      control = opcode >= 0x08_u8
      unless {0x00_u8, 0x01_u8, 0x02_u8, 0x08_u8, 0x09_u8, 0x0a_u8}.includes?(opcode)
        raise ProtocolError.new("unsupported Live frame opcode", "live read")
      end

      length_code = (second & 0x7f_u8).to_i
      header_size = 2
      payload_size = case length_code
                     when 126
                       return nil if @frame_size < 4
                       header_size = 4
                       length = (@frame_buffer[2].to_i << 8) | @frame_buffer[3].to_i
                       raise ProtocolError.new("Live frame uses non-minimal extended length", "live read") if length < 126
                       length
                     when 127
                       return nil if @frame_size < 10
                       header_size = 10
                       length = 0_u64
                       8.times { |index| length = (length << 8) | @frame_buffer[2 + index].to_u64 }
                       raise ProtocolError.new("Live frame uses non-minimal extended length", "live read") if length < 65_536_u64
                       raise ProtocolError.new("Live frame exceeds byte budget", "live read") if length > MAX_MESSAGE_BYTES.to_u64
                       length.to_i
                     else
                       length_code
                     end

      if control && (!final || payload_size > 125)
        raise ProtocolError.new("invalid Live control frame", "live read")
      end
      raise ProtocolError.new("Live frame exceeds byte budget", "live read") if payload_size > MAX_MESSAGE_BYTES
      total_size = header_size + payload_size
      return nil if @frame_size < total_size
      IncomingFrame.new(opcode, final, header_size, payload_size, total_size)
    end

    private def handle_frame(frame : IncomingFrame, cancelled : Proc(Bool)) : String?
      payload = @frame_buffer[frame.payload_offset, frame.payload_size]
      case frame.opcode
      when 0x09_u8
        write_frame(Time.monotonic + WRITE_DEADLINE, cancelled) { @writer.pong(payload) }
        nil
      when 0x0a_u8
        nil
      when 0x08_u8
        validate_close_payload(payload)
        raise TransportError.new("Live peer closed the WebSocket", "live read")
      when 0x02_u8
        raise ProtocolError.new("binary Live frames are unsupported", "live read")
      when 0x01_u8
        raise ProtocolError.new("new Live text frame interrupted a fragmented message", "live read") if @message_in_progress
        append_message(payload)
        if frame.final
          finish_message
        else
          @message_in_progress = true
          nil
        end
      when 0x00_u8
        raise ProtocolError.new("unexpected Live continuation", "live read") unless @message_in_progress
        append_message(payload)
        if frame.final
          @message_in_progress = false
          finish_message
        end
      else
        raise ProtocolError.new("unsupported Live frame", "live read")
      end
    end

    private def write_frame(deadline : Time::Span, cancelled : Proc(Bool), &)
      self.class.with_socket_deadline(@tcp, deadline, "Live frame write deadline exceeded", cancelled) do
        {% if flag?(:live_test) %}
          if entered = @@slow_write_entered
            interval = @@slow_write_interval
            @@slow_write_entered = nil
            entered.send(nil)
            # The peer deliberately ignores these bytes. Keep making genuine
            # TCP progress until the one production deadline closes the socket.
            loop do
              @tcp.write(Bytes[0_u8])
              @tcp.flush
              sleep interval
            end
          end
        {% end %}
        yield
      end
    rescue ex : TransportError
      raise ex
    rescue ex
      raise TransportError.new(ex.message || "Live frame write failed", "live write")
    end

    private def validate_close_payload(payload : Bytes)
      raise ProtocolError.new("Live close frame has a one-byte body", "live read") if payload.size == 1
      return if payload.empty?
      code = (payload[0].to_u16 << 8) | payload[1].to_u16
      valid_code = (code >= 1000 && code <= 1014 && !{1004_u16, 1005_u16, 1006_u16}.includes?(code)) ||
                   (code >= 3000 && code <= 4999)
      raise ProtocolError.new("Live close frame has an invalid status code", "live read") unless valid_code
      reason = String.new(payload[2, payload.size - 2])
      raise ProtocolError.new("Live close frame reason is not UTF-8", "live read") unless reason.valid_encoding?
    end

    private def append_message(payload : Bytes)
      if @message.size + payload.size > MAX_MESSAGE_BYTES
        raise ProtocolError.new("Live message exceeds byte budget", "live read")
      end
      @message.write(payload)
    end

    private def finish_message : String
      text = @message.to_s
      @message.clear
      raise ProtocolError.new("Live text frame is not UTF-8", "live read") unless text.valid_encoding?
      text
    end

    private def consume_frame(size : Int32)
      remaining = @frame_size - size
      remaining.times { |index| @frame_buffer[index] = @frame_buffer[size + index] }
      @frame_size = remaining
      @frame_started_at = remaining > 0 ? Time.monotonic : nil
    end
  end

  record StateVersion, query_set : UInt32, identity : UInt32, timestamp : String, timestamp_number : UInt64
  record ReconnectState,
    socket : OwnerWebSocket?,
    query_set_version : UInt32,
    remote_version : StateVersion,
    connection_count : UInt32,
    last_close_reason : String,
    reconnect_at : Time::Span?,
    backoff : Time::Span

  class LiveState
    property last_update : UpdateFingerprint?
    property rehydrating : Bool
    getter path : String
    getter args : JSON::Any
    getter subscription : Subscription

    def initialize(@path, @args, @subscription)
      @last_update = nil
      @rehydrating = true
    end
  end

  abstract class LiveCommand
  end

  class SubscribeCommand < LiveCommand
    getter path : String
    getter args : JSON::Any
    getter response : Channel(Subscription | Error)

    def initialize(@path, @args, @response); end
  end

  class UnsubscribeCommand < LiveCommand
    getter id : Int32
    getter response : Channel(Nil | Error)

    {% if flag?(:live_test) %}
      getter remove_entered : Channel(Nil)?
      getter remove_resume : Channel(Nil)?
      getter remove_failed : Channel(Nil)?

      def initialize(@id, @response, @remove_entered = nil, @remove_resume = nil, @remove_failed = nil); end
    {% else %}
      def initialize(@id, @response); end
    {% end %}
  end

  class DisconnectCommand < LiveCommand
    getter response : Channel(Nil | Error)

    def initialize(@response); end
  end

  class CloseCommand < LiveCommand
    getter response : Channel(Nil | Error)

    def initialize(@response); end
  end

  # All mutable socket, transition, backoff, and query-set state below exists
  # only in #run. Public methods submit commands and wait for their owner ack.
  class LiveManager
    INITIAL_TIMESTAMP = "AAAAAAAAAAA="
    INITIAL_BACKOFF   = 100.milliseconds
    MAX_BACKOFF       = 5.seconds

    def initialize(@base_url : URI, @client_version : String)
      @commands = Channel(LiveCommand).new(32)
      @closed = false
      @closing = false
      @close_waiters = [] of Channel(Nil | Error)
      @close_mutex = Mutex.new
      @interrupt_mutex = Mutex.new
      @interrupt_generation = 0_u64
      spawn { run }
    end

    {% if flag?(:live_test) %}
      @@close_pause_entered : Channel(Nil)? = nil
      @@close_pause_resume : Channel(Nil)? = nil

      def self.pause_next_close(entered : Channel(Nil), resume : Channel(Nil))
        @@close_pause_entered = entered
        @@close_pause_resume = resume
      end
    {% end %}

    def subscribe(path : String, args : JSON::Any) : Subscription
      response = Channel(Subscription | Error).new(1)
      @commands.send(SubscribeCommand.new(path, args, response))
      result = response.receive
      raise result if result.is_a?(Error)
      result
    rescue Channel::ClosedError
      raise ClosedError.new("Live manager is closed", "live")
    end

    def unsubscribe(id : Int32)
      interrupt_owner
      response = Channel(Nil | Error).new(1)
      @commands.send(UnsubscribeCommand.new(id, response))
      result = response.receive
      raise result if result.is_a?(Error)
    rescue Channel::ClosedError
      raise ClosedError.new("Live manager is closed", "live")
    end

    {% if flag?(:live_test) %}
      def unsubscribe_with_remove_pause(id : Int32, entered : Channel(Nil), resume : Channel(Nil), failed : Channel(Nil))
        interrupt_owner
        response = Channel(Nil | Error).new(1)
        @commands.send(UnsubscribeCommand.new(id, response, entered, resume, failed))
        result = response.receive
        raise result if result.is_a?(Error)
      rescue Channel::ClosedError
        raise ClosedError.new("Live manager is closed", "live")
      end
    {% end %}

    def debug_disconnect
      response = Channel(Nil | Error).new(1)
      @commands.send(DisconnectCommand.new(response))
      result = response.receive
      raise result if result.is_a?(Error)
    rescue Channel::ClosedError
      raise ClosedError.new("Live manager is closed", "live")
    end

    def close
      waiter = Channel(Nil | Error).new(1)
      enqueue = false
      already_closed = @close_mutex.synchronize do
        if @closed
          true
        else
          @close_waiters << waiter
          unless @closing
            @closing = true
            enqueue = true
          end
          false
        end
      end
      return if already_closed
      if enqueue
        interrupt_owner
        @commands.send(CloseCommand.new(waiter))
      end
      result = waiter.receive
      raise result if result.is_a?(Error)
    rescue Channel::ClosedError
      error = ClosedError.new("Live manager is closed", "live")
      finish_close(error)
      raise error
    end

    private def interrupt_owner
      @interrupt_mutex.synchronize { @interrupt_generation &+= 1_u64 }
    end

    private def operation_cancelled : Proc(Bool)
      generation = @interrupt_mutex.synchronize { @interrupt_generation }
      -> { @interrupt_mutex.synchronize { @interrupt_generation != generation } }
    end

    private def finish_close(error : Error? = nil)
      waiters = @close_mutex.synchronize do
        return if @closed && @close_waiters.empty?
        @closed = true
        current = @close_waiters
        @close_waiters = [] of Channel(Nil | Error)
        current
      end
      waiters.each { |waiting| waiting.send(error || nil) rescue nil }
    end

    private def run
      active = {} of Int32 => LiveState
      budget = LiveUpdateBudget.new
      socket : OwnerWebSocket? = nil
      next_id = 0
      query_set_version = 0_u32
      remote_version = zero_version
      connection_count = 0_u32
      last_close_reason = "InitialConnect"
      max_timestamp = INITIAL_TIMESTAMP
      max_timestamp_number = 0_u64
      reconnect_at : Time::Span? = nil
      backoff = INITIAL_BACKOFF

      loop do
        # This non-blocking command drain makes control commands win over socket
        # reads. Frame reads have a fixed deadline, so close and unsubscribe
        # remain bounded for idle, flood, and partial-frame peers.
        select
        when command = @commands.receive
          case command
          when SubscribeCommand
            id = next_id
            next_id += 1
            sub = Subscription.new(self, id, budget)
            active[id] = LiveState.new(command.path, command.args, sub)
            command.response.send(sub)
            if socket
              begin
                query_set_version = add(socket.not_nil!, query_set_version, id, active[id])
              rescue ex
                publish_transport(active, ex)
                reconnect = enter_reconnect(socket, active, connection_count, ex.message || "write failed", backoff)
                socket = reconnect.socket
                query_set_version = reconnect.query_set_version
                remote_version = reconnect.remote_version
                connection_count = reconnect.connection_count
                last_close_reason = reconnect.last_close_reason
                reconnect_at = reconnect.reconnect_at
                backoff = reconnect.backoff
              end
            else
              reconnect_at ||= Time.monotonic
            end
          when UnsubscribeCommand
            state = active.delete(command.id)
            # Finish before the acknowledgement. Adapter relays observe this
            # close and cannot publish a dequeued old update after that ack.
            state.try &.subscription.finish
            if socket && state
              {% if flag?(:live_test) %}
                if entered = command.remove_entered
                  entered.send(nil)
                  command.remove_resume.not_nil!.receive
                end
              {% end %}
              begin
                query_set_version = remove(socket.not_nil!, query_set_version, command.id)
              rescue ex
                publish_transport(active, ex)
                reconnect = enter_reconnect(socket, active, connection_count, ex.message || "write failed", backoff)
                socket = reconnect.socket
                query_set_version = reconnect.query_set_version
                remote_version = reconnect.remote_version
                connection_count = reconnect.connection_count
                last_close_reason = reconnect.last_close_reason
                reconnect_at = reconnect.reconnect_at
                backoff = reconnect.backoff
                {% if flag?(:live_test) %}
                  command.remove_failed.try &.send(nil)
                {% end %}
              end
            end
            reconnect_at = nil if active.empty?
            command.response.send(nil)
          when DisconnectCommand
            if socket
              # The acknowledgement is sent only after the old connection has
              # been closed, all remote state retired, and a reconnect is set.
              reconnect = enter_reconnect(socket, active, connection_count, "DebugDisconnect", backoff, immediate: true, advance_backoff: false)
              socket = reconnect.socket
              query_set_version = reconnect.query_set_version
              remote_version = reconnect.remote_version
              connection_count = reconnect.connection_count
              last_close_reason = reconnect.last_close_reason
              reconnect_at = reconnect.reconnect_at
              backoff = reconnect.backoff
              command.response.send(nil)
            else
              command.response.send(TransportError.new("Live WebSocket is not connected", "live"))
            end
          when CloseCommand
            {% if flag?(:live_test) %}
              if entered = @@close_pause_entered
                resume = @@close_pause_resume.not_nil!
                @@close_pause_entered = nil
                @@close_pause_resume = nil
                entered.send(nil)
                resume.receive
              end
            {% end %}
            socket.try &.close
            active.each_value { |state| state.subscription.finish }
            # Wake every caller that joined this close, not just the caller
            # whose command won the race into the owner mailbox.
            finish_close
            break
          end
        else
          now = Time.monotonic
          if !socket && !active.empty? && (!reconnect_at || now >= reconnect_at.not_nil!)
            begin
              socket = open_socket(connection_count, last_close_reason, max_timestamp)
              # A completed WebSocket handshake is a healthy connection even
              # if a later Add replay write fails. Do not carry an old maximum
              # delay across that successful transport transition.
              backoff = INITIAL_BACKOFF
              query_set_version = replay(socket.not_nil!, active)
              remote_version = zero_version
              reconnect_at = nil
            rescue ex
              reconnect = enter_reconnect(socket, active, connection_count, ex.message || "Live dial failed", backoff)
              socket = reconnect.socket
              query_set_version = reconnect.query_set_version
              remote_version = reconnect.remote_version
              connection_count = reconnect.connection_count
              last_close_reason = reconnect.last_close_reason
              reconnect_at = reconnect.reconnect_at
              backoff = reconnect.backoff
            end
          end

          if current = socket
            begin
              if raw = current.poll(operation_cancelled)
                remote_version, max_timestamp, max_timestamp_number = handle_message(raw, active, remote_version, max_timestamp, max_timestamp_number)
                # Reset only after the message has parsed and applied. A
                # malformed packet must not make a failing peer look healthy.
                backoff = INITIAL_BACKOFF
              end
              # A peer with bytes continuously ready must not monopolise the
              # cooperative scheduler before another fiber can enqueue its
              # close or unsubscribe command.
              Fiber.yield
            rescue ex : Error
              publish_protocol(active, ex)
              reconnect = enter_reconnect(socket, active, connection_count, ex.message || "Live transport failed", backoff)
              socket = reconnect.socket
              query_set_version = reconnect.query_set_version
              remote_version = reconnect.remote_version
              connection_count = reconnect.connection_count
              last_close_reason = reconnect.last_close_reason
              reconnect_at = reconnect.reconnect_at
              backoff = reconnect.backoff
            rescue ex
              error = TransportError.new(ex.message || "Live transport failed", "live read")
              publish_transport(active, error)
              reconnect = enter_reconnect(socket, active, connection_count, error.message || "Live transport failed", backoff)
              socket = reconnect.socket
              query_set_version = reconnect.query_set_version
              remote_version = reconnect.remote_version
              connection_count = reconnect.connection_count
              last_close_reason = reconnect.last_close_reason
              reconnect_at = reconnect.reconnect_at
              backoff = reconnect.backoff
            end
          else
            sleep 5.milliseconds
          end
        end
      end
    rescue Channel::ClosedError
    ensure
      finish_close(ClosedError.new("Live manager owner stopped", "live"))
      @commands.close rescue nil
    end

    private def live_uri
      uri = @base_url.dup
      uri.scheme = uri.scheme == "https" ? "wss" : "ws"
      uri.path = "#{uri.path.rstrip('/')}/api/sync"
      uri.query = nil
      uri.fragment = nil
      uri
    end

    private def open_socket(connection_count : UInt32, last_close_reason : String, max_timestamp : String)
      # DNS, TCP, TLS, HTTP 101, and the first Connect frame share one absolute
      # budget. A close or unsubscribe increments the control generation and
      # closes the in-flight socket instead of waiting for that whole budget.
      deadline = Time.monotonic + OwnerWebSocket::CONNECT_DEADLINE
      cancelled = operation_cancelled
      socket = OwnerWebSocket.connect(live_uri, @client_version, deadline, cancelled)
      begin
        connect = {"type" => "Connect", "sessionId" => UUID.random.to_s, "connectionCount" => connection_count, "lastCloseReason" => last_close_reason, "clientTs" => 0}
        connect["maxObservedTimestamp"] = max_timestamp unless max_timestamp == INITIAL_TIMESTAMP
        socket.send_json(connect, deadline, cancelled)
        socket
      rescue ex
        # Assignment to the owner's socket state happens only after this
        # method returns, so retire the local transport here on any failed or
        # interrupted first frame.
        socket.close
        raise ex
      end
    end

    private def replay(socket : OwnerWebSocket, active : Hash(Int32, LiveState)) : UInt32
      return 0_u32 if active.empty?
      modifications = active.keys.sort.map do |id|
        state = active[id]
        {"type" => "Add", "queryId" => id, "udfPath" => state.path, "args" => [state.args]}
      end
      socket.send_json({"type" => "ModifyQuerySet", "baseVersion" => 0, "newVersion" => 1, "modifications" => modifications}, cancelled: operation_cancelled)
      1_u32
    end

    private def add(socket : OwnerWebSocket, version : UInt32, id : Int32, state : LiveState) : UInt32
      socket.send_json({"type" => "ModifyQuerySet", "baseVersion" => version, "newVersion" => version + 1, "modifications" => [{"type" => "Add", "queryId" => id, "udfPath" => state.path, "args" => [state.args]}]}, cancelled: operation_cancelled)
      version + 1
    end

    private def remove(socket : OwnerWebSocket, version : UInt32, id : Int32) : UInt32
      socket.send_json({"type" => "ModifyQuerySet", "baseVersion" => version, "newVersion" => version + 1, "modifications" => [{"type" => "Remove", "queryId" => id}]}, cancelled: operation_cancelled)
      version + 1
    end

    private def zero_version
      StateVersion.new(0_u32, 0_u32, INITIAL_TIMESTAMP, 0_u64)
    end

    private def next_backoff(backoff : Time::Span)
      doubled = backoff * 2
      doubled > MAX_BACKOFF ? MAX_BACKOFF : doubled
    end

    # Every path that can replay the active query set comes through here. The
    # remote versions and parser transport retire as one state transition, and
    # every surviving query is marked before a replacement socket can replay
    # its Add. That keeps unchanged rehydration suppression independent of
    # which read, write, dial, or debug path initiated the reconnect.
    private def enter_reconnect(socket : OwnerWebSocket?, active : Hash(Int32, LiveState), connection_count : UInt32, reason : String, backoff : Time::Span, immediate = false, advance_backoff = true) : ReconnectState
      socket.try &.close
      active.each_value { |state| state.rehydrating = true }
      reconnect_at = active.empty? ? nil : Time.monotonic + (immediate ? 0.seconds : backoff)
      next_delay = advance_backoff ? next_backoff(backoff) : backoff
      ReconnectState.new(nil, 0_u32, zero_version, connection_count + 1, reason, reconnect_at, next_delay)
    end

    private def parse_version(value : JSON::Any) : StateVersion
      timestamp = value["ts"].as_s
      StateVersion.new(value["querySet"].as_i.to_u32, value["identity"].as_i.to_u32, timestamp, Convex.decode_live_timestamp(timestamp))
    rescue ex : ProtocolError
      raise ex
    rescue ex
      raise ProtocolError.new("invalid Live StateVersion: #{ex.message}", "live")
    end

    private def logs(modification : JSON::Any)
      modification["logLines"]?.try(&.as_a.map(&.as_s)) || [] of String
    end

    private def handle_message(raw : String, active : Hash(Int32, LiveState), remote_version : StateVersion, max_timestamp : String, max_number : UInt64) : {StateVersion, String, UInt64}
      message = JSON.parse(raw)
      case message["type"].as_s
      when "Ping", "MutationResponse", "ActionResponse"
        return {remote_version, max_timestamp, max_number}
      when "FatalError", "AuthError", "TransitionChunk"
        raise ProtocolError.new("#{message["type"].as_s}: #{message["error"]?}", "live")
      when "Transition"
        start_version = parse_version(message["startVersion"])
        end_version = parse_version(message["endVersion"])
        raise ProtocolError.new("Live transition start version mismatch", "live") unless start_version == remote_version
        staged = [] of {Int32, Update, UpdateFingerprint}
        message["modifications"].as_a.each do |modification|
          id = modification["queryId"].as_i
          case modification["type"].as_s
          when "QueryUpdated"
            update = Update.new(modification["value"], nil, logs(modification))
            staged << {id, update, Convex.update_fingerprint(update.to_json)}
          when "QueryFailed"
            update = Update.new(nil, FunctionError.new(modification["errorMessage"].as_s, "query", modification["errorData"]?, logs(modification)), logs(modification))
            staged << {id, update, Convex.update_fingerprint(update.to_json)}
          when "QueryRemoved"
          else
            raise ProtocolError.new("unknown Live transition modification #{modification["type"].as_s}", "live")
          end
        end
        # Commit the complete transition, including numeric uint64 timestamp,
        # before delivery so no subscriber observes a half-applied state.
        new_max = end_version.timestamp_number > max_number ? end_version.timestamp_number : max_number
        new_timestamp = end_version.timestamp_number > max_number ? end_version.timestamp : max_timestamp
        staged.sort_by!(&.[0])
        staged.each do |id, update, encoded|
          if state = active[id]?
            # A reconnect rehydrates the remote state. Identical values must not
            # be replayed to the adapter before the later external update.
            unless state.rehydrating && state.last_update == encoded
              state.subscription.deliver(update)
            end
            state.last_update = encoded
            state.rehydrating = false
          end
        end
        {end_version, new_timestamp, new_max}
      else
        raise ProtocolError.new("unknown Live message #{message["type"].as_s}", "live")
      end
    rescue ex : Error
      raise ex
    rescue ex
      raise ProtocolError.new("decode Live message: #{ex.message}", "live")
    end

    private def publish_protocol(active : Hash(Int32, LiveState), error : Error)
      active.each_value { |state| state.subscription.deliver(Update.new(nil, error)) }
    end

    private def publish_transport(active : Hash(Int32, LiveState), error : Exception)
      transport = error.as?(TransportError) || TransportError.new(error.message || "Live transport failed", "live")
      active.each_value { |state| state.subscription.deliver(Update.new(nil, transport)) }
    end
  end

  class Client
    VERSION                 = "crystal-0.1.0"
    MAX_HTTP_RESPONSE_BYTES = 2 * 1024 * 1024
    @url : URI
    @bearer_token : String?
    @live : LiveManager?
    @mutex : Mutex
    @closed : Bool

    def initialize(url : String, @bearer_token : String? = nil)
      @url = URI.parse(url)
      raise ArgumentError.new("Convex URL must use http or https") unless ["http", "https"].includes?(@url.scheme)
      @live = nil
      @mutex = Mutex.new
      @closed = false
    end

    def set_auth(token : String)
      @mutex.synchronize { raise ClosedError.new("client is closed") if @closed; @bearer_token = token }
    end

    def query(path : String, args = {} of String => JSON::Any) : Result
      call("query", path, args)
    end

    def mutation(path : String, args = {} of String => JSON::Any) : Result
      call("mutation", path, args)
    end

    def action(path : String, args = {} of String => JSON::Any) : Result
      call("action", path, args)
    end

    def subscribe(path : String, args = {} of String => JSON::Any) : Subscription
      @mutex.synchronize { raise ClosedError.new("client is closed") if @closed; @live ||= LiveManager.new(@url, VERSION) }.not_nil!.subscribe(path, JSON.parse(args.to_json))
    end

    def debug_disconnect
      live = @live || raise TransportError.new("Live WebSocket is not connected", "live")
      live.debug_disconnect
    end

    def close
      live = @mutex.synchronize { @closed = true; @live }
      live.try &.close
    end

    private def call(operation : String, path : String, args)
      raise ArgumentError.new("Convex function path is required") if path.empty?
      body = {"path" => path, "args" => args, "format" => "json"}.to_json
      headers = HTTP::Headers{"Content-Type" => "application/json", "Accept" => "application/json", "Convex-Client" => VERSION}
      token = @mutex.synchronize { raise ClosedError.new("client is closed") if @closed; @bearer_token }
      headers["Authorization"] = "Bearer #{token}" if token && !token.empty?
      response_body = begin
        HTTP::Client.post(@url.resolve("/api/#{operation}"), headers: headers, body: body) do |response|
          status_code = response.status_code
          unless status_code >= 200 && status_code <= 299
            # A proxy or backend error must not become a successful Convex result
            # merely because its body happens to have {"status":"success"}.
            raise TransportError.new("HTTP request failed with status #{status_code}", operation)
          end
          read_http_body(response.body_io, operation)
        end
      rescue ex : Error
        raise ex
      rescue ex
        # Only connection, TLS, deadline, and body-read failures cross this
        # boundary. Application JSON is decoded below as protocol data.
        raise TransportError.new(ex.message || "HTTP request failed", operation)
      end
      decode_http_response(response_body, operation)
    end

    private def decode_http_response(response_body : String, operation : String) : Result
      decoded = begin
        JSON.parse(response_body)
      rescue JSON::ParseException
        raise ProtocolError.new("invalid Convex response JSON", operation)
      end
      envelope = begin
        decoded.as_h
      rescue TypeCastError
        raise ProtocolError.new("Convex response must be an object", operation)
      end
      status = response_string(envelope, "status", operation)
      logs = response_logs(envelope, operation)
      case status
      when "success"
        raise ProtocolError.new("Convex success response is missing value", operation) unless envelope.has_key?("value")
        Result.new(envelope["value"], logs)
      when "error"
        message = response_string(envelope, "errorMessage", operation)
        raise FunctionError.new(message, operation, envelope["errorData"]?, logs)
      else
        raise ProtocolError.new("unknown Convex response status", operation)
      end
    rescue ex : Error
      raise ex
    rescue ex
      # Any unanticipated JSON shape failure is still a protocol violation.
      # It must never be flattened into a transport failure after HTTP passed.
      raise ProtocolError.new("invalid Convex response envelope: #{ex.message}", operation)
    end

    private def response_string(envelope : Hash(String, JSON::Any), field : String, operation : String) : String
      value = envelope[field]? || raise ProtocolError.new("Convex response is missing #{field}", operation)
      value.as_s
    rescue ex : ProtocolError
      raise ex
    rescue TypeCastError
      raise ProtocolError.new("Convex response #{field} must be a string", operation)
    end

    private def response_logs(envelope : Hash(String, JSON::Any), operation : String) : Array(String)
      value = envelope["logLines"]?
      return [] of String unless value
      value.as_a.map(&.as_s)
    rescue TypeCastError
      raise ProtocolError.new("Convex response logLines must be an array of strings", operation)
    end

    private def read_http_body(input : IO, operation : String) : String
      output = IO::Memory.new
      buffer = Bytes.new(16 * 1024)
      total = 0
      loop do
        count = input.read(buffer)
        break if count == 0
        total += count
        # Check before copying into the retained output. Chunked and compressed
        # responses therefore cannot allocate an unbounded body first.
        raise TransportError.new("HTTP response too large", operation) if total > MAX_HTTP_RESPONSE_BYTES
        output.write(buffer[0, count])
      end
      output.to_s
    end
  end
end

struct Convex::Update
  def to_json(json : JSON::Builder)
    json.object do
      if error = @error
        json.field "error" do
          json.object do
            json.field "name", error.class.name.split("::").last
            json.field "message", error.message
            if operation = error.operation
              json.field "operation", operation
            end
            if data = error.data
              json.field "data", data
            end
            json.field "logs", error.logs unless error.logs.empty?
          end
        end
      elsif value = @value
        json.field "value", value
      end
      json.field "logs", @logs unless @logs.empty?
    end
  end
end
