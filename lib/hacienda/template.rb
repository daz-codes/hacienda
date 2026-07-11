# frozen_string_literal: true

require "erb"

module Hacienda
  class Template < ERB
    class Compiler < ERB::Compiler
      def add_insert_cmd(output, content)
        output.push("#{@insert_cmd}(::Hacienda::HTML.escape((#{content})))")
      end
    end

    def make_compiler(trim_mode)
      Compiler.new(trim_mode)
    end
  end
end
