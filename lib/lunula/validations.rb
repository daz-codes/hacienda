# frozen_string_literal: true

module Lunula
  class ValidationErrors
    include Enumerable

    def initialize
      @details = []
    end

    def add(attribute, message = nil)
      if message.nil?
        message = attribute
        attribute = :base
      end

      @details << [attribute.to_sym, message.to_s]
      nil
    end

    def [](attribute)
      @details
        .select { |name, _message| name == attribute.to_sym }
        .map { |_name, message| message }
    end

    def each(&block)
      full_messages.each(&block)
    end

    def any?
      @details.any?
    end

    def empty?
      @details.empty?
    end

    def clear
      @details.clear
    end

    def full_messages
      @details.map do |attribute, message|
        attribute == :base ? message : "#{humanize(attribute)} #{message}"
      end
    end

    def to_a
      full_messages
    end

    private

    def humanize(attribute)
      attribute.to_s.tr("_", " ").capitalize
    end
  end

  module Validations
    def errors
      @errors ||= ValidationErrors.new
    end

    def valid?(*arguments, **keywords, &block)
      errors.clear
      returned_errors = run_validate(*arguments, **keywords, &block)
      import_returned_errors(returned_errors)
      errors.empty?
    end

    def invalid?(*arguments, **keywords, &block)
      !valid?(*arguments, **keywords, &block)
    end

    private

    def run_validate(*arguments, **keywords, &block)
      return unless respond_to?(:validate, true)

      if keywords.empty?
        validate(*arguments, &block)
      else
        validate(*arguments, **keywords, &block)
      end
    end

    def import_returned_errors(returned_errors)
      return if errors.any?
      return if returned_errors.nil? || returned_errors.equal?(errors)

      case returned_errors
      when String
        errors.add(returned_errors)
      when Array
        returned_errors.each { |message| errors.add(message) }
      end
    end
  end
end
