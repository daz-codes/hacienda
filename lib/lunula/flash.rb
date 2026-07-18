# frozen_string_literal: true

module Lunula
  class Flash
    SESSION_KEY = "lunula.flash"

    class Current
      include Enumerable

      def initialize(messages)
        @messages = messages
      end

      def [](key)
        @messages[key.to_s]
      end

      def []=(key, value)
        @messages[key.to_s] = value
      end

      def each(&block)
        @messages.each(&block)
      end

      def to_h
        @messages.dup
      end
    end

    include Enumerable

    def initialize(session, consume: true)
      @session = session
      messages = consume ? @session.delete(SESSION_KEY) : @session[SESSION_KEY]
      @current = normalize(messages || {})
      @now = Current.new(@current)
    end

    def [](key)
      @current[key.to_s]
    end

    def []=(key, value)
      next_messages[key.to_s] = value
    end

    def now
      @now
    end

    def each(&block)
      @current.each(&block)
    end

    def any?
      @current.any?
    end

    def to_h
      @current.dup
    end

    private

    def next_messages
      @session[SESSION_KEY] ||= {}
    end

    def normalize(messages)
      messages.each_with_object({}) do |(key, value), normalized|
        normalized[key.to_s] = value
      end
    end
  end
end
