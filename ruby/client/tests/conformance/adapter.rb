#!/usr/local/bin/ruby
# frozen_string_literal: true

require "json"
require "socket"
require "thread"

$LOAD_PATH.unshift(ENV.fetch("CONVEX_CLIENT_PATH", File.expand_path("../..", __dir__)))
require "convex"

ADAPTER_PROTOCOL_VERSION = 1

# NDJSONWriter keeps concurrent subscription events from interleaving with
# command responses. stdout belongs exclusively to the adapter protocol.
class NDJSONWriter
  def initialize(io)
    @io = io
    @io.sync = true
    @mutex = Mutex.new
  end

  def write(event)
    @mutex.synchronize { @io.puts(JSON.generate(event)) }
  end
end

def adapter_error(error)
  details = {
    "name" => error.class.name.split("::").last,
    "message" => error.message,
    "data" => nil
  }
  details["data"] = error.data if error.is_a?(Convex::FunctionError)
  details
end

def run_adapter(input, output)
  writer = NDJSONWriter.new(output)
  client = nil
  client_mutex = Mutex.new
  subscriptions = {}
  subscription_threads = {}

  ensure_client = lambda do
    client_mutex.synchronize do
      next client if client

      deployment_url = ENV.fetch("CONVEX_URL")
      client = Convex::Client.new(
        deployment_url,
        bearer_token: ENV["CONVEX_AUTH_TOKEN"],
        client_version: "ruby-0.1.0"
      )
    end
  end

  write_error = lambda do |id, error, subscription_id = nil|
    event = {
      "type" => subscription_id ? "subscription" : "error",
      "error" => adapter_error(error)
    }
    event["id"] = id if id && !subscription_id
    event["subscriptionId"] = subscription_id if subscription_id
    event["logs"] = error.logs if error.is_a?(Convex::FunctionError)
    writer.write(event)
  end

  input.each_line do |line|
    command = JSON.parse(line)
    id = command["id"]
    case command["op"]
    when "hello"
      unless command["protocolVersion"] == ADAPTER_PROTOCOL_VERSION
        raise Convex::ProtocolError,
              "unsupported adapter protocol version #{command["protocolVersion"].inspect}"
      end
      writer.write(
        "protocolVersion" => ADAPTER_PROTOCOL_VERSION,
        "id" => id,
        "type" => "ready",
        "language" => "ruby",
        "implementation" => "native-ruby-#{RUBY_VERSION}",
        "runtime" => "ruby-#{RUBY_VERSION}"
      )
    when "query", "mutation", "action"
      result = ensure_client.call.public_send(
        command.fetch("op"),
        command.fetch("path"),
        command["args"] || {}
      )
      writer.write(
        "id" => id,
        "type" => "result",
        "value" => result.value,
        "logs" => result.logs
      )
    when "setAuth"
      ensure_client.call.set_auth(command["token"].to_s)
      writer.write("id" => id, "type" => "ack")
    when "subscribe"
      subscription_id = command.fetch("subscriptionId")
      subscriptions.delete(subscription_id)&.close
      subscription_threads.delete(subscription_id)&.join
      subscription = ensure_client.call.subscribe(command.fetch("path"), command["args"] || {})
      subscriptions[subscription_id] = subscription
      writer.write("id" => id, "type" => "ack")

      # Each adapter subscription forwards the real client's typed updates.
      # The public client itself is callback-free and keeps its protocol thread
      # independent from slow NDJSON output.
      subscription_threads[subscription_id] = Thread.new do
        loop do
          update = subscription.next_update
          if update.error
            write_error.call(nil, update.error, subscription_id)
          else
            writer.write(
              "type" => "subscription",
              "subscriptionId" => subscription_id,
              "value" => update.value,
              "logs" => update.logs
            )
          end
        end
      rescue Convex::ClosedError
        nil
      rescue StandardError => error
        write_error.call(nil, error, subscription_id)
      end
    when "unsubscribe"
      subscription_id = command.fetch("subscriptionId")
      subscriptions.delete(subscription_id)&.close
      subscription_threads.delete(subscription_id)&.join
      writer.write("id" => id, "type" => "ack")
    when "debugDisconnect"
      ensure_client.call.debug_disconnect_for_adapter
      writer.write("id" => id, "type" => "ack")
    when "close"
      subscriptions.each_value(&:close)
      subscriptions.clear
      subscription_threads.each_value(&:join)
      subscription_threads.clear
      client_mutex.synchronize { client&.close }
      writer.write("id" => id, "type" => "closed")
      return
    else
      raise Convex::ProtocolError, "unknown adapter operation #{command["op"].inspect}"
    end
  rescue JSON::ParserError => error
    write_error.call(nil, Convex::ProtocolError.new("decode command: #{error.message}"))
  rescue StandardError => error
    write_error.call(id, error)
  end
ensure
  subscriptions&.each_value(&:close)
  subscription_threads&.each_value(&:join)
  client&.close
end

listen_address = ENV["ADAPTER_LISTEN"]
if listen_address.to_s.empty?
  run_adapter($stdin, $stdout)
else
  host, port = listen_address.split(":", 2)
  server = TCPServer.new(host, Integer(port, 10))
  warn "adapter listening on #{listen_address}"
  connection = server.accept
  begin
    run_adapter(connection, connection)
  ensure
    connection.close
    server.close
  end
end
