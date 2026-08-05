require "json"
require "socket"
require "../../../client/client"

PROTOCOL = 1
alias EventValue = JSON::Any | String | Int32 | Array(String) | Hash(String, String)
alias Event = Hash(String, EventValue)

def emit_event(output : IO, writer : Mutex, event : Event)
  writer.synchronize { output.puts(event.to_json); output.flush }
end

def error_details(error : Exception)
  {"name" => error.class.name.split("::").last, "message" => error.message || "error"}
end

def run_adapter(input : IO, output : IO)
  client = Convex::Client.new(ENV.fetch("CONVEX_URL"), ENV["CONVEX_AUTH_TOKEN"]?)
  subscriptions = {} of String => Convex::Subscription
  writer = Mutex.new
  input.each_line do |line|
    id = "error"
    begin
      command = JSON.parse(line)
      id = command["id"].as_s
      case command["op"].as_s
      when "hello"
        raise Convex::ProtocolError.new("unsupported adapter protocol") unless command["protocolVersion"].as_i == PROTOCOL
        emit_event(output, writer, {"protocolVersion" => PROTOCOL, "id" => id, "type" => "ready", "language" => "crystal", "implementation" => "native-crystal-#{Crystal::VERSION}", "runtime" => "crystal-#{Crystal::VERSION}"})
      when "query", "mutation", "action"
        args = command["args"]?.try(&.as_h) || {} of String => JSON::Any
        result = case command["op"].as_s
                 when "query"    then client.query(command["path"].as_s, args)
                 when "mutation" then client.mutation(command["path"].as_s, args)
                 else                 client.action(command["path"].as_s, args)
                 end
        emit_event(output, writer, {"id" => id, "type" => "result", "value" => result.value, "logs" => result.logs})
      when "setAuth"
        client.set_auth(command["token"].as_s)
        emit_event(output, writer, {"id" => id, "type" => "ack"})
      when "subscribe"
        sid = command["subscriptionId"].as_s
        subscriptions.delete(sid).try &.close
        sub = client.subscribe(command["path"].as_s, command["args"]?.try(&.as_h) || {} of String => JSON::Any)
        subscriptions[sid] = sub
        emit_event(output, writer, {"id" => id, "type" => "ack"})
        spawn do
          loop do
            update = sub.next
            if error = update.error
              emit_event(output, writer, {"type" => "subscription", "subscriptionId" => sid, "error" => error_details(error)})
            else
              emit_event(output, writer, {"type" => "subscription", "subscriptionId" => sid, "value" => update.value.not_nil!, "logs" => update.logs})
            end
          end
        rescue Convex::ClosedError
        end
      when "unsubscribe"
        sid = command["subscriptionId"].as_s
        subscriptions.delete(sid).try &.close
        emit_event(output, writer, {"id" => id, "type" => "ack"})
      when "debugDisconnect"
        client.debug_disconnect
        emit_event(output, writer, {"id" => id, "type" => "ack"})
      when "close"
        subscriptions.each_value(&.close)
        client.close
        emit_event(output, writer, {"id" => id, "type" => "closed"})
        break
      else
        raise Convex::ProtocolError.new("unknown adapter operation")
      end
    rescue ex
      emit_event(output, writer, {"id" => id, "type" => "error", "error" => error_details(ex)})
    end
  end
ensure
  client.try &.close
end

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
