# frozen_string_literal: true

require "erb"

module Lunula
  class SafeHTML < String
    def initialize(value = "")
      super(value.to_s)
      freeze
    end
  end

  module HTML
    module_function

    def escape(value)
      return value if value.is_a?(SafeHTML)

      ERB::Util.html_escape(value)
    end

    def safe(value)
      return value if value.is_a?(SafeHTML)

      SafeHTML.new(value)
    end
  end
end
