# frozen_string_literal: true

require "erb"

module Lunula
  class Template < ERB
    class Compiler < ERB::Compiler
      def add_insert_cmd(output, content)
        output.push("#{@insert_cmd}(::Lunula::HTML.escape((#{content})))")
      end
    end

    def make_compiler(trim_mode)
      Compiler.new(trim_mode)
    end
  end
end
