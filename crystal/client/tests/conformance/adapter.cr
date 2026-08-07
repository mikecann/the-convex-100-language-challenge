require "json"
require "socket"
require "../../../client/client"

PROTOCOL                  =  1
MAX_SUBSCRIPTIONS         = 16
OUTPUT_MAX_LINE_BYTES     = 3 * 1024 * 1024
OUTPUT_MAX_EVENTS         = MAX_SUBSCRIPTIONS + 1
OUTPUT_MAX_RETAINED_BYTES = OUTPUT_MAX_EVENTS * OUTPUT_MAX_LINE_BYTES
OUTPUT_TERMINAL_BYTES     = 64 * 1024
OUTPUT_WRITE_DEADLINE     = {% if flag?(:adapter_test) %} 250.milliseconds {% else %} 1.second {% end %}
alias Event = Hash(String, JSON::Any)
record OutputEnvelope, encoded : String, retained_bytes : Int32, terminal : Bool, completion : Channel(Convex::TransportError | Nil)?

def json(value : String | Int32 | JSON::Any)
  value.is_a?(JSON::Any) ? value : JSON::Any.new(value)
end

def strings(values : Array(String))
  JSON::Any.new(values.map { |value| JSON::Any.new(value) })
end

class OutputBudget
  def initialize
    @mutex = Mutex.new
    @events = 0
    @bytes = 0
    @terminal = false
  end

  def reserve(bytes : Int32, terminal : Bool)
    @mutex.synchronize do
      if terminal
        raise Convex::ProtocolError.new("adapter terminal output reservation is occupied") if @terminal
        raise Convex::ProtocolError.new("adapter terminal event exceeds reserved byte budget") if bytes > OUTPUT_TERMINAL_BYTES
        @terminal = true
      else
        if @events >= OUTPUT_MAX_EVENTS || @bytes + bytes > OUTPUT_MAX_RETAINED_BYTES
          raise Convex::TransportError.new("adapter output budget is full")
        end
        @events += 1
        @bytes += bytes
      end
    end
  end

  def release(bytes : Int32, terminal : Bool)
    @mutex.synchronize do
      if terminal
        @terminal = false
      else
        @events -= 1
        @bytes -= bytes
      end
    end
  end

  def retained : {Int32, Int32, Bool}
    @mutex.synchronize { {@events, @bytes, @terminal} }
  end
end

# One writer fiber owns every output byte. Producers reserve the complete
# encoded line before enqueueing and the reservation remains charged until the
# final byte and flush complete. A separate small terminal slot means `close`
# can always enter the queue even when all 17 data slots are occupied.
class AdapterOutput
  getter budget : OutputBudget
  @failure : Convex::TransportError?

  def initialize(output : IO, input : IO? = nil)
    @output = output
    @input = input || output
    @budget = OutputBudget.new
    @queue = Channel(OutputEnvelope).new(OUTPUT_MAX_EVENTS + 1)
    @enqueue = Mutex.new
    @state = Mutex.new
    @failure = nil
    spawn { run }
  end

  # EOF is also an ordering boundary. Queue a zero-byte terminal barrier so
  # the process cannot return while earlier asynchronous lines are unwritten.
  def drain
    completion = Channel(Convex::TransportError | Nil).new(1)
    envelope = OutputEnvelope.new("", 0, true, completion)
    @enqueue.synchronize { enqueue(envelope) }
    outcome = completion.receive
    raise outcome if outcome.is_a?(Exception)
  end

  def transport_failed? : Bool
    @state.synchronize { !@failure.nil? }
  end

  def emit(event : Event, terminal = false, wait = false)
    encoded = event.to_json + "\n"
    raise Convex::ProtocolError.new("adapter event exceeds encoded-byte budget") if encoded.bytesize > OUTPUT_MAX_LINE_BYTES
    completion = wait ? Channel(Convex::TransportError | Nil).new(1) : nil
    envelope = OutputEnvelope.new(encoded, encoded.bytesize, terminal, completion)
    @enqueue.synchronize { enqueue(envelope) }
    if completed = completion
      outcome = completed.receive
      raise outcome if outcome.is_a?(Exception)
    end
  end

  # Admission and the caller's validity check share the same ordering lock.
  # Subscription invalidation can therefore act as an acknowledgement barrier:
  # an event is either queued before the later ack or rejected as stale.
  def emit_if(event : Event, &)
    encoded = event.to_json + "\n"
    raise Convex::ProtocolError.new("adapter event exceeds encoded-byte budget") if encoded.bytesize > OUTPUT_MAX_LINE_BYTES
    envelope = OutputEnvelope.new(encoded, encoded.bytesize, false, nil)
    @enqueue.synchronize do
      return unless yield
      enqueue(envelope)
    end
  end

  private def enqueue(envelope : OutputEnvelope)
    # Once the single writer fails, reject producers synchronously. This is
    # important for the terminal close path: its caller must not report a
    # successful adapter shutdown after the controller has permanently
    # stopped reading and the output deadline has retired the connection.
    if failure = @state.synchronize { @failure }
      raise failure
    end
    @budget.reserve(envelope.retained_bytes, envelope.terminal)
    @queue.send(envelope)
  end

  private def run
    loop do
      envelope = @queue.receive
      failure = @state.synchronize { @failure }
      begin
        raise failure if failure
        write_with_deadline(envelope.encoded)
        envelope.completion.try &.send(nil)
      rescue ex
        failure = ex.as?(Convex::TransportError) || Convex::TransportError.new(ex.message || "adapter output failed")
        @state.synchronize { @failure ||= failure }
        envelope.completion.try &.send(failure)
      ensure
        @budget.release(envelope.retained_bytes, envelope.terminal)
      end
    end
  rescue Channel::ClosedError
  end

  private def write_with_deadline(encoded : String)
    state = Mutex.new
    completed = false
    expired = false
    spawn do
      sleep OUTPUT_WRITE_DEADLINE
      should_close = state.synchronize do
        unless completed
          expired = true
          true
        else
          false
        end
      end
      if should_close
        # Output failure is process-wide. Closing both directions wakes a
        # command loop which would otherwise remain blocked forever after a
        # permanently stopped stdout/controller connection.
        @output.close rescue nil
        @input.close rescue nil
      end
    end
    begin
      @output.write(encoded.to_slice)
      @output.flush
      raise Convex::TransportError.new("adapter output deadline exceeded") if state.synchronize { expired }
    rescue ex
      raise Convex::TransportError.new("adapter output deadline exceeded") if state.synchronize { expired }
      raise ex
    ensure
      state.synchronize { completed = true }
    end
  end
