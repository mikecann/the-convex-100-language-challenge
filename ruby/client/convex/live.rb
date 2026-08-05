# frozen_string_literal: true

require "json"
require "securerandom"
require "thread"

require_relative "web_socket"

module Convex
  Update = Data.define(:value, :error, :logs)

  # A reactive query subscription. `next_update` blocks for the next current
  # value, while `close` removes the query from the shared Live connection.
  class Subscription
    CLOSED = Object.new.freeze

    def initialize(manager, query_id)
      @manager = manager
      @query_id = query_id
      @updates = SizedQueue.new(16)
      @mutex = Mutex.new
      @closed = false
    end

    def next_update(timeout: nil)
      update = if timeout
                 readable, = IO.select([queue_signal_reader], nil, nil, timeout)
                 raise TransportError.new("timed out waiting for Live update", operation: "live") unless readable

                 queue_pop
               else
                 queue_pop
               end
      raise ClosedError, "Live subscription is closed" if update.equal?(CLOSED)

      update
    end

    def close
      should_close = @mutex.synchronize do
        next false if @closed

        @closed = true
        true
      end
      @manager.unsubscribe(@query_id) if should_close
      nil
    end

    # LiveManager calls this only after an atomic transition is committed. A
    # slow consumer keeps the newest reactive value rather than blocking sync.
    def deliver(update)
      @updates.push(update, true)
      signal_queue
    rescue ThreadError
      @updates.pop(true) rescue nil
      @updates.push(update, true) rescue nil
      signal_queue
    end

    def finish
      @updates.push(CLOSED, true)
      signal_queue
    rescue ThreadError
      @updates.pop(true) rescue nil
      retry
    end

    private

    # A pipe lets IO.select provide a timeout without using Ruby's asynchronous
    # Timeout exceptions inside protocol code.
    def queue_signal_reader
      @signal_mutex ||= Mutex.new
      @signal_mutex.synchronize do
        unless @signal_reader
          @signal_reader, @signal_writer = IO.pipe
          @signal_writer.sync = true
          signal_queue unless @updates.empty?
        end
      end
      @signal_reader
    end

    def signal_queue
      return unless @signal_writer

      @signal_writer.write_nonblock(".")
    rescue IO::WaitWritable, Errno::EPIPE
      nil
    end

    def queue_pop
      value = @updates.pop
      @signal_reader&.read_nonblock(1) rescue nil
      value
    end
  end

  # Owns one WebSocket and all active reactive queries. A single worker thread
  # serializes query-set versions and transition application, avoiding races
  # between subscriptions, reconnects, and incoming messages.
  class LiveManager
    INITIAL_TIMESTAMP = "AAAAAAAAAAA="
    INITIAL_BACKOFF = 0.1
    MAX_BACKOFF = 15.0
    INACTIVITY_LIMIT = 30.0

    def initialize(deployment_url, client_version)
      uri = URI.parse(deployment_url)
      uri.scheme = uri.scheme == "https" ? "wss" : "ws"
      uri.path = "#{uri.path.to_s.sub(%r{/+\z}, "")}/api/sync"
      uri.query = nil
      uri.fragment = nil

      @websocket_url = uri.to_s
      @client_version = client_version
      @commands = Queue.new
      @wake_reader, @wake_writer = IO.pipe
      @wake_writer.sync = true
      @worker = Thread.new { run }
      @worker.name = "convex-live" if @worker.respond_to?(:name=)
    end

    def subscribe(path, args)
      request(:subscribe, path: path, args: deep_copy(args))
    end

    def unsubscribe(query_id)
      request(:unsubscribe, query_id: query_id)
    rescue ClosedError
      nil
    end

    def debug_disconnect
      request(:debug_disconnect)
    end

    def close
      request(:close)
      @worker.join
      nil
    rescue ClosedError
      nil
    end

    private

    def request(type, payload = {})
      response = Queue.new
      @commands << payload.merge(type: type, response: response)
      wake
      outcome, value = response.pop
      raise value if outcome == :error

      value
    end

    def wake
      @wake_writer.write_nonblock(".")
    rescue IO::WaitWritable, Errno::EPIPE
      nil
    end

    def run
      reset_state
      loop do
        process_commands
        break if @closed

        connect_if_due
        readable, = IO.select(readers, nil, nil, select_timeout)
        if readable&.include?(@wake_reader)
          @wake_reader.read_nonblock(4096) rescue nil
        end
        if @socket && (readable&.include?(@socket.io) || @socket.pending?)
          read_server_message
        end
        disconnect("InactiveServer", reconnect: true) if @socket && monotonic - @last_server_response > INACTIVITY_LIMIT
      rescue StandardError => error
        publish_protocol_error(error) if error.is_a?(ProtocolError)
        disconnect(error.message, reconnect: true)
      end
    ensure
      @socket&.close
      @subscriptions.each_value { |state| state[:subscription].finish }
      @wake_reader.close rescue nil
      @wake_writer.close rescue nil
    end

    def reset_state
      @subscriptions = {}
      @remote_results = {}
      @next_query_id = 0
      @query_set_version = 0
      @remote_version = zero_version
      @max_observed_timestamp = nil
      @connection_count = 0
      @last_close_reason = "InitialConnect"
      @next_backoff = INITIAL_BACKOFF
      @reconnect_at = nil
      @last_server_response = monotonic
      @socket = nil
      @closed = false
    end

    def process_commands
      loop do
        command = @commands.pop(true)
        case command[:type]
        when :subscribe
          add_subscription(command)
        when :unsubscribe
          remove_subscription(command)
        when :debug_disconnect
          debug_disconnect_command(command)
        when :close
          command[:response] << [:ok, nil]
          @closed = true
          @socket&.close
        end
      rescue ThreadError
        break
      rescue StandardError => error
        command[:response] << [:error, error]
      end
    end

    def add_subscription(command)
      query_id = @next_query_id
      @next_query_id += 1
      subscription = Subscription.new(self, query_id)
      @subscriptions[query_id] = {
        path: command[:path],
        args: command[:args],
        subscription: subscription
      }
      command[:response] << [:ok, subscription]

      if @socket
        modify_query_set([add_modification(query_id, @subscriptions.fetch(query_id))])
      else
        @reconnect_at = monotonic
      end
    end

    def remove_subscription(command)
      state = @subscriptions.delete(command[:query_id])
      @remote_results.delete(command[:query_id])
      if state
        state[:subscription].finish
        modify_query_set([{ "type" => "Remove", "queryId" => command[:query_id] }]) if @socket
      end
      @reconnect_at = nil if @subscriptions.empty?
      command[:response] << [:ok, nil]
    end

    def debug_disconnect_command(command)
      unless @socket
        raise TransportError.new("Live WebSocket is not connected", operation: "live")
      end

      disconnect("DebugDisconnect", reconnect: true)
      command[:response] << [:ok, nil]
    end

    def connect_if_due
      return if @socket || @subscriptions.empty?
      return if @reconnect_at && monotonic < @reconnect_at

      @socket = WebSocket.connect(@websocket_url, client_version: @client_version)
      @query_set_version = 0
      @remote_version = zero_version
      @remote_results = {}
      @last_server_response = monotonic
      connect_message = {
        "type" => "Connect",
        "sessionId" => SecureRandom.uuid,
        "connectionCount" => @connection_count,
        "lastCloseReason" => @last_close_reason,
        "clientTs" => 0
      }
      # The pinned profile omits this optional field on the first connection.
      connect_message["maxObservedTimestamp"] = @max_observed_timestamp if @max_observed_timestamp
      @socket.write_json(connect_message)

      unless @subscriptions.empty?
        modifications = @subscriptions.sort.map { |query_id, state| add_modification(query_id, state) }
        modify_query_set(modifications)
      end
      @reconnect_at = nil
    rescue StandardError => error
      @socket&.close_now
      @socket = nil
      @last_close_reason = error.message
      @connection_count += 1
      schedule_reconnect
    end

    def modify_query_set(modifications)
      @socket.write_json(
        "type" => "ModifyQuerySet",
        "baseVersion" => @query_set_version,
        "newVersion" => @query_set_version + 1,
        "modifications" => modifications
      )
      @query_set_version += 1
    end

    def add_modification(query_id, state)
      {
        "type" => "Add",
        "queryId" => query_id,
        "udfPath" => state[:path],
        "args" => [state[:args]]
      }
    end

    def read_server_message
      raw = @socket.read_message
      if raw.nil?
        disconnect("ServerClosed", reconnect: true)
        return
      end

      @last_server_response = monotonic
      @next_backoff = INITIAL_BACKOFF
      message = JSON.parse(raw)
      case message["type"]
      when "Transition"
        handle_transition(message)
      when "Ping", "MutationResponse", "ActionResponse"
        # This client currently sends HTTP mutations and actions only.
      when "FatalError", "AuthError"
        raise ProtocolError, "#{message["type"]}: #{message["error"]}"
      when "TransitionChunk"
        raise ProtocolError, "TransitionChunk assembly is not implemented by the Ruby demonstration"
      else
        raise ProtocolError, "unknown server message #{message["type"].inspect}"
      end
    rescue JSON::ParserError => error
      raise ProtocolError, "decode server message: #{error.message}"
    end

    def handle_transition(message)
      unless message["startVersion"] == @remote_version
        raise ProtocolError, "Transition start version does not match the local version"
      end

      changed = {}
      Array(message["modifications"]).each do |modification|
        query_id = modification.fetch("queryId")
        case modification["type"]
        when "QueryUpdated"
          update = Update.new(deep_copy(modification["value"]), nil, Array(modification["logLines"]))
          @remote_results[query_id] = update
          changed[query_id] = update
        when "QueryFailed"
          error = FunctionError.new(
            modification["errorMessage"].to_s,
            operation: "query",
            data: deep_copy(modification["errorData"]),
            logs: Array(modification["logLines"])
          )
          update = Update.new(nil, error, error.logs)
          @remote_results[query_id] = update
          changed[query_id] = update
        when "QueryRemoved"
          @remote_results.delete(query_id)
        else
          raise ProtocolError, "unknown Transition modification #{modification["type"].inspect}"
        end
      end

      # Commit the whole transition before any application callback observes it.
      @remote_version = message.fetch("endVersion")
      @max_observed_timestamp = @remote_version["ts"]
      changed.sort.each do |query_id, update|
        @subscriptions[query_id]&.fetch(:subscription)&.deliver(update)
      end
    end

    def publish_protocol_error(error)
      @subscriptions.each_value do |state|
        state[:subscription].deliver(Update.new(nil, error, []))
      end
    end

    def disconnect(reason, reconnect:)
      if @socket
        @socket.close_now
        @socket = nil
        @connection_count += 1
      end
      @last_close_reason = reason
      @query_set_version = 0
      @remote_version = zero_version
      @remote_results = {}
      schedule_reconnect if reconnect && !@subscriptions.empty?
    end

    def schedule_reconnect
      @reconnect_at = monotonic + @next_backoff
      @next_backoff = [@next_backoff * 2, MAX_BACKOFF].min
    end

    def readers
      [@wake_reader, @socket&.io].compact
    end

    def select_timeout
      return 0 if @socket&.pending?
      return 0.1 if @socket
      return 1.0 unless @reconnect_at

      [[@reconnect_at - monotonic, 0].max, 1.0].min
    end

    def zero_version
      { "querySet" => 0, "identity" => 0, "ts" => INITIAL_TIMESTAMP }
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
