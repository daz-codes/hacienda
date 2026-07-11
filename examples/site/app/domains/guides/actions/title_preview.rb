# frozen_string_literal: true

module Guides
  module TitlePreview
    def self.respond(_context, params)
      title = params[:title].to_s.strip
      title = "Untitled record" if title.empty?

      response <<~HTML
        <h3 id="record-title">#{Hacienda::HTML.escape(title)}</h3>
      HTML
    end
  end
end
