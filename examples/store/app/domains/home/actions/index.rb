# frozen_string_literal: true

module Home
  module Index
    def self.respond(_context, _params)
      {framework: "Hacienda", command: "hac"}
    end
  end
end
