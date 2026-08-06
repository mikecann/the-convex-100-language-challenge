require "json"
require "socket"
require "../../../client/client"

PROTOCOL                  =  1
MAX_SUBSCRIPTIONS         = 16
OUTPUT_MAX_LINE_BYTES     = 3 * 1024 * 1024
OUTPUT_MAX_EVENTS         = MAX_SUBSCRIPTIONS + 1
OUTPUT_MAX_RETAINED_BYTES = OUTPUT_MAX_EVENTS * OUTPUT_MAX_LINE_BYTES
alias Event = Hash(String, JSON::Any)

def json(value : String | Int32 | JSON::Any)
  value.is_a?(JSON::Any) ? value : JSON::Any.new(value)
end

def strings(values : Array(String))
  JSON::Any.new(values.map { |value| JSON::Any.new(value) })
end

def emit_event(output : IO, writer : Mutex, event : Event)
  encoded = event.to_json
  raise Convex::ProtocolError.new("adapter event exceeds encoded-byte budget") if encoded.bytesize + 1 > OUTPUT_MAX_LINE_BYTES
  # There is deliberately no output mailbox. Each of the capped subscription
  # relays can retain one dequeued event while waiting here, plus one controller
  # response. Their conservative encoded ceiling is OUTPUT_MAX_RETAINED_BYTES.
  writer.synchronize { output.puts(encoded); output.flush }
end

def error_details(error : Exception) : JSON::Any
  details = {"name" => JSON::Any.new(error.class.name.split("::").last), "message" => JSON::Any.new(error.message || "error")} of String => JSON::Any
  if convex_error = error.as?(Convex::Error)
    if operation = convex_error.operation
      details["operation"] = JSON::Any.new(operation)
    end
    if data = convex_error.data
      details["data"] = data
    end
    details["logs"] = strings(convex_error.logs) unless convex_error.logs.empty?
  end
  JSON::Any.new(details)
end

class SubscriptionRelay
  @pause_entered : Channel(Nil)?
  @pause_resume : Channel(Nil)?

  def initialize
    @mutex = Mutex.new
    @active = true
    @pause_entered = nil
    @pause_resume = nil
  end

  def invalidate
    @mutex.synchronize { @active = false }
  end

  # Deterministic conformance-only hook. It pauses after the subscription
  # fiber has dequeued an update but before it tries to cross the writer lock.
  def pause_after_dequeue(entered : Channel(Nil), resume : Channel(Nil))
    @mutex.synchronize do
      @pause_entered = entered
      @pause_resume = resume
    end
  end

  # The writer lock makes invalidation an acknowledgement barrier. A relay
  # that already owns the writer may finish before the ack; a relay that has
  # not emitted yet observes inactive and cannot cross the ack.
  def emit(output : IO, writer : Mutex, event : Event)
    pause = @mutex.synchronize do
      return unless @active
      {@pause_entered, @pause_resume}
    end
    if entered = pause[0]
      entered.send(nil)
      pause[1].not_nil!.receive
    end
    writer.synchronize do
      return unless @mutex.synchronize { @active }
      encoded = event.to_json
      raise Convex::ProtocolError.new("adapter event exceeds encoded-byte budget") if encoded.bytesize + 1 > OUTPUT_MAX_LINE_BYTES
      output.puts(encoded)
      output.flush
    end
  end
end

def run_adapter(input : IO, output : IO)
  client = Convex::Client.new(ENV.fetch("CONVEX_URL"), ENV["CONVEX_AUTH_TOKEN"]?)
  subscriptions = {} of String => {Convex::Subscription, SubscriptionRelay}
  writer = Mutex.new
  input.each_line do |line|
    id : String? = nil
    begin
      command = JSON.parse(line)
      id = command["id"].as_s
      command_id = id.not_nil!
      case command["op"].as_s
      when "hello"
        raise Convex::ProtocolError.new("unsupported adapter protocol") unless command["protocolVersion"].as_i == PROTOCOL
        emit_event(output, writer, {"protocolVersion" => json(PROTOCOL), "id" => json(command_id), "type" => json("ready"), "language" => json("crystal"), "implementation" => json("native-crystal-#{Crystal::VERSION}"), "runtime" => json("crystal-#{Crystal::VERSION}")})
      when "query", "mutation", "action"
        args = command["args"]?.try(&.as_h) || {} of String => JSON::Any
        result = case command["op"].as_s
                 when "query"    then client.query(command["path"].as_s, args)
                 when "mutation" then client.mutation(command["path"].as_s, args)
                 else                 client.action(command["path"].as_s, args)
                 end
        event = {"id" => json(command_id), "type" => json("result"), "value" => result.value} of String => JSON::Any
        event["logs"] = strings(result.logs) unless result.logs.empty?
        emit_event(output, writer, event)
      when "setAuth"
        client.set_auth(command["token"].as_s)
        emit_event(output, writer, {"id" => json(command_id), "type" => json("ack")})
      when "subscribe"
        sid = command["subscriptionId"].as_s
        if previous = subscriptions.delete(sid)
          previous[1].invalidate
          previous[0].close
        end
        raise Convex::ProtocolError.new("adapter subscription count exceeds output budget") if subscriptions.size >= MAX_SUBSCRIPTIONS
        sub = client.subscribe(command["path"].as_s, command["args"]?.try(&.as_h) || {} of String => JSON::Any)
        relay = SubscriptionRelay.new
        subscriptions[sid] = {sub, relay}
        emit_event(output, writer, {"id" => json(command_id), "type" => json("ack")})
        spawn do
          loop do
            update = sub.next
            if error = update.error
              relay.emit(output, writer, {"type" => json("subscription"), "subscriptionId" => json(sid), "error" => error_details(error)})
            else
              event = {"type" => json("subscription"), "subscriptionId" => json(sid), "value" => update.value.not_nil!} of String => JSON::Any
              event["logs"] = strings(update.logs) unless update.logs.empty?
              relay.emit(output, writer, event)
            end
          end
        rescue Convex::ClosedError
        end
      when "unsubscribe"
        sid = command["subscriptionId"].as_s
        if previous = subscriptions.delete(sid)
          previous[1].invalidate
          previous[0].close
        end
        emit_event(output, writer, {"id" => json(command_id), "type" => json("ack")})
      when "debugDisconnect"
        client.debug_disconnect
        emit_event(output, writer, {"id" => json(command_id), "type" => json("ack")})
      when "close"
        subscriptions.each_value do |state|
          state[1].invalidate
          state[0].close
        end
        client.close
        emit_event(output, writer, {"id" => json(command_id), "type" => json("closed")})
        break
      else
        raise Convex::ProtocolError.new("unknown adapter operation")
      end
    rescue ex
      event = {} of String => JSON::Any
      if error_id = id
        event["id"] = json(error_id)
      end
      event["type"] = json("error")
      event["error"] = error_details(ex)
      emit_event(output, writer, event)
    end
  end
ensure
  client.try &.close
end

{% unless flag?(:adapter_test) %}
  if address = ENV["ADAPTER_LISTEN"]?
    host, port = address.split(":", 2)
    server = TCPServer.new(host, port.to_i)
    connection = server.accept
    begin
      run_adapter(connection, connection)
    ensure
      connection.close
      server.close
    end
  else
    run_adapter(STDIN, STDOUT)
  end
{% end %}
