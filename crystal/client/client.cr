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
  end

  # HTTP::WebSocket#run owns its own callback loop, which made the first Crystal
  # implementation split socket ownership between that callback and the manager.
  # This small wrapper keeps the raw IO and frame parser in the manager's one
  # owner fiber. A frame that stalls after bytes are available is abandoned with
  # its connection, never resumed as though its next byte were a new header.
  alias LiveIO = TCPSocket | OpenSSL::SSL::Socket::Client

  # Count bytes returned to the frame parser, including bytes already buffered
  # inside OpenSSL. Raw descriptor readiness cannot see those bytes, which can
  # otherwise strand a WebSocket message read alongside the HTTP 101 response.
  class CountingLiveIO < IO
    getter bytes_read = 0

    def initialize(@inner : LiveIO)
    end

    def reset_bytes_read
      @bytes_read = 0
    end

    def read(slice : Bytes) : Int32
      count = @inner.read(slice)
      @bytes_read += count
      count
    end

    def write(slice : Bytes) : Nil
      @inner.write(slice)
    end

    def flush
      @inner.flush
    end

    def close
      @inner.close
    end
  end

  class OwnerWebSocket
    CONNECT_DEADLINE    = 5.seconds
    HALF_FRAME_DEADLINE = 250.milliseconds
    MAX_MESSAGE_BYTES   = 2 * 1024 * 1024
    MAX_FRAMES_PER_POLL = 8

    def initialize(@io : LiveIO, @tcp : TCPSocket)
      @counting_io = CountingLiveIO.new(@io)
      @protocol = HTTP::WebSocket::Protocol.new(@counting_io, masked: true)
      @buffer = Bytes.new(16 * 1024)
      @message = IO::Memory.new
      @message_opcode = HTTP::WebSocket::Protocol::Opcode::CONTINUATION
    end

    def self.connect(uri : URI, client_version : String) : OwnerWebSocket
      host = uri.hostname || raise ArgumentError.new("Live URL has no host")
      path = uri.request_target
      raise ArgumentError.new("Live URL has no path") unless path
      tls = ["https", "wss"].includes?(uri.scheme)
      port = uri.port || (tls ? 443 : 80)
      tcp = TCPSocket.new(host, port)
      tcp.read_timeout = CONNECT_DEADLINE
      tcp.write_timeout = CONNECT_DEADLINE
      io : LiveIO = tcp
      secured_socket : OpenSSL::SSL::Socket::Client? = nil
      begin
        if tls
          context = OpenSSL::SSL::Context::Client.new
          secured = OpenSSL::SSL::Socket::Client.new(tcp, context: context, sync_close: true, hostname: host)
          secured.read_timeout = CONNECT_DEADLINE
          secured.write_timeout = CONNECT_DEADLINE
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
        unless response.status.switching_protocols? && response.headers["Sec-WebSocket-Accept"]? == HTTP::WebSocket::Protocol.key_challenge(key)
          raise TransportError.new("Live WebSocket handshake was denied", "live dial")
        end
        tcp.read_timeout = HALF_FRAME_DEADLINE
        tcp.write_timeout = HALF_FRAME_DEADLINE
        if secured = secured_socket
          secured.read_timeout = HALF_FRAME_DEADLINE
          secured.write_timeout = HALF_FRAME_DEADLINE
        end
        OwnerWebSocket.new(io, tcp)
      rescue ex
        io.close rescue nil
        raise ex
      end
    end

    # Returns at most one complete UTF-8 text message. Ping and pong frames are
    # handled immediately by this same owner. A timeout before the first byte is
    # ordinary idleness; a timeout during Protocol#receive retires the socket.
    def poll : String?
      @counting_io.reset_bytes_read
      frames = 0
      loop do
        frames += 1
        info = @protocol.receive(@buffer)
        payload = @buffer[0, info.size]
        case info.opcode
        when .ping?
          @protocol.pong(payload)
          return nil if frames >= MAX_FRAMES_PER_POLL
          next
        when .pong?
          return nil if frames >= MAX_FRAMES_PER_POLL
          next
        when .close?
          raise TransportError.new("Live peer closed the WebSocket", "live read")
        when .text?, .continuation?
          if info.opcode.text? && @message.size == 0
            @message_opcode = info.opcode
          elsif @message_opcode.continuation?
            raise ProtocolError.new("unexpected Live continuation", "live read")
          end
          raise ProtocolError.new("Live frame exceeds byte budget", "live read") if @message.size + payload.size > MAX_MESSAGE_BYTES
          @message.write(payload)
          next unless info.final
          text = @message.to_s
          @message.clear
          @message_opcode = HTTP::WebSocket::Protocol::Opcode::CONTINUATION
          raise ProtocolError.new("Live text frame is not UTF-8", "live read") unless text.valid_encoding?
          return text
        when .binary?
          raise ProtocolError.new("binary Live frames are unsupported", "live read")
        else
          raise ProtocolError.new("unsupported Live frame", "live read")
        end
      end
    rescue ex : IO::TimeoutError
      # No frame bytes means an idle connection. Any consumed byte, or an
      # unfinished fragmented message, means parser state is now ambiguous and
      # the owner must abandon the whole connection before reconnecting.
      return nil if @counting_io.bytes_read == 0 && @message.size == 0
      raise TransportError.new("Live half-frame deadline exceeded", "live read")
    end

    def send_json(value)
      @protocol.send(value.to_json)
    end

    def close
      # Abort the raw descriptor first. TLS close_notify can otherwise wait on
      # an idle or flooding peer and violate the owner's close deadline.
      @tcp.close rescue nil
      @io.close rescue nil
    end
  end

  record StateVersion, query_set : UInt32, identity : UInt32, timestamp : String, timestamp_number : UInt64

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

    def initialize(@id, @response); end
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
      @close_mutex = Mutex.new
      spawn { run }
    end

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
      response = Channel(Nil | Error).new(1)
      @commands.send(UnsubscribeCommand.new(id, response))
      result = response.receive
      raise result if result.is_a?(Error)
    rescue Channel::ClosedError
      raise ClosedError.new("Live manager is closed", "live")
    end

    def debug_disconnect
      response = Channel(Nil | Error).new(1)
      @commands.send(DisconnectCommand.new(response))
      result = response.receive
      raise result if result.is_a?(Error)
    rescue Channel::ClosedError
      raise ClosedError.new("Live manager is closed", "live")
    end

    def close
      return if @close_mutex.synchronize { @closed }
      response = Channel(Nil | Error).new(1)
      @commands.send(CloseCommand.new(response))
      response.receive
      @close_mutex.synchronize { @closed = true }
    rescue Channel::ClosedError
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
                socket.try &.close
                socket = nil
                connection_count += 1
                last_close_reason = ex.message || "write failed"
                reset_remote(active)
                remote_version = zero_version
                query_set_version = 0_u32
                reconnect_at = Time.monotonic + backoff
                backoff = next_backoff(backoff)
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
              begin
                query_set_version = remove(socket.not_nil!, query_set_version, command.id)
              rescue ex
                publish_transport(active, ex)
                socket.try &.close
                socket = nil
                connection_count += 1
                last_close_reason = ex.message || "write failed"
                remote_version = zero_version
                query_set_version = 0_u32
                reconnect_at = active.empty? ? nil : Time.monotonic + backoff
                backoff = next_backoff(backoff)
              end
            end
            reconnect_at = nil if active.empty?
            command.response.send(nil)
          when DisconnectCommand
            if socket
              # The acknowledgement is sent only after the old connection has
              # been closed, all remote state retired, and a reconnect is set.
              socket.not_nil!.close
              socket = nil
              connection_count += 1
              last_close_reason = "DebugDisconnect"
              remote_version = zero_version
              query_set_version = 0_u32
              active.each_value { |state| state.rehydrating = true }
              reconnect_at = active.empty? ? nil : Time.monotonic
              command.response.send(nil)
            else
              command.response.send(TransportError.new("Live WebSocket is not connected", "live"))
            end
          when CloseCommand
            socket.try &.close
            active.each_value { |state| state.subscription.finish }
            command.response.send(nil)
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
              socket.try &.close
              socket = nil
              last_close_reason = ex.message || "Live dial failed"
              connection_count += 1
              reconnect_at = Time.monotonic + backoff
              backoff = next_backoff(backoff)
            end
          end

          if current = socket
            begin
              if raw = current.poll
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
              current.close
              socket = nil
              connection_count += 1
              last_close_reason = ex.message || "Live transport failed"
              remote_version = zero_version
              query_set_version = 0_u32
              active.each_value { |state| state.rehydrating = true }
              reconnect_at = active.empty? ? nil : Time.monotonic + backoff
              backoff = next_backoff(backoff)
            rescue ex
              error = TransportError.new(ex.message || "Live transport failed", "live read")
              publish_transport(active, error)
              current.close
              socket = nil
              connection_count += 1
              last_close_reason = error.message || "Live transport failed"
              remote_version = zero_version
              query_set_version = 0_u32
              active.each_value { |state| state.rehydrating = true }
              reconnect_at = active.empty? ? nil : Time.monotonic + backoff
              backoff = next_backoff(backoff)
            end
          else
            sleep 5.milliseconds
          end
        end
      end
    rescue Channel::ClosedError
    ensure
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
      socket = OwnerWebSocket.connect(live_uri, @client_version)
      connect = {"type" => "Connect", "sessionId" => UUID.random.to_s, "connectionCount" => connection_count, "lastCloseReason" => last_close_reason, "clientTs" => 0}
      connect["maxObservedTimestamp"] = max_timestamp unless max_timestamp == INITIAL_TIMESTAMP
      socket.send_json(connect)
      socket
    end

    private def replay(socket : OwnerWebSocket, active : Hash(Int32, LiveState)) : UInt32
      return 0_u32 if active.empty?
      modifications = active.keys.sort.map do |id|
        state = active[id]
        {"type" => "Add", "queryId" => id, "udfPath" => state.path, "args" => [state.args]}
      end
      socket.send_json({"type" => "ModifyQuerySet", "baseVersion" => 0, "newVersion" => 1, "modifications" => modifications})
      1_u32
    end

    private def add(socket : OwnerWebSocket, version : UInt32, id : Int32, state : LiveState) : UInt32
      socket.send_json({"type" => "ModifyQuerySet", "baseVersion" => version, "newVersion" => version + 1, "modifications" => [{"type" => "Add", "queryId" => id, "udfPath" => state.path, "args" => [state.args]}]})
      version + 1
    end

    private def remove(socket : OwnerWebSocket, version : UInt32, id : Int32) : UInt32
      socket.send_json({"type" => "ModifyQuerySet", "baseVersion" => version, "newVersion" => version + 1, "modifications" => [{"type" => "Remove", "queryId" => id}]})
      version + 1
    end

    private def zero_version
      StateVersion.new(0_u32, 0_u32, INITIAL_TIMESTAMP, 0_u64)
    end

    private def next_backoff(backoff : Time::Span)
      doubled = backoff * 2
      doubled > MAX_BACKOFF ? MAX_BACKOFF : doubled
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

    private def reset_remote(active)
      active.each_value { |state| state.rehydrating = true }
    end
  end

  class Client
    VERSION = "crystal-0.1.0"
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
      response = HTTP::Client.post(@url.resolve("/api/#{operation}"), headers: headers, body: body)
      raise TransportError.new("HTTP response too large", operation) if response.body.bytesize > 2 * 1024 * 1024
      decoded = JSON.parse(response.body)
      case decoded["status"].as_s
      when "success"
        Result.new(decoded["value"], decoded["logLines"]?.try(&.as_a.map(&.as_s)) || [] of String)
      when "error"
        logs = decoded["logLines"]?.try(&.as_a.map(&.as_s)) || [] of String
        raise FunctionError.new(decoded["errorMessage"].as_s, operation, decoded["errorData"]?, logs)
      else
        raise ProtocolError.new("unknown Convex response status", operation)
      end
    rescue ex : Error
      raise ex
    rescue ex
      raise TransportError.new(ex.message || "HTTP request failed", operation)
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
