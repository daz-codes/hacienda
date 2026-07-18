# frozen_string_literal: true

module Guides
  class Actions < Hacienda::Actions
    def blog(_context, _params)
      Samples::Blog.locals
    end

    def helium(_context, _params)
      Samples::Helium.locals
    end

    def store(_context, _params)
      source = File.read(File.expand_path("../../docs/getting-started.md", APP_ROOT))
      {document: Markdown.render(source)}
    end
  end
end