end

def emit_event(writer : AdapterOutput, event : Event, terminal = false, wait = false)
  writer.emit(event, terminal, wait)
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
  def emit(writer : AdapterOutput, event : Event)
    pause = @mutex.synchronize do
      return unless @active
      {@pause_entered, @pause_resume}
    end
    if entered = pause[0]
      entered.send(nil)
      pause[1].not_nil!.receive
    end
    writer.emit_if(event) { @mutex.synchronize { @active } }
  end
end

def protocol_error(message : String) : Convex::ProtocolError
  Convex::ProtocolError.new(message)
end

def command_object(value : JSON::Any) : Hash(String, JSON::Any)
  value.as_h
rescue TypeCastError
  raise protocol_error("adapter command must be an object")
end

def command_string(command : Hash(String, JSON::Any), key : String) : String
  value = command[key]? || raise protocol_error("adapter command is missing #{key}")
  value.as_s
rescue TypeCastError
  raise protocol_error("adapter command #{key} must be a string")
end

def command_identifier(command : Hash(String, JSON::Any), key : String) : String
  value = command_string(command, key)
  if value.strip.empty? || value.size > 128
    raise protocol_error("adapter command #{key} must be nonblank and at most 128 characters")
  end
  value
end

def command_args(command : Hash(String, JSON::Any), required : Bool = true) : Hash(String, JSON::Any)
  value = command["args"]?
  return {} of String => JSON::Any if !value && !required
  raise protocol_error("adapter command is missing args") unless value
  value.not_nil!.as_h
rescue TypeCastError
  raise protocol_error("adapter command args must be an object")
end

def command_path(command : Hash(String, JSON::Any), required : Bool = true, function_path : Bool = true) : String?
  value = command["path"]?
  return nil if !value && !required
  raise protocol_error("adapter command is missing path") unless value
  path = value.not_nil!.as_s
  if function_path && (path.strip.empty? || path.size < 3)
    raise protocol_error("adapter command path must be nonblank and at least 3 characters")
  end
  path
rescue TypeCastError
  raise protocol_error("adapter command path must be a string")
end

def validate_command_keys(command : Hash(String, JSON::Any), allowed : Array(String), required : Array(String))
  if missing = required.find { |key| !command.has_key?(key) }
    raise protocol_error("adapter command is missing #{missing}")
  end
  if unexpected = command.keys.find { |key| !allowed.includes?(key) }
    raise protocol_error("adapter command has unexpected property #{unexpected}")
  end
end

