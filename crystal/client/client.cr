require "http/client"
require "http/web_socket"
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
  end

  # Subscription delivery is bounded by both event count and encoded bytes.
  # Dropping the oldest value keeps a slow adapter consumer from retaining an
  # unbounded stream while preserving the newest Convex state.
  class Subscription
    MAX_EVENTS = 16
    MAX_BYTES  = 4 * 1024 * 1024
    getter id : Int32

    def initialize(@manager : LiveManager, @id : Int32)
      @queue = Channel(Update).new(MAX_EVENTS)
      @bytes = 0
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
      @mutex.synchronize { @bytes -= update.to_json.bytesize }
      update
    rescue Channel::ClosedError
      raise ClosedError.new("Live subscription is closed", "live")
    end

    def deliver(update : Update)
      encoded = update.to_json.bytesize
      return if encoded > MAX_BYTES
      @mutex.synchronize do
        return if @finished

        # Keep both bounds real. A full queue can still be well below the byte
        # limit, and a few large JSON values can fill the byte budget first.
        while @bytes + encoded > MAX_BYTES
          select
          when dropped = @queue.receive
            @bytes -= dropped.to_json.bytesize
          else
            break
          end
        end

        begin
          select
          when @queue.send(update)
            @bytes += encoded
          else
            select
            when dropped = @queue.receive
              @bytes -= dropped.to_json.bytesize
            else
              return
            end
            select
            when @queue.send(update)
              @bytes += encoded
            else
              # A slow consumer must never make the Live owner wait. The
              # newest state is optional when the bounded queue is racing
              # with a consumer, so drop this update rather than blocking.
            end
          end
        rescue Channel::ClosedError
          # finish closed the queue while this update was being prepared.
        end
      end
    end

    def finish
      @mutex.synchronize do
        return if @finished
        @finished = true
        # Closing wakes a blocked consumer immediately. Draining an open
        # channel with receive? can wait forever once its last value is gone.
        @queue.close
        @bytes = 0
      end
    end

    def close
      @manager.unsubscribe(@id)
    rescue ClosedError
    end
  end

  class LiveManager
    INITIAL_TIMESTAMP = "AAAAAAAAAAA="

    def initialize(@base_url : URI, @client_version : String)
      @mutex = Mutex.new
      @subscriptions = {} of Int32 => {String, JSON::Any, Subscription}
      @commands = Channel(Tuple(Symbol, Int32?, String?, JSON::Any?, Channel(Nil | Error))).new(64)
      @incoming = Channel(String).new(64)
      @closed = false
      @next_id = 0
      @query_set_version = 0_u32
      spawn { run }
    end

    def subscribe(path : String, args : JSON::Any) : Subscription
      response = Channel(Nil | Error).new(1)
      @commands.send({:subscribe, nil, path, args, response})
      response.receive
      @mutex.synchronize { @subscriptions.values.last[2] }
    end

    def unsubscribe(id : Int32)
      response = Channel(Nil | Error).new(1)
      @commands.send({:unsubscribe, id, nil, nil, response})
      response.receive
    end

    def debug_disconnect
      response = Channel(Nil | Error).new(1)
      @commands.send({:disconnect, nil, nil, nil, response})
      response.receive
    end

    def close
      return if @closed
      response = Channel(Nil | Error).new(1)
      @commands.send({:close, nil, nil, nil, response})
      response.receive
      @closed = true
    end

    private def run
      socket : HTTP::WebSocket? = nil
      loop do
        select
        when command = @commands.receive
          type, id, path, args, response = command
          begin
            case type
            when :subscribe
              query_id = @mutex.synchronize do
                value = @next_id
                @next_id += 1
                value
              end
              subscription = Subscription.new(self, query_id)
              @mutex.synchronize { @subscriptions[query_id] = {path.not_nil!, args.not_nil!, subscription} }
              connect(socket) unless socket
              if socket
                send_query_set(socket.not_nil!, query_id, path.not_nil!, args.not_nil!)
              end
              response.send(nil)
            when :unsubscribe
              state = @mutex.synchronize { @subscriptions.delete(id.not_nil!) }
              state.try &.[2].finish
              if socket
                base_version = @query_set_version
                send_json(socket, {"type" => "ModifyQuerySet", "baseVersion" => base_version, "newVersion" => base_version + 1, "modifications" => [{"type" => "Remove", "queryId" => id.not_nil!}]})
                @query_set_version = base_version + 1
              end
              response.send(nil)
            when :disconnect
              raise TransportError.new("Live WebSocket is not connected", "live") unless socket
              socket.not_nil!.close
              socket = nil
              @query_set_version = 0_u32
              response.send(nil)
            when :close
              socket.try &.close
              @mutex.synchronize { @subscriptions.each_value { |state| state[2].finish } }
              response.send(nil)
              break
            end
          rescue ex : Error
            response.send(ex)
          rescue ex
            response.send(TransportError.new(ex.message || "Live transport failed", "live"))
          end
        when raw = @incoming.receive
          handle_message(raw)
        else
          if !socket && @mutex.synchronize { !@subscriptions.empty? }
            begin
              socket = connect(nil)
              @query_set_version = 0_u32
              @mutex.synchronize { @subscriptions.each { |id, state| send_query_set(socket.not_nil!, id, state[0], state[1]) } }
            rescue
              sleep 250.milliseconds
            end
          else
            sleep 10.milliseconds
          end
        end
      end
    rescue Channel::ClosedError
    ensure
      @mutex.synchronize { @subscriptions.each_value { |state| state[2].finish } }
    end

    private def connect(_socket) : HTTP::WebSocket
      uri = @base_url.dup
      uri.scheme = uri.scheme == "https" ? "wss" : "ws"
      uri.path = "#{uri.path.rstrip('/')}/api/sync"
      socket = HTTP::WebSocket.new(uri, HTTP::Headers{"Convex-Client" => @client_version})
      socket.on_message { |message| @incoming.send(message) }
      spawn { socket.run rescue nil }
      send_json(socket, {"type" => "Connect", "sessionId" => UUID.random.to_s, "connectionCount" => 0, "lastCloseReason" => "InitialConnect", "clientTs" => 0})
      socket
    end

    private def send_query_set(socket : HTTP::WebSocket, id : Int32, path : String, args : JSON::Any)
      base_version = @query_set_version
      send_json(socket, {"type" => "ModifyQuerySet", "baseVersion" => base_version, "newVersion" => base_version + 1, "modifications" => [{"type" => "Add", "queryId" => id, "udfPath" => path, "args" => [args]}]})
      @query_set_version = base_version + 1
    end

    private def send_json(socket : HTTP::WebSocket, value)
      socket.send(value.to_json)
    end

    private def handle_message(raw : String)
      message = JSON.parse(raw)
      case message["type"].as_s
      when "Transition"
        message["modifications"].as_a.each do |mod|
          id = mod["queryId"].as_i
          state = @mutex.synchronize { @subscriptions[id]? }
          next unless state
          if mod["type"].as_s == "QueryUpdated"
            state[2].deliver(Update.new(mod["value"], nil, mod["logLines"]?.try(&.as_a.map(&.as_s)) || [] of String))
          elsif mod["type"].as_s == "QueryFailed"
            logs = mod["logLines"]?.try(&.as_a.map(&.as_s)) || [] of String
            state[2].deliver(Update.new(nil, FunctionError.new(mod["errorMessage"].as_s, "query", mod["errorData"]?), logs))
          end
        end
      when "Ping"
      when "FatalError", "AuthError"
        raise ProtocolError.new("#{message["type"]}: #{message["error"]}", "live")
      else
        raise ProtocolError.new("unknown Live message #{message["type"]}", "live")
      end
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
      @live.try &.debug_disconnect || raise TransportError.new("Live WebSocket is not connected", "live")
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
        json.field "error", error.message
      elsif value = @value
        json.field "value", value
      end
    end
  end
end
