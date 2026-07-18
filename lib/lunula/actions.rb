# frozen_string_literal: true

require "set"

module Lunula
  class Actions
    include Responses

    RESERVED_NAMES = (Responses.public_instance_methods(false) + %i[dispatch initialize]).to_set.freeze

    class << self
      def action_methods
        public_instance_methods(false).to_set.freeze
      end

      def action?(name)
        action_methods.include?(name.to_sym)
      end

      def validate!
        conflicts = defined_instance_methods & RESERVED_NAMES
        return self if conflicts.empty?

        names = conflicts.to_a.sort.map(&:inspect).join(", ")
        noun = conflicts.one? ? "name" : "names"
        raise Error, "#{self.name} defines reserved action #{noun} #{names}"
      end

      private

      def defined_instance_methods
        methods = public_instance_methods(false) +
          protected_instance_methods(false) +
          private_instance_methods(false)
        methods.to_set
      end
    end

    def dispatch(name, context, params)
      action = name.to_sym
      unless self.class.action?(action)
        raise NotFound, "action not found: #{self.class.name}##{action}"
      end

      public_send(action, context, params)
    end
  end
end