def validate_command(command : Hash(String, JSON::Any), operation : String)
  case operation
  when "hello"
    validate_command_keys(command, ["protocolVersion", "id", "op"], ["protocolVersion", "id", "op"])
    version = command["protocolVersion"]
    unless version.raw.is_a?(Int64) && version.as_i == PROTOCOL
      raise protocol_error("unsupported adapter protocol")
    end
  when "query", "mutation", "action"
    validate_command_keys(command, ["id", "op", "path", "args"], ["id", "op", "path", "args"])
    command_path(command)
    command_args(command)
  when "subscribe"
    validate_command_keys(command, ["id", "op", "subscriptionId", "path", "args"], ["id", "op", "subscriptionId", "path", "args"])
    command_identifier(command, "subscriptionId")
    command_path(command)
    command_args(command)
  when "unsubscribe"
    # The shared schema permits optional path/args on the combined subscribe
    # shape. Validate their types if present instead of silently narrowing them.
    validate_command_keys(command, ["id", "op", "subscriptionId", "path", "args"], ["id", "op", "subscriptionId"])
    command_identifier(command, "subscriptionId")
    # The shared unsubscribe shape permits any string, including an empty
    # informational path. Only operations that invoke Convex require a
    # nonblank function path.
    command_path(command, required: false, function_path: false) if command["path"]?
    command_args(command, required: false) if command["args"]?
  when "setAuth"
    validate_command_keys(command, ["id", "op", "token"], ["id", "op", "token"])
    command_string(command, "token")
  when "close", "debugDisconnect"
    validate_command_keys(command, ["id", "op"], ["id", "op"])
  else
    raise protocol_error("unknown adapter operation")
  end
end

def run_adapter(input : IO, output : IO)
  client = Convex::Client.new(ENV.fetch("CONVEX_URL"), ENV["CONVEX_AUTH_TOKEN"]?)
  subscriptions = {} of String => {Convex::Subscription, SubscriptionRelay}
  writer = AdapterOutput.new(output, input)
  input.each_line do |line|
    id : String? = nil
    begin
      parsed = begin
        JSON.parse(line)
      rescue JSON::ParseException
        raise protocol_error("invalid adapter JSON")
      end
      command = command_object(parsed)
      id = command_identifier(command, "id")
      command_id = id.not_nil!
      operation = command_string(command, "op")
      validate_command(command, operation)
      case operation
      when "hello"
        emit_event(writer, {"protocolVersion" => json(PROTOCOL), "id" => json(command_id), "type" => json("ready"), "language" => json("crystal"), "implementation" => json("native-crystal-#{Crystal::VERSION}"), "runtime" => json("crystal-#{Crystal::VERSION}")})
      when "query", "mutation", "action"
        args = command_args(command)
        result = case operation
                 when "query"    then client.query(command["path"].as_s, args)
                 when "mutation" then client.mutation(command["path"].as_s, args)
                 else                 client.action(command["path"].as_s, args)
                 end
        event = {"id" => json(command_id), "type" => json("result"), "value" => result.value} of String => JSON::Any
        event["logs"] = strings(result.logs) unless result.logs.empty?
        emit_event(writer, event)
      when "setAuth"
        client.set_auth(command["token"].as_s)
        emit_event(writer, {"id" => json(command_id), "type" => json("ack")})
      when "subscribe"
        sid = command_identifier(command, "subscriptionId")
        if previous = subscriptions.delete(sid)
          previous[1].invalidate
          previous[0].close
        end
        raise Convex::ProtocolError.new("adapter subscription count exceeds output budget") if subscriptions.size >= MAX_SUBSCRIPTIONS
        sub = client.subscribe(command_path(command).not_nil!, command_args(command))
        relay = SubscriptionRelay.new
        subscriptions[sid] = {sub, relay}
        emit_event(writer, {"id" => json(command_id), "type" => json("ack")})
        spawn do
          loop do
            update = sub.next
            if error = update.error
              relay.emit(writer, {"type" => json("subscription"), "subscriptionId" => json(sid), "error" => error_details(error)})
            else
              event = {"type" => json("subscription"), "subscriptionId" => json(sid), "value" => update.value.not_nil!} of String => JSON::Any
              event["logs"] = strings(update.logs) unless update.logs.empty?
              relay.emit(writer, event)
            end
          end
        rescue Convex::ClosedError
        end
      when "unsubscribe"
        sid = command_identifier(command, "subscriptionId")
        if previous = subscriptions.delete(sid)
          previous[1].invalidate
          previous[0].close
        end
        emit_event(writer, {"id" => json(command_id), "type" => json("ack")})
      when "debugDisconnect"
        client.debug_disconnect
        emit_event(writer, {"id" => json(command_id), "type" => json("ack")})
      when "close"
        subscriptions.each_value do |state|
          state[1].invalidate
          state[0].close
        end
        client.close
        emit_event(writer, {"id" => json(command_id), "type" => json("closed")}, terminal: true, wait: true)
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
      emit_event(writer, event)
    end
  end
  writer.drain
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
