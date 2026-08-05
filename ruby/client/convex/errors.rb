# frozen_string_literal: true

module Convex
  class Error < StandardError; end

  # A Convex function ran and returned an application or developer error.
  class FunctionError < Error
    attr_reader :operation, :data, :logs

    def initialize(message, operation:, data: nil, logs: [])
      @operation = operation
      @data = data
      @logs = logs.freeze
      super("Convex #{operation} failed: #{message}")
    end
  end

  # A peer message did not match the pinned HTTP or Live contract.
  class ProtocolError < Error; end

  # HTTP or WebSocket transport failed before Convex produced a function result.
  class TransportError < Error
    attr_reader :operation, :cause

    def initialize(message, operation:, cause: nil)
      @operation = operation
      @cause = cause
      super("Convex #{operation} transport error: #{message}")
    end
  end

  class ClosedError < Error; end
end
