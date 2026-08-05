# frozen_string_literal: true

require "json"
require "rbconfig"
require "net/http"
require "thread"
require "uri"

require_relative "convex/errors"
require_relative "convex/live"

module Convex
  # The result of a successful Convex function call. Keeping logs separate from
  # the returned value mirrors Convex's HTTP response instead of losing useful
  # diagnostics when the value is decoded.
  Result = Data.define(:value, :logs)

  # A small native Ruby client for Convex's documented JSON HTTP API and the
  # explicitly pinned convex-rs 0.10.4 realtime profile.
  class Client
    DEFAULT_CLIENT_VERSION = "ruby-0.1.0"
    MAX_RESPONSE_BYTES = 2 * 1024 * 1024
    VALID_OPERATIONS = %w[query mutation action].freeze

    attr_reader :deployment_url

    def initialize(deployment_url, bearer_token: nil, client_version: DEFAULT_CLIENT_VERSION)
      uri = URI.parse(deployment_url)
      unless %w[http https].include?(uri.scheme) && uri.host
        raise ArgumentError, "Convex deployment URL must use http or https and include a host"
      end
      raise ArgumentError, "Convex deployment URL must not include user information" if uri.userinfo

      uri.query = nil
      uri.fragment = nil
      uri.path = uri.path.to_s.sub(%r{/+\z}, "")

      @deployment_url = uri.to_s.sub(%r{/+\z}, "")
      @client_version = client_version
      @bearer_token = bearer_token.to_s
      @mutex = Mutex.new
      @closed = false
      @live_manager = nil
    rescue URI::InvalidURIError => error
      raise ArgumentError, "invalid Convex deployment URL: #{error.message}"
    end

    # Replace the bearer token used by later HTTP requests. An empty token
    # clears authentication. Live authentication is outside this experiment.
    def set_auth(token)
      @mutex.synchronize do
        raise ClosedError, "Convex client is closed" if @closed

        @bearer_token = token.to_s
      end
      nil
    end

    def query(path, args = {})
      call("query", path, args)
    end

    def mutation(path, args = {})
      call("mutation", path, args)
    end

    def action(path, args = {})
      call("action", path, args)
    end

    # Subscribe to a reactive query using the pinned unversioned /api/sync
    # protocol. The subscription's first update is the current query value.
    def subscribe(path, args = {})
      validate_function(path, args)
      manager = @mutex.synchronize do
        raise ClosedError, "Convex client is closed" if @closed

        @live_manager ||= LiveManager.new(@deployment_url, @client_version)
      end
      manager.subscribe(path, args)
    end

    # Close Live networking and reject future operations. This method is
    # intentionally idempotent so it is safe in an ensure block.
    def close
      manager = @mutex.synchronize do
        was_closed = @closed
        @closed = true
        was_closed ? nil : @live_manager
      end
      manager&.close
      nil
    end

    # This hook exists only for the black-box adapter. Normal application code
    # should never need to deliberately break its transport.
    def debug_disconnect_for_adapter
      manager = @mutex.synchronize do
        raise ClosedError, "Convex client is closed" if @closed

        @live_manager
      end
      raise TransportError.new("Live WebSocket is not connected", operation: "live") unless manager

      manager.debug_disconnect
    end

    private

    def call(operation, path, args)
      raise ArgumentError, "unknown Convex operation #{operation.inspect}" unless VALID_OPERATIONS.include?(operation)

      validate_function(path, args)
      token = @mutex.synchronize do
        raise ClosedError, "Convex client is closed" if @closed

        @bearer_token.dup
      end

      endpoint = URI.parse("#{@deployment_url}/api/#{operation}")
      request = Net::HTTP::Post.new(endpoint)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request["Convex-Client"] = @client_version
      request["Authorization"] = "Bearer #{token}" unless token.empty?
      request.body = JSON.generate(path: path, args: args, format: "json")

      response = Net::HTTP.start(
        endpoint.host,
        endpoint.port,
        use_ssl: endpoint.scheme == "https",
        open_timeout: 10,
        read_timeout: 30,
        write_timeout: 10
      ) { |http| http.request(request) }
      body = response.body.to_s
      if body.bytesize > MAX_RESPONSE_BYTES
        raise TransportError.new(
          "response exceeds #{MAX_RESPONSE_BYTES} bytes",
          operation: operation
        )
      end

      decoded = JSON.parse(body)
      case decoded["status"]
      when "success"
        raise ProtocolError, "success response omitted value" unless decoded.key?("value")

        Result.new(decoded["value"], Array(decoded["logLines"]))
      when "error"
        raise FunctionError.new(
          decoded["errorMessage"].to_s,
          operation: operation,
          data: decoded["errorData"],
          logs: Array(decoded["logLines"])
        )
      else
        raise ProtocolError, "HTTP #{response.code} response has unknown status #{decoded["status"].inspect}"
      end
    rescue FunctionError, ProtocolError, ClosedError, ArgumentError
      raise
    rescue JSON::ParserError => error
      raise TransportError.new(
        "HTTP response was not a Convex response: #{error.message}",
        operation: operation,
        cause: error
      )
    rescue StandardError => error
      raise TransportError.new(error.message, operation: operation, cause: error)
    end

    def validate_function(path, args)
      raise ArgumentError, "Convex function path is required" if path.to_s.empty?
      raise ArgumentError, "Convex arguments must be a named JSON object" unless args.is_a?(Hash)

      # Encoding here catches unsupported Ruby objects before a request or Live
      # command is allowed to modify client state.
      JSON.generate(args)
    rescue JSON::GeneratorError => error
      raise ArgumentError, "encode Convex arguments: #{error.message}"
    end
  end
end
