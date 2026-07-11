# frozen_string_literal: true

module Guides
  module Store
    def self.respond(_context, _params)
      source = File.read(File.expand_path("../../docs/getting-started.md", APP_ROOT))
      {document: Markdown.render(source)}
    end
  end
end
